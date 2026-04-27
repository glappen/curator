require "rails_helper"

# End-to-end smoke for the M3 retrieval pipeline. Drives the full chain
# inline against the dummy app:
#
#   Curator.ingest → IngestDocumentJob → EmbedChunksJob (real body,
#   RubyLLM stubbed at HTTP via the suite-level stub_embed) →
#   Curator.search across :vector / :keyword / :hybrid →
#   Curator.reembed scope=:all → re-search.
#
# The point is not retrieval quality (the deterministic stub doesn't
# model real semantics) — it's that every layer's outputs are wired to
# the next layer's inputs and that the snapshot row + status
# transitions hold across a full round trip.
RSpec.describe "Curator retrieval end-to-end smoke", type: :request do
  include ActiveJob::TestHelper

  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }
  let(:md_path)     { fixture_dir.join("sample.md") }
  let(:csv_path)    { fixture_dir.join("sample.csv") }

  let!(:default_kb) { Curator::KnowledgeBase.seed_default! }

  before { Curator.configure { |c| c.extractor = :basic } }
  after  { Curator.reset_config! }

  # Drives ingestion with the suite-level deterministic embed stub so
  # cosine ordering between queries and chunks that share tokens is
  # meaningful.
  def ingest_corpus!
    perform_enqueued_jobs do
      Curator.ingest(md_path.to_s)
      Curator.ingest(csv_path.to_s)
    end
  end

  def all_documents
    Curator::Document.where(knowledge_base_id: default_kb.id)
  end

  def all_chunks
    Curator::Chunk.joins(:document).where(curator_documents: { knowledge_base_id: default_kb.id })
  end

  # Ranks are 1-indexed and contiguous — every retrieval strategy must
  # number hits 1..n with no gaps, regardless of how the underlying
  # candidates were scored or fused.
  def expect_ranks_monotonic(results)
    expect(results.hits.map(&:rank)).to eq((1..results.size).to_a)
  end

  context "after ingesting a small corpus" do
    before { ingest_corpus! }

    it "lands every document at :complete with one embedding row per chunk" do
      docs = all_documents
      expect(docs.count).to eq(2)
      expect(docs.pluck(:status)).to all(eq("complete"))

      chunk_count = all_chunks.count
      expect(chunk_count).to be >= 2
      expect(Curator::Embedding.where(chunk_id: all_chunks.select(:id)).count).to eq(chunk_count)
      expect(Curator::Embedding.distinct.pluck(:embedding_model)).to contain_exactly(default_kb.embedding_model)
    end

    describe "vector retrieval" do
      it "returns ranked hits and snapshots strategy=vector" do
        results = Curator.search("Sample Markdown",
                                 knowledge_base: default_kb,
                                 strategy:       :vector,
                                 threshold:      0.0)

        expect(results).not_to be_empty
        expect_ranks_monotonic(results)
        expect(results.hits.map(&:score)).to all(be_a(Float))

        row = Curator::Search.find(results.search_id)
        expect(row.retrieval_strategy).to eq("vector")
        expect(row).to be_success
      end
    end

    describe "keyword retrieval" do
      it "returns ranked hits without invoking the embed API and snapshots strategy=keyword" do
        WebMock.reset_executed_requests!
        results = Curator.search("markdown",
                                 knowledge_base: default_kb,
                                 strategy:       :keyword)

        expect(results).not_to be_empty
        expect_ranks_monotonic(results)
        expect(results.hits.map(&:score)).to all(be_nil)
        expect(WebMock).not_to have_requested(:post, RubyLLMStubs::EMBEDDING_URL)

        row = Curator::Search.find(results.search_id)
        expect(row.retrieval_strategy).to   eq("keyword")
        expect(row.similarity_threshold).to be_nil
        expect(row).to                      be_success
      end
    end

    describe "hybrid retrieval (KB default)" do
      it "fuses vector + keyword hits and snapshots strategy=hybrid" do
        results = Curator.search("Sample Markdown",
                                 knowledge_base: default_kb,
                                 threshold:      -1.0)

        expect(results).not_to be_empty
        expect_ranks_monotonic(results)

        row = Curator::Search.find(results.search_id)
        expect(row.retrieval_strategy).to eq("hybrid")
        expect(row).to                    be_success
      end
    end
  end

  describe "reembed scope=:all round trip" do
    it "drives every chunk through :pending → :embedded and leaves search working" do
      ingest_corpus!

      original_embedding_ids = Curator::Embedding.where(chunk_id: all_chunks.select(:id)).pluck(:id)
      expect(original_embedding_ids).not_to be_empty

      result = nil
      perform_enqueued_jobs do
        result = Curator.reembed(knowledge_base: default_kb, scope: :all)
      end

      expect(result.scope).to             eq(:all)
      expect(result.documents_touched).to eq(all_documents.count)
      expect(result.chunks_touched).to    eq(all_chunks.count)

      # Embedding rows were nuked and rewritten — no overlap with the
      # pre-reembed set — and every chunk landed back at :embedded with
      # its document at :complete.
      new_embedding_ids = Curator::Embedding.where(chunk_id: all_chunks.select(:id)).pluck(:id)
      expect(new_embedding_ids.size).to                     eq(all_chunks.count)
      expect(new_embedding_ids & original_embedding_ids).to be_empty
      expect(all_chunks.pluck(:status)).to                  all(eq("embedded"))
      expect(all_documents.pluck(:status)).to               all(eq("complete"))

      results = Curator.search("Sample Markdown",
                               knowledge_base: default_kb,
                               threshold:      -1.0)
      expect(results).not_to be_empty
      expect_ranks_monotonic(results)
    end
  end
end
