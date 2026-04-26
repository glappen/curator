require "rails_helper"

RSpec.describe Curator::SearchResults do
  let(:kb)  { build_stubbed(:curator_knowledge_base) }
  let(:hit) do
    Curator::Hit.new(
      rank: 1, chunk_id: 1, document_id: 1, document_name: "doc",
      page_number: nil, text: "body", score: 0.8, source_url: nil
    )
  end

  def results(hits)
    described_class.new(query: "q", hits: hits, duration_ms: 12, knowledge_base: kb, search_id: 99)
  end

  it "is empty when hits is empty" do
    r = results([])
    expect(r).to be_empty
    expect(r.size).to eq(0)
  end

  it "iterates hits and reports size" do
    r = results([ hit, hit ])
    expect(r).not_to be_empty
    expect(r.size).to eq(2)
    expect(r.to_a).to eq([ hit, hit ])
  end

  it "enumerable methods compose (Enumerable mixed in)" do
    r = results([ hit ])
    expect(r.first).to eq(hit)
    expect(r.map(&:chunk_id)).to eq([ 1 ])
  end

  it "exposes the bookkeeping fields" do
    r = results([ hit ])
    expect(r.query).to          eq("q")
    expect(r.duration_ms).to    eq(12)
    expect(r.knowledge_base).to eq(kb)
    expect(r.search_id).to      eq(99)
  end
end
