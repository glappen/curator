module Curator
  class Retrieval < ApplicationRecord
    self.table_name = "curator_retrievals"

    STATUSES = %i[success failed].freeze
    ORIGINS  = %i[adhoc console console_review].freeze

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    belongs_to :chat,    class_name: "Chat",    optional: true
    belongs_to :message, class_name: "Message", optional: true

    has_many :retrieval_steps, class_name: "Curator::RetrievalStep", dependent: :destroy
    has_many :retrieval_hits,  class_name: "Curator::RetrievalHit",  dependent: :destroy
    has_many :evaluations,     class_name: "Curator::Evaluation",    dependent: :destroy

    enum :status, STATUSES.index_with(&:to_s)
    enum :origin, ORIGINS.index_with(&:to_s)

    validates :query, presence: true

    # Reconstruct a Curator::Answer from this row's persisted state.
    # Raises ArgumentError on rows with no assistant message
    # (Curator.retrieve-only rows or :failed asks). See
    # Curator::Answer.from_retrieval for the full contract.
    def to_answer
      Curator::Answer.from_retrieval(self)
    end

    # Open a new retrieval row that snapshots the effective config from
    # `pipeline` plus its KB. Returns nil when query logging is disabled,
    # so callers don't need to guard `Curator.config.log_queries`. The
    # `chat_extras` keyword splat carries chat-flavored snapshot columns
    # (strict_grounding, include_citations, chat_id) that the ask path
    # populates from the start so an early failure still records intent.
    def self.open_for(pipeline:, chat_model: nil, origin: :adhoc, **chat_extras)
      return nil unless Curator.config.log_queries
      kb = pipeline.knowledge_base

      create!(
        knowledge_base:       kb,
        query:                pipeline.query,
        chat_model:           chat_model || kb.chat_model,
        embedding_model:      kb.embedding_model,
        retrieval_strategy:   pipeline.strategy.to_s,
        similarity_threshold: pipeline.threshold,
        chunk_limit:          pipeline.limit,
        origin:               origin,
        **chat_extras
      )
    end

    def mark_failed!(error, started_at:)
      update!(
        status:            :failed,
        error_message:     "#{error.class}: #{error.message}",
        total_duration_ms: ((Time.current - started_at) * 1000).to_i
      )
    end

    def mark_success!(started_at:, **extras)
      update!(
        extras.merge(
          status:            :success,
          total_duration_ms: ((Time.current - started_at) * 1000).to_i
        )
      )
    end
  end
end
