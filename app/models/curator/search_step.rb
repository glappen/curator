module Curator
  class SearchStep < ApplicationRecord
    self.table_name = "curator_search_steps"

    STEP_TYPES = %w[
      embed_query
      vector_search
      keyword_search
      rrf_fusion
      prompt_assembly
      llm_call
      tool_call
    ].freeze

    STATUSES = %w[success error].freeze

    belongs_to :search, class_name: "Curator::Search"

    validates :sequence,    presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :sequence,    uniqueness: { scope: :search_id }
    validates :step_type,   inclusion: { in: STEP_TYPES }
    validates :status,      inclusion: { in: STATUSES }
    validates :started_at,  presence: true
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
