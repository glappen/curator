require "spec_helper"

RSpec.describe Curator::IngestResult do
  let(:document) { Object.new }

  it "constructs a created result with no reason" do
    result = described_class.new(document: document, status: :created)
    expect(result).to be_created
    expect(result).not_to be_duplicate
    expect(result.reason).to be_nil
  end

  it "constructs a duplicate result with an optional reason" do
    result = described_class.new(document: document, status: :duplicate, reason: "sha256 hit")
    expect(result).to be_duplicate
    expect(result.reason).to eq("sha256 hit")
  end

  it "rejects unknown statuses" do
    expect {
      described_class.new(document: document, status: :skipped)
    }.to raise_error(ArgumentError, /must be one of/)
  end

  it "is immutable (Data value object)" do
    result = described_class.new(document: document, status: :created)
    expect { result.instance_variable_set(:@status, :duplicate) }.to raise_error(FrozenError)
  end
end
