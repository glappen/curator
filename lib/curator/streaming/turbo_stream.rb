module Curator
  module Streaming
    # Phase 1 skeleton. `.open` provides just enough block-sugar shape
    # for Phase 2B's controller to call against; the per-frame writers
    # (#append, #replace, #close) are no-op stubs. Phase 2A replaces
    # the stubs with real `<turbo-stream>` frame writes and hardens
    # `.open` to swallow `IOError` / `ActionController::Live::ClientDisconnected`
    # on close (operator navigated away mid-stream).
    #
    # TODO Phase 2A: implement #append, #replace, #close + close-error
    # swallowing in `.open`.
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

      def append(text)
        # TODO Phase 2A: write a `<turbo-stream action="append">` frame.
      end

      def replace(target:, html:)
        # TODO Phase 2A: write a `<turbo-stream action="replace">` frame.
      end

      def close
        return if @closed

        @closed = true
        # TODO Phase 2A: flush + close the underlying stream.
      end
    end
  end
end
