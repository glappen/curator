module Curator
  module Retrievers
    # Shared retrieval core for `Curator.retrieve` and `Curator.ask`.
    # Owns input validation, KB resolution, effective-value (strategy /
    # limit / threshold) computation, query embedding, and strategy
    # dispatch with trace emission. Does *not* open or close
    # `curator_retrievals` rows — that's the caller's job, since each
    # caller (`Retriever` vs. `Asker`) writes a different snapshot
    # column set when the row is created.
    #
    # Constructor validates + resolves eagerly so any `ArgumentError`
    # raises *before* the caller has opened a retrieval row. Pipeline
    # exposes the resolved values via readers (`#knowledge_base`,
    # `#strategy`, `#limit`, `#threshold`) so the caller can populate
    # row snapshots from a single source of truth.
    class Pipeline
      STRATEGIES = %i[vector keyword hybrid].freeze

      attr_reader :query, :knowledge_base, :strategy, :limit, :threshold

      def self.call(retrieval_row = nil, **kwargs) = new(**kwargs).call(retrieval_row)

      def initialize(query:, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil)
        @query = query
        validate_query!
        validate_strategy!(strategy)

        @knowledge_base = KnowledgeBase.resolve(knowledge_base)
        @strategy       = (strategy || @knowledge_base.retrieval_strategy).to_sym
        @limit          = limit || @knowledge_base.chunk_limit
        validate_threshold_keyword_pairing!(threshold)
        @threshold      = effective_threshold(threshold)
      end

      # Run the retrieval and return the ordered hits. Caller owns the
      # `retrieval_row` lifecycle (open before the call, close after);
      # Pipeline only reads it to attach trace step rows and (when the
      # row is non-nil) bulk-insert the per-hit audit trail into
      # `curator_retrieval_hits`. Centralizing the write here means
      # both `Curator.retrieve` and `Curator.ask` get the same audit
      # trail through one site, and a failed insert flips the parent
      # row to `:failed` via the caller's existing `mark_failed!`.
      def call(retrieval_row)
        hits = execute_strategy(retrieval_row)
        persist_hits!(retrieval_row, hits) if retrieval_row
        hits
      end

      private

      def validate_query!
        return if @query.is_a?(String) && !@query.strip.empty?
        raise ArgumentError, "query must be a non-empty string"
      end

      def validate_strategy!(strategy_override)
        return if strategy_override.nil?
        return if STRATEGIES.include?(strategy_override.to_sym)
        raise ArgumentError,
              "strategy must be one of #{STRATEGIES.inspect} (got #{strategy_override.inspect})"
      end

      def validate_threshold_keyword_pairing!(threshold_override)
        return unless @strategy == :keyword
        return if threshold_override.nil?
        raise ArgumentError,
              "threshold: is meaningless for keyword retrieval (tsvector rank is not a probability)"
      end

      def effective_threshold(threshold_override)
        return nil if @strategy == :keyword
        threshold_override.nil? ? @knowledge_base.similarity_threshold.to_f : threshold_override.to_f
      end

      def execute_strategy(retrieval_row)
        # Embed once at the top for any strategy that needs a query
        # vector. Vector and Hybrid both consume the same `query_vec`;
        # Keyword ignores it. This guarantees hybrid never re-embeds.
        query_vec = needs_query_vec? ? embed_query(retrieval_row) : nil

        case @strategy
        when :vector  then run_vector(query_vec, retrieval_row)
        when :keyword then run_keyword(retrieval_row)
        when :hybrid  then run_hybrid(query_vec, retrieval_row)
        end
      end

      def needs_query_vec?
        @strategy == :vector || @strategy == :hybrid
      end

      def embed_query(retrieval_row)
        Curator::Tracing.record(
          retrieval:       retrieval_row,
          step_type:       :embed_query,
          payload_builder: ->(emb) { { model: emb.model, input_tokens: emb.input_tokens } }
        ) do
          RubyLLM.embed(@query, model: @knowledge_base.embedding_model)
        end.vectors
      rescue RubyLLM::Error, Neighbor::Error => e
        raise Curator::EmbeddingError, "query embedding failed (#{e.class}): #{e.message}"
      end

      def run_vector(query_vec, retrieval_row)
        Curator::Tracing.record(
          retrieval:       retrieval_row,
          step_type:       :vector_search,
          payload_builder: ->(hits) { { candidate_count: hits.size, top_chunk_ids: hits.first(5).map(&:chunk_id) } }
        ) do
          Curator::Retrievers::Vector.new.call(@knowledge_base, query_vec, limit: @limit, threshold: @threshold)
        end
      end

      def run_keyword(retrieval_row)
        Curator::Tracing.record(
          retrieval:       retrieval_row,
          step_type:       :keyword_search,
          payload_builder: ->(hits) { { candidate_count: hits.size, top_chunk_ids: hits.first(5).map(&:chunk_id) } }
        ) do
          Curator::Retrievers::Keyword.new.call(@knowledge_base, @query, limit: @limit)
        end
      end

      # Hybrid emits a single rrf_fusion trace step whose payload
      # captures the input list lengths and the fused output count.
      # We call Vector + Keyword directly here (rather than through
      # Hybrid#call) so we can pull candidate counts into the trace
      # payload without double-running anything.
      def run_hybrid(query_vec, retrieval_row)
        meta = { vector_count: 0, keyword_count: 0 }
        Curator::Tracing.record(
          retrieval: retrieval_row,
          step_type: :rrf_fusion,
          payload_builder: ->(hits) {
            {
              vector_candidate_count:  meta[:vector_count],
              keyword_candidate_count: meta[:keyword_count],
              fused_count:             hits.size,
              top_chunk_ids:           hits.first(5).map(&:chunk_id)
            }
          }
        ) do
          vector_hits  = Curator::Retrievers::Vector.new.call(@knowledge_base, query_vec, limit: @limit, threshold: @threshold)
          keyword_hits = Curator::Retrievers::Keyword.new.call(@knowledge_base, @query, limit: @limit)
          meta[:vector_count]  = vector_hits.size
          meta[:keyword_count] = keyword_hits.size
          Curator::Retrievers::Hybrid.fuse(vector_hits, keyword_hits, limit: @limit)
        end
      end

      # Snapshots `text` / `document_name` / `page_number` /
      # `source_url` so reconstruction survives downstream chunk
      # re-chunking and document deletion. One round-trip per
      # retrieval; failure raises and the caller's `mark_failed!`
      # wrapper flips the parent row to `:failed`.
      def persist_hits!(retrieval_row, hits)
        return if hits.empty?
        rows = hits.map do |h|
          {
            retrieval_id:  retrieval_row.id,
            chunk_id:      h.chunk_id,
            document_id:   h.document_id,
            rank:          h.rank,
            score:         h.score,
            document_name: h.document_name,
            page_number:   h.page_number,
            text:          h.text,
            source_url:    h.source_url
          }
        end
        Curator::RetrievalHit.insert_all!(rows)
      end
    end
  end
end
