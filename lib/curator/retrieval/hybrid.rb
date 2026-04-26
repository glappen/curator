module Curator
  module Retrieval
    # Hybrid retrieval = vector ∪ keyword fused via Reciprocal Rank
    # Fusion (Neighbor::Reranking.rrf). The vector half is filtered by
    # `threshold` *before* fusion (Q3): bumping threshold high enough
    # to empty the vector list collapses hybrid to keyword-only —
    # operationally useful when an operator wants exact-match
    # semantics with hybrid still configured at the KB level.
    #
    # Hit#score carries the underlying cosine for chunks that came
    # through the vector half; keyword-only contributions get nil
    # (Q6). The fused RRF score is intentionally not exposed —
    # cosine and RRF are different units and conflating them in one
    # `score` field would mislead callers.
    #
    # Vector and Keyword are run sequentially; see m3 implementation
    # notes for why threading isn't on the table here.
    class Hybrid
      def call(kb, query, query_vec, limit:, threshold:)
        return [] if limit <= 0

        vector_hits  = Vector.new.call(kb, query_vec, limit: limit, threshold: threshold)
        keyword_hits = Keyword.new.call(kb, query, limit: limit)
        self.class.fuse(vector_hits, keyword_hits, limit: limit)
      end

      # Pure fusion of two ranked Hit lists. Public for the Searcher
      # which calls Vector + Keyword directly so it can record their
      # candidate counts in the rrf_fusion trace payload without
      # double-running the queries.
      def self.fuse(vector_hits, keyword_hits, limit:)
        return [] if limit <= 0

        vector_ids       = vector_hits.map(&:chunk_id)
        keyword_ids      = keyword_hits.map(&:chunk_id)
        return [] if vector_ids.empty? && keyword_ids.empty?

        vector_score_by_id = vector_hits.to_h { |h| [ h.chunk_id, h.score ] }
        # Build a chunk_id → Hit lookup. Vector hits overwrite keyword
        # ones for the same chunk so we prefer the vector copy as the
        # source of truth (text/title/page are identical between the
        # two — same chunk row — but the vector copy makes the
        # provenance easier to reason about when debugging).
        hits_by_id = {}
        keyword_hits.each { |h| hits_by_id[h.chunk_id] = h }
        vector_hits.each  { |h| hits_by_id[h.chunk_id] = h }

        fused = Neighbor::Reranking.rrf(vector_ids, keyword_ids)
        fused.first(limit).each_with_index.map do |row, idx|
          base = hits_by_id.fetch(row[:result])
          Curator::Hit.new(
            rank:          idx + 1,
            chunk_id:      base.chunk_id,
            document_id:   base.document_id,
            document_name: base.document_name,
            page_number:   base.page_number,
            text:          base.text,
            score:         vector_score_by_id[base.chunk_id],
            source_url:    base.source_url
          )
        end
      end
    end
  end
end
