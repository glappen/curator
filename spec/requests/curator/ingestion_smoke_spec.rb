require "rails_helper"
require "tmpdir"
require "fileutils"

# End-to-end smoke for the ingest pipeline: drives Curator.ingest /
# ingest_directory / reingest against the dummy app and runs the full
# IngestDocumentJob → EmbedChunksJob chain inline. With M3 landed, a
# document at :complete now means real embeddings exist for every
# chunk, not just a status flip — assertions enforce that contract via
# the embedding-row count, not by inspecting the job internals.
RSpec.describe "Curator ingestion end-to-end smoke", type: :request do
  include ActiveJob::TestHelper

  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }
  let(:md_path)     { fixture_dir.join("sample.md") }
  let(:pdf_path)    { fixture_dir.join("sample.pdf") }

  let!(:default_kb) do
    Curator::KnowledgeBase.seed_default!
  end

  before { Curator.configure { |c| c.extractor = :basic } }
  after  { Curator.reset_config! }

  it "ingests a fixture file and drives it through to :complete with chunks" do
    result = nil
    perform_enqueued_jobs do
      result = Curator.ingest(md_path.to_s)
    end

    expect(result).to be_created
    document = result.document.reload
    expect(document.knowledge_base).to eq(default_kb)
    expect(document.status).to eq("complete")
    expect(document.stage_error).to be_nil
    expect(document.chunks.count).to be >= 1
    expect(Curator::Embedding.where(chunk: document.chunks).count).to eq(document.chunks.count)

    first = document.chunks.order(:sequence).first
    expect(first.sequence).to eq(0)
    expect(first.content).to include("Sample Markdown")
    expect(first.token_count).to be > 0
  end

  it "returns :duplicate on a second ingest of the same file with no new rows or jobs" do
    perform_enqueued_jobs { Curator.ingest(md_path.to_s) }

    document_count_before = Curator::Document.count
    chunk_count_before    = Curator::Chunk.count

    result = nil
    expect {
      result = Curator.ingest(md_path.to_s)
    }.not_to have_enqueued_job(Curator::IngestDocumentJob)

    expect(result).to be_duplicate
    expect(Curator::Document.count).to eq(document_count_before)
    expect(Curator::Chunk.count).to eq(chunk_count_before)
  end

  it "raises FileTooLargeError before any DB write when the file exceeds max_document_size" do
    Curator.config.max_document_size = 10

    expect {
      Curator.ingest(md_path.to_s)
    }.to raise_error(Curator::FileTooLargeError, /max_document_size/)

    expect(Curator::Document.count).to eq(0)
  end

  it "marks a document :failed with UnsupportedMimeError in stage_error " \
     "when an unsupported MIME (PDF under :basic) is ingested" do
    result = nil
    perform_enqueued_jobs do
      result = Curator.ingest(pdf_path.to_s)
    end

    expect(result).to be_created
    document = result.document.reload
    expect(document.status).to eq("failed")
    expect(document.stage_error).to include("Curator::UnsupportedMimeError")
    expect(document.chunks).to be_empty
  end

  it "ingest_directory drives a mixed fixture tree to :complete on the first pass " \
     "and reports :duplicate on the second" do
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "alpha.md"), "# alpha\n\nFirst doc body for the smoke spec.\n")
      File.binwrite(File.join(dir, "beta.csv"), "name,role\nAda,engineer\nGrace,admiral\n")

      first_results = nil
      perform_enqueued_jobs do
        first_results = Curator.ingest_directory(dir)
      end

      expect(first_results.map(&:status)).to all(eq(:created))
      first_results.each do |r|
        doc = r.document.reload
        expect(doc.status).to eq("complete")
        expect(doc.chunks.count).to be >= 1
        expect(Curator::Embedding.where(chunk: doc.chunks).count).to eq(doc.chunks.count)
      end

      second_results = Curator.ingest_directory(dir)
      expect(second_results.map(&:status)).to all(eq(:duplicate))
    end
  end

  it "reingest replaces chunks and returns the document to :complete" do
    created = nil
    perform_enqueued_jobs { created = Curator.ingest(md_path.to_s) }

    document = created.document
    original_chunk_ids = document.chunks.pluck(:id)
    expect(original_chunk_ids).not_to be_empty

    perform_enqueued_jobs { Curator.reingest(document) }

    document.reload
    expect(document.status).to eq("complete")
    expect(document.stage_error).to be_nil

    new_chunk_ids = document.chunks.pluck(:id)
    expect(new_chunk_ids).not_to be_empty
    expect(new_chunk_ids & original_chunk_ids).to be_empty
    expect(Curator::Embedding.where(chunk_id: new_chunk_ids).count).to eq(new_chunk_ids.size)
  end
end
