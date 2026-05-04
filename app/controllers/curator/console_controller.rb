module Curator
  class ConsoleController < ApplicationController
    STRATEGIES = %w[hybrid vector keyword].freeze

    def show
      @knowledge_base     = KnowledgeBase.resolve(params[:knowledge_base_slug])
      @knowledge_bases    = KnowledgeBase.order(:name, :id)
      @chat_model_options = build_chat_model_options(@knowledge_base.chat_model)
      @topic              = SecureRandom.uuid
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
        chat_model:           presence(params[:chat_model])
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

    # Build the chat_model `<select>` source: every chat model RubyLLM
    # knows about, filtered to providers that have credentials configured
    # in this host, grouped by provider for `<optgroup>` rendering. If
    # the KB's saved `chat_model` isn't in the resulting list (custom
    # alias, or provider not currently configured), prepend a
    # "(custom)" group so the form round-trips without dropping the
    # value.
    def build_chat_model_options(current_model)
      configured_slugs = RubyLLM::Provider
                           .configured_providers(RubyLLM.config)
                           .map(&:slug)
                           .to_set

      grouped = RubyLLM.models.chat_models
                       .select { |m| configured_slugs.include?(m.provider.to_s) }
                       .group_by { |m| m.provider.to_s }
                       .sort.to_h
                       .transform_values do |models|
        models.map { |m| [ m.id, m.id ] }.sort
      end

      already_listed = grouped.values.flatten(1).any? { |_, id| id == current_model }
      return grouped if already_listed

      { "(custom)" => [ [ current_model, current_model ] ] }.merge(grouped)
    end

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
