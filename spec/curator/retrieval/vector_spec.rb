require "rails_helper"

RSpec.describe Curator::Retrieval::Vector do
  subject(:strategy) { described_class.new }

  let(:kb)       { create(:curator_knowledge_base) }
  let(:document) { create(:curator_document, knowledge_base: kb) }

  def make_chunk(content:, sequence:, page_number: nil)
    chunk = create(:curator_chunk,
                   document:    document,
                   sequence:    sequence,
                   content:     content,
                   page_number: page_number,
                   status:      :embedded)
    create(:curator_embedding,
           chunk:           chunk,
           embedding:       deterministic_vector(content, 1536),
           embedding_model: kb.embedding_model)
    chunk
  end

  def query_vec(text)
    deterministic_vector(text, 1536)
  end

  it "returns hits ordered by descending cosine similarity, ranks 1-indexed" do
    near = make_chunk(content: "alpha beta gamma",  sequence: 0)
    mid  = make_chunk(content: "alpha delta",       sequence: 1)
    far  = make_chunk(content: "epsilon zeta",      sequence: 2)

    hits = strategy.call(kb, query_vec("alpha beta gamma"), limit: 5, threshold: 0.0)

    expect(hits.map(&:chunk_id)).to eq([ near.id, mid.id, far.id ])
    expect(hits.map(&:rank)).to     eq([ 1, 2, 3 ])
    expect(hits.first.score).to be > hits.last.score
    expect(hits.map(&:score)).to all(be_between(0.0, 1.0).inclusive)
  end

  it "drops hits below the cosine threshold before ranking" do
    near = make_chunk(content: "alpha beta gamma", sequence: 0)
    _far = make_chunk(content: "epsilon zeta",     sequence: 1)

    hits = strategy.call(kb, query_vec("alpha beta gamma"), limit: 5, threshold: 0.95)

    expect(hits.map(&:chunk_id)).to eq([ near.id ])
    expect(hits.first.rank).to eq(1)
  end

  it "honors limit (caps the candidate set before ranking)" do
    chunks = 3.times.map { |i| make_chunk(content: "alpha word#{i}", sequence: i) }
    hits = strategy.call(kb, query_vec("alpha word0"), limit: 2, threshold: 0.0)
    expect(hits.size).to eq(2)
    expect(hits.first.chunk_id).to eq(chunks.first.id)
  end

  it "ignores embeddings whose model doesn't match the KB's current model" do
    stale_chunk = create(:curator_chunk, document: document, sequence: 0, content: "alpha beta", status: :embedded)
    create(:curator_embedding,
           chunk:           stale_chunk,
           embedding:       deterministic_vector("alpha beta", 1536),
           embedding_model: "old-model")
    fresh = make_chunk(content: "alpha beta", sequence: 1)

    hits = strategy.call(kb, query_vec("alpha beta"), limit: 5, threshold: 0.0)

    expect(hits.map(&:chunk_id)).to eq([ fresh.id ])
  end

  it "populates document and chunk fields on the Hit" do
    document.update!(title: "Alpha Memo", source_url: "https://example.com/a")
    chunk = make_chunk(content: "alpha beta", sequence: 0, page_number: 4)

    hit = strategy.call(kb, query_vec("alpha beta"), limit: 5, threshold: 0.0).first

    expect(hit.chunk_id).to      eq(chunk.id)
    expect(hit.document_id).to   eq(document.id)
    expect(hit.document_name).to eq("Alpha Memo")
    expect(hit.source_url).to    eq("https://example.com/a")
    expect(hit.page_number).to   eq(4)
    expect(hit.text).to          eq("alpha beta")
  end

  it "returns an empty array when the KB has no embeddings" do
    hits = strategy.call(kb, query_vec("anything"), limit: 5, threshold: 0.0)
    expect(hits).to eq([])
  end

  it "returns an empty array on nil query_vec or non-positive limit" do
    expect(strategy.call(kb, nil, limit: 5, threshold: 0.0)).to eq([])
    expect(strategy.call(kb, query_vec("x"), limit: 0, threshold: 0.0)).to eq([])
  end
end
