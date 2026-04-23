require "spec_helper"

RSpec.describe Curator::TokenCounter do
  it "exposes a CHARS_PER_TOKEN heuristic constant" do
    expect(described_class::CHARS_PER_TOKEN).to be_a(Integer)
    expect(described_class::CHARS_PER_TOKEN).to be > 0
  end

  describe ".count" do
    it "returns 0 for nil or empty input" do
      expect(described_class.count(nil)).to eq(0)
      expect(described_class.count("")).to eq(0)
    end

    it "rounds up: a single char is one token" do
      expect(described_class.count("x")).to eq(1)
    end

    it "scales linearly with length at the CHARS_PER_TOKEN ratio" do
      ratio = described_class::CHARS_PER_TOKEN
      expect(described_class.count("a" * ratio)).to eq(1)
      expect(described_class.count("a" * (ratio * 10))).to eq(10)
    end

    it "rounds partials up (ceil), not down" do
      ratio = described_class::CHARS_PER_TOKEN
      expect(described_class.count("a" * (ratio + 1))).to eq(2)
    end
  end
end
