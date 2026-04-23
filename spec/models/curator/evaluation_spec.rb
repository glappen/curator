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
  end

  it "exposes a tooltip for every failure category" do
    expect(Curator::Evaluation::FAILURE_CATEGORY_TOOLTIPS.keys)
      .to match_array(Curator::Evaluation::FAILURE_CATEGORIES)
  end
end
