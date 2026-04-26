require "rails_helper"

RSpec.describe Curator::EmbedChunksJob, type: :job do
  let(:kb)       { create(:curator_knowledge_base, embedding_model: "text-embedding-3-small") }
  let(:document) { create(:curator_document, knowledge_base: kb, status: :embedding) }

  def create_chunk(seq, content)
    create(:curator_chunk, document: document, sequence: seq, content: content, status: :pending)
  end

  describe "happy path" do
    it "embeds every pending chunk, writes embeddings, and flips the doc to :complete" do
      chunks = 3.times.map { |i| create_chunk(i, "chunk #{i} body text") }
      stub   = stub_embed(model: "text-embedding-3-small")

      described_class.perform_now(document.id)

      expect(stub).to have_been_requested.once
      expect(chunks.map { |c| c.reload.status }).to all(eq("embedded"))
      expect(document.reload.status).to eq("complete")
      expect(Curator::Embedding.where(chunk: chunks).pluck(:embedding_model))
        .to all(eq("text-embedding-3-small"))
      expect(document.partially_embedded?).to be(false)
    end
  end

  describe "per-chunk rejection" do
    it "marks the offending chunk :failed but completes the rest of the batch" do
      good_a = create_chunk(0, "fine content A")
      bad    = create_chunk(1, "trigger-rejection content")
      good_b = create_chunk(2, "fine content B")

      WebMock.stub_request(:post, RubyLLMStubs::EMBEDDING_URL).to_return do |request|
        inputs = JSON.parse(request.body).fetch("input")
        inputs = [ inputs ] unless inputs.is_a?(Array)
        if inputs.include?(bad.content)
          {
            status:  400,
            headers: { "Content-Type" => "application/json" },
            body:    { "error" => { "type" => "invalid_request_error", "message" => "input too long" } }.to_json
          }
        else
          data = inputs.each_with_index.map do |text, idx|
            { "embedding" => deterministic_vector(text, 1536), "index" => idx, "object" => "embedding" }
          end
          {
            status:  200,
            headers: { "Content-Type" => "application/json" },
            body:    {
              "data"  => data,
              "model" => "text-embedding-3-small",
              "usage" => { "prompt_tokens" => inputs.length, "total_tokens" => inputs.length }
            }.to_json
          }
        end
      end

      described_class.perform_now(document.id)

      expect(good_a.reload.status).to eq("embedded")
      expect(good_b.reload.status).to eq("embedded")
      expect(bad.reload.status).to eq("failed")
      expect(bad.embed_error).to include("BadRequestError")
      expect(document.reload.status).to eq("complete")
      expect(document.failed_chunk_count).to eq(1)
      expect(document.partially_embedded?).to be(true)
    end
  end

  describe "whole-batch failure" do
    it "raises on a 503 and embeds nothing; a successful retry completes the doc" do
      create_chunk(0, "alpha")
      create_chunk(1, "beta")

      failing = stub_embed_error(:server_error)
      expect { described_class.perform_now(document.id) }.to raise_error(RubyLLM::ServiceUnavailableError)
      expect(Curator::Embedding.count).to eq(0)
      expect(document.reload.status).to eq("embedding")
      WebMock.remove_request_stub(failing)

      stub_embed
      described_class.perform_now(document.id)

      expect(document.reload.status).to eq("complete")
      expect(Curator::Embedding.count).to eq(2)
    end

    it "skips already-embedded chunks on retry (pending filter)" do
      already_embedded = create_chunk(0, "previously embedded")
      create(:curator_embedding, chunk: already_embedded, embedding_model: kb.embedding_model)
      already_embedded.update!(status: :embedded)

      create_chunk(1, "to-embed-now")

      stub = stub_embed
      described_class.perform_now(document.id)

      expect(stub).to have_been_requested.once
      expect(Curator::Embedding.count).to eq(2)
      # Verify the second embed call only saw 1 input (not both chunks).
      expect(WebMock).to have_requested(:post, RubyLLMStubs::EMBEDDING_URL)
        .with { |req| Array(JSON.parse(req.body).fetch("input")).length == 1 }
    end
  end

  describe "batch size" do
    it "honors config.embedding_batch_size when slicing pending chunks" do
      Curator.config.embedding_batch_size = 2
      5.times { |i| create_chunk(i, "content #{i}") }

      stub = stub_embed
      described_class.perform_now(document.id)

      # 5 chunks at batch_size=2 → 3 HTTP calls (2 / 2 / 1).
      expect(stub).to have_been_requested.times(3)
    ensure
      Curator.reset_config!
    end
  end

  describe "deleted-document mid-flight" do
    it "is a silent no-op when the document was destroyed before the job runs" do
      doc_id = document.id
      document.destroy!
      expect { described_class.perform_now(doc_id) }.not_to raise_error
    end
  end

  describe "non-:embedding doc" do
    it "is a no-op if the document is no longer in :embedding state" do
      create_chunk(0, "irrelevant")
      document.update!(status: :pending)

      stub = stub_embed
      described_class.perform_now(document.id)

      expect(stub).not_to have_been_requested
      expect(document.reload.status).to eq("pending")
    end
  end
end
