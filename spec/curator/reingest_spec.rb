require "rails_helper"

RSpec.describe Curator, ".reingest" do
  include ActiveJob::TestHelper

  let(:kb)       { create(:curator_knowledge_base) }
  let(:document) { create(:curator_document, knowledge_base: kb, status: :complete, stage_error: nil) }

  before do
    create(:curator_chunk, document: document, sequence: 0)
    create(:curator_chunk, document: document, sequence: 1)
  end

  it "destroys existing chunks, resets the document to :pending, and re-enqueues IngestDocumentJob" do
    expect {
      Curator.reingest(document)
    }.to change { document.chunks.count }.from(2).to(0)

    document.reload
    expect(document.status).to eq("pending")
    expect(document.stage_error).to be_nil
    expect(Curator::IngestDocumentJob).to have_been_enqueued.with(document.id)
  end

  it "clears a prior stage_error" do
    document.update!(status: :failed, stage_error: "Curator::ExtractionError: boom")

    Curator.reingest(document)

    expect(document.reload.stage_error).to be_nil
    expect(document.status).to eq("pending")
  end

  it "does not enqueue when the destroy/reset transaction rolls back" do
    allow(document).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(document))

    expect {
      Curator.reingest(document)
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(Curator::IngestDocumentJob).not_to have_been_enqueued
    # Chunks survive because the destroy_all happened in the same transaction.
    expect(document.chunks.count).to eq(2)
  end

  it "returns the document so callers can chain" do
    expect(Curator.reingest(document)).to eq(document)
  end
end
