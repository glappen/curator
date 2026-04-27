module Curator
  # Service object for `Curator.retrieve`. Thin wrapper around
  # `Curator::Retrievers::Pipeline`: opens a `curator_retrievals` row
  # (snapshotting effective config from the Pipeline), delegates the
  # actual retrieval to Pipeline, and closes the row with `:success` or
  # `:failed`. When `Curator.config.log_queries` is false no row is
  # written and `retrieval_id` is nil.
  class Retriever
    def initialize(query, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil)
      @raw_query          = query
      @knowledge_base     = knowledge_base
      @limit_override     = limit
      @threshold_override = threshold
      @strategy_override  = strategy
    end

    def call
      pipeline = Curator::Retrievers::Pipeline.new(
        query:          @raw_query,
        knowledge_base: @knowledge_base,
        limit:          @limit_override,
        threshold:      @threshold_override,
        strategy:       @strategy_override
      )

      retrieval_row = open_retrieval_row!(pipeline)
      run(pipeline, retrieval_row)
    end

    private

    def open_retrieval_row!(pipeline)
      return nil unless Curator.config.log_queries

      Curator::Retrieval.create!(
        knowledge_base:       pipeline.knowledge_base,
        query:                @raw_query,
        chat_model:           pipeline.knowledge_base.chat_model,
        embedding_model:      pipeline.knowledge_base.embedding_model,
        retrieval_strategy:   pipeline.strategy.to_s,
        similarity_threshold: pipeline.threshold,
        chunk_limit:          pipeline.limit
      )
    end

    def run(pipeline, retrieval_row)
      started_at = Time.current
      hits       = pipeline.call(retrieval_row)
      duration   = ((Time.current - started_at) * 1000).to_i

      retrieval_row&.update!(status: :success, total_duration_ms: duration)

      Curator::RetrievalResults.new(
        query:          @raw_query,
        hits:           hits,
        duration_ms:    duration,
        knowledge_base: pipeline.knowledge_base,
        retrieval_id:   retrieval_row&.id
      )
    rescue StandardError => e
      # Per CLAUDE.md "fail loud" rule, every failure flips the
      # already-opened retrieval row to :failed — programming bugs, DB
      # failures, Neighbor::Errors all need the row marked so operators
      # can see them in the retrievals admin view.
      mark_failed!(retrieval_row, started_at, e)
      raise
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
