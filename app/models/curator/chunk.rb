module Curator
  class Chunk < ApplicationRecord
    self.table_name = "curator_chunks"

    STATUSES = %i[pending embedded failed].freeze

    belongs_to :document, class_name: "Curator::Document"
    has_one    :embedding, class_name: "Curator::Embedding", dependent: :destroy

    enum :status, STATUSES.index_with(&:to_s)

    validates :sequence,    presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :content,     presence: true
    validates :token_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :char_start,  numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :char_end,    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :sequence,    uniqueness: { scope: :document_id }
  end
end
