module Curator
  # Service object for `Curator.retrieve`. Thin wrapper around
  # `Curator::Retrievers::Pipeline`: opens a `curator_retrievals` row
  # (snapshotting effective config from the Pipeline), delegates the
  # actual retrieval to Pipeline, and closes the row with `:success` or
  # `:failed`. When `Curator.config.log_queries` is false no row is
  # written and `retrieval_id` is nil.
  class Retriever
    def self.call(...) = new(...).call

    def initialize(query, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil)
      @raw_query          = query
      @knowledge_base     = knowledge_base
      @limit_override     = limit
      @threshold_override = threshold
      @strategy_override  = strategy
    end

    def call
      pipeline      = Curator::Retrievers::Pipeline.new(
        query:          @raw_query,
        knowledge_base: @knowledge_base,
        limit:          @limit_override,
        threshold:      @threshold_override,
        strategy:       @strategy_override
      )
      retrieval_row = Curator::Retrieval.open_for(pipeline: pipeline)
      run(pipeline, retrieval_row)
    end

    private

    def run(pipeline, retrieval_row)
      started_at = Time.current
      hits       = pipeline.call(retrieval_row)
      retrieval_row&.mark_success!(started_at: started_at)

      Curator::RetrievalResults.new(
        query:          @raw_query,
        hits:           hits,
        duration_ms:    retrieval_row&.total_duration_ms || ((Time.current - started_at) * 1000).to_i,
        knowledge_base: pipeline.knowledge_base,
        retrieval_id:   retrieval_row&.id
      )
    rescue StandardError => e
      # Per CLAUDE.md "fail loud" rule, every failure flips the
      # already-opened retrieval row to :failed — programming bugs, DB
      # failures, Neighbor::Errors all need the row marked so operators
      # can see them in the retrievals admin view.
      retrieval_row&.mark_failed!(e, started_at: started_at)
      raise
    end
  end
end
