require "erb"

module Curator
  module Streaming
    # Thin pump for emitting `<turbo-stream>` frames into a chunked
    # `text/vnd.turbo-stream.html` response body. The Console controller
    # (Phase 2B) instantiates this against `response.stream` from
    # `ActionController::Live`; specs instantiate against `StringIO`.
    #
    # Wire format per frame:
    #   <turbo-stream action="..." target="..."><template>...</template></turbo-stream>
    class TurboStream
      def self.open(stream:, target:)
        pump = new(stream: stream, target: target)
        yield pump
      ensure
        pump&.close
      end

      def initialize(stream:, target:)
        @stream = stream
        @target = target
        @closed = false
      end

      # Append `text` to the pump's bound target. Text is HTML-escaped —
      # this is the path LLM token deltas flow through, so it must be safe
      # against `<script>` etc. in model output.
      def append(text)
        write_frame(action: "append", target: @target, body: ERB::Util.html_escape(text))
      end

      # Replace `target`'s contents with raw `html`. Caller owns escaping —
      # this exists for server-rendered partials (sources list, status badge)
      # where the HTML is trusted.
      def replace(target:, html:)
        write_frame(action: "replace", target: target, body: html)
      end

      # Idempotent. Swallows IOError / ClientDisconnected so a mid-stream
      # operator-navigate-away doesn't mask the real error from the block
      # (or surface as noise when the stream was already torn down).
      def close
        return if @closed

        @closed = true
        @stream.close
      rescue IOError, ActionController::Live::ClientDisconnected
        nil
      end

      private

      def write_frame(action:, target:, body:)
        escaped_target = ERB::Util.html_escape(target)
        @stream.write(
          %(<turbo-stream action="#{action}" target="#{escaped_target}"><template>#{body}</template></turbo-stream>)
        )
      end
    end
  end
end
