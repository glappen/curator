module Curator
  # Records `curator_retrieval_steps` rows around retrieval / LLM work
  # and republishes each persisted step as an `ActiveSupport::Notifications`
  # event on the `"curator.step"` channel so external observers (chat
  # response jobs, console streamers) can react to step writes without
  # polling. The DB row remains the system-of-record; the notification
  # is just a fan-out hook layered on top.
  #
  # Reads `Curator.config.trace_level`:
  #   - :off     — no rows, no events, block runs as-is.
  #   - :summary — row + event with empty payload.
  #   - :full    — payload_builder evaluated on the block result.
  #
  # The block's return value is what `record` returns, so callers can use
  # this around any unit of work without restructuring.
  module Tracing
    CHANNEL = "curator.step".freeze

    module_function

    def record(retrieval:, step_type:, payload_builder: nil)
      level = Curator.config.trace_level
      return yield if level == :off || retrieval.nil?

      started_at = Time.current
      begin
        result = yield
        step = write_step!(
          retrieval:   retrieval,
          step_type:   step_type,
          started_at:  started_at,
          duration_ms: elapsed_ms(started_at),
          payload:     payload_for(level, payload_builder, result),
          status:      :success
        )
        publish_event(retrieval, step)
        result
      rescue StandardError => e
        step = write_step!(
          retrieval:     retrieval,
          step_type:     step_type,
          started_at:    started_at,
          duration_ms:   elapsed_ms(started_at),
          payload:       {},
          status:        :error,
          error_message: e.message
        )
        publish_event(retrieval, step)
        raise
      end
    end

    # Subscribe to `curator.step` events scoped to a single chat or
    # retrieval. The block is invoked with the event payload (a Hash)
    # for every matching event; non-matching events are filtered out
    # before the block runs.
    #
    # `scope` is matched by class:
    #   - Curator::Retrieval  → filters payload[:retrieval_id]
    #   - anything else       → filters payload[:chat_id] (works for the
    #                           ruby_llm-generated `Chat` model and the
    #                           Phase 3a `Curator::Chat` wrapper, both
    #                           of which expose `#id`)
    #
    # Returns an opaque subscriber handle. Pass it to `unsubscribe` to
    # release. Subscribers leak globally if not released; long-lived
    # callers (e.g. background jobs) must use `ensure` to clean up.
    def subscribe(scope:, &block)
      raise ArgumentError, "block required" unless block
      raise ArgumentError, "scope required" if scope.nil?
      filter = filter_for(scope)
      ActiveSupport::Notifications.subscribe(CHANNEL) do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        block.call(event.payload) if filter.call(event.payload)
      end
    end

    def unsubscribe(handle)
      ActiveSupport::Notifications.unsubscribe(handle)
    end

    def payload_for(level, builder, result)
      return {} if level == :summary
      return {} if builder.nil?
      builder.call(result) || {}
    end

    def elapsed_ms(started_at)
      ((Time.current - started_at) * 1000).to_i
    end

    # Sequence allocated via a SELECT COUNT against the existing
    # rows. v1 simplicity over an in-memory counter — `Curator.retrieve`
    # is single-threaded per request, so concurrent step writes
    # against the same retrieval don't happen and the unique
    # (retrieval_id, sequence) index won't collide. If a future async
    # tracing path appears, swap this for a counter on the retrieval
    # row or a per-retrieval Concurrent::AtomicFixnum.
    def write_step!(retrieval:, step_type:, started_at:, duration_ms:, payload:, status:, error_message: nil)
      Curator::RetrievalStep.create!(
        retrieval:     retrieval,
        sequence:      retrieval.retrieval_steps.count,
        step_type:     step_type.to_s,
        started_at:    started_at,
        duration_ms:   duration_ms,
        status:        status.to_s,
        payload:       payload,
        error_message: error_message
      )
    end

    # Synthesizes an AS::Notifications event whose payload carries
    # everything a subscriber needs to render without re-querying:
    # the parent retrieval/chat ids for filtering, plus the persisted
    # step's identity and contents. `instrument` with no block emits
    # a zero-duration event — duration is already on the payload as
    # `duration_ms`, the actual wall-clock cost of the wrapped work.
    #
    # Enum-like fields (`step_type`, `status`) are symbolized at the
    # notification boundary so subscriber dispatch
    # (`case payload[:step_type] when :tool_call_started ...`) matches
    # the symbol-first convention used everywhere else in Curator's
    # public API. DB columns stay String; symbolization happens here.
    def publish_event(retrieval, step)
      ActiveSupport::Notifications.instrument(CHANNEL,
        retrieval_id:  retrieval.id,
        chat_id:       retrieval.chat_id,
        step_id:       step.id,
        step_type:     step.step_type.to_sym,
        sequence:      step.sequence,
        status:        step.status.to_sym,
        started_at:    step.started_at,
        duration_ms:   step.duration_ms,
        payload:       step.payload,
        error_message: step.error_message
      )
    end

    def filter_for(scope)
      case scope
      when Curator::Retrieval
        retrieval_id = scope.id
        ->(payload) { payload[:retrieval_id] == retrieval_id }
      else
        chat_id = scope.id
        ->(payload) { payload[:chat_id] == chat_id }
      end
    end
  end
end
