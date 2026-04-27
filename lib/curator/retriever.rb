module Curator
  # Service object for `Curator.retrieve`. Resolves the KB, validates
  # input, embeds the query, runs the configured retrieval strategy,
  # and returns a `Curator::RetrievalResults`. Every call (regardless of
  # strategy) snapshots config onto a `curator_retrievals` row so
  # operators can replay / audit later — unless `config.log_queries`
  # is false, in which case no row is written and `retrieval_id` is nil.
  class Retriever
    STRATEGIES = %i[vector keyword hybrid].freeze

    def initialize(query, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil)
      @raw_query        = query
      @knowledge_base   = knowledge_base
      @limit_override   = limit
      @threshold_override = threshold
      @strategy_override = strategy
    end

    def call
      validate_query!
      validate_strategy!

      kb        = resolve_kb
      strategy  = (@strategy_override || kb.retrieval_strategy).to_sym
      limit     = @limit_override || kb.chunk_limit
      threshold = effective_threshold(kb, strategy)

      validate_threshold!(strategy, threshold)

      retrieval_row = open_retrieval_row!(kb, strategy: strategy, limit: limit, threshold: threshold)

      run(kb, strategy, limit, threshold, retrieval_row)
    end

    private

    def validate_query!
      return if @raw_query.is_a?(String) && !@raw_query.strip.empty?
      raise ArgumentError, "query must be a non-empty string"
    end

    def validate_strategy!
      return if @strategy_override.nil?
      return if STRATEGIES.include?(@strategy_override.to_sym)
      raise ArgumentError, "strategy must be one of #{STRATEGIES.inspect} (got #{@strategy_override.inspect})"
    end

    def validate_threshold!(strategy, _threshold)
      return unless strategy == :keyword
      return if @threshold_override.nil?
      raise ArgumentError, "threshold: is meaningless for keyword retrieval (tsvector rank is not a probability)"
    end

    def resolve_kb
      case @knowledge_base
      when nil                  then KnowledgeBase.default!
      when KnowledgeBase        then @knowledge_base
      when String, Symbol       then KnowledgeBase.find_by!(slug: @knowledge_base.to_s)
      else
        raise ArgumentError,
              "knowledge_base: must be a Curator::KnowledgeBase, String, or " \
              "Symbol slug (got #{@knowledge_base.class})"
      end
    end

    def effective_threshold(kb, strategy)
      return nil if strategy == :keyword
      override = @threshold_override
      override.nil? ? kb.similarity_threshold.to_f : override.to_f
    end

    def open_retrieval_row!(kb, strategy:, limit:, threshold:)
      return nil unless Curator.config.log_queries

      Curator::Retrieval.create!(
        knowledge_base:       kb,
        query:                @raw_query,
        chat_model:           kb.chat_model,
        embedding_model:      kb.embedding_model,
        retrieval_strategy:   strategy.to_s,
        similarity_threshold: threshold,
        chunk_limit:          limit
      )
    end

    def run(kb, strategy, limit, threshold, retrieval_row)
      started_at = Time.current
      hits       = execute_strategy(kb, strategy, limit, threshold, retrieval_row)
      duration   = ((Time.current - started_at) * 1000).to_i

      retrieval_row&.update!(status: :success, total_duration_ms: duration)

      Curator::RetrievalResults.new(
        query:          @raw_query,
        hits:           hits,
        duration_ms:    duration,
        knowledge_base: kb,
        retrieval_id:   retrieval_row&.id
      )
    rescue StandardError => e
      # Per CLAUDE.md "fail loud" rule, every failure flips the
      # already-opened retrieval row to :failed — not just embedding
      # errors. Programming bugs, DB failures, Neighbor::Errors all
      # need the row marked so operators can see them in the retrievals
      # admin view.
      mark_failed!(retrieval_row, started_at, e)
      raise
    end

    def execute_strategy(kb, strategy, limit, threshold, retrieval_row)
      # Embed once at the top for any strategy that needs a query
      # vector. Vector and Hybrid both consume the same `query_vec`;
      # Keyword ignores it. This guarantees hybrid never re-embeds.
      query_vec = needs_query_vec?(strategy) ? embed_query(kb, retrieval_row) : nil

      case strategy
      when :vector  then run_vector(kb, query_vec, limit, threshold, retrieval_row)
      when :keyword then run_keyword(kb, limit, retrieval_row)
      when :hybrid  then run_hybrid(kb, query_vec, limit, threshold, retrieval_row)
      end
    end

    def needs_query_vec?(strategy)
      strategy == :vector || strategy == :hybrid
    end

    def embed_query(kb, retrieval_row)
      Curator::Tracing.record(
        retrieval:       retrieval_row,
        step_type:       :embed_query,
        payload_builder: ->(emb) { { model: emb.model, input_tokens: emb.input_tokens } }
      ) do
        RubyLLM.embed(@raw_query, model: kb.embedding_model)
      end.vectors
    rescue RubyLLM::Error, Neighbor::Error => e
      raise Curator::EmbeddingError, "query embedding failed (#{e.class}): #{e.message}"
    end

    def run_vector(kb, query_vec, limit, threshold, retrieval_row)
      Curator::Tracing.record(
        retrieval:       retrieval_row,
        step_type:       :vector_search,
        payload_builder: ->(hits) { { candidate_count: hits.size, top_chunk_ids: hits.first(5).map(&:chunk_id) } }
      ) do
        Curator::Retrievers::Vector.new.call(kb, query_vec, limit: limit, threshold: threshold)
      end
    end

    def run_keyword(kb, limit, retrieval_row)
      Curator::Tracing.record(
        retrieval:       retrieval_row,
        step_type:       :keyword_search,
        payload_builder: ->(hits) { { candidate_count: hits.size, top_chunk_ids: hits.first(5).map(&:chunk_id) } }
      ) do
        Curator::Retrievers::Keyword.new.call(kb, @raw_query, limit: limit)
      end
    end

    # Hybrid emits a single rrf_fusion trace step whose payload
    # captures the input list lengths and the fused output count
    # (per Phase 5 spec). We call Vector + Keyword directly here
    # rather than through Hybrid#call so we can pull the candidate
    # counts into the trace payload without double-running anything.
    def run_hybrid(kb, query_vec, limit, threshold, retrieval_row)
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
        vector_hits  = Curator::Retrievers::Vector.new.call(kb, query_vec, limit: limit, threshold: threshold)
        keyword_hits = Curator::Retrievers::Keyword.new.call(kb, @raw_query, limit: limit)
        meta[:vector_count]  = vector_hits.size
        meta[:keyword_count] = keyword_hits.size
        Curator::Retrievers::Hybrid.fuse(vector_hits, keyword_hits, limit: limit)
      end
    end

    def mark_failed!(retrieval_row, started_at, error)
      return if retrieval_row.nil?
      retrieval_row.update!(
        status:            :failed,
        error_message:     "#{error.class}: #{error.message}",
        total_duration_ms: ((Time.current - started_at) * 1000).to_i
      )
    end
  end
end
