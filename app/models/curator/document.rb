module Curator
  class Document < ApplicationRecord
    self.table_name = "curator_documents"

    STATUSES = %i[pending extracting embedding complete failed].freeze

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    has_many   :chunks, class_name: "Curator::Chunk", dependent: :destroy

    has_one_attached :file

    enum :status, STATUSES.index_with(&:to_s)

    validates :title,        presence: true
    validates :content_hash, presence: true
    validates :mime_type,    presence: true
    validates :byte_size,    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
