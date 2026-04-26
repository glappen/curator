module Curator
  # Re-embed chunks for a knowledge base. Three scopes:
  #
  #   :stale   — :failed chunks plus :embedded chunks whose
  #              `embedding_model` no longer matches `kb.embedding_model`.
  #              Excludes :pending — those are mid-flight from normal
  #              ingestion; sweeping them up would race with in-progress
  #              EmbedChunksJobs.
  #   :failed  — only chunks in `:failed` status. Use to retry partial
  #              failures without touching model-stale `:embedded` rows.
  #   :all     — every chunk in the KB. Nukes embeddings and re-stems
  #              `content_tsvector` from the KB's current
  #              `tsvector_config` (the path operators take after
  #              flipping that setting).
  #
  # Returns a Result with counts so the rake task / admin UI can report
  # what it did.
  class Reembed
    SCOPES = %i[stale failed all].freeze

    Result = Data.define(:documents_touched, :chunks_touched, :scope)

    def initialize(knowledge_base: nil, scope: :stale)
      @kb    = resolve_kb(knowledge_base)
      @scope = scope.to_sym
      raise ArgumentError, "scope: must be one of #{SCOPES.inspect} (got #{scope.inspect})" \
        unless SCOPES.include?(@scope)
    end

    def call
      chunk_ids_by_doc = group_chunk_ids_by_document
      total_chunks     = chunk_ids_by_doc.values.sum(&:size)

      return Result.new(documents_touched: 0, chunks_touched: 0, scope: @scope) if total_chunks.zero?

      # Pre-flight only when there's work — avoids paying a provider
      # round-trip on a clean KB. Raises EmbeddingDimensionMismatch
      # before any row is touched.
      preflight_dim_check!

      chunk_ids_by_doc.each { |doc_id, chunk_ids| reembed_document!(doc_id, chunk_ids) }

      Result.new(
        documents_touched: chunk_ids_by_doc.size,
        chunks_touched:    total_chunks,
        scope:             @scope
      )
    end

    private

    def resolve_kb(kb)
      case kb
      when nil                  then KnowledgeBase.default!
      when KnowledgeBase        then kb
      when String, Symbol       then KnowledgeBase.find_by!(slug: kb.to_s)
      else
        raise ArgumentError,
              "knowledge_base: must be a Curator::KnowledgeBase, String, or " \
              "Symbol slug (got #{kb.class})"
      end
    end

    # Returns { document_id => [chunk_id, ...] } for chunks the scope
    # selects. Empty hash when nothing matches — caller short-circuits.
    def group_chunk_ids_by_document
      ids = scoped_chunks.pluck(:document_id, :id)
      ids.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    def scoped_chunks
      base = Curator::Chunk.joins(:document).where(curator_documents: { knowledge_base_id: @kb.id })
      case @scope
      when :all     then base
      when :failed  then base.where(curator_chunks: { status: :failed })
      when :stale   then stale_chunks(base)
      end
    end

    # :stale = (status = :failed) ∪ (has embedding row whose model ≠ KB's).
    # :pending chunks (no embedding row, status :pending) are explicitly
    # excluded — they're ingest in-flight, not stale.
    def stale_chunks(base)
      base.left_joins(:embedding).where(
        "curator_chunks.status = :failed OR " \
        "(curator_embeddings.id IS NOT NULL AND curator_embeddings.embedding_model != :model)",
        failed: "failed",
        model:  @kb.embedding_model
      )
    end

    def preflight_dim_check!
      # Always pass an array so RubyLLM returns Array<Array<Float>> —
      # avoids the "single string gets unwrapped" branch that would
      # need conditional unwrapping on the response side.
      result = RubyLLM.embed([ "a" ], model: @kb.embedding_model)
      actual = result.vectors.first.size
      expected = embedding_column_dim
      return if actual == expected

      raise Curator::EmbeddingDimensionMismatch.new(
        expected: expected, actual: actual, model: @kb.embedding_model
      )
    rescue RubyLLM::Error, Neighbor::Error => e
      # Mirror Searcher#embed_query: provider/network failures during
      # the pre-flight surface as Curator::EmbeddingError so callers
      # only have to rescue Curator's error hierarchy.
      raise Curator::EmbeddingError,
            "reembed pre-flight embed failed (#{e.class}): #{e.message}"
    end

    def embedding_column_dim
      Curator::Embedding.columns_hash["embedding"].sql_type[/\Avector\((\d+)\)\z/, 1].to_i
    end

    def reembed_document!(doc_id, chunk_ids)
      Curator::Chunk.transaction do
        Curator::Embedding.where(chunk_id: chunk_ids).delete_all
        Curator::Chunk.where(id: chunk_ids).update_all(status: "pending", embed_error: nil)
        # :all also re-stems content_tsvector with the KB's current
        # tsvector_config — chunk's after_save callback only fires on
        # content changes, so update_all bypassing callbacks is the
        # right tool here.
        if @scope == :all
          Curator::Chunk.where(id: chunk_ids).update_all([
            "content_tsvector = to_tsvector(?::regconfig, content)",
            @kb.tsvector_config
          ])
        end
        Curator::Document.where(id: doc_id).update_all(status: "embedding")
      end
      # Enqueue outside the transaction so the worker can't pick up the
      # doc before the commit is visible. Mirrors Curator.ingest.
      Curator::EmbedChunksJob.perform_later(doc_id)
    end
  end
end
