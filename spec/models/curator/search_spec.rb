require "rails_helper"

RSpec.describe Curator::Search, type: :model do
  describe "validations" do
    it "requires a query and a knowledge base" do
      s = build(:curator_search, query: nil, knowledge_base: nil)
      expect(s).not_to be_valid
      expect(s.errors.attribute_names).to include(:query, :knowledge_base)
    end
  end

  describe "associations" do
    it "permits a nil chat and message" do
      expect(build(:curator_search, chat: nil, message: nil)).to be_valid
    end

    it "destroys dependent search_steps and evaluations" do
      search = create(:curator_search)
      create(:curator_search_step, search: search)
      create(:curator_evaluation, search: search)

      expect { search.destroy! }
        .to change(Curator::SearchStep, :count).by(-1)
        .and change(Curator::Evaluation, :count).by(-1)
    end
  end
end
