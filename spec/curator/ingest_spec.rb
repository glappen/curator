require "rails_helper"
require "tempfile"

RSpec.describe Curator, ".ingest" do
  include ActiveJob::TestHelper

  let(:kb)          { create(:curator_knowledge_base) }
  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }
  let(:md_path)     { fixture_dir.join("sample.md") }

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with("example.com").and_return([ "93.184.216.34" ])
    allow(Resolv).to receive(:getaddresses).with("www.cnn.com").and_return([ "151.101.3.5" ])
  end

  describe "creates a document on first ingest" do
    it "returns IngestResult(status: :created) and persists the document" do
      result = nil
      expect {
        result = Curator.ingest(md_path.to_s, knowledge_base: kb)
      }.to change(Curator::Document, :count).by(1)

      expect(result).to be_a(Curator::IngestResult)
      expect(result).to be_created
      doc = result.document
      expect(doc).to be_persisted
      expect(doc.knowledge_base).to eq(kb)
      expect(doc.status).to eq("pending")
      expect(doc.mime_type).to eq("text/markdown")
      expect(doc.byte_size).to eq(md_path.size)
      expect(doc.content_hash).to eq(Digest::SHA256.hexdigest(md_path.binread))
      expect(doc.title).to eq("sample")
      expect(doc.file).to be_attached
    end

    it "enqueues Curator::IngestDocumentJob for the new document" do
      result = Curator.ingest(md_path.to_s, knowledge_base: kb)
      expect(Curator::IngestDocumentJob).to have_been_enqueued.with(result.document.id)
    end

    it "passes through title, source_url, and metadata" do
      result = Curator.ingest(
        md_path.to_s,
        knowledge_base: kb,
        title: "Custom Title",
        source_url: "https://example.com/sample.md",
        metadata: { "tag" => "onboarding" }
      )
      expect(result.document.title).to eq("Custom Title")
      expect(result.document.source_url).to eq("https://example.com/sample.md")
      expect(result.document.metadata).to eq("tag" => "onboarding")
    end
  end

  describe "dedup" do
    it "returns :duplicate on a matching content_hash without side effects" do
      first = Curator.ingest(md_path.to_s, knowledge_base: kb)
      clear_enqueued_jobs

      result = nil
      expect {
        result = Curator.ingest(md_path.to_s, knowledge_base: kb)
      }.not_to change(Curator::Document, :count)

      expect(result).to be_duplicate
      expect(result.document).to eq(first.document)
      expect(Curator::IngestDocumentJob).not_to have_been_enqueued
    end

    it "scopes dedup per knowledge base" do
      other_kb = create(:curator_knowledge_base)
      Curator.ingest(md_path.to_s, knowledge_base: kb)

      result = Curator.ingest(md_path.to_s, knowledge_base: other_kb)
      expect(result).to be_created
      expect(result.document.knowledge_base).to eq(other_kb)
    end
  end

  describe "size limit" do
    it "raises FileTooLargeError before any DB write" do
      Curator.config.max_document_size = 10

      expect {
        Curator.ingest(md_path.to_s, knowledge_base: kb)
      }.to raise_error(Curator::FileTooLargeError, /max_document_size/)
      expect(Curator::Document.count).to eq(0)
    ensure
      Curator.reset_config!
    end
  end

  describe "knowledge_base: resolution" do
    it "accepts a slug string" do
      kb # realize
      result = Curator.ingest(md_path.to_s, knowledge_base: kb.slug)
      expect(result).to be_created
      expect(result.document.knowledge_base).to eq(kb)
    end

    it "accepts a slug symbol" do
      kb
      result = Curator.ingest(md_path.to_s, knowledge_base: kb.slug.to_sym)
      expect(result).to be_created
      expect(result.document.knowledge_base).to eq(kb)
    end

    it "raises RecordNotFound for an unknown slug" do
      expect {
        Curator.ingest(md_path.to_s, knowledge_base: "does-not-exist")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ArgumentError for other types" do
      expect {
        Curator.ingest(md_path.to_s, knowledge_base: 42)
      }.to raise_error(ArgumentError, /must be a Curator::KnowledgeBase/)
    end
  end

  describe "Curator.ingest_url" do
    it "fetches the URL and creates a document" do
      stub_request(:get, "https://example.com/a.md")
        .to_return(
          status: 200,
          body: "# remote\n",
          headers: { "Content-Type" => "text/markdown" }
        )

      result = Curator.ingest_url("https://example.com/a.md", knowledge_base: kb)
      expect(result).to be_created
      expect(result.document.title).to eq("a")
      expect(result.document.mime_type).to eq("text/markdown")
    end

    it "falls back to the URL as title when the path has no usable basename" do
      stub_request(:get, "https://www.cnn.com/")
        .to_return(status: 200, body: "<html></html>", headers: { "Content-Type" => "text/html" })

      result = Curator.ingest_url("https://www.cnn.com/", knowledge_base: kb)
      expect(result.document.title).to eq("https://www.cnn.com/")
    end

    it "still honors an explicit title: override for bare URLs" do
      stub_request(:get, "https://www.cnn.com/")
        .to_return(status: 200, body: "<html></html>", headers: { "Content-Type" => "text/html" })

      result = Curator.ingest_url("https://www.cnn.com/", knowledge_base: kb, title: "CNN")
      expect(result.document.title).to eq("CNN")
    end

    it "defaults source_url to the final (post-redirect) URL" do
      stub_request(:get, "https://example.com/redir")
        .to_return(status: 302, headers: { "Location" => "https://example.com/final.md" })
      stub_request(:get, "https://example.com/final.md")
        .to_return(
          status: 200,
          body: "# final\n",
          headers: { "Content-Type" => "text/markdown" }
        )

      result = Curator.ingest_url("https://example.com/redir", knowledge_base: kb)
      expect(result.document.source_url).to eq("https://example.com/final.md")
    end

    it "honors an explicit source_url: override" do
      stub_request(:get, "https://example.com/a.md")
        .to_return(status: 200, body: "# x\n", headers: { "Content-Type" => "text/markdown" })

      result = Curator.ingest_url(
        "https://example.com/a.md",
        knowledge_base: kb,
        source_url: "https://canonical.example/a"
      )
      expect(result.document.source_url).to eq("https://canonical.example/a")
    end

    it "dedups a URL ingested twice" do
      stub_request(:get, "https://example.com/a.md")
        .to_return(status: 200, body: "# x\n", headers: { "Content-Type" => "text/markdown" })

      first = Curator.ingest_url("https://example.com/a.md", knowledge_base: kb)
      result = Curator.ingest_url("https://example.com/a.md", knowledge_base: kb)
      expect(result).to be_duplicate
      expect(result.document).to eq(first.document)
    end

    it "propagates FetchError for failed responses" do
      stub_request(:get, "https://example.com/404").to_return(status: 404)

      expect {
        Curator.ingest_url("https://example.com/404", knowledge_base: kb)
      }.to raise_error(Curator::FetchError)
    end
  end

  describe "file normalization" do
    it "accepts an ActiveStorage::Blob" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("# a blob\n"),
        filename: "blob.md",
        content_type: "text/markdown"
      )
      result = Curator.ingest(blob, knowledge_base: kb)
      expect(result).to be_created
      expect(result.document.mime_type).to eq("text/markdown")
      expect(result.document.byte_size).to eq("# a blob\n".bytesize)
    end

    it "accepts an ActionDispatch::Http::UploadedFile" do
      tempfile = Tempfile.new([ "upload", ".md" ])
      tempfile.write("# uploaded\n")
      tempfile.rewind
      uploaded = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: "uploaded.md",
        type: "text/markdown"
      )

      result = Curator.ingest(uploaded, knowledge_base: kb)
      expect(result).to be_created
      expect(result.document.title).to eq("uploaded")
    ensure
      tempfile&.close!
    end
  end
end
