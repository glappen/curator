require "rails_helper"

RSpec.describe Curator::Streaming::TurboStream do
  let(:io) { StringIO.new }

  describe "#append" do
    it "writes a turbo-stream append frame for the bound target" do
      pump = described_class.new(stream: io, target: "console-answer")
      pump.append("hello")

      expect(io.string).to eq(
        '<turbo-stream action="append" target="console-answer">' \
        "<template>hello</template>" \
        "</turbo-stream>"
      )
    end

    it "HTML-escapes the appended text" do
      pump = described_class.new(stream: io, target: "console-answer")
      pump.append("<script>alert('x')</script>")

      expect(io.string).to eq(
        '<turbo-stream action="append" target="console-answer">' \
        "<template>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</template>" \
        "</turbo-stream>"
      )
      expect(io.string).not_to include("<script>")
    end

    it "HTML-escapes the target attribute (defense in depth)" do
      pump = described_class.new(stream: io, target: 'x" onmouseover="evil')
      pump.append("hi")

      expect(io.string).to include('target="x&quot; onmouseover=&quot;evil"')
      expect(io.string).not_to include('onmouseover="evil"')
    end

    it "writes one frame per call (deltas append in order)" do
      pump = described_class.new(stream: io, target: "t")
      pump.append("a")
      pump.append("b")

      expect(io.string.scan("<turbo-stream").size).to eq(2)
      expect(io.string.index("<template>a</template>"))
        .to be < io.string.index("<template>b</template>")
    end
  end

  describe "#replace" do
    it "writes a replace frame with raw html for an arbitrary target" do
      pump = described_class.new(stream: io, target: "console-answer")
      pump.replace(target: "console-sources", html: "<li>doc</li>")

      expect(io.string).to eq(
        '<turbo-stream action="replace" target="console-sources">' \
        "<template><li>doc</li></template>" \
        "</turbo-stream>"
      )
    end
  end

  describe "#close" do
    it "closes the underlying stream" do
      pump = described_class.new(stream: io, target: "x")
      pump.close

      expect(io).to be_closed
    end

    it "is idempotent" do
      pump = described_class.new(stream: io, target: "x")
      pump.close

      expect { pump.close }.not_to raise_error
    end

    it "swallows IOError raised by the underlying stream close" do
      stream = instance_double(StringIO)
      allow(stream).to receive(:close).and_raise(IOError)

      pump = described_class.new(stream: stream, target: "x")

      expect { pump.close }.not_to raise_error
    end

    it "swallows ActionController::Live::ClientDisconnected" do
      stream = instance_double(StringIO)
      allow(stream).to receive(:close)
        .and_raise(ActionController::Live::ClientDisconnected)

      pump = described_class.new(stream: stream, target: "x")

      expect { pump.close }.not_to raise_error
    end
  end

  describe ".open" do
    it "yields the pump and closes the stream after the block returns" do
      yielded = nil
      described_class.open(stream: io, target: "console-answer") do |pump|
        yielded = pump
        pump.append("hi")
      end

      expect(yielded).to be_a(described_class)
      expect(io).to be_closed
      expect(io.string).to include("<template>hi</template>")
    end

    it "re-raises errors from the block but still closes the stream" do
      expect {
        described_class.open(stream: io, target: "x") do |_pump|
          raise IOError, "boom"
        end
      }.to raise_error(IOError, "boom")

      expect(io).to be_closed
    end
  end
end
