module Curator
  class Evaluation < ApplicationRecord
    self.table_name = "curator_evaluations"

    RATINGS = %i[positive negative].freeze

    FAILURE_CATEGORIES = %w[
      hallucination
      wrong_retrieval
      incomplete
      wrong_citation
      refused_incorrectly
      off_topic
      other
    ].freeze

    FAILURE_CATEGORY_TOOLTIPS = {
      "hallucination"       => "The answer states facts that aren't supported by any retrieved source.",
      "wrong_retrieval"     => "The retrieved sources aren't relevant to the question.",
      "incomplete"          => "The right sources were retrieved, but the answer omits relevant information from them.",
      "wrong_citation"      => "A citation marker points to a source that doesn't actually support the claim.",
      "refused_incorrectly" => "The answer says \"I don't know\" but the information exists in the knowledge base.",
      "off_topic"           => "The answer doesn't address the question being asked.",
      "other"               => "Something else is wrong — please describe in the feedback field."
    }.freeze

    belongs_to :retrieval, class_name: "Curator::Retrieval"

    EVALUATOR_ROLES = %i[reviewer end_user].freeze

    enum :rating, RATINGS.index_with(&:to_s)

    validate :failure_categories_are_known
    validate :failure_categories_only_on_negative

    # Distinct chat_models drawn from retrievals that have at least one
    # evaluation. Used to populate the chat-model filter dropdown on the
    # Evaluations index — restricting to evaluated retrievals means the
    # dropdown only surfaces values that can actually narrow the list.
    def self.distinct_chat_models
      joins(:retrieval)
        .where.not(curator_retrievals: { chat_model: nil })
        .distinct
        .order("curator_retrievals.chat_model")
        .pluck("curator_retrievals.chat_model")
    end

    # Canonical write path for creating / updating an evaluation.
    # Both new and update flows go through here: pass `evaluation_id:`
    # to update an existing row in place (Console edit-in-place flow);
    # omit it to create a new row.
    def self.create_or_update!(retrieval:, rating:, evaluator_role:, **attrs)
      unless RATINGS.include?(rating.to_sym)
        raise ArgumentError,
              "rating must be one of #{RATINGS.inspect} (got #{rating.inspect})"
      end
      unless EVALUATOR_ROLES.include?(evaluator_role.to_sym)
        raise ArgumentError,
              "evaluator_role must be one of #{EVALUATOR_ROLES.inspect} (got #{evaluator_role.inspect})"
      end

      retrieval = retrieval.is_a?(Curator::Retrieval) ? retrieval : Curator::Retrieval.find(retrieval)

      evaluation_attrs = {
        rating:             rating.to_s,
        evaluator_role:     evaluator_role.to_s,
        evaluator_id:       attrs[:evaluator_id],
        feedback:           attrs[:feedback],
        ideal_answer:       attrs[:ideal_answer],
        failure_categories: Array(attrs[:failure_categories])
      }

      if attrs[:evaluation_id]
        evaluation = retrieval.evaluations.find(attrs[:evaluation_id])
        evaluation.update!(evaluation_attrs)
        evaluation
      else
        retrieval.evaluations.create!(evaluation_attrs)
      end
    end

    private

    def failure_categories_are_known
      unknown = Array(failure_categories) - FAILURE_CATEGORIES
      return if unknown.empty?

      errors.add(:failure_categories, "contains unknown values: #{unknown.join(', ')}")
    end

    def failure_categories_only_on_negative
      return if Array(failure_categories).empty?
      return if rating == "negative"

      errors.add(:failure_categories, "are only allowed on :negative evaluations")
    end

    # Filter scope that mirrors the querystring contract on
    # `EvaluationsController#index` so the same filter form drives both
    # the on-screen table and the export.
    def self.with_filters(filters)
      scope = joins(retrieval: :knowledge_base)
              .includes(retrieval: %i[knowledge_base message])
      scope = scope.where(curator_knowledge_bases: { slug: filters[:kb] })          if filters[:kb].present?
      scope = scope.where(rating: filters[:rating])                                 if filters[:rating].present?
      scope = scope.where(evaluator_role: filters[:evaluator_role])                 if filters[:evaluator_role].present?
      scope = scope.where(curator_retrievals: { chat_model: filters[:chat_model] }) if filters[:chat_model].present?
      if filters[:embedding_model].present?
        scope = scope.where(curator_retrievals: { embedding_model: filters[:embedding_model] })
      end
      if filters[:evaluator_id].present?
        needle = ActiveRecord::Base.sanitize_sql_like(filters[:evaluator_id])
        scope  = scope.where("curator_evaluations.evaluator_id ILIKE ?", "%#{needle}%")
      end
      if (cats = Array(filters[:failure_categories]).reject(&:blank?)).any?
        scope = scope.where("curator_evaluations.failure_categories && ARRAY[?]::varchar[]", cats)
      end
      if (since = parse_date(filters[:since]))
        scope = scope.where("curator_evaluations.created_at >= ?", since.beginning_of_day)
      end
      if (before = parse_date(filters[:until]))
        scope = scope.where("curator_evaluations.created_at <= ?", before.end_of_day)
      end
      scope
    end

    def self.parse_date(value)
      return value if value.is_a?(Date) || value.is_a?(Time)
      return nil if value.blank?
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_date
  end
end
