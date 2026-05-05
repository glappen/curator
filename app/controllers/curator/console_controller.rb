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
      @knowledge_base  = KnowledgeBase.resolve(params[:knowledge_base_slug])
      @knowledge_bases = KnowledgeBase.order(:name, :id)
      @topic           = SecureRandom.uuid
      @origin          = FORM_ORIGINS.include?(params[:origin]) ? params[:origin] : "console"
      # The "Re-run in Console" deep link from the Retrievals tab carries
      # the original retrieval's snapshot config so the form opens with
      # the exact configuration that produced the logged run. Each
      # override field falls back to the KB default placeholder when the
      # URL doesn't carry it, so a plain ?query=... link still works.
      @query                = params[:query].to_s
      @chunk_limit          = numeric_param(:chunk_limit)
      @similarity_threshold = float_param(:similarity_threshold)
      @strategy             = STRATEGIES.include?(params[:strategy]) ? params[:strategy] : nil
      # `chat_model` is intentionally not whitelisted (unlike `strategy`,
      # whose universe is fixed at three values). RubyLLM's chat-model
      # universe is open: aliases, experimental ids, and retired models
      # logged on past retrievals are all legitimate values. ModelOptions
      # has a `(custom)` optgroup fallback for ids that aren't in the
      # live registry — but that fallback only fires when the *current*
      # value passed to `ModelOptions.chat` matches the id, so the
      # selected model has to be resolved before the options are built.
      @chat_model         = presence(params[:chat_model])
      @chat_model_options = ModelOptions.chat(@chat_model || @knowledge_base.chat_model)
      @system_prompt      = params[:system_prompt].to_s
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
