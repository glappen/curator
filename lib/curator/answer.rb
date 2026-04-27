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
  end
end
