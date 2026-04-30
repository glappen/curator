module Curator
  class DocumentsController < ApplicationController
    before_action :set_knowledge_base

    def index
      @documents = @knowledge_base.documents
                                  .where.not(status: :deleting)
                                  .order(created_at: :desc)
      # Single grouped aggregate keeps the row count constant in N. The
      # row partial falls back to `document.chunks.count` when this isn't
      # passed (the broadcast render path renders one row at a time).
      @chunk_counts = Chunk.where(document_id: @documents.pluck(:id))
                           .group(:document_id)
                           .count
    end

    def create
      files = Array(params[:files]).reject(&:blank?)

      if files.empty?
        redirect_to knowledge_base_documents_path(@knowledge_base),
                    alert: "No files were selected."
        return
      end

      counts = { created: 0, duplicate: 0, failed: 0 }
      failures = []

      files.each do |file|
        result = ingest_one(file)
        counts[result.status] += 1
        failures << result.reason if result.failed? && result.reason
      end

      redirect_to knowledge_base_documents_path(@knowledge_base),
                  notice: summary_flash(counts, failures)
    end

    # Async delete: a single doc with thousands of chunks/embeddings can
    # take seconds to cascade. Flip the row to :deleting (index scope
    # already hides it) so the operator sees the row vanish on the next
    # render, then hand off to DestroyDocumentJob.
    #
    # Transaction wraps the status flip + enqueue so a queue-adapter
    # failure rolls the row back instead of stranding it in :deleting.
    # Solid Queue (the v1 default) is DB-backed, so its enqueue is part
    # of the same transaction and rolls back too. Out-of-band adapters
    # like Sidekiq enqueue immediately on `perform_later`, so a rolled-
    # back transaction would leave a zombie job — but the job's
    # `find_by(id:)` short-circuits cleanly in that case.
    def destroy
      document = @knowledge_base.documents.find(params[:id])
      ActiveRecord::Base.transaction do
        document.update!(status: :deleting)
        DestroyDocumentJob.perform_later(document.id)
      end

      redirect_to knowledge_base_documents_path(@knowledge_base),
                  notice: "Document queued for deletion."
    end

    # Re-ingest: flip status back to :pending and enqueue. The chunk
    # teardown happens inside IngestDocumentJob (see #run_pipeline!) so
    # this stays cheap — a single UPDATE + enqueue. Subsequent job-side
    # status writes broadcast on the per-KB stream automatically.
    def reingest
      document = @knowledge_base.documents.find(params[:id])
      Curator.reingest(document)

      redirect_to knowledge_base_documents_path(@knowledge_base),
                  notice: "Re-ingesting \"#{document.title}\"."
    end

    private

    def set_knowledge_base
      @knowledge_base = KnowledgeBase.find_by!(slug: params[:knowledge_base_slug])
    end

    # Per-file rescue mirrors `Curator.ingest_directory`'s contract:
    # known ingest failures (bad MIME, oversized blob, validation
    # collision) are countable and the batch keeps going. Anything
    # outside that surface (DB outage, OOM, programming error)
    # propagates and aborts the request — those aren't "1 failed", they
    # mean the upload form itself is broken.
    def ingest_one(file)
      Curator.ingest(file, knowledge_base: @knowledge_base)
    rescue Curator::Error, ActiveRecord::RecordInvalid => e
      IngestResult.new(
        document: nil,
        status:   :failed,
        reason:   "#{e.class}: #{e.message}"
      )
    end

    # Show up to two unique failure reasons in the flash. A 50-file batch
    # with mixed errors (some oversize, some bad MIME) shouldn't collapse
    # to a single misleading cause; a 50-file batch with the same error
    # 50× shouldn't bloat the flash either.
    FAILURE_REASONS_IN_FLASH = 2

    def summary_flash(counts, failures)
      parts = [
        "#{counts[:created]} ingested",
        "#{counts[:duplicate]} duplicate",
        "#{counts[:failed]} failed"
      ]
      summary = parts.join(", ") + "."
      return summary if failures.empty?

      "#{summary} (#{failures.uniq.first(FAILURE_REASONS_IN_FLASH).join('; ')})"
    end
  end
end
