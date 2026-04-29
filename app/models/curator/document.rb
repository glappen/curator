module Curator
  class Document < ApplicationRecord
    self.table_name = "curator_documents"

    STATUSES = %i[pending extracting embedding complete failed deleting].freeze

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    has_many   :chunks, class_name: "Curator::Chunk", dependent: :destroy

    has_one_attached :file

    enum :status, STATUSES.index_with(&:to_s)

    validates :title,        presence: true
    validates :content_hash, presence: true
    validates :mime_type,    presence: true
    validates :byte_size,    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def failed_chunk_count
      chunks.where(status: :failed).count
    end

    def partially_embedded?
      failed_chunk_count.positive?
    end

    # ---- Broadcasts (M5) ----
    # Phases 3 and 4 each append `after_*_commit` broadcast callbacks here
    # in parallel worktrees:
    #   - Phase 3: KB-card refresh on the "curator_knowledge_bases_index" stream
    #   - Phase 4: per-KB document row replace/append/remove on `[kb, "documents"]`
    # This region exists so both phases insert between the markers and the
    # textual merge stays trivial.
    # ---- /Broadcasts ----
  end
end
