module Curator
  class Retrieval < ApplicationRecord
    self.table_name = "curator_retrievals"

    STATUSES = %i[success failed].freeze
    ORIGINS  = %i[adhoc console console_review chat_tool].freeze

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    # `::Chat` / `::Message` — bare `"Chat"` would resolve inside the
    # enclosing `Curator` module to `Curator::Chat` (the M8 wrapper)
    # instead of RubyLLM's AR-backed `Chat`. Same hazard with
    # `Message` (none today, but cheap parity).
    belongs_to :chat,    class_name: "::Chat",    optional: true
    belongs_to :message, class_name: "::Message", optional: true

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

    # Filter scope that mirrors the querystring contract on
    # `RetrievalsController#index` so the same filter form drives both
    # the on-screen table and the export.
    def self.with_filters(filters)
      scope = all
      scope = scope.where(origin: %w[adhoc console]) unless truthy?(filters[:show_review])
      scope = scope.where(knowledge_base_id: filters[:knowledge_base_id]) if filters[:knowledge_base_id].present?
      if filters[:kb_slug].present?
        scope = scope.joins(:knowledge_base)
                     .where(curator_knowledge_bases: { slug: filters[:kb_slug] })
      end
      if (from = parse_date(filters[:from]))
        scope = scope.where("created_at >= ?", from)
      end
      if (to = parse_date(filters[:to]))
        scope = scope.where("created_at <  ?", to + 1)
      end
      scope = scope.where(status: filters[:status])                   if filters[:status].present?
      scope = scope.where(chat_model: filters[:chat_model])           if filters[:chat_model].present?
      scope = scope.where(embedding_model: filters[:embedding_model]) if filters[:embedding_model].present?
      scope = scope.where("query ILIKE ?", "%#{filters[:query]}%")    if filters[:query].present?
      scope = apply_rating_filter(scope, filters)
      scope
    end

    def self.apply_rating_filter(scope, filters)
      if filters[:rating].present?
        scope.joins(:evaluations).where(curator_evaluations: { rating: filters[:rating] }).distinct
      elsif truthy?(filters[:unrated])
        scope.where.missing(:evaluations)
      else
        scope
      end
    end
    private_class_method :apply_rating_filter

    def self.parse_date(value)
      return value if value.is_a?(Date) || value.is_a?(Time)
      return nil if value.blank?
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_date

    def self.truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
    private_class_method :truthy?
  end
end
