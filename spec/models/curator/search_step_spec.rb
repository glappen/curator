require "rails_helper"

RSpec.describe Curator::SearchStep, type: :model do
  it "rejects unknown step_type" do
    expect(build(:curator_search_step, step_type: "totally_not_real")).not_to be_valid
  end

  it "rejects unknown status" do
    expect(build(:curator_search_step, status: "pending")).not_to be_valid
  end

  it "enforces sequence uniqueness within a search" do
    search = create(:curator_search)
    create(:curator_search_step, search: search, sequence: 0)
    expect(build(:curator_search_step, search: search, sequence: 0)).not_to be_valid
  end
end
