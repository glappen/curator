module Curator
  # Records `curator_search_steps` rows around retrieval / LLM work.
  # Reads `Curator.config.trace_level`:
  #   - :off     — no rows, block runs as-is.
  #   - :summary — row written with empty payload.
  #   - :full    — payload_builder evaluated on the block result.
  #
  # The block's return value is what `record` returns, so callers can use
  # this around any unit of work without restructuring.
  module Tracing
    module_function

    def record(search:, step_type:, payload_builder: nil)
      level = Curator.config.trace_level
      return yield if level == :off || search.nil?

      started_at = Time.current
      begin
        result = yield
        write_step!(
          search:      search,
          step_type:   step_type,
          started_at:  started_at,
          duration_ms: elapsed_ms(started_at),
          payload:     payload_for(level, payload_builder, result),
          status:      :success
        )
        result
      rescue StandardError => e
        write_step!(
          search:        search,
          step_type:     step_type,
          started_at:    started_at,
          duration_ms:   elapsed_ms(started_at),
          payload:       {},
          status:        :error,
          error_message: e.message
        )
        raise
      end
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
    # rows. v1 simplicity over an in-memory counter — `Curator.search`
    # is single-threaded per request, so concurrent step writes
    # against the same search don't happen and the unique
    # (search_id, sequence) index won't collide. If a future async
    # tracing path appears, swap this for a counter on the search
    # row or a per-search Concurrent::AtomicFixnum.
    def write_step!(search:, step_type:, started_at:, duration_ms:, payload:, status:, error_message: nil)
      Curator::SearchStep.create!(
        search:        search,
        sequence:      search.search_steps.count,
        step_type:     step_type.to_s,
        started_at:    started_at,
        duration_ms:   duration_ms,
        status:        status.to_s,
        payload:       payload,
        error_message: error_message
      )
    end
  end
end
