module Curator
  module Retrievers
    # Pure-keyword retrieval over the GIN-indexed `content_tsvector`
    # column. Joins through `documents` (not `embeddings`) so chunks in
    # `:pending` or `:failed` status are still queryable — keyword
    # search is the fallback that works without any embedding present.
    # The tsvector config used at *query* time matches the KB's
    # `tsvector_config`, which is the same regconfig that Phase 1's
    # `after_save` callback used at index time. Mismatched configs
    # silently miss matches (different stemmers), so this symmetry is
    # load-bearing.
    #
    # Hit#score is nil for keyword retrieval — tsvector ranks are
    # length-dependent and not directly comparable to cosine, so we
    # don't pretend they are. See Q6 in features/m3-embedding-retrieval.md.
    class Keyword
      def call(kb, query, limit:)
        return [] if query.nil? || query.to_s.strip.empty? || limit <= 0

        scope = matching_chunks(kb, query).limit(limit)

        scope.each_with_index.map { |chunk, idx| build_hit(chunk, idx + 1) }
      end

      private

      def matching_chunks(kb, query)
        # `sanitize_sql_array` quotes the regconfig + query so we can
        # interpolate the same `plainto_tsquery(...)` expression into
        # both the WHERE filter and the ORDER BY rank without binding
        # the same parameter twice. Raw `?` placeholders work in
        # `where`, but `order(Arel.sql(...))` doesn't accept binds —
        # interpolating a sanitized fragment is the standard escape
        # hatch.
        tsquery_sql = ActiveRecord::Base.sanitize_sql_array([
          "plainto_tsquery(?::regconfig, ?)", kb.tsvector_config, query
        ])

        Curator::Chunk
          .joins(:document)
          .where(curator_documents: { knowledge_base_id: kb.id })
          .where("curator_chunks.content_tsvector @@ #{tsquery_sql}")
          .order(Arel.sql("ts_rank(curator_chunks.content_tsvector, #{tsquery_sql}) DESC, curator_chunks.id ASC"))
          .includes(:document)
      end

      def build_hit(chunk, rank)
        document = chunk.document
        Curator::Hit.new(
          rank:          rank,
          chunk_id:      chunk.id,
          document_id:   document.id,
          document_name: document.title,
          page_number:   chunk.page_number,
          text:          chunk.content,
          score:         nil,
          source_url:    document.source_url
        )
      end
    end
  end
end
