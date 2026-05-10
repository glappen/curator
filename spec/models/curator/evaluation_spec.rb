require "rails_helper"

RSpec.describe Curator::Evaluation, type: :model do
  describe "rating enum" do
    it "accepts :positive and :negative" do
      expect(build(:curator_evaluation, rating: "positive")).to be_valid
      expect(build(:curator_evaluation, rating: "negative")).to be_valid
    end
  end

  describe "failure_categories" do
    it "accepts the empty default" do
      expect(build(:curator_evaluation).failure_categories).to eq([])
    end

    it "accepts any known category" do
      Curator::Evaluation::FAILURE_CATEGORIES.each do |cat|
        e = build(:curator_evaluation, rating: "negative", failure_categories: [ cat ])
        expect(e).to be_valid, "expected #{cat} to be valid"
      end
    end

    it "accepts multiple known categories on one evaluation" do
      e = build(:curator_evaluation,
                rating: "negative",
                failure_categories: %w[hallucination wrong_retrieval])
      expect(e).to be_valid
    end

    it "rejects unknown categories" do
      e = build(:curator_evaluation, rating: "negative", failure_categories: %w[bogus])
      expect(e).not_to be_valid
      expect(e.errors[:failure_categories]).to be_present
    end

    it "rejects categories on :positive ratings" do
      e = build(:curator_evaluation, rating: "positive", failure_categories: %w[hallucination])
      expect(e).not_to be_valid
      expect(e.errors[:failure_categories]).to be_present
    end
  end

  it "exposes a tooltip for every failure category" do
    expect(Curator::Evaluation::FAILURE_CATEGORY_TOOLTIPS.keys)
      .to match_array(Curator::Evaluation::FAILURE_CATEGORIES)
  end

  describe ".distinct_chat_models" do
    it "returns sorted distinct chat_models from retrievals that have evaluations" do
      r1 = create(:curator_retrieval, chat_model: "gpt-5-mini")
      r2 = create(:curator_retrieval, chat_model: "gpt-5")
      r3 = create(:curator_retrieval, chat_model: "gpt-5-mini") # dup
      _unevaluated = create(:curator_retrieval, chat_model: "claude-opus-4-7")
      [ r1, r2, r3 ].each { |r| create(:curator_evaluation, retrieval: r) }

      expect(Curator::Evaluation.distinct_chat_models).to eq(%w[gpt-5 gpt-5-mini])
    end

    it "skips evaluated retrievals with a nil chat_model" do
      r = create(:curator_retrieval, chat_model: nil)
      create(:curator_evaluation, retrieval: r)

      expect(Curator::Evaluation.distinct_chat_models).to eq([])
    end
  end

  describe ".with_filters" do
    let!(:kb)       { create(:curator_knowledge_base, slug: "default") }
    let!(:other_kb) { create(:curator_knowledge_base, slug: "scrolls") }

    let!(:r_alpha) { create(:curator_retrieval, knowledge_base: kb, query: "alpha question") }
    let!(:r_beta)  { create(:curator_retrieval, knowledge_base: kb, query: "beta question") }
    let!(:r_delta) { create(:curator_retrieval, knowledge_base: other_kb, query: "delta question") }

    let!(:positive_eval) do
      create(:curator_evaluation, retrieval: r_alpha, rating: :positive,
             evaluator_id: "alice@example.com", evaluator_role: :reviewer)
    end
    let!(:negative_eval) do
      create(:curator_evaluation, retrieval: r_beta, rating: :negative,
             evaluator_id: "bob@example.com", evaluator_role: :end_user,
             failure_categories: %w[hallucination wrong_citation])
    end
    let!(:other_kb_eval) do
      create(:curator_evaluation, retrieval: r_delta, rating: :positive)
    end

    it "filters by KB slug" do
      ids = described_class.with_filters(kb: "scrolls").pluck(:id)
      expect(ids).to     include(other_kb_eval.id)
      expect(ids).not_to include(positive_eval.id, negative_eval.id)
    end

    it "filters by rating" do
      ids = described_class.with_filters(rating: "positive").pluck(:id)
      expect(ids).to     include(positive_eval.id, other_kb_eval.id)
      expect(ids).not_to include(negative_eval.id)
    end

    it "filters by failure_categories with ANY-of semantics" do
      ids = described_class.with_filters(failure_categories: [ "hallucination" ]).pluck(:id)
      expect(ids).to     include(negative_eval.id)
      expect(ids).not_to include(positive_eval.id)
    end

    it "filters by evaluator_id substring" do
      ids = described_class.with_filters(evaluator_id: "alice").pluck(:id)
      expect(ids).to     include(positive_eval.id)
      expect(ids).not_to include(negative_eval.id)
    end

    it "filters by evaluator_role" do
      ids = described_class.with_filters(evaluator_role: "end_user").pluck(:id)
      expect(ids).to     include(negative_eval.id)
      expect(ids).not_to include(positive_eval.id)
    end

    it "filters by since" do
      positive_eval.update!(created_at: 3.days.ago)
      ids = described_class.with_filters(since: 1.day.ago.to_date.iso8601).pluck(:id)
      expect(ids).not_to include(positive_eval.id)
      expect(ids).to     include(negative_eval.id)
    end

    it "ignores a malformed since date" do
      ids = described_class.with_filters(since: "garbage").pluck(:id)
      expect(ids).to include(positive_eval.id, negative_eval.id, other_kb_eval.id)
    end
  end
end
