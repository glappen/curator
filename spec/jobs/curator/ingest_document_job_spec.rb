require "rails_helper"

RSpec.describe Curator::IngestDocumentJob, type: :job do
  include ActiveJob::TestHelper

  before do
    Curator.configure { |c| c.extractor = :basic }
  end

  after { Curator.reset_config! }

  let(:kb) { create(:curator_knowledge_base, chunk_size: 64, chunk_overlap: 8) }

  let(:document) do
    doc = create(:curator_document, knowledge_base: kb, status: :pending, mime_type: "text/markdown")
    doc.file.attach(
      io:           StringIO.new(text),
      filename:     "sample.md",
      content_type: "text/markdown"
    )
    doc
  end

  let(:text) do
    <<~MD
      First paragraph with enough words to register on the token counter.

      Second paragraph follows after a blank line and adds more content.

      Third paragraph closes things out so the chunker has material to pack.
    MD
  end

  it "passes the extractor a tempfile path with an extension derived from document.mime_type " \
     "(regression: extensionless ActiveStorage paths broke Kreuzberg MIME sniffing on bare-URL ingests)" do
    document.file.purge
    # Mimic the URL fetcher fallback: bare URL → filename "download" with no extension.
    document.file.attach(io: StringIO.new(text), filename: "download", content_type: "text/markdown")

    captured_path = nil
    captured_mime = nil
    allow_any_instance_of(Curator::Extractors::Basic).to receive(:extract) do |_, path, mime_type:|
      captured_path = path
      captured_mime = mime_type
      Curator::Extractors::ExtractionResult.new(content: text, mime_type: mime_type, pages: [])
    end

    described_class.perform_now(document.id)

    expect(captured_mime).to eq("text/markdown")
    expect(File.extname(captured_path)).to eq(".md")
  end

  it "extracts, chunks, persists chunks, advances to :embedding, and enqueues EmbedChunksJob" do
    described_class.perform_now(document.id)
    document.reload

    expect(document.status).to eq("embedding")
    expect(document.stage_error).to be_nil
    expect(document.chunks.count).to be >= 1

    first = document.chunks.order(:sequence).first
    expect(first.sequence).to eq(0)
    expect(first.status).to eq("pending")
    expect(first.content).to include("First paragraph")
    expect(first.token_count).to be > 0

    expect(Curator::EmbedChunksJob).to have_been_enqueued.with(document.id)
  end

  it "writes chunk sequences contiguously starting at zero" do
    described_class.perform_now(document.id)
    sequences = document.chunks.order(:sequence).pluck(:sequence)
    expect(sequences).to eq((0...sequences.length).to_a)
  end

  it "marks the document :failed and records stage_error when the extractor raises" do
    allow_any_instance_of(Curator::Extractors::Basic)
      .to receive(:extract).and_raise(Curator::ExtractionError, "boom")

    described_class.perform_now(document.id)

    document.reload
    expect(document.status).to eq("failed")
    expect(document.stage_error).to include("Curator::ExtractionError", "boom")
    expect(document.chunks).to be_empty
    expect(Curator::EmbedChunksJob).not_to have_been_enqueued
  end

  it "logs an error when the pipeline fails" do
    allow_any_instance_of(Curator::Extractors::Basic)
      .to receive(:extract).and_raise(Curator::ExtractionError, "boom")
    expect(Rails.logger).to receive(:error).with(/IngestDocumentJob failed.*Curator::ExtractionError.*boom/)

    described_class.perform_now(document.id)
  end

  it "marks :failed when the chunker yields no chunks (e.g. empty extraction)" do
    document.file.purge
    document.file.attach(io: StringIO.new(""), filename: "empty.md", content_type: "text/markdown")

    described_class.perform_now(document.id)

    document.reload
    expect(document.status).to eq("failed")
    expect(document.stage_error).to include("no chunks")
    expect(Curator::EmbedChunksJob).not_to have_been_enqueued
  end

  it "marks :failed when the chunker emits a negative offset (regression guard)" do
    bad_chunks = [ { content: "x", token_count: 1, char_start: -1, char_end: 5, page_number: nil } ]
    allow_any_instance_of(Curator::Chunkers::Paragraph).to receive(:chunk).and_return(bad_chunks)

    described_class.perform_now(document.id)

    document.reload
    expect(document.status).to eq("failed")
    expect(document.stage_error).to include("char_start=-1")
    expect(document.chunks).to be_empty
  end

  it "marks :failed with a clear error when the configured extractor is unsupported" do
    allow(Curator.config).to receive(:extractor).and_return(:nonsense)

    described_class.perform_now(document.id)

    document.reload
    expect(document.status).to eq("failed")
    expect(document.stage_error).to include("Curator::ConfigurationError", "nonsense")
  end

  it "is a no-op unless the document is still pending" do
    document.update!(status: :complete)

    expect {
      described_class.perform_now(document.id)
    }.not_to have_enqueued_job(Curator::EmbedChunksJob)

    expect(document.reload.status).to eq("complete")
  end

  it "is a silent no-op when the document was deleted before the job ran" do
    deleted_id = document.id
    document.destroy!

    expect {
      described_class.perform_now(deleted_id)
    }.not_to raise_error
    expect(Curator::EmbedChunksJob).not_to have_been_enqueued
  end

  describe "recovery: prior run committed chunks but failed before enqueue" do
    it "re-enqueues EmbedChunksJob without re-extracting when doc is :embedding with chunks" do
      document.update!(status: :embedding)
      create(:curator_chunk, document: document, sequence: 0)

      expect_any_instance_of(Curator::Extractors::Basic).not_to receive(:extract)

      described_class.perform_now(document.id)

      expect(Curator::EmbedChunksJob).to have_been_enqueued.with(document.id)
      expect(document.reload.status).to eq("embedding")
    end

    it "does not enqueue when doc is :embedding but has no chunks (state can't be recovered safely)" do
      document.update!(status: :embedding)

      described_class.perform_now(document.id)

      expect(Curator::EmbedChunksJob).not_to have_been_enqueued
    end
  end
end
