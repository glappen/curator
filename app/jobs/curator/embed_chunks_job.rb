module Curator
  class EmbedChunksJob < ApplicationJob
    # TODO(M3): real embedding pipeline. Until then, flipping the document
    # to :complete lets the Phase 5 job hand off to an end-to-end green
    # smoke test without pulling in OpenAI/pgvector work.
    def perform(document)
      document.update!(status: :complete)
    end
  end
end
