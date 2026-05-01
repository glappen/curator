module Curator
  class EmbedChunksJob < ApplicationJob
    def perform(document_id)
      document = Curator::Document.find_by(id: document_id)
      return unless document
      return unless document.embedding?

      Curator::Documents::EmbedChunks.call(document)
    end
  end
end
