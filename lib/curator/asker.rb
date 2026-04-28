module Curator
  # Service object for `Curator.ask`. Orchestrates: open a
  # `curator_retrievals` row with snapshot config → run the shared
  # `Curator::Retrievers::Pipeline` for hits → assemble the system
  # prompt → create a RubyLLM `Chat` (`curator_scope: nil`) →
  # `chat.with_instructions(...).ask(query)` wrapped in a `:llm_call`
  # trace step → finalize the row with `chat_id` / `message_id` /
  # `system_prompt_*` and return `Curator::Answer`. Mirrors
  # `Curator::Retriever`'s row-lifecycle wrapper shape; the row is
  # opened *with* the chat-flavored snapshot columns
  # (strict_grounding / include_citations) populated from the start
  # so an early failure still leaves a row that records the operator
  # intent.
  class Asker
    def initialize(query, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil,
                   system_prompt: nil, chat_model: nil)
      @raw_query              = query
      @knowledge_base_arg     = knowledge_base
      @limit_override         = limit
      @threshold_override     = threshold
      @strategy_override      = strategy
      @system_prompt_override = system_prompt
      @chat_model_override    = chat_model
    end

    def call(&stream_block)
      pipeline = Curator::Retrievers::Pipeline.new(
        query:          @raw_query,
        knowledge_base: @knowledge_base_arg,
        limit:          @limit_override,
        threshold:      @threshold_override,
        strategy:       @strategy_override
      )
      effective_chat_model = @chat_model_override || pipeline.knowledge_base.chat_model

      retrieval_row = open_retrieval_row!(pipeline, effective_chat_model)
      run(pipeline, retrieval_row, effective_chat_model, &stream_block)
    end

    private

    def open_retrieval_row!(pipeline, chat_model)
      return nil unless Curator.config.log_queries
      kb = pipeline.knowledge_base

      Curator::Retrieval.create!(
        knowledge_base:       kb,
        query:                @raw_query,
        chat_model:           chat_model,
        embedding_model:      kb.embedding_model,
        retrieval_strategy:   pipeline.strategy.to_s,
        similarity_threshold: pipeline.threshold,
        chunk_limit:          pipeline.limit,
        strict_grounding:     kb.strict_grounding,
        include_citations:    kb.include_citations
      )
    end

    def run(pipeline, retrieval_row, chat_model, &stream_block)
      started_at = Time.current
      kb         = pipeline.knowledge_base
      hits       = pipeline.call(retrieval_row)

      assembled = assemble_prompt(kb, hits, retrieval_row)

      chat            = create_chat!(chat_model, retrieval_row)
      assistant_msg   = invoke_llm!(chat, assembled[:system_prompt_text], retrieval_row, &stream_block)
      ar_message      = chat.messages.order(:id).last

      duration = ((Time.current - started_at) * 1000).to_i
      retrieval_row&.update!(
        message_id:        ar_message.id,
        status:            :success,
        total_duration_ms: duration
      )

      Curator::Answer.new(
        answer:            assistant_msg.content,
        retrieval_results: build_retrieval_results(hits, kb, retrieval_row, duration),
        retrieval_id:      retrieval_row&.id,
        strict_grounding:  kb.strict_grounding
      )
    rescue StandardError => e
      mark_failed!(retrieval_row, started_at, e)
      raise
    end

    def assemble_prompt(kb, hits, retrieval_row)
      kb_for_assembly = kb_with_prompt_override(kb)

      result = Curator::Tracing.record(
        retrieval:       retrieval_row,
        step_type:       :prompt_assembly,
        payload_builder: ->(r) {
          {
            hit_count:             hits.size,
            system_prompt_hash:    r[:system_prompt_hash],
            prompt_token_estimate: r[:prompt_token_estimate]
          }
        }
      ) do
        Curator::Prompt::Assembler.new.call(kb: kb_for_assembly, hits: hits)
      end

      retrieval_row&.update!(
        system_prompt_text: result[:system_prompt_text],
        system_prompt_hash: result[:system_prompt_hash]
      )
      result
    end

    # The `system_prompt:` call-site override replaces only the
    # *instructions half* of the assembled prompt — same semantics as
    # `kb.system_prompt`. We dup the KB record (in-memory only, never
    # saved) and overwrite `system_prompt` so Assembler doesn't need
    # an extra parameter.
    def kb_with_prompt_override(kb)
      return kb if @system_prompt_override.nil?

      override = kb.dup
      override.system_prompt = @system_prompt_override
      override
    end

    def create_chat!(chat_model, retrieval_row)
      chat = Chat.create!(model: chat_model, curator_scope: nil)
      retrieval_row&.update!(chat_id: chat.id)
      chat
    end

    def invoke_llm!(chat, system_prompt_text, retrieval_row, &stream_block)
      streaming = !stream_block.nil?

      Curator::Tracing.record(
        retrieval:       retrieval_row,
        step_type:       :llm_call,
        payload_builder: ->(msg) {
          {
            model:         msg.model_id,
            input_tokens:  msg.input_tokens,
            output_tokens: msg.output_tokens,
            finish_reason: extract_finish_reason(msg),
            streamed:      streaming
          }
        }
      ) do
        chat.context = llm_context
        chat.with_instructions(system_prompt_text)

        if streaming
          chat.ask(@raw_query) { |c| stream_block.call(c.content) if c.content }
        else
          chat.ask(@raw_query)
        end
      end
    rescue RubyLLM::Error => e
      raise Curator::LLMError, "LLM call failed (#{e.class}): #{e.message}"
    end

    # Per-call RubyLLM context that propagates Curator's
    # `llm_retry_count` into faraday-retry's `max:`. The retry
    # middleware operates at the request layer — on a streaming
    # ask, a mid-stream error *does* trigger a fresh HTTP request,
    # which means partial deltas already yielded can be replayed
    # on the next attempt. Streaming consumers that need
    # at-most-once delivery should set `llm_retry_count = 0`.
    def llm_context
      @llm_context ||= RubyLLM.context do |c|
        c.max_retries = Curator.config.llm_retry_count
      end
    end

    # `finish_reason` is the only trace signal that distinguishes a
    # `length`-truncated answer from a `stop`-completed one — M5's
    # admin badge and M7's evaluation failure-category UI both
    # depend on it. RubyLLM doesn't expose it on Message, so we dig
    # into the raw provider response. OpenAI puts it at
    # `body["choices"][0]["finish_reason"]`; Anthropic uses
    # `body["stop_reason"]` at top level (other providers TBD).
    # When v2 adds non-OpenAI providers, generalize this — for v1
    # the OpenAI shape is the only one we ship.
    def extract_finish_reason(msg)
      body = msg.raw.respond_to?(:body) ? msg.raw.body : nil
      return nil unless body.is_a?(Hash)
      body.dig("choices", 0, "finish_reason") || body["stop_reason"]
    end

    def build_retrieval_results(hits, kb, retrieval_row, duration_ms)
      Curator::RetrievalResults.new(
        query:          @raw_query,
        hits:           hits,
        duration_ms:    duration_ms,
        knowledge_base: kb,
        retrieval_id:   retrieval_row&.id
      )
    end

    def mark_failed!(retrieval_row, started_at, error)
      return if retrieval_row.nil?
      retrieval_row.update!(
        status:            :failed,
        error_message:     "#{error.class}: #{error.message}",
        total_duration_ms: ((Time.current - started_at) * 1000).to_i
      )
    end
  end
end
