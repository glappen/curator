module Curator
  class Embedding < ApplicationRecord
    self.table_name = "curator_embeddings"

    belongs_to :chunk, class_name: "Curator::Chunk"

    has_neighbors :embedding

    validates :chunk_id,         uniqueness: true
    validates :embedding,       presence: true
    validates :embedding_model, presence: true
  end
end
