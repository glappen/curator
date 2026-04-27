require "rails_helper"

RSpec.describe Curator::Retrieval, type: :model do
  describe "validations" do
    it "requires a query and a knowledge base" do
      r = build(:curator_retrieval, query: nil, knowledge_base: nil)
      expect(r).not_to be_valid
      expect(r.errors.attribute_names).to include(:query, :knowledge_base)
    end
  end

  describe "associations" do
    it "permits a nil chat and message" do
      expect(build(:curator_retrieval, chat: nil, message: nil)).to be_valid
    end

    it "destroys dependent retrieval_steps and evaluations" do
      retrieval = create(:curator_retrieval)
      create(:curator_retrieval_step, retrieval: retrieval)
      create(:curator_evaluation, retrieval: retrieval)

      expect { retrieval.destroy! }
        .to change(Curator::RetrievalStep, :count).by(-1)
        .and change(Curator::Evaluation, :count).by(-1)
    end
  end
end
