require "rails_helper"

RSpec.describe Curator::Retrievers::Hybrid do
  let(:kb)       { create(:curator_knowledge_base, tsvector_config: "english") }
  let(:document) { create(:curator_document, knowledge_base: kb) }

  # Mirrors Pipeline#run_hybrid: run Vector + Keyword and fuse them.
  # The spec previously called a Hybrid#call that did the same; the
  # fusion-only Hybrid module exposes only `.fuse`.
  def strategy_call(kb, query, query_vec, limit:, threshold:)
    return [] if limit <= 0
    vector_hits  = Curator::Retrievers::Vector.new.call(kb, query_vec, limit: limit, threshold: threshold)
    keyword_hits = Curator::Retrievers::Keyword.new.call(kb, query, limit: limit)
    described_class.fuse(vector_hits, keyword_hits, limit: limit)
  end

  def make_chunk(content:, sequence:, embed_for: nil, status: :embedded, page_number: nil, doc: document)
    chunk = create(:curator_chunk,
                   document:    doc,
                   sequence:    sequence,
                   content:     content,
                   page_number: page_number,
                   status:      status)
    if embed_for
      create(:curator_embedding,
             chunk:           chunk,
             embedding:       deterministic_vector(embed_for, 1536),
             embedding_model: kb.embedding_model)
    end
    chunk
  end

  def query_vec(text)
    deterministic_vector(text, 1536)
  end

  describe "fusion ordering" do
    it "ranks a chunk that's top in both lists above any single-list strong hit" do
      # `dual` is high-rank in both vector (its content shares all
      # tokens with the query) and keyword (it has the most token
      # repetition for the query word). `vec_only` ranks high under
      # vector but doesn't contain the keyword. `kw_only` ranks high
      # under keyword but its embedding is dissimilar to the query.
      dual     = make_chunk(content: "alpha alpha alpha gamma",
                            sequence: 0, embed_for: "alpha gamma")
      vec_only = make_chunk(content: "gamma delta epsilon",
                            sequence: 1, embed_for: "alpha gamma")
      kw_only  = make_chunk(content: "alpha alpha",
                            sequence: 2, embed_for: "epsilon zeta theta")

      hits = strategy_call(kb, "alpha", query_vec("alpha gamma"), limit: 5, threshold: 0.0)

      expect(hits.first.chunk_id).to eq(dual.id)
      expect(hits.map(&:chunk_id)).to include(vec_only.id, kw_only.id)
      expect(hits.map(&:rank)).to     eq((1..hits.size).to_a)
    end

    it "filters the vector list by threshold *before* fusion — high threshold collapses to keyword-only" do
      # Only kw_only's content has the keyword. Both chunks' embeddings
      # are far from query_vec("alpha"), so threshold 0.99 empties the
      # vector list and fusion falls back to keyword-only — the
      # operationally meaningful collapse case (Phase 5 spec).
      kw_only = make_chunk(content: "alpha alpha", sequence: 0,
                           embed_for: "totally unrelated tokens z")
      _filler = make_chunk(content: "yet other words here", sequence: 1,
                           embed_for: "different unrelated y")

      vec_lo = strategy_call(kb, "alpha", query_vec("alpha"), limit: 5, threshold: 0.0).map(&:chunk_id)
      vec_hi = strategy_call(kb, "alpha", query_vec("alpha"), limit: 5, threshold: 0.99).map(&:chunk_id)

      expect(vec_hi).to eq([ kw_only.id ])
      expect(vec_lo).to include(kw_only.id)
    end
  end

  describe "score field provenance" do
    it "carries the cosine score for vector contributors and nil for keyword-only" do
      # Threshold 0.5 keeps `dual` (its embedding == query_vec, so
      # cosine ≈ 1.0) but drops `kw_only` from the vector half (its
      # embedding shares no tokens with the query, cosine ≈ 0). Both
      # match keyword "alpha". Fusion includes both; only the
      # vector-contributor `dual` carries a cosine score.
      dual    = make_chunk(content: "alpha", sequence: 0, embed_for: "alpha")
      kw_only = make_chunk(content: "alpha alpha", sequence: 1,
                           embed_for: "totally unrelated tokens z")

      hits     = strategy_call(kb, "alpha", query_vec("alpha"), limit: 5, threshold: 0.5)
      hit_for  = ->(id) { hits.find { |h| h.chunk_id == id } }

      expect(hit_for[dual.id].score).to    be_a(Float)
      expect(hit_for[dual.id].score).to    be_between(0.0, 1.0).inclusive
      expect(hit_for[kw_only.id].score).to be_nil
    end
  end

  describe "edge cases" do
    it "returns an empty array when both halves are empty" do
      expect(strategy_call(kb, "zzzzzzz", query_vec("nothing"), limit: 5, threshold: 0.99)).to eq([])
    end

    it "returns an empty array on non-positive limit" do
      make_chunk(content: "alpha", sequence: 0, embed_for: "alpha")
      expect(strategy_call(kb, "alpha", query_vec("alpha"), limit: 0, threshold: 0.0)).to eq([])
    end

    it "honors limit on the fused output" do
      5.times { |i| make_chunk(content: "alpha word#{i}", sequence: i, embed_for: "alpha word#{i}") }
      hits = strategy_call(kb, "alpha", query_vec("alpha"), limit: 3, threshold: 0.0)
      expect(hits.size).to eq(3)
      expect(hits.map(&:rank)).to eq([ 1, 2, 3 ])
    end

    it "populates document and chunk fields on the Hit" do
      document.update!(title: "Alpha Memo", source_url: "https://example.com/a")
      chunk = make_chunk(content: "alpha beta", sequence: 0, page_number: 9, embed_for: "alpha beta")

      hit = strategy_call(kb, "alpha", query_vec("alpha beta"), limit: 5, threshold: 0.0).first

      expect(hit.chunk_id).to      eq(chunk.id)
      expect(hit.document_id).to   eq(document.id)
      expect(hit.document_name).to eq("Alpha Memo")
      expect(hit.source_url).to    eq("https://example.com/a")
      expect(hit.page_number).to   eq(9)
      expect(hit.text).to          eq("alpha beta")
    end
  end
end
