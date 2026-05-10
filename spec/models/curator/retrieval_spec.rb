require "rails_helper"

RSpec.describe Curator::Retrieval, type: :model do
  describe "validations" do
    it "requires a query and a knowledge base" do
      r = build(:curator_retrieval, query: nil, knowledge_base: nil)
      expect(r).not_to be_valid
      expect(r.errors.attribute_names).to include(:query, :knowledge_base)
    end
  end

  describe "ORIGINS" do
    it "includes the M8 :chat_tool value" do
      expect(described_class::ORIGINS).to include(:chat_tool)
    end

    it "accepts :chat_tool via the enum" do
      r = build(:curator_retrieval, origin: :chat_tool)
      expect(r).to be_valid
      expect(r.origin).to eq("chat_tool")
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

  describe ".with_filters" do
    let(:kb)       { create(:curator_knowledge_base, slug: "default") }
    let(:other_kb) { create(:curator_knowledge_base, slug: "other") }

    let!(:adhoc) do
      create(:curator_retrieval,
             knowledge_base: kb, query: "alpha", origin: :adhoc, status: :success)
    end
    let!(:console_run) do
      create(:curator_retrieval,
             knowledge_base: kb, query: "beta", origin: :console, status: :failed)
    end
    let!(:review_run) do
      create(:curator_retrieval,
             knowledge_base: kb, query: "gamma", origin: :console_review)
    end
    let!(:other_kb_run) do
      create(:curator_retrieval,
             knowledge_base: other_kb, query: "delta", origin: :adhoc)
    end

    it "hides :console_review rows by default" do
      ids = described_class.with_filters({}).pluck(:id)
      expect(ids).to     include(adhoc.id, console_run.id, other_kb_run.id)
      expect(ids).not_to include(review_run.id)
    end

    it "includes :console_review rows when show_review is truthy" do
      ids = described_class.with_filters(show_review: "true").pluck(:id)
      expect(ids).to include(review_run.id)
    end

    it "filters by knowledge_base_id" do
      ids = described_class.with_filters(knowledge_base_id: kb.id).pluck(:id)
      expect(ids).to     include(adhoc.id, console_run.id)
      expect(ids).not_to include(review_run.id, other_kb_run.id)
    end

    it "filters by KB slug" do
      ids = described_class.with_filters(kb_slug: "other").pluck(:id)
      expect(ids).to     include(other_kb_run.id)
      expect(ids).not_to include(adhoc.id)
    end

    it "filters by status" do
      ids = described_class.with_filters(status: "failed").pluck(:id)
      expect(ids).to     include(console_run.id)
      expect(ids).not_to include(adhoc.id)
    end

    it "filters by ILIKE query substring" do
      ids = described_class.with_filters(query: "alph").pluck(:id)
      expect(ids).to     include(adhoc.id)
      expect(ids).not_to include(console_run.id)
    end

    it "filters by `from` date inclusively" do
      adhoc.update!(created_at: 3.days.ago)
      ids = described_class.with_filters(from: 1.day.ago.to_date.iso8601).pluck(:id)
      expect(ids).not_to include(adhoc.id)
      expect(ids).to     include(console_run.id)
    end

    it "ignores a malformed `from` date" do
      ids = described_class.with_filters(from: "garbage").pluck(:id)
      expect(ids).to include(adhoc.id)
    end

    it "filters by rating" do
      create(:curator_evaluation, retrieval: adhoc, rating: :positive)
      ids = described_class.with_filters(rating: "positive").pluck(:id)
      expect(ids).to     include(adhoc.id)
      expect(ids).not_to include(console_run.id)
    end

    it "filters by unrated" do
      create(:curator_evaluation, retrieval: adhoc, rating: :positive)
      ids = described_class.with_filters(unrated: "true").pluck(:id)
      expect(ids).not_to include(adhoc.id)
      expect(ids).to     include(console_run.id)
    end
  end
end
