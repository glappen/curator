require "rails_helper"

RSpec.describe Curator::Retrievers::Pipeline do
  let(:kb) do
    create(:curator_knowledge_base,
           retrieval_strategy:   "vector",
           similarity_threshold: 0.0,
           chunk_limit:          5)
  end
  let(:document) { create(:curator_document, knowledge_base: kb) }

  def make_chunk(content:, sequence:)
    chunk = create(:curator_chunk,
                   document: document,
                   sequence: sequence,
                   content:  content,
                   status:   :embedded)
    create(:curator_embedding,
           chunk:           chunk,
           embedding:       deterministic_vector(content, 1536),
           embedding_model: kb.embedding_model)
    chunk
  end

  def open_row(strategy:, threshold:, limit: 5)
    Curator::Retrieval.create!(
      knowledge_base:       kb,
      query:                "alpha",
      embedding_model:      kb.embedding_model,
      retrieval_strategy:   strategy.to_s,
      similarity_threshold: threshold,
      chunk_limit:          limit
    )
  end

  before { stub_embed(model: kb.embedding_model) }

  describe "input validation (constructor raises before any DB write)" do
    it "raises on a blank query" do
      expect { described_class.new(query: "   ", knowledge_base: kb) }
        .to raise_error(ArgumentError, /query/i)
    end

    it "raises on an unknown strategy" do
      expect { described_class.new(query: "q", knowledge_base: kb, strategy: :bogus) }
        .to raise_error(ArgumentError, /strategy/i)
    end

    it "raises when strategy: :keyword is paired with a non-nil threshold" do
      expect {
        described_class.new(query: "q", knowledge_base: kb, strategy: :keyword, threshold: 0.5)
      }.to raise_error(ArgumentError, /threshold/i)
    end

    it "exposes resolved values for the caller to snapshot onto the row" do
      pipeline = described_class.new(query: "q", knowledge_base: kb, limit: 3, threshold: 0.4)
      expect(pipeline.knowledge_base).to eq(kb)
      expect(pipeline.strategy).to       eq(:vector)
      expect(pipeline.limit).to          eq(3)
      expect(pipeline.threshold).to      eq(0.4)
    end
  end

  describe "trace-step emission" do
    around do |ex|
      original = Curator.config.trace_level
      Curator.config.trace_level = :full
      ex.run
    ensure
      Curator.config.trace_level = original
    end

    it ":vector emits embed_query + vector_search" do
      make_chunk(content: "alpha", sequence: 0)
      row      = open_row(strategy: :vector, threshold: 0.0)
      pipeline = described_class.new(query: "alpha", knowledge_base: kb, strategy: :vector)

      pipeline.call(row)

      expect(row.retrieval_steps.order(:sequence).pluck(:step_type))
        .to eq(%w[embed_query vector_search])
    end

    it ":keyword emits only keyword_search (no embed_query)" do
      make_chunk(content: "alpha", sequence: 0)
      row      = open_row(strategy: :keyword, threshold: nil)
      pipeline = described_class.new(query: "alpha", knowledge_base: kb, strategy: :keyword)

      pipeline.call(row)

      expect(row.retrieval_steps.order(:sequence).pluck(:step_type))
        .to eq(%w[keyword_search])
    end

    it ":hybrid emits embed_query + rrf_fusion" do
      make_chunk(content: "alpha", sequence: 0)
      row      = open_row(strategy: :hybrid, threshold: 0.0)
      pipeline = described_class.new(query: "alpha", knowledge_base: kb, strategy: :hybrid)

      pipeline.call(row)

      expect(row.retrieval_steps.order(:sequence).pluck(:step_type))
        .to eq(%w[embed_query rrf_fusion])
    end
  end

  describe "hit persistence (curator_retrieval_hits)" do
    it "writes one row per Hit with snapshot columns matching the chunk + document" do
      chunk    = make_chunk(content: "alpha beta", sequence: 0)
      row      = open_row(strategy: :vector, threshold: 0.0)
      pipeline = described_class.new(query: "alpha beta", knowledge_base: kb, strategy: :vector)

      hits = pipeline.call(row)

      hit_rows = row.retrieval_hits.order(:rank).to_a
      expect(hit_rows.size).to eq(hits.size)
      first = hit_rows.first
      expect(first.rank).to          eq(1)
      expect(first.chunk_id).to      eq(chunk.id)
      expect(first.document_id).to   eq(document.id)
      expect(first.text).to          eq(chunk.content)
      expect(first.document_name).to eq(document.title)
      expect(first.score.to_f).to    be > 0.5
    end

    it "stores score: nil for keyword-only contributors (tsvector rank is not a probability)" do
      make_chunk(content: "alpha beta", sequence: 0)
      row      = open_row(strategy: :keyword, threshold: nil)
      pipeline = described_class.new(query: "alpha beta", knowledge_base: kb, strategy: :keyword)

      pipeline.call(row)

      hit_rows = row.retrieval_hits.order(:rank).to_a
      expect(hit_rows).not_to be_empty
      expect(hit_rows.map(&:score).compact).to eq([])
    end

    it "writes nothing when retrieval_row is nil (log_queries: false path)" do
      make_chunk(content: "alpha", sequence: 0)
      pipeline = described_class.new(query: "alpha", knowledge_base: kb, strategy: :vector)

      expect { pipeline.call(nil) }.not_to change(Curator::RetrievalHit, :count)
    end

    it "writes nothing when there are zero hits" do
      row      = open_row(strategy: :vector, threshold: 0.99)
      pipeline = described_class.new(query: "noise", knowledge_base: kb, strategy: :vector,
                                     threshold: 0.99)

      pipeline.call(row)

      expect(row.retrieval_hits).to be_empty
    end

    it "propagates insert failure (the caller's mark_failed! flips the parent row)" do
      make_chunk(content: "alpha", sequence: 0)
      row      = open_row(strategy: :vector, threshold: 0.0)
      pipeline = described_class.new(query: "alpha", knowledge_base: kb, strategy: :vector)

      allow(Curator::RetrievalHit).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { pipeline.call(row) }.to raise_error(ActiveRecord::StatementInvalid, /boom/)
    end
  end
end
