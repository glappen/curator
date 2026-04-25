module Curator
  class IngestDocumentJob < ApplicationJob
    # TODO(Phase 5): extract -> chunk -> insert curator_chunks rows ->
    # enqueue EmbedChunksJob. This stub exists so Phase 4's Curator.ingest
    # can enqueue a real job class.
    def perform(document_id)
      document = Curator::Document.find(document_id)
      return unless document.pending?

      document.update!(status: :embedding)
      EmbedChunksJob.perform_later(document.id)
    end
  end
end
