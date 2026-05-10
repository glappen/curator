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
    include Curator::StreamingExport
    # `ActionController::Live` enables `response.stream.write` for the
    # `#export` action — see `RetrievalsController` for the rationale.
    include ActionController::Live

    FILTER_PARAMS = %i[
      kb since until rating evaluator_role evaluator_id
      chat_model embedding_model failure_categories
    ].freeze

    def index
      @filters             = filter_params
      scope                = Evaluation.with_filters(filter_params)
                                         .order("curator_evaluations.created_at DESC, curator_evaluations.id DESC")
      @page                = paginate(scope, page: params[:page], per: params[:per])
      @evaluations         = @page.records.includes(retrieval: :knowledge_base)
      @kb_options          = Curator::KnowledgeBase.order(:name).pluck(:name, :slug)
      @chat_model_options  = Curator::Evaluation.distinct_chat_models
    end

    # CSV streams row-by-row to `response.stream`; JSON is buffered
    # and sent via `send_data`. See `RetrievalsController#export` for
    # the streaming rationale and the header dance.
    def export
      format   = params[:format].to_s.presence || "csv"
      filename = "curator-evaluations-#{Time.current.strftime('%Y%m%dT%H%M%S')}.#{format}"

      case format
      when "csv"
        response.headers["Content-Type"]        = "text/csv; charset=utf-8"
        response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
          disposition: "attachment", filename: filename
        )
        response.headers["X-Accel-Buffering"]   = "no"
        response.headers["Cache-Control"]       = "no-cache"
        begin
          ActiveRecord::Base.connection_pool.with_connection do
            scope = Evaluation.with_filters(filter_params)
            stream_csv(
              io:      response.stream,
              rows:    scope.find_each(order: :desc),
              columns: EVALUATION_EXPORT_COLUMNS
            ) { |e| evaluation_export_row(e, :csv) }
          end
        ensure
          response.stream.close
        end
      when "json"
        io = StringIO.new
        scope = Evaluation.with_filters(filter_params)
        stream_json(
          io:   io,
          rows: scope.find_each(order: :desc)
        ) { |e| evaluation_export_row(e, :json) }
        send_data io.string, type: "application/json",
                             disposition: "attachment", filename: filename
      else
        head :unsupported_media_type
      end
    end

    def create
      evaluation = Curator::Evaluation.create_or_update!(
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

    EVALUATION_EXPORT_COLUMNS = %i[
      retrieval_id query answer kb_slug chat_model embedding_model
      rating feedback ideal_answer failure_categories
      evaluator_id evaluator_role created_at
    ].freeze

    EVALUATION_ANSWER_TRUNCATION = 500

    def evaluation_export_row(evaluation, format)
      retrieval = evaluation.retrieval
      cats      = Array(evaluation.failure_categories)
      {
        retrieval_id:       retrieval.id,
        query:              retrieval.query,
        answer:             truncated_answer(retrieval.message&.content),
        kb_slug:            retrieval.knowledge_base.slug,
        chat_model:         retrieval.chat_model,
        embedding_model:    retrieval.embedding_model,
        rating:             evaluation.rating,
        feedback:           evaluation.feedback,
        ideal_answer:       evaluation.ideal_answer,
        failure_categories: serialize_categories(cats, format),
        evaluator_id:       evaluation.evaluator_id,
        evaluator_role:     evaluation.evaluator_role,
        created_at:         evaluation.created_at&.iso8601
      }
    end

    def truncated_answer(text)
      return nil if text.nil?
      return text if text.length <= EVALUATION_ANSWER_TRUNCATION

      "#{text[0, EVALUATION_ANSWER_TRUNCATION - 1]}…"
    end

    # CSV cells are flat strings, so categories collapse to a
    # `;`-joined string (avoids the comma-vs-Excel-delimiter trap).
    # JSON keeps them as an array because the consumer can iterate
    # natively. An empty list becomes nil in CSV (renders as a blank
    # cell — semantically "no value") and `[]` in JSON.
    def serialize_categories(categories, format)
      case format
      when :csv  then categories.empty? ? nil : categories.join(";")
      when :json then categories
      end
    end

    def filter_params
      cats = Array(params[:failure_categories]).reject(&:blank?)
      FILTER_PARAMS.index_with { |key| params[key] }
                   .merge(failure_categories: cats)
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
