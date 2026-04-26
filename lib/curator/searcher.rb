module Curator
  # Service object for `Curator.search`. Resolves the KB, validates
  # input, embeds the query, runs the configured retrieval strategy,
  # and returns a `Curator::SearchResults`. Every call (regardless of
  # strategy) snapshots config onto a `curator_searches` row so
  # operators can replay / audit later — unless `config.log_queries`
  # is false, in which case no row is written and `search_id` is nil.
  class Searcher
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

      search_row = open_search_row!(kb, strategy: strategy, limit: limit, threshold: threshold)

      run(kb, strategy, limit, threshold, search_row)
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

    def open_search_row!(kb, strategy:, limit:, threshold:)
      return nil unless Curator.config.log_queries

      Curator::Search.create!(
        knowledge_base:       kb,
        query:                @raw_query,
        chat_model:           kb.chat_model,
        embedding_model:      kb.embedding_model,
        retrieval_strategy:   strategy.to_s,
        similarity_threshold: threshold,
        chunk_limit:          limit
      )
    end

    def run(kb, strategy, limit, threshold, search_row)
      started_at = Time.current
      hits       = execute_strategy(kb, strategy, limit, threshold, search_row)
      duration   = ((Time.current - started_at) * 1000).to_i

      search_row&.update!(status: :success, total_duration_ms: duration)

      Curator::SearchResults.new(
        query:          @raw_query,
        hits:           hits,
        duration_ms:    duration,
        knowledge_base: kb,
        search_id:      search_row&.id
      )
    rescue StandardError => e
      # Per CLAUDE.md "fail loud" rule, every failure flips the
      # already-opened search row to :failed — not just embedding
      # errors. Programming bugs, DB failures, Neighbor::Errors all
      # need the row marked so operators can see them in the searches
      # admin view.
      mark_failed!(search_row, started_at, e)
      raise
    end

    def execute_strategy(kb, strategy, limit, threshold, search_row)
      case strategy
      when :vector
        query_vec = embed_query(kb, search_row)
        run_vector(kb, query_vec, limit, threshold, search_row)
      when :keyword, :hybrid
        raise NotImplementedError, "strategy: #{strategy.inspect} arrives in M3 phase #{strategy == :keyword ? 4 : 5}"
      end
    end

    def embed_query(kb, search_row)
      Curator::Tracing.record(
        search:          search_row,
        step_type:       :embed_query,
        payload_builder: ->(emb) { { model: emb.model, input_tokens: emb.input_tokens } }
      ) do
        RubyLLM.embed(@raw_query, model: kb.embedding_model)
      end.vectors
    rescue RubyLLM::Error, Neighbor::Error => e
      raise Curator::EmbeddingError, "query embedding failed (#{e.class}): #{e.message}"
    end

    def run_vector(kb, query_vec, limit, threshold, search_row)
      Curator::Tracing.record(
        search:          search_row,
        step_type:       :vector_search,
        payload_builder: ->(hits) { { candidate_count: hits.size, top_chunk_ids: hits.first(5).map(&:chunk_id) } }
      ) do
        Curator::Retrieval::Vector.new.call(kb, query_vec, limit: limit, threshold: threshold)
      end
    end

    def mark_failed!(search_row, started_at, error)
      return if search_row.nil?
      search_row.update!(
        status:            :failed,
        error_message:     "#{error.class}: #{error.message}",
        total_duration_ms: ((Time.current - started_at) * 1000).to_i
      )
    end
  end
end
