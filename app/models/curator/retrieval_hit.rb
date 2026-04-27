module Curator
  # One row per Hit returned by a retrieval. Persists the audit trail
  # M5 admin and M7 evaluations need: rank + score + the snapshot
  # columns (text / document_name / page_number / source_url) that
  # let a past Q&A reconstruct itself even after `Curator.reingest`
  # destroys + recreates chunks or `document.destroy` removes them.
  #
  # Live FKs (`chunk_id`, `document_id`) are nullify-on-delete so
  # admin UIs can still link to the current chunk *when it exists*
  # and render a "source no longer available" affordance otherwise.
  class RetrievalHit < ApplicationRecord
    self.table_name = "curator_retrieval_hits"

    belongs_to :retrieval, class_name: "Curator::Retrieval"
    belongs_to :chunk,     class_name: "Curator::Chunk",    optional: true
    belongs_to :document,  class_name: "Curator::Document", optional: true

    validates :rank,          presence: true,
                              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :document_name, presence: true
    validates :text,          presence: true
  end
end
