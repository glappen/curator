module Curator
  class Embedding < ApplicationRecord
    include Turbo::Broadcastable

    self.table_name = "curator_embeddings"

    belongs_to :chunk, class_name: "Curator::Chunk"

    has_neighbors :embedding

    validates :chunk_id,         uniqueness: true
    validates :embedding,       presence: true
    validates :embedding_model, presence: true

    # Pulls the embedding column's vector dimension from the schema once
    # per process. The value is fixed at install time (`--embedding-dim`)
    # and only changes via a migration + reembed, so caching is safe and
    # avoids deserializing a 1536-float pgvector column just to call
    # `.size` on it from the chunk inspector.
    def self.dimension
      @dimension ||= columns_hash["embedding"].sql_type[/\Avector\((\d+)\)\z/, 1].to_i
    end

    # ---- Broadcasts (M5 Phase 6) ----
    # The doc-show header carries an "X of Y embedded" counter that has
    # to stay in sync as `EmbedChunksJob` writes embeddings. Broadcast
    # the parent document's header on every embedding create/destroy —
    # the partial recomputes the counter on render. Suppressed in
    # non-broadcast specs via spec/support/turbo_helpers.rb.
    after_create_commit  -> { broadcast_header_replace }
    after_destroy_commit -> { broadcast_header_replace }
    # ---- /Broadcasts ----

    private

    # Skip when the chunk or document is in the process of being destroyed
    # (cascade): rendering the header partial against a missing parent
    # would issue a count query that returns 0 against a row that no
    # longer exists, and the doc's own `after_destroy_commit` will tear
    # the frame down anyway.
    def broadcast_header_replace
      doc = chunk&.document
      return if doc.nil? || doc.destroyed?

      broadcast_replace_to doc,
                           target:  ActionView::RecordIdentifier.dom_id(doc, :header),
                           partial: "curator/documents/header",
                           locals:  { document: doc }
    end
  end
end
