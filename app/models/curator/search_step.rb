module Curator
  class SearchStep < ApplicationRecord
    self.table_name = "curator_search_steps"

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

    belongs_to :search, class_name: "Curator::Search"

    validates :sequence,    presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :sequence,    uniqueness: { scope: :search_id }
    validates :step_type,   inclusion: { in: STEP_TYPES.map(&:to_s) }
    validates :status,      inclusion: { in: STATUSES.map(&:to_s) }
    validates :started_at,  presence: true
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
