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

    after_save :refresh_content_tsvector, if: :saved_change_to_content?

    private

    # Computes content_tsvector via the parent KB's tsvector_config and
    # writes it back via update_all so callbacks don't recurse. Note:
    # changing a KB's tsvector_config does NOT refresh existing chunks —
    # trigger a `:all` reembed (Phase 6) to rewrite their tsvectors.
    def refresh_content_tsvector
      self.class.where(id: id).update_all([
        "content_tsvector = to_tsvector(?::regconfig, content)",
        document.knowledge_base.tsvector_config
      ])
    end
  end
end
