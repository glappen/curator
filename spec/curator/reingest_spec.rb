require "rails_helper"

RSpec.describe Curator, ".reingest" do
  include ActiveJob::TestHelper

  let(:kb)       { create(:curator_knowledge_base) }
  let(:document) { create(:curator_document, knowledge_base: kb, status: :complete, stage_error: nil) }

  before do
    create(:curator_chunk, document: document, sequence: 0)
    create(:curator_chunk, document: document, sequence: 1)
  end

  it "resets the document to :pending and re-enqueues IngestDocumentJob" do
    Curator.reingest(document)

    document.reload
    expect(document.status).to eq("pending")
    expect(document.stage_error).to be_nil
    expect(Curator::IngestDocumentJob).to have_been_enqueued.with(document.id)
  end

  it "leaves prior chunks in place — teardown happens inside IngestDocumentJob, " \
     "not here, so the request handler stays cheap" do
    expect {
      Curator.reingest(document)
    }.not_to change { document.chunks.count }
  end

  it "clears a prior stage_error" do
    document.update!(status: :failed, stage_error: "Curator::ExtractionError: boom")

    Curator.reingest(document)

    expect(document.reload.stage_error).to be_nil
    expect(document.status).to eq("pending")
  end

  it "does not enqueue when the status flip raises" do
    allow(document).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(document))

    expect {
      Curator.reingest(document)
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(Curator::IngestDocumentJob).not_to have_been_enqueued
  end

  it "returns the document so callers can chain" do
    expect(Curator.reingest(document)).to eq(document)
  end

  it "resets status in the DB even when the in-memory document is stale " \
     "(regression: callers who hold a doc reference from `Curator.ingest` see " \
     "status=:pending in memory while the job has driven the row to :complete; " \
     "without a reload, AR dirty-tracking would compare new=old and emit no UPDATE)" do
    # Mirror what Curator.ingest hands back: an AR instance whose in-memory
    # status is :pending. Then simulate the job running by writing :complete
    # straight to the DB without touching the in-memory copy.
    fresh = create(:curator_document, knowledge_base: kb, status: :pending)
    Curator::Document.where(id: fresh.id).update_all(status: "complete")
    expect(fresh.status).to eq("pending") # in-memory still stale

    Curator.reingest(fresh)

    expect(Curator::Document.find(fresh.id).status).to eq("pending")
  end
end
