module Curator
  class ConsoleController < ApplicationController
    STRATEGIES = %w[hybrid vector keyword].freeze
    # Console form may be loaded with `?origin=console_review` — the
    # "Re-run in Console" deep link from the Retrievals tab uses it so
    # the resulting retrieval is tagged as a review-loop run, not a
    # fresh ad-hoc Console session. Anything else falls back to the
    # plain :console default so a tampered querystring can't write
    # garbage into the column.
    FORM_ORIGINS = %w[console console_review].freeze

    def show
      @knowledge_base     = KnowledgeBase.resolve(params[:knowledge_base_slug])
      @knowledge_bases    = KnowledgeBase.order(:name, :id)
      @chat_model_options = ModelOptions.chat(@knowledge_base.chat_model)
      @topic              = SecureRandom.uuid
      @origin             = FORM_ORIGINS.include?(params[:origin]) ? params[:origin] : "console"
    end

    # Form-submit endpoint. Enqueues a `Curator::ConsoleStreamJob` against
    # the per-tab broadcast topic carried in the form's hidden `topic`
    # field, then returns a small turbo-stream that flips the status
    # badge to :streaming and clears the previous run's answer + sources
    # panes. Token-by-token rendering happens via the Action Cable
    # subscription that `console#show` set up with `turbo_stream_from`.
    def run
      topic = params[:topic].to_s
      raise ActionController::ParameterMissing, :topic if topic.blank?

      ConsoleStreamJob.perform_later(
        topic:                topic,
        knowledge_base_slug:  params[:knowledge_base_slug],
        query:                params[:query].to_s,
        chunk_limit:          numeric_param(:chunk_limit),
        similarity_threshold: float_param(:similarity_threshold),
        strategy:             presence(params[:strategy]),
        system_prompt:        presence(params[:system_prompt]),
        chat_model:           presence(params[:chat_model]),
        origin:               FORM_ORIGINS.include?(params[:origin]) ? params[:origin] : "console"
      )

      # `update` (not `replace`): the status partial doesn't carry the
      # `console-status` id on its root, so a `replace` would swap the
      # wrapping div out and leave subsequent broadcasts targeting nothing.
      # See ConsoleStreamJob for the matching note.
      render turbo_stream: [
        turbo_stream.update("console-status",
                            partial: "status",
                            locals:  { state: :streaming, message: nil }),
        turbo_stream.update("console-answer",  ""),
        turbo_stream.update("console-sources", "")
      ]
    end

    private

    def numeric_param(key)
      v = params[key]
      v.present? ? v.to_i : nil
    end

    def float_param(key)
      v = params[key]
      v.present? ? v.to_f : nil
    end

    def presence(value)
      value.present? ? value : nil
    end
  end
end
