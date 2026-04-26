module Curator
  class EmbedChunksJob < ApplicationJob
    # Per-input rejection from OpenAI surfaces as a 400 that fails the
    # whole batch — there is no partial-success response shape. When we
    # see one of these, we re-issue per chunk to identify the bad inputs
    # and mark them :failed individually. UnauthorizedError /
    # PaymentRequiredError / ForbiddenError are also 4xx but are config
    # problems, not input problems — let those raise so AJ surfaces them.
    PER_INPUT_ERRORS = [
      RubyLLM::BadRequestError,
      RubyLLM::ContextLengthExceededError
    ].freeze

    def perform(document_id)
      document = Curator::Document.find_by(id: document_id)
      return unless document
      return unless document.embedding?

      kb      = document.knowledge_base
      pending = document.chunks.where(status: :pending).order(:sequence).to_a
      pending.each_slice(Curator.config.embedding_batch_size) { |slice| embed_batch!(slice, kb) }

      finalize_document!(document)
    end

    private

    def embed_batch!(chunks, kb)
      result = RubyLLM.embed(chunks.map(&:content), model: kb.embedding_model)

      Curator::Embedding.transaction do
        chunks.zip(result.vectors).each { |chunk, vector| persist_embedding!(chunk, vector, kb.embedding_model) }
      end
    rescue *PER_INPUT_ERRORS
      embed_one_by_one!(chunks, kb)
    end

    def embed_one_by_one!(chunks, kb)
      chunks.each do |chunk|
        result = RubyLLM.embed(chunk.content, model: kb.embedding_model)
        persist_embedding!(chunk, result.vectors, kb.embedding_model)
      rescue *PER_INPUT_ERRORS => e
        chunk.update!(status: :failed, embed_error: "#{e.class}: #{e.message}")
      end
    end

    def persist_embedding!(chunk, vector, embedding_model)
      Curator::Embedding.create!(
        chunk:           chunk,
        embedding:       vector,
        embedding_model: embedding_model
      )
      chunk.update!(status: :embedded, embed_error: nil)
    end

    # Document is :complete once every chunk is terminal (:embedded or
    # :failed). Per the M3 ideation: a partially-failed doc is still
    # complete — surfaced via Document#partially_embedded? and the admin
    # "needs attention" panel, not by blocking the doc forever.
    def finalize_document!(document)
      return if document.chunks.where(status: :pending).exists?
      document.update!(status: :complete)
    end
  end
end
