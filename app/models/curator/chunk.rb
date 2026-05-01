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

    # Bulk-rewrites `content_tsvector` for the given chunk ids using
    # `config` as the Postgres regconfig. Bypasses callbacks (raw SQL via
    # update_all) so it's safe to call from a row's after_save hook
    # without recursion. Used by both the per-chunk refresh callback and
    # the `:all` reembed scope that re-stems every chunk after a KB's
    # tsvector_config flip.
    def self.refresh_tsvector!(ids:, config:)
      where(id: ids).update_all([
        "content_tsvector = to_tsvector(?::regconfig, content)",
        config
      ])
    end

    private

    def refresh_content_tsvector
      self.class.refresh_tsvector!(ids: id, config: document.knowledge_base.tsvector_config)
    end
  end
end
