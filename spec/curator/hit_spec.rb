require "rails_helper"

RSpec.describe Curator::Hit do
  let(:base_attrs) do
    {
      rank:          1,
      chunk_id:      42,
      document_id:   7,
      document_name: "Refund Policy.pdf",
      page_number:   3,
      text:          "Refunds are processed within 14 days.",
      score:         0.91,
      source_url:    "https://example.com/refunds.pdf"
    }
  end

  it "exposes every field via reader" do
    hit = described_class.new(**base_attrs)
    base_attrs.each { |k, v| expect(hit.public_send(k)).to eq(v) }
  end

  it "is value-equal across equivalent instances" do
    expect(described_class.new(**base_attrs)).to eq(described_class.new(**base_attrs))
  end

  it "tolerates a nil score for keyword-only contributions" do
    hit = described_class.new(**base_attrs.merge(score: nil))
    expect(hit.score).to be_nil
  end

  it "raises on missing required fields" do
    expect { described_class.new(**base_attrs.except(:chunk_id)) }
      .to raise_error(ArgumentError)
  end
end
