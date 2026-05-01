module Curator
  class DocumentsController < ApplicationController
    include Curator::PaginationHelper

    before_action :set_knowledge_base

    def index
      scope     = @knowledge_base.documents
                                 .where.not(status: :deleting)
                                 .order(created_at: :desc)
      @page     = paginate(scope, page: params[:page], per: params[:per])
      @documents = @page.records
      # Single grouped aggregate keeps the row count constant in N. The
      # row partial falls back to `document.chunks.count` when this isn't
      # passed (the broadcast render path renders one row at a time).
      @chunk_counts = Chunk.where(document_id: @documents.pluck(:id))
                           .group(:document_id)
                           .count
    end

    def show
      @document = @knowledge_base.documents.find(params[:id])
      scope     = @document.chunks.order(:sequence)
      @page     = paginate(scope, page: params[:page], per: params[:per])
      @chunks   = @page.records
      # Preload embeddings keyed by chunk_id so the per-chunk partial can
      # render the badge + model + dim + embedded-at without an N+1. The
      # KB's current `embedding_model` is the one we count as "embedded";
      # rows with a stale model are treated as missing so a model swap
      # surfaces as work-to-redo in the inspector. Explicit `select`
      # excludes the `embedding` vector column — pulling N×1536 floats
      # back just to render a model name + timestamp is ~600KB of
      # wire/heap waste per show-page render at per=100.
      chunk_ids = @chunks.map(&:id)
      @embeddings_by_chunk_id = Embedding
        .select(:id, :chunk_id, :embedding_model, :created_at)
        .where(chunk_id: chunk_ids, embedding_model: @knowledge_base.embedding_model)
        .index_by(&:chunk_id)
    end

    def create
      files = Array(params[:files]).reject(&:blank?)
      if files.empty?
        redirect_to knowledge_base_documents_path(@knowledge_base),
                    alert: "No files were selected."
        return
      end

      result = Documents::IngestBatch.call(kb: @knowledge_base, files: files)
      redirect_to knowledge_base_documents_path(@knowledge_base),
                  notice: summary_flash(result.counts, result.failures)
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
