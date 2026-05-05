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
