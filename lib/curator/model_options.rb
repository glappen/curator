require "active_support/core_ext/integer/time"

module Curator
  # Builds grouped `<optgroup>` select sources for the chat / embedding
  # model dropdowns rendered by the admin UI (KB form, Console form). We
  # pull the model list from RubyLLM's in-process registry, filter to
  # providers whose credentials are configured on this host, and group by
  # provider.
  #
  # Each option's *label* carries the model id followed by RubyLLM's
  # pricing data when available — chat models render input/output USD per
  # 1M tokens, embedding models render input USD per 1M tokens. The
  # *value* stays the bare model id so saved records remain readable
  # ("gpt-5-mini") and form round-tripping ignores label drift if pricing
  # data changes between RubyLLM versions.
  #
  # When the caller's *current* value isn't in the resulting list — a
  # custom alias, an experimental model name, or a model belonging to a
  # provider whose credentials aren't configured here — we prepend a
  # synthetic `(custom)` group so the form round-trips the value instead
  # of silently rewriting it. Custom entries have no pricing data.
  module ModelOptions
    # Anything older than this falls out of the chat dropdown. RubyLLM's
    # registry includes the long tail back to GPT-3.5 / Claude-2.x — at
    # 15 months we keep the current generation and the immediately prior
    # generation (the realistic "switch back if the new one regresses"
    # window) and drop the rest. Saved values that fall off the list are
    # preserved by the (custom) group fallback in `build`.
    CHAT_MODEL_RECENCY_MONTHS = 15

    # Substrings in a chat model's id that mark it as a non-text-chat
    # specialty model — audio, realtime voice, transcription, TTS, web
    # search wrappers, image/video/audio generation. RubyLLM lumps these
    # into `chat_models` because they share the chat-completion endpoint
    # shape, but they aren't useful answers to "which model should
    # `Curator.ask` use." Built as one regex so the per-model check
    # stays a single match call.
    NON_CHAT_ID_PATTERN = /
      audio | realtime | transcribe | -tts\b |
      -search- | image | sora | veo | imagen |
      lyria | clip | robotics | computer-use |
      deep-research | nano-banana |
      embedding | gemma | \Aaqa\z
    /x

    class << self
      def chat(current_model)
        models = RubyLLM.models.chat_models.select { |m| chat_model?(m) }
        build(models, current_model) { |m| chat_pricing_label(m) }
      end

      def embedding(current_model)
        build(RubyLLM.models.embedding_models, current_model) { |m| embedding_pricing_label(m) }
      end

      private

      def chat_model?(model)
        return false if model.id.match?(NON_CHAT_ID_PATTERN)
        return false if model.family.to_s.start_with?("gemma")

        date = model.created_at
        return true if date.nil?

        date >= CHAT_MODEL_RECENCY_MONTHS.months.ago
      end

      def build(models, current_model)
        configured_slugs = RubyLLM::Provider
                             .configured_providers(RubyLLM.config)
                             .map(&:slug)
                             .to_set

        grouped = models
                    .select { |m| configured_slugs.include?(m.provider.to_s) }
                    .group_by { |m| m.provider.to_s }
                    .sort.to_h
                    .transform_values do |list|
          list.map { |m| [ option_label(m.id, yield(m)), m.id ] }
              .sort_by(&:last)
        end

        return grouped if current_model.blank?

        already_listed = grouped.values.flatten(1).any? { |_, id| id == current_model }
        return grouped if already_listed

        { "(custom)" => [ [ current_model, current_model ] ] }.merge(grouped)
      end

      def option_label(id, suffix)
        suffix.present? ? "#{id} (#{suffix})" : id
      end

      def chat_pricing_label(model)
        input  = format_price(model.pricing.text_tokens.input)
        output = format_price(model.pricing.text_tokens.output)
        return nil if input.nil? || output.nil?

        "#{input} / #{output} per 1M"
      end

      def embedding_pricing_label(model)
        # Embedding token pricing lives under `text_tokens` in RubyLLM's
        # registry — the `embeddings` category is reserved for per-API-call
        # / per-image-embedding rate structures and is empty for text
        # embedding models. Output per token is meaningless for embeddings;
        # show input only.
        input = format_price(model.pricing.text_tokens.input)
        return nil if input.nil?

        "#{input} per 1M"
      end

      # RubyLLM stores prices as USD per million tokens. Most chat-model
      # rates land in [$0.01, $50.00]; embedding rates can dip below
      # $0.01 (text-embedding-3-small is $0.02). Use 4-decimal precision
      # under a cent so sub-penny rates don't collapse to "$0.00".
      def format_price(value)
        return nil if value.nil? || value.zero?

        value < 0.01 ? format("$%.4f", value) : format("$%.2f", value)
      end
    end
  end
end
