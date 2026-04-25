require "rails_helper"

RSpec.describe Curator::EmbedChunksJob, type: :job do
  it "flips the document to :complete (M2 stub; real body lands in M3)" do
    doc = create(:curator_document, status: :embedding)
    described_class.perform_now(doc.id)
    expect(doc.reload.status).to eq("complete")
  end

  it "is a no-op unless the document is still embedding" do
    doc = create(:curator_document, status: :pending)

    described_class.perform_now(doc.id)

    expect(doc.reload.status).to eq("pending")
  end
end
