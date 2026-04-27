require "rails_helper"

RSpec.describe Curator::Answer do
  let(:kb) { build_stubbed(:curator_knowledge_base) }
  let(:hit) do
    Curator::Hit.new(
      rank: 1, chunk_id: 1, document_id: 1, document_name: "doc",
      page_number: nil, text: "body", score: 0.8, source_url: nil
    )
  end

  def results(hits)
    Curator::RetrievalResults.new(
      query: "q", hits: hits, duration_ms: 12,
      knowledge_base: kb, retrieval_id: 99
    )
  end

  def answer(hits:, strict_grounding:)
    described_class.new(
      answer:            "x",
      retrieval_results: results(hits),
      retrieval_id:      99,
      strict_grounding:  strict_grounding
    )
  end

  describe "#refused?" do
    it "is true when strict_grounding and hits are empty" do
      expect(answer(hits: [], strict_grounding: true).refused?).to be true
    end

    it "is false when strict_grounding is false (empty hits)" do
      expect(answer(hits: [], strict_grounding: false).refused?).to be false
    end

    it "is false when hits are non-empty regardless of strict_grounding" do
      expect(answer(hits: [ hit ], strict_grounding: true).refused?).to  be false
      expect(answer(hits: [ hit ], strict_grounding: false).refused?).to be false
    end

    it "coerces non-boolean strict_grounding to a boolean (defensive)" do
      expect(answer(hits: [], strict_grounding: nil).refused?).to be false
    end
  end

  describe "#sources" do
    it "returns retrieval_results.hits" do
      a = answer(hits: [ hit ], strict_grounding: false)
      expect(a.sources).to eq([ hit ])
    end

    it "is empty when retrieval_results has no hits" do
      a = answer(hits: [], strict_grounding: true)
      expect(a.sources).to eq([])
    end
  end

  it "exposes the constructor fields" do
    a = answer(hits: [ hit ], strict_grounding: true)
    expect(a.answer).to eq("x")
    expect(a.retrieval_results.hits).to eq([ hit ])
    expect(a.retrieval_id).to eq(99)
    expect(a.strict_grounding).to be true
  end
end
