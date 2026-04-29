module Curator
  class Document < ApplicationRecord
    include Turbo::Broadcastable

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

    # Phase 3 — KB index card refresh on doc create/update/destroy. The card
    # partial computes doc count + last-ingested-at, so any document change
    # to a KB's collection should re-render its card.
    after_create_commit  -> { broadcast_kb_card_refresh }
    after_update_commit  -> { broadcast_kb_card_refresh }
    after_destroy_commit -> { broadcast_kb_card_refresh }
    # ---- /Broadcasts ----

    private

    # Skip when the parent KB is itself being destroyed (cascade): the KB's
    # own `after_destroy_commit` will broadcast a `remove` for the same
    # frame, and rendering the card partial against an in-memory destroyed
    # KB would issue a count query that returns 0 against a row that no
    # longer exists.
    def broadcast_kb_card_refresh
      kb = knowledge_base
      return if kb.nil? || kb.destroyed?

      broadcast_replace_to "curator_knowledge_bases_index",
                           target:  ActionView::RecordIdentifier.dom_id(kb, :card),
                           partial: "curator/knowledge_bases/card",
                           locals:  { kb: kb }
    end
  end
end
