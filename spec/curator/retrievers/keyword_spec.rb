require "rails_helper"

RSpec.describe Curator::Retrievers::Keyword do
  subject(:strategy) { described_class.new }

  let(:kb)       { create(:curator_knowledge_base, tsvector_config: "english") }
  let(:document) { create(:curator_document, knowledge_base: kb) }

  def make_chunk(content:, sequence:, status: :embedded, page_number: nil, doc: document)
    create(:curator_chunk,
           document:    doc,
           sequence:    sequence,
           content:     content,
           page_number: page_number,
           status:      status)
  end

  it "returns hits ordered by descending tsvector rank with 1-indexed ranks" do
    # `quickly` and `quick` both stem to `quick` in english; the chunk
    # with both occurrences ranks above the chunk with one.
    high = make_chunk(content: "quick brown fox runs quickly across",            sequence: 0)
    low  = make_chunk(content: "the quick brown fox is fast across the meadow",  sequence: 1)
    _na  = make_chunk(content: "absolutely unrelated text about gardening",      sequence: 2)

    hits = strategy.call(kb, "quick", limit: 5)

    expect(hits.map(&:chunk_id).first(2)).to eq([ high.id, low.id ])
    expect(hits.map(&:rank)).to              eq((1..hits.size).to_a)
  end

  it "leaves Hit#score nil for every result" do
    make_chunk(content: "alpha beta gamma", sequence: 0)
    hit = strategy.call(kb, "alpha", limit: 5).first
    expect(hit.score).to be_nil
  end

  it "scopes to the given KB — chunks in another KB don't appear" do
    other_kb = create(:curator_knowledge_base, tsvector_config: "english")
    other    = create(:curator_document, knowledge_base: other_kb)
    _ours    = make_chunk(content: "alpha beta", sequence: 0)
    _theirs  = make_chunk(content: "alpha beta", sequence: 0, doc: other)

    hits = strategy.call(kb, "alpha", limit: 10)
    expect(hits.size).to eq(1)
    expect(hits.first.document_id).to eq(document.id)
  end

  it "returns chunks in :pending and :failed status (no embedding required)" do
    pending_chunk = make_chunk(content: "alpha beta", sequence: 0, status: :pending)
    failed_chunk  = make_chunk(content: "alpha gamma", sequence: 1, status: :failed)

    hit_ids = strategy.call(kb, "alpha", limit: 10).map(&:chunk_id)

    expect(hit_ids).to include(pending_chunk.id, failed_chunk.id)
  end

  it "respects the KB's tsvector_config end-to-end (index AND query)" do
    # Same content under two KBs with different stem configs. The
    # english KB stems "running" → "run" so a query for "run" hits;
    # the simple KB indexes the literal token "running" so the same
    # query for "run" misses.
    english_kb  = create(:curator_knowledge_base, tsvector_config: "english")
    simple_kb   = create(:curator_knowledge_base, tsvector_config: "simple")
    english_doc = create(:curator_document, knowledge_base: english_kb)
    simple_doc  = create(:curator_document, knowledge_base: simple_kb)

    english_chunk = create(:curator_chunk, document: english_doc, sequence: 0,
                                           content: "I am running today")
    create(:curator_chunk, document: simple_doc, sequence: 0,
                           content: "I am running today")

    english_hits = strategy.call(english_kb, "run", limit: 5)
    simple_hits  = strategy.call(simple_kb,  "run", limit: 5)

    expect(english_hits.map(&:chunk_id)).to eq([ english_chunk.id ])
    expect(simple_hits).to                  eq([])
  end

  it "honors the limit parameter" do
    5.times { |i| make_chunk(content: "alpha word#{i}", sequence: i) }
    expect(strategy.call(kb, "alpha", limit: 3).size).to eq(3)
  end

  it "populates document and chunk fields on the Hit" do
    document.update!(title: "Alpha Memo", source_url: "https://example.com/a")
    chunk = make_chunk(content: "alpha beta", sequence: 0, page_number: 7)

    hit = strategy.call(kb, "alpha", limit: 5).first

    expect(hit.chunk_id).to      eq(chunk.id)
    expect(hit.document_id).to   eq(document.id)
    expect(hit.document_name).to eq("Alpha Memo")
    expect(hit.source_url).to    eq("https://example.com/a")
    expect(hit.page_number).to   eq(7)
    expect(hit.text).to          eq("alpha beta")
  end

  it "returns an empty array when nothing matches the tsquery" do
    make_chunk(content: "alpha beta", sequence: 0)
    expect(strategy.call(kb, "zzzzzzz", limit: 5)).to eq([])
  end

  it "returns an empty array on blank query or non-positive limit" do
    make_chunk(content: "alpha", sequence: 0)
    expect(strategy.call(kb, "",  limit: 5)).to eq([])
    expect(strategy.call(kb, nil, limit: 5)).to eq([])
    expect(strategy.call(kb, "alpha", limit: 0)).to eq([])
  end
end
