module Curator
  module Retrieval
    # Mid-reembed safety: vector + hybrid only see embeddings whose
    # `embedding_model` column still matches the KB's current
    # `embedding_model`. During a model swap reembed, in-flight
    # cross-model vectors are invisible — better to temporarily shrink
    # the corpus than to mix cosines from incompatible models.
    # Keyword retrieval intentionally does not include this — pure
    # keyword does not need an embedding to be present.
    module EmbeddingScoped
      private

      def model_scoped_embeddings(kb)
        Curator::Embedding.where(embedding_model: kb.embedding_model)
      end
    end
  end
end
