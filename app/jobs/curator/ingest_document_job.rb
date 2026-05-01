module Curator
  class IngestDocumentJob < ApplicationJob
    # Phase 5: extract -> chunk -> persist curator_chunks rows -> hand off
    # to EmbedChunksJob. Failures of the pipeline land the document in
    # :failed with stage_error populated and an error log entry; the job
    # does not re-raise extraction failures so ActiveJob retries don't
    # churn on what are usually deterministic input-quality failures
    # (bad PDF, unsupported MIME, empty file).
    def perform(document_id)
      # find_by(id:) instead of find: a doc deleted between enqueue and
      # execution should be a silent no-op, not RecordNotFound (which
      # would still be a StandardError but would crash the failure-path
      # rescue in prepare_for_embedding since `document` would be unbound).
      document = Curator::Document.find_by(id: document_id)
      return unless document

      prepare_for_embedding(document) if document.pending?

      # Enqueue is intentionally outside the rescue and outside the
      # transaction. Two reasons:
      #
      # 1. If perform_later raises (queue down), the chunks are already
      #    persisted — propagating the error to ActiveJob lets the queue
      #    adapter retry the job. On retry, document.pending? is false
      #    but document.embedding? is true, so we hit the recovery path
      #    here and just re-enqueue without re-extracting.
      # 2. Enqueueing inside the transaction races: a worker could pick
      #    up the doc before COMMIT made its chunks visible.
      EmbedChunksJob.perform_later(document.id) if document.embedding? && document.chunks.exists?
    end

    private

    def prepare_for_embedding(document)
      Curator::Documents::ExtractAndChunk.call(document)
    rescue StandardError => e
      Rails.logger.error(
        "[Curator] IngestDocumentJob failed for document=#{document.id}: #{e.class}: #{e.message}"
      )
      document.update!(status: :failed, stage_error: "#{e.class}: #{e.message}")
    end
  end
end
