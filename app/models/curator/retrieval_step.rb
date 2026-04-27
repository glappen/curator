module Curator
  class RetrievalStep < ApplicationRecord
    self.table_name = "curator_retrieval_steps"

    STEP_TYPES = %i[
      embed_query
      vector_search
      keyword_search
      rrf_fusion
      prompt_assembly
      llm_call
      tool_call
    ].freeze

    STATUSES = %i[success error].freeze

    belongs_to :retrieval, class_name: "Curator::Retrieval"

    validates :sequence,    presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :sequence,    uniqueness: { scope: :retrieval_id }
    validates :step_type,   inclusion: { in: STEP_TYPES.map(&:to_s) }
    validates :status,      inclusion: { in: STATUSES.map(&:to_s) }
    validates :started_at,  presence: true
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
