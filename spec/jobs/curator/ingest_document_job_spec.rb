require "rails_helper"

RSpec.describe Curator::IngestDocumentJob, type: :job do
  include ActiveJob::TestHelper

  # Phase 4 stub: full extract -> chunk -> embed pipeline lands in Phase 5.
  # This spec guards the job class exists and hands off to EmbedChunksJob.
  it "advances the document to :embedding and enqueues EmbedChunksJob" do
    doc = create(:curator_document, status: :pending)
    described_class.perform_now(doc)
    expect(doc.reload.status).to eq("embedding")
    expect(Curator::EmbedChunksJob).to have_been_enqueued.with(doc)
  end
end
