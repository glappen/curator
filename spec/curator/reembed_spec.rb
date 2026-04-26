require "rails_helper"

RSpec.describe Curator, ".reembed" do
  include ActiveJob::TestHelper

  let(:kb)       { create(:curator_knowledge_base, embedding_model: "text-embedding-3-small") }
  let(:document) { create(:curator_document, knowledge_base: kb, status: :complete) }

  def make_embedded_chunk(doc: document, sequence: nil, model: kb.embedding_model)
    seq = sequence || doc.chunks.maximum(:sequence).to_i + (doc.chunks.exists? ? 1 : 0)
    chunk = create(:curator_chunk, document: doc, sequence: seq, status: :embedded)
    create(:curator_embedding, chunk: chunk, embedding_model: model)
    chunk
  end

  def make_failed_chunk(doc: document, sequence: nil, embed_error: "boom")
    seq = sequence || doc.chunks.maximum(:sequence).to_i + (doc.chunks.exists? ? 1 : 0)
    create(:curator_chunk, document: doc, sequence: seq, status: :failed, embed_error: embed_error)
  end

  def make_pending_chunk(doc: document, sequence: nil)
    seq = sequence || doc.chunks.maximum(:sequence).to_i + (doc.chunks.exists? ? 1 : 0)
    create(:curator_chunk, document: doc, sequence: seq, status: :pending)
  end

  describe "no-work case" do
    it "returns chunks_touched: 0 and never calls /embeddings on a clean KB" do
      make_embedded_chunk

      WebMock.reset_executed_requests!

      result = Curator.reembed(knowledge_base: kb)

      expect(result.chunks_touched).to eq(0)
      expect(result.documents_touched).to eq(0)
      expect(result.scope).to eq(:stale)
      expect(WebMock).not_to have_requested(:post, RubyLLMStubs::EMBEDDING_URL)
      expect(Curator::EmbedChunksJob).not_to have_been_enqueued
    end

    it "is also a no-op for :failed when no chunks are :failed" do
      make_embedded_chunk
      WebMock.reset_executed_requests!

      result = Curator.reembed(knowledge_base: kb, scope: :failed)

      expect(result.chunks_touched).to eq(0)
      expect(WebMock).not_to have_requested(:post, RubyLLMStubs::EMBEDDING_URL)
    end
  end

  describe ":stale scope" do
    it "re-embeds chunks whose embedding_model differs from the KB's" do
      stale = make_embedded_chunk(model: "old-model")
      fresh = make_embedded_chunk(model: kb.embedding_model)

      result = Curator.reembed(knowledge_base: kb, scope: :stale)

      expect(result.chunks_touched).to eq(1)
      expect(result.documents_touched).to eq(1)
      expect(stale.reload.status).to eq("pending")
      expect(Curator::Embedding.where(chunk_id: stale.id)).to be_empty
      expect(fresh.reload.status).to eq("embedded")
      expect(Curator::Embedding.where(chunk_id: fresh.id)).to exist
      expect(document.reload.status).to eq("embedding")
      expect(Curator::EmbedChunksJob).to have_been_enqueued.with(document.id)
    end

    it "includes :failed chunks alongside model-stale embedded ones" do
      stale  = make_embedded_chunk(model: "old-model")
      failed = make_failed_chunk

      result = Curator.reembed(knowledge_base: kb, scope: :stale)

      expect(result.chunks_touched).to eq(2)
      expect(stale.reload.status).to eq("pending")
      expect(failed.reload.status).to eq("pending")
      expect(failed.reload.embed_error).to be_nil
    end

    it "counts a chunk that's both :failed AND has a stale embedding row exactly once" do
      # Edge case in the OR: failed-status chunk that also happens to
      # have a stale embedding row (e.g. status flipped to :failed
      # post-embed). Both halves of the OR match — must dedupe.
      overlap = create(:curator_chunk, document: document, sequence: 0, status: :failed, embed_error: "boom")
      create(:curator_embedding, chunk: overlap, embedding_model: "old-model")

      result = Curator.reembed(knowledge_base: kb, scope: :stale)

      expect(result.chunks_touched).to eq(1)
      expect(overlap.reload.status).to eq("pending")
      expect(Curator::Embedding.where(chunk_id: overlap.id)).to be_empty
    end

    it "enqueues one EmbedChunksJob per touched document" do
      doc2 = create(:curator_document, knowledge_base: kb, status: :complete)
      stale1 = make_embedded_chunk(doc: document, model: "old-model")
      stale2 = make_embedded_chunk(doc: doc2, model: "old-model")

      result = Curator.reembed(knowledge_base: kb, scope: :stale)

      expect(result.chunks_touched).to eq(2)
      expect(result.documents_touched).to eq(2)
      expect(stale1.reload.status).to eq("pending")
      expect(stale2.reload.status).to eq("pending")
      expect(document.reload.status).to eq("embedding")
      expect(doc2.reload.status).to eq("embedding")
      expect(Curator::EmbedChunksJob).to have_been_enqueued.with(document.id).exactly(:once)
      expect(Curator::EmbedChunksJob).to have_been_enqueued.with(doc2.id).exactly(:once)
    end

    it "excludes :pending chunks (mid-flight ingest)" do
      pending = make_pending_chunk

      result = Curator.reembed(knowledge_base: kb, scope: :stale)

      expect(result.chunks_touched).to eq(0)
      expect(pending.reload.status).to eq("pending")
      expect(document.reload.status).to eq("complete") # untouched
      expect(Curator::EmbedChunksJob).not_to have_been_enqueued
    end
  end

  describe ":failed scope" do
    it "only touches :failed chunks; leaves model-stale :embedded chunks alone" do
      stale  = make_embedded_chunk(model: "old-model")
      failed = make_failed_chunk

      result = Curator.reembed(knowledge_base: kb, scope: :failed)

      expect(result.chunks_touched).to eq(1)
      expect(failed.reload.status).to eq("pending")
      expect(stale.reload.status).to eq("embedded") # untouched
      expect(Curator::Embedding.where(chunk_id: stale.id)).to exist
    end
  end

  describe ":all scope" do
    it "nukes embeddings and re-embeds even up-to-date chunks" do
      fresh1 = make_embedded_chunk(model: kb.embedding_model)
      fresh2 = make_embedded_chunk(model: kb.embedding_model)

      result = Curator.reembed(knowledge_base: kb, scope: :all)

      expect(result.chunks_touched).to eq(2)
      expect(Curator::Embedding.where(chunk_id: [ fresh1.id, fresh2.id ])).to be_empty
      expect(fresh1.reload.status).to eq("pending")
      expect(fresh2.reload.status).to eq("pending")
      expect(document.reload.status).to eq("embedding")
    end

    it "re-stems content_tsvector with the KB's current tsvector_config" do
      kb.update!(tsvector_config: "english")
      chunk = create(:curator_chunk, document: document, sequence: 0, content: "running quickly")
      # Initial tsvector under english stems "running" → "run"
      english_lexemes = lexemes(chunk.id)
      expect(english_lexemes).to include("run")
      expect(english_lexemes).not_to include("running")

      kb.update!(tsvector_config: "simple")
      Curator.reembed(knowledge_base: kb, scope: :all)

      simple_lexemes = lexemes(chunk.id)
      expect(simple_lexemes).to include("running")
      expect(simple_lexemes).not_to include("run")
    end
  end

  describe "pre-flight" do
    it "raises EmbeddingDimensionMismatch before any row is touched" do
      stale = make_embedded_chunk(model: "old-model")
      stub_embed(model: kb.embedding_model, dimension: 1024)

      expect {
        Curator.reembed(knowledge_base: kb, scope: :stale)
      }.to raise_error(Curator::EmbeddingDimensionMismatch) { |e|
        expect(e.expected).to be > 0
        expect(e.actual).to eq(1024)
      }

      # Nothing got touched — original embedding still there, status unchanged.
      expect(stale.reload.status).to eq("embedded")
      expect(Curator::Embedding.where(chunk_id: stale.id)).to exist
      expect(document.reload.status).to eq("complete")
      expect(Curator::EmbedChunksJob).not_to have_been_enqueued
    end

    it "wraps RubyLLM transport errors as Curator::EmbeddingError" do
      make_embedded_chunk(model: "old-model")
      stub_embed_error(:server_error, model: kb.embedding_model)

      expect {
        Curator.reembed(knowledge_base: kb, scope: :stale)
      }.to raise_error(Curator::EmbeddingError, /pre-flight embed failed/)

      expect(Curator::EmbedChunksJob).not_to have_been_enqueued
    end

    it "raises on dim mismatch for :failed and :all too" do
      make_failed_chunk
      stub_embed(model: kb.embedding_model, dimension: 1024)

      expect {
        Curator.reembed(knowledge_base: kb, scope: :failed)
      }.to raise_error(Curator::EmbeddingDimensionMismatch)

      expect {
        Curator.reembed(knowledge_base: kb, scope: :all)
      }.to raise_error(Curator::EmbeddingDimensionMismatch)
    end
  end

  describe "argument handling" do
    it "raises ArgumentError for unknown scope" do
      expect {
        Curator.reembed(knowledge_base: kb, scope: :bogus)
      }.to raise_error(ArgumentError, /scope:/)
    end

    it "resolves a string slug" do
      make_failed_chunk
      result = Curator.reembed(knowledge_base: kb.slug, scope: :failed)
      expect(result.chunks_touched).to eq(1)
    end
  end

  def lexemes(chunk_id)
    row = Curator::Chunk.connection.select_one(
      Curator::Chunk.sanitize_sql_array([
        "SELECT content_tsvector::text AS tv FROM curator_chunks WHERE id = ?", chunk_id
      ])
    )
    row.fetch("tv").to_s.scan(/'([^']+)'/).flatten
  end
end
