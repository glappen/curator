require "rails_helper"

RSpec.describe "Curator::EvaluationsController", type: :request do
  let(:retrieval) { create(:curator_retrieval) }

  before { Curator.reset_config! }
  after  { Curator.reset_config! }

  describe "POST /curator/evaluations" do
    it "creates a :positive evaluation and returns its id as JSON" do
      expect {
        post "/curator/evaluations", params: {
          retrieval_id: retrieval.id,
          rating:       "positive",
          feedback:     "looks good"
        }
      }.to change(Curator::Evaluation, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)

      evaluation = Curator::Evaluation.sole
      expect(body).to                       eq("id" => evaluation.id, "rating" => "positive")
      expect(evaluation.retrieval_id).to    eq(retrieval.id)
      expect(evaluation.rating).to          eq("positive")
      expect(evaluation.evaluator_role).to  eq("reviewer")
      expect(evaluation.feedback).to        eq("looks good")
    end

    it "creates a :negative evaluation with multi-select failure categories" do
      post "/curator/evaluations", params: {
        retrieval_id:       retrieval.id,
        rating:             "negative",
        feedback:           "off",
        ideal_answer:       "the right answer",
        failure_categories: %w[hallucination wrong_retrieval]
      }

      expect(response).to have_http_status(:created)
      evaluation = Curator::Evaluation.sole
      expect(evaluation.rating).to             eq("negative")
      expect(evaluation.ideal_answer).to       eq("the right answer")
      expect(evaluation.failure_categories).to match_array(%w[hallucination wrong_retrieval])
    end

    it "drops blank entries from failure_categories (Rails form quirk)" do
      post "/curator/evaluations", params: {
        retrieval_id:       retrieval.id,
        rating:             "negative",
        failure_categories: [ "", "hallucination", "" ]
      }

      expect(response).to have_http_status(:created)
      expect(Curator::Evaluation.sole.failure_categories).to eq(%w[hallucination])
    end

    it "updates the existing row in place when evaluation_id is given" do
      original = Curator.evaluate(
        retrieval:      retrieval,
        rating:         :positive,
        evaluator_role: :reviewer
      )

      expect {
        post "/curator/evaluations", params: {
          retrieval_id:  retrieval.id,
          evaluation_id: original.id,
          rating:        "negative",
          feedback:      "rewrote"
        }
      }.not_to change(Curator::Evaluation, :count)

      original.reload
      expect(response).to           have_http_status(:ok)
      expect(original.rating).to    eq("negative")
      expect(original.feedback).to  eq("rewrote")
    end

    it "populates evaluator_id from current_admin_evaluator" do
      Curator.configure { |c| c.current_admin_evaluator = ->(controller) { controller.request.headers["X-User"] } }

      post "/curator/evaluations",
           params:  { retrieval_id: retrieval.id, rating: "positive" },
           headers: { "X-User" => "alice@example.com" }

      expect(response).to                              have_http_status(:created)
      expect(Curator::Evaluation.sole.evaluator_id).to eq("alice@example.com")
    end

    it "leaves evaluator_id nil when no admin evaluator hook is configured" do
      post "/curator/evaluations", params: { retrieval_id: retrieval.id, rating: "positive" }

      expect(response).to                              have_http_status(:created)
      expect(Curator::Evaluation.sole.evaluator_id).to be_nil
    end

    it "is gated by the admin auth hook" do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      Curator.configure { |c| c.authenticate_admin_with { head :unauthorized } }

      expect {
        post "/curator/evaluations", params: { retrieval_id: retrieval.id, rating: "positive" }
      }.not_to change(Curator::Evaluation, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "400s when retrieval_id is missing" do
      expect {
        post "/curator/evaluations", params: { rating: "positive" }
      }.not_to change(Curator::Evaluation, :count)

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /curator/evaluations (turbo_stream)" do
    let(:turbo_headers) do
      { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }
    end

    it "returns a turbo_stream update for #console-evaluation with the rating-aware form" do
      post "/curator/evaluations",
           params:  { retrieval_id: retrieval.id, rating: "negative" },
           headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(Mime[:turbo_stream].to_s)

      evaluation = Curator::Evaluation.sole
      expect(response.body).to include('action="update"')
      expect(response.body).to include('target="console-evaluation"')
      # Hidden round-trip field for the next submit.
      expect(response.body).to include(%(name="evaluation_id"))
      expect(response.body).to include(%(value="#{evaluation.id}"))
      # Negative rating reveals the failure-categories fieldset.
      expect(response.body).to include("failure_categories")
      expect(response.body).to include("hallucination")
    end

    it "renders the positive variant without failure categories" do
      post "/curator/evaluations",
           params:  { retrieval_id: retrieval.id, rating: "positive" },
           headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to     include('target="console-evaluation"')
      expect(response.body).not_to include("failure_categories")
    end

    it "flips a :negative eval (with categories) to :positive in place" do
      original = Curator.evaluate(
        retrieval:          retrieval,
        rating:             :negative,
        evaluator_role:     :reviewer,
        failure_categories: %w[hallucination]
      )

      # Mirrors the Stimulus flip path: client clears the checkboxes
      # before submit when rating goes :negative -> :positive, so the
      # server sees an empty failure_categories array (or no key).
      expect {
        post "/curator/evaluations",
             params:  {
               retrieval_id:  retrieval.id,
               evaluation_id: original.id,
               rating:        "positive"
             },
             headers: turbo_headers
      }.not_to change(Curator::Evaluation, :count)

      expect(response).to                    have_http_status(:ok)
      expect(original.reload.rating).to      eq("positive")
      expect(original.failure_categories).to eq([])
    end

    it "PATCHes the same row when evaluation_id is present" do
      original = Curator.evaluate(
        retrieval:      retrieval,
        rating:         :positive,
        evaluator_role: :reviewer
      )

      expect {
        post "/curator/evaluations",
             params:  {
               retrieval_id:  retrieval.id,
               evaluation_id: original.id,
               rating:        "negative",
               feedback:      "actually no"
             },
             headers: turbo_headers
      }.not_to change(Curator::Evaluation, :count)

      original.reload
      expect(original.rating).to     eq("negative")
      expect(original.feedback).to   eq("actually no")
      expect(response.body).to       include(%(value="#{original.id}"))
    end
  end
end
