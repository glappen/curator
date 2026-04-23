module Curator
  class Search < ApplicationRecord
    self.table_name = "curator_searches"

    STATUSES = %i[success failed].freeze

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    belongs_to :chat,    class_name: "Chat",    optional: true
    belongs_to :message, class_name: "Message", optional: true

    has_many :search_steps, class_name: "Curator::SearchStep", dependent: :destroy
    has_many :evaluations,  class_name: "Curator::Evaluation", dependent: :destroy

    enum :status, STATUSES.index_with(&:to_s)

    validates :query, presence: true
  end
end
