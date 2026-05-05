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
end
