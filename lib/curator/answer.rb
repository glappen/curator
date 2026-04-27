module Curator
  # Return value from Curator.ask. Wraps the assistant text plus the
  # underlying RetrievalResults and the bookkeeping callers need to tie
  # the ask back to its persisted artifacts: the curator_retrievals row
  # id (nil when config.log_queries is false) and the strict_grounding
  # flag *as snapshotted at query time* — flipping the KB later doesn't
  # retroactively change `refused?`.
  Answer = Data.define(:answer, :retrieval_results, :retrieval_id, :strict_grounding) do
    def sources  = retrieval_results.hits
    def refused? = retrieval_results.empty? && !!strict_grounding

    # Reconstruct an Answer from a persisted Curator::Retrieval row.
    # Hits come from `curator_retrieval_hits` snapshot rows so
    # downstream re-chunking (Curator.reingest) or document deletion
    # doesn't lose source text. Pre-Phase-5 rows (no hit rows)
    # reconstruct to `sources == []` rather than raising — the
    # migration is forward-only and historical rows degrade gracefully.
    #
    # Raises ArgumentError on rows with no assistant message
    # (`message_id: nil`): Curator.retrieve-only rows and :failed
    # asks have an audit trail but no Answer to reconstruct.
    def self.from_retrieval(retrieval)
      if retrieval.message_id.nil?
        raise ArgumentError,
              "cannot reconstruct Answer from retrieval ##{retrieval.id}: " \
              "no assistant message (Curator.retrieve-only or :failed ask)"
      end

      # `retrieval.message_id` has no DB-level FK to `messages` (the
      # column is a plain bigint, since RubyLLM owns that table). Host
      # apps that prune old `messages` rows can leave a dangling
      # message_id behind — surface that as a clean ArgumentError
      # instead of a NoMethodError on `nil.content`.
      message = retrieval.message
      if message.nil?
        raise ArgumentError,
              "cannot reconstruct Answer from retrieval ##{retrieval.id}: " \
              "message ##{retrieval.message_id} no longer exists"
      end

      hits = retrieval.retrieval_hits.order(:rank).map do |hit_row|
        Curator::Hit.new(
          rank:          hit_row.rank,
          chunk_id:      hit_row.chunk_id,
          document_id:   hit_row.document_id,
          document_name: hit_row.document_name,
          page_number:   hit_row.page_number,
          text:          hit_row.text,
          score:         hit_row.score&.to_f,
          source_url:    hit_row.source_url
        )
      end

      retrieval_results = Curator::RetrievalResults.new(
        query:          retrieval.query,
        hits:           hits,
        duration_ms:    retrieval.total_duration_ms,
        knowledge_base: retrieval.knowledge_base,
        retrieval_id:   retrieval.id
      )

      new(
        answer:            message.content,
        retrieval_results: retrieval_results,
        retrieval_id:      retrieval.id,
        strict_grounding:  retrieval.strict_grounding
      )
    end
  end
end
