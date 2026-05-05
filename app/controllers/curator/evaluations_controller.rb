module Curator
  # Admin write endpoint for `Curator::Evaluation`. Both create + update
  # land on `#create`: the form posts with a hidden `evaluation_id`
  # field on subsequent submits, which routes through the same action
  # and updates the existing row in place.
  #
  # Two response shapes:
  #   * Turbo Stream — Phase 2 Console flow. Returns a single
  #     `turbo_stream.update("console-evaluation", ...)` that swaps the
  #     thumbs widget (or its prior expanded form) for a freshly
  #     rendered rating-aware form bound to the persisted row.
  #   * JSON — Phase 1 / programmatic callers. Returns
  #     `{ id:, rating: }` so the caller can stash the id for the next
  #     update submit.
  #
  # v1 has no per-evaluator authorization on update — any admin who
  # passes the `authenticate_admin_with` hook can PATCH any other
  # admin's evaluation by id. Multi-tenancy + per-row ownership are
  # explicitly deferred to v2+ (see implementation.md "Deferred").
  class EvaluationsController < ApplicationController
    include Curator::PaginationHelper

    FILTER_PARAMS = %i[
      kb since until rating evaluator_role evaluator_id
      chat_model embedding_model failure_categories
    ].freeze

    def index
      @filters             = filter_params
      scope                = apply_filters(base_scope)
      @page                = paginate(scope, page: params[:page], per: params[:per])
      @evaluations         = @page.records.includes(retrieval: :knowledge_base)
      @kb_options          = Curator::KnowledgeBase.order(:name).pluck(:name, :slug)
      @chat_model_options  = Curator::Evaluation.distinct_chat_models
    end

    def create
      evaluation = Curator.evaluate(
        retrieval:          retrieval_param,
        rating:             params[:rating],
        evaluator_role:     :reviewer,
        evaluator_id:       current_admin_evaluator_id,
        feedback:           param_or_nil(:feedback),
        ideal_answer:       param_or_nil(:ideal_answer),
        failure_categories: Array(params[:failure_categories]).reject(&:blank?),
        evaluation_id:      param_or_nil(:evaluation_id)
      )

      if request.format.turbo_stream?
        render turbo_stream: turbo_stream.update(
          "console-evaluation",
          partial: "curator/evaluations/form",
          locals:  { evaluation: evaluation }
        )
      else
        # 200 on update, 201 on create — the JSON contract has to
        # distinguish the two for programmatic callers, since the route
        # collapses both onto POST.
        status = param_or_nil(:evaluation_id) ? :ok : :created
        render json: { id: evaluation.id, rating: evaluation.rating }, status: status
      end
    end

    private

    def base_scope
      Curator::Evaluation
        .joins(retrieval: :knowledge_base)
        .order("curator_evaluations.created_at DESC, curator_evaluations.id DESC")
    end

    # Filters are chained conditionally so absent querystring keys behave
    # as "no filter". Date inputs are coerced to ISO-8601 dates and
    # silently dropped on parse failure (a malformed `since=garbage`
    # becomes a no-op rather than a 400 — the index is exploratory).
    def apply_filters(scope)
      f = @filters
      scope = scope.where(curator_knowledge_bases: { slug: f[:kb] })             if f[:kb].present?
      scope = scope.where(rating: f[:rating])                                    if f[:rating].present?
      scope = scope.where(evaluator_role: f[:evaluator_role])                    if f[:evaluator_role].present?
      scope = scope.where(curator_retrievals: { chat_model: f[:chat_model] })    if f[:chat_model].present?
      scope = scope.where(curator_retrievals: { embedding_model: f[:embedding_model] }) if f[:embedding_model].present?

      if f[:evaluator_id].present?
        # `sanitize_sql_like` escapes `%` and `_` so a literal substring
        # like `foo_bar` doesn't silently match `foo-bar` via the LIKE
        # wildcard. The `%…%` wrapping below is intentionally raw — we
        # *do* want the result to match anywhere in the column.
        needle = ActiveRecord::Base.sanitize_sql_like(f[:evaluator_id])
        scope  = scope.where("curator_evaluations.evaluator_id ILIKE ?", "%#{needle}%")
      end

      if (cats = f[:failure_categories]).present?
        # ANY-of semantics — the eval matches if it carries at least one
        # of the requested categories. Postgres array overlap operator.
        scope = scope.where("curator_evaluations.failure_categories && ARRAY[?]::varchar[]", cats)
      end

      if (since = parse_date(f[:since]))
        scope = scope.where("curator_evaluations.created_at >= ?", since.beginning_of_day)
      end

      if (before = parse_date(f[:until]))
        scope = scope.where("curator_evaluations.created_at <= ?", before.end_of_day)
      end

      scope
    end

    def filter_params
      cats = Array(params[:failure_categories]).reject(&:blank?)
      FILTER_PARAMS.index_with { |key| params[key] }
                   .merge(failure_categories: cats)
    end

    def parse_date(value)
      return nil if value.blank?
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def retrieval_param
      retrieval_id = params[:retrieval_id].presence ||
                     raise(ActionController::ParameterMissing, :retrieval_id)
      Curator::Retrieval.find(retrieval_id)
    end

    def param_or_nil(key)
      value = params[key]
      value.present? ? value : nil
    end
  end
end
