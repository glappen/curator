module Curator
  # Admin index + detail for `Curator::Retrieval`. The detail view is
  # the unified "what happened on this run?" surface — query, persisted
  # answer, ranked sources, snapshot config, trace timeline, and the
  # rating-aware annotation form. Phase 4 (Evaluations tab) will link
  # into this same `#show` with `?evaluation_id=...`.
  #
  # Filter state lives in the URL querystring so a page link / browser
  # back button restores the operator's view without server-side state.
  class RetrievalsController < ApplicationController
    include Curator::PaginationHelper
    include Curator::StreamingExport
    # `ActionController::Live` enables `response.stream.write` for the
    # `#export` action so a multi-MB CSV download surfaces row-by-row
    # instead of buffering the full result set in the worker's heap.
    # Other actions in this controller don't touch the stream and run
    # under the normal request lifecycle. The thread-per-request
    # implication is fine for admin actions; the heap pressure relief
    # on a long export window is worth it.
    include ActionController::Live

    # Free-text query is `ILIKE`-matched against the persisted query
    # column. Cap the length so a paste of an entire transcript can't
    # turn into a multi-MB filter param.
    QUERY_FILTER_MAX = 200

    def index
      @filters = filter_params
      scope    = Retrieval.with_filters(filter_params)
                          .includes(:knowledge_base)
                          .order(created_at: :desc)
      @page    = paginate(scope, page: params[:page], per: params[:per])
      @retrievals       = @page.records
      # Single grouped aggregate avoids an N+1 on the per-row eval-count
      # badge. Rows without any evaluations are absent from the hash;
      # the view defaults to 0.
      @eval_counts      = Evaluation.where(retrieval_id: @retrievals.map(&:id))
                                    .group(:retrieval_id)
                                    .count
      @knowledge_bases  = KnowledgeBase.order(:name, :id)
      @chat_models      = scope_models(:chat_model)
      @embedding_models = scope_models(:embedding_model)
    end

    # CSV streams row-by-row to `response.stream` so a large export
    # doesn't buffer the full result set in worker heap. JSON is a
    # single document — streaming an array literal incrementally to
    # the browser is more plumbing than payoff at single-document
    # scale, so it's buffered and sent via `send_data`.
    def export
      format   = params[:format].to_s.presence || "csv"
      filename = "curator-retrievals-#{Time.current.strftime('%Y%m%dT%H%M%S')}.#{format}"

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
            scope = Retrieval.with_filters(filter_params)
                             .includes(:knowledge_base, :message, :retrieval_hits, :evaluations)
            stream_csv(
              io:     response.stream,
              rows:   scope.find_each(order: :desc),
              columns: RETRIEVAL_EXPORT_COLUMNS
            ) { |r| retrieval_export_row(r) }
          end
        ensure
          response.stream.close
        end
      when "json"
        io = StringIO.new
        scope = Retrieval.with_filters(filter_params)
                         .includes(:knowledge_base, :message, :retrieval_hits, :evaluations)
        stream_json(
          io:   io,
          rows: scope.find_each(order: :desc)
        ) { |r| retrieval_export_row(r) }
        send_data io.string, type: "application/json",
                             disposition: "attachment", filename: filename
      else
        head :unsupported_media_type
      end
    end

    def show
      @retrieval        = Retrieval.includes(:knowledge_base,
                                             :retrieval_steps,
                                             retrieval_hits: :document)
                                   .find(params[:id])
      @hits             = @retrieval.retrieval_hits.order(:rank)
      @steps            = @retrieval.retrieval_steps.order(:sequence)
      @evaluations      = @retrieval.evaluations.order(created_at: :desc)
      @answer_text      = persisted_answer_text(@retrieval)
      @focused_eval_id  = params[:evaluation_id].presence&.to_i
      # New eval scaffold — annotation form starts at :negative since
      # SMEs explicitly hitting the detail view are usually correcting
      # something. Operator can flip rating in place.
      @new_evaluation   = Evaluation.new(retrieval: @retrieval, rating: :negative)
    end

    private

    def filter_params
      {
        knowledge_base_id: params[:knowledge_base_id].presence,
        from:              params[:from].presence,
        to:                params[:to].presence,
        status:            params[:status].presence,
        chat_model:        params[:chat_model].presence,
        embedding_model:   params[:embedding_model].presence,
        rating:            params[:rating].presence,
        unrated:           ActiveModel::Type::Boolean.new.cast(params[:unrated]),
        query:             params[:query].to_s.strip.first(QUERY_FILTER_MAX).presence,
        # `:console_review` rows are review-loop noise (every "Re-run in
        # Console" deep link from this very tab creates one) — hidden by
        # default so the index keeps showing real operator and user
        # traffic.
        show_review:       ActiveModel::Type::Boolean.new.cast(params[:show_review])
      }
    end

    RETRIEVAL_EXPORT_COLUMNS = %i[
      retrieval_id query answer kb_slug chat_model embedding_model
      status origin retrieved_hit_count eval_count created_at
    ].freeze

    RETRIEVAL_ANSWER_TRUNCATION = 500

    def retrieval_export_row(retrieval)
      {
        retrieval_id:        retrieval.id,
        query:               retrieval.query,
        answer:              truncated_answer(retrieval.message&.content),
        kb_slug:             retrieval.knowledge_base.slug,
        chat_model:          retrieval.chat_model,
        embedding_model:     retrieval.embedding_model,
        status:              retrieval.status,
        origin:              retrieval.origin,
        retrieved_hit_count: retrieval.retrieval_hits.size,
        eval_count:          retrieval.evaluations.size,
        created_at:          retrieval.created_at&.iso8601
      }
    end

    def truncated_answer(text)
      return nil if text.nil?
      return text if text.length <= RETRIEVAL_ANSWER_TRUNCATION

      "#{text[0, RETRIEVAL_ANSWER_TRUNCATION - 1]}…"
    end

    # Distinct dropdown values for the chat_model / embedding_model
    # filters. Sourced from existing rows so a model that's never been
    # used doesn't clutter the filter — and a deprecated model still
    # appears as long as it has historical retrievals.
    def scope_models(column)
      Retrieval.where.not(column => nil).distinct.order(column).pluck(column)
    end

    # Reconstruct the rendered answer for the detail view. RubyLLM
    # stores the assistant text on the linked Message row; rows that
    # never made it that far (`:failed` mid-pipeline, or `mark_failed!`
    # before chat creation) have no message — return nil and let the
    # view show a placeholder.
    def persisted_answer_text(retrieval)
      retrieval.message&.content
    end
  end
end
