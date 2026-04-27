module Curator
  class Retrieval < ApplicationRecord
    self.table_name = "curator_retrievals"

    STATUSES = %i[success failed].freeze

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    belongs_to :chat,    class_name: "Chat",    optional: true
    belongs_to :message, class_name: "Message", optional: true

    has_many :retrieval_steps, class_name: "Curator::RetrievalStep", dependent: :destroy
    has_many :retrieval_hits,  class_name: "Curator::RetrievalHit",  dependent: :destroy
    has_many :evaluations,     class_name: "Curator::Evaluation",    dependent: :destroy

    enum :status, STATUSES.index_with(&:to_s)

    validates :query, presence: true

    # Reconstruct a Curator::Answer from this row's persisted state.
    # Raises ArgumentError on rows with no assistant message
    # (Curator.retrieve-only rows or :failed asks). See
    # Curator::Answer.from_retrieval for the full contract.
    def to_answer
      Curator::Answer.from_retrieval(self)
    end
  end
end
