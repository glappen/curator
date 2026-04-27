require "rails_helper"

RSpec.describe Curator::RetrievalStep, type: :model do
  it "rejects unknown step_type" do
    expect(build(:curator_retrieval_step, step_type: "totally_not_real")).not_to be_valid
  end

  it "rejects unknown status" do
    expect(build(:curator_retrieval_step, status: "pending")).not_to be_valid
  end

  it "enforces sequence uniqueness within a retrieval" do
    retrieval = create(:curator_retrieval)
    create(:curator_retrieval_step, retrieval: retrieval, sequence: 0)
    expect(build(:curator_retrieval_step, retrieval: retrieval, sequence: 0)).not_to be_valid
  end
end
