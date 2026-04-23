require "rails_helper"

RSpec.describe Curator::EmbedChunksJob, type: :job do
  it "flips the document to :complete (M2 stub; real body lands in M3)" do
    doc = create(:curator_document, status: :embedding)
    described_class.perform_now(doc)
    expect(doc.reload.status).to eq("complete")
  end
end
