module Curator
  module Retrieval
    # Pure-vector retrieval: cosine over the pgvector HNSW index, gated
    # by the KB's current `embedding_model` so a mid-reembed window can't
    # serve cross-model cosines. `threshold` is a cosine-similarity
    # cutoff (1.0 = identical, 0.0 = orthogonal); hits below it are
    # dropped before ranking.
    class Vector
      include EmbeddingScoped

      def call(kb, query_vec, limit:, threshold:)
        return [] if query_vec.nil? || limit <= 0

        rows = model_scoped_embeddings(kb)
                 .nearest_neighbors(:embedding, query_vec, distance: "cosine")
                 .includes(chunk: :document)
                 .limit(limit)
                 .to_a

        rows
          .map     { |emb| [ emb, cosine_similarity(emb) ] }
          .reject  { |_, score| threshold && score < threshold }
          .each_with_index
          .map     { |(emb, score), idx| build_hit(emb, score, idx + 1) }
      end

      private

      # pgvector cosine distance is in [0, 2] (cos θ ∈ [-1, 1] →
      # distance = 1 - cos θ). Mapping back gives a similarity in
      # [-1, 1]. For typical LLM embedding distributions the value
      # stays positive, but we don't clamp — surfacing a negative
      # cosine truthfully is more useful than pretending it can't
      # happen, and `Hit#score` already documents the range.
      def cosine_similarity(embedding)
        1.0 - embedding.neighbor_distance.to_f
      end

      def build_hit(embedding, score, rank)
        chunk    = embedding.chunk
        document = chunk.document
        Curator::Hit.new(
          rank:          rank,
          chunk_id:      chunk.id,
          document_id:   document.id,
          document_name: document.title,
          page_number:   chunk.page_number,
          text:          chunk.content,
          score:         score,
          source_url:    document.source_url
        )
      end
    end
  end
end
