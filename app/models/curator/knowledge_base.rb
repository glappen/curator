module Curator
  class KnowledgeBase < ApplicationRecord
    self.table_name = "curator_knowledge_bases"

    has_many :documents, class_name: "Curator::Document", dependent: :destroy
    has_many :searches,  class_name: "Curator::Search",   dependent: :destroy

    validates :name, presence: true
    validates :slug,
              presence: true,
              uniqueness: true,
              format: { with: /\A[a-z0-9_-]+\z/ }
    validates :embedding_model,      presence: true
    validates :chat_model,           presence: true
    validates :chunk_size,           numericality: { only_integer: true, greater_than: 0 }
    validates :chunk_overlap,        numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :similarity_threshold, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :retrieval_strategy,   inclusion: { in: %w[hybrid vector keyword] }

    before_save :unset_prior_default, if: -> { is_default? && is_default_changed? }

    private

    def unset_prior_default
      self.class.where(is_default: true).where.not(id: id).update_all(is_default: false)
    end
  end
end
