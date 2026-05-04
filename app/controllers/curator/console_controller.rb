module Curator
  class ConsoleController < ApplicationController
    include ActionController::Live

    STRATEGIES = %w[hybrid vector keyword].freeze

    def show
      @knowledge_base     = KnowledgeBase.resolve(params[:knowledge_base_slug])
      @knowledge_bases    = KnowledgeBase.order(:name, :id)
      @chat_model_options = build_chat_model_options(@knowledge_base.chat_model)
    end

    # ActionController::Live action. Streams `<turbo-stream>` frames
    # over a single chunked HTTP response: `append` per LLM delta into
    # `console-answer`, then `replace` the sources panel and the status
    # badge once Asker returns. On a Curator::Error, the answer frame
    # ends partial and the status badge flips to :failed with the
    # error message — caller saw whatever streamed before the raise.
    def run
      response.headers["Content-Type"]  = "text/vnd.turbo-stream.html"
      response.headers["Cache-Control"] = "no-cache"

      Curator::Streaming::TurboStream.open(
        stream: response.stream, target: "console-answer"
      ) do |pump|
        run_with_pump(pump)
      end
    end

    private

    # KB resolution happens *inside* the pump block so a bad slug
    # (`ActiveRecord::RecordNotFound`) flips to a failed status frame
    # instead of escaping `TurboStream.open` — escaping would skip the
    # block-sugar `ensure pump.close` and leave the Live stream open
    # until Rails times it out. `Curator::Error` covers Asker's
    # retrieval/LLM failures; `RecordNotFound` covers the bad-slug
    # case. Anything else (programmer error) keeps propagating.
    def run_with_pump(pump)
      kb = KnowledgeBase.resolve(params[:knowledge_base_slug])

      answer = Curator::Asker.call(
        params[:query].to_s,
        knowledge_base: kb,
        limit:          numeric_param(:chunk_limit),
        threshold:      float_param(:similarity_threshold),
        strategy:       presence(params[:strategy]),
        system_prompt:  presence(params[:system_prompt]),
        chat_model:     presence(params[:chat_model])
      ) { |delta| pump.append(delta) }

      pump.replace(target: "console-sources", html: render_sources(answer.sources, kb))
      pump.replace(target: "console-status",  html: render_status(:done))
    rescue Curator::Error, ActiveRecord::RecordNotFound => e
      pump.replace(
        target: "console-status",
        html:   render_status(:failed, message: e.message)
      )
    end

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

    def render_sources(hits, kb)
      return render_to_string(partial: "empty_sources", formats: [ :html ]) if hits.empty?

      render_to_string(
        partial:    "source",
        collection: hits,
        as:         :hit,
        formats:    [ :html ],
        locals:     { kb: kb }
      )
    end

    def render_status(state, message: nil)
      render_to_string(
        partial: "status",
        formats: [ :html ],
        locals:  { state: state, message: message }
      )
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
