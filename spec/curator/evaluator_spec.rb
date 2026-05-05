require "rails_helper"

RSpec.describe Curator::Evaluator do
  let(:retrieval) { create(:curator_retrieval) }

  describe ".call" do
    it "persists a :positive evaluation with feedback and evaluator_id" do
      evaluation = described_class.call(
        retrieval:      retrieval,
        rating:         :positive,
        evaluator_role: :reviewer,
        evaluator_id:   "alice@example.com",
        feedback:       "spot on"
      )

      expect(evaluation).to                  be_persisted
      expect(evaluation.retrieval_id).to     eq(retrieval.id)
      expect(evaluation.rating).to           eq("positive")
      expect(evaluation.evaluator_role).to   eq("reviewer")
      expect(evaluation.evaluator_id).to     eq("alice@example.com")
      expect(evaluation.feedback).to         eq("spot on")
      expect(evaluation.failure_categories).to eq([])
    end

    it "persists a :negative evaluation with categories + ideal answer" do
      evaluation = described_class.call(
        retrieval:          retrieval,
        rating:             :negative,
        evaluator_role:     :reviewer,
        ideal_answer:       "the actual answer",
        failure_categories: %w[hallucination wrong_citation]
      )

      expect(evaluation.rating).to             eq("negative")
      expect(evaluation.ideal_answer).to       eq("the actual answer")
      expect(evaluation.failure_categories).to match_array(%w[hallucination wrong_citation])
    end

    it "accepts an integer retrieval id and resolves it" do
      evaluation = described_class.call(
        retrieval:      retrieval.id,
        rating:         :positive,
        evaluator_role: :end_user
      )

      expect(evaluation.retrieval_id).to eq(retrieval.id)
      expect(evaluation.evaluator_role).to eq("end_user")
    end

    it "updates an existing row in place when evaluation_id is given" do
      original = described_class.call(
        retrieval:      retrieval,
        rating:         :positive,
        evaluator_role: :reviewer,
        feedback:       "first take"
      )

      updated = described_class.call(
        retrieval:          retrieval,
        rating:             :negative,
        evaluator_role:     :reviewer,
        feedback:           "actually wrong",
        failure_categories: %w[hallucination],
        evaluation_id:      original.id
      )

      expect(updated.id).to                  eq(original.id)
      expect(updated.rating).to              eq("negative")
      expect(updated.feedback).to            eq("actually wrong")
      expect(updated.failure_categories).to  eq(%w[hallucination])
      expect(Curator::Evaluation.count).to   eq(1)
    end

    it "scopes evaluation_id lookup to the retrieval (cross-retrieval id raises)" do
      other_retrieval = create(:curator_retrieval)
      stranger        = described_class.call(
        retrieval:      other_retrieval,
        rating:         :positive,
        evaluator_role: :reviewer
      )

      expect {
        described_class.call(
          retrieval:      retrieval,
          rating:         :negative,
          evaluator_role: :reviewer,
          evaluation_id:  stranger.id
        )
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect(stranger.reload.rating).to eq("positive")
    end

    it "raises ArgumentError on an unknown rating" do
      expect {
        described_class.call(retrieval: retrieval, rating: :meh, evaluator_role: :reviewer)
      }.to raise_error(ArgumentError, /rating/)
    end

    it "raises ArgumentError on an unknown evaluator_role" do
      expect {
        described_class.call(retrieval: retrieval, rating: :positive, evaluator_role: :robot)
      }.to raise_error(ArgumentError, /evaluator_role/)
    end

    it "raises RecordInvalid on an unknown failure_category" do
      expect {
        described_class.call(
          retrieval:          retrieval,
          rating:             :negative,
          evaluator_role:     :reviewer,
          failure_categories: %w[nonsense]
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /failure categories/i)
    end

    it "raises RecordInvalid when categories are passed on a :positive rating" do
      expect {
        described_class.call(
          retrieval:          retrieval,
          rating:             :positive,
          evaluator_role:     :reviewer,
          failure_categories: %w[hallucination]
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /failure categories/i)
    end
  end

  describe "Curator.evaluate delegator" do
    it "delegates to Evaluator.call" do
      evaluation = Curator.evaluate(
        retrieval:      retrieval,
        rating:         :positive,
        evaluator_role: :reviewer
      )

      expect(evaluation).to be_persisted
      expect(evaluation).to be_a(Curator::Evaluation)
    end
  end
end
