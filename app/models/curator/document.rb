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
    # Phase 3 — KB index card refresh on doc create/update/destroy. The card
    # partial computes doc count + last-ingested-at, so any document change
    # to a KB's collection should re-render its card.
    after_create_commit  -> { broadcast_kb_card_refresh }
    after_update_commit  -> { broadcast_kb_card_refresh }
    after_destroy_commit -> { broadcast_kb_card_refresh }

    # Phase 4 — per-KB documents stream. The index page subscribes via
    # `turbo_stream_from kb, "documents"`. Status flips written from
    # `IngestDocumentJob` / `EmbedChunksJob` flow through `update` and
    # piggyback on `after_update_commit` — no extra wiring required.
    after_create_commit  -> { broadcast_document_row(:append) }
    after_update_commit  -> { broadcast_document_row(:replace) }
    after_destroy_commit -> { broadcast_document_row(:remove) }
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

    def broadcast_document_row(action)
      stream = [ knowledge_base, "documents" ]
      target = ActionView::RecordIdentifier.dom_id(self)

      case action
      when :append
        broadcast_append_to(stream,
                            target:  ActionView::RecordIdentifier.dom_id(knowledge_base, :documents),
                            partial: "curator/documents/document",
                            locals:  { document: self })
      when :replace
        broadcast_replace_to(stream,
                             target:  target,
                             partial: "curator/documents/document",
                             locals:  { document: self })
      when :remove
        broadcast_remove_to(stream, target: target)
      end
    end
  end
end
