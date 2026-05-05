require "rails_helper"

RSpec.describe "Curator::EvaluationsController", type: :request do
  let(:retrieval) { create(:curator_retrieval) }

  before { Curator.reset_config! }
  after  { Curator.reset_config! }

  describe "GET /curator/evaluations" do
    it "renders the index with all evaluations by default" do
      e1 = create(:curator_evaluation, retrieval: retrieval, rating: "positive")
      e2 = create(:curator_evaluation, retrieval: retrieval, rating: "negative",
                                       failure_categories: %w[hallucination])

      get "/curator/evaluations"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Evaluations")
      expect(response.body).to include("👍 Positive")
      expect(response.body).to include("👎 Negative")
      # Each row links to the unified detail view with the eval anchor.
      expect(response.body).to include("/curator/retrievals/#{retrieval.id}?evaluation_id=#{e1.id}")
      expect(response.body).to include("/curator/retrievals/#{retrieval.id}?evaluation_id=#{e2.id}")
    end

    it "filters by KB slug (joined through retrieval)" do
      kb_a = create(:curator_knowledge_base, name: "Alpha", slug: "alpha")
      kb_b = create(:curator_knowledge_base, name: "Bravo", slug: "bravo")
      r_a  = create(:curator_retrieval, knowledge_base: kb_a, query: "alpha-q")
      r_b  = create(:curator_retrieval, knowledge_base: kb_b, query: "bravo-q")
      create(:curator_evaluation, retrieval: r_a)
      create(:curator_evaluation, retrieval: r_b)

      get "/curator/evaluations", params: { kb: "alpha" }

      expect(response.body).to     include("alpha-q")
      expect(response.body).not_to include("bravo-q")
    end

    it "filters by rating" do
      pos = create(:curator_evaluation, retrieval: retrieval, rating: "positive", feedback: "pos-marker")
      neg = create(:curator_evaluation, retrieval: retrieval, rating: "negative", feedback: "neg-marker")

      get "/curator/evaluations", params: { rating: "negative" }

      # Use the eval row's evaluator-id-fallback link as a row identity probe.
      expect(response.body).to     include("evaluation_id=#{neg.id}")
      expect(response.body).not_to include("evaluation_id=#{pos.id}")
    end

    it "filters by evaluator_role" do
      reviewer = create(:curator_evaluation, retrieval: retrieval, evaluator_role: "reviewer")
      end_user = create(:curator_evaluation, retrieval: retrieval, evaluator_role: "end_user")

      get "/curator/evaluations", params: { evaluator_role: "end_user" }

      expect(response.body).to     include("evaluation_id=#{end_user.id}")
      expect(response.body).not_to include("evaluation_id=#{reviewer.id}")
    end

    it "filters by evaluator_id with case-insensitive substring match" do
      alice = create(:curator_evaluation, retrieval: retrieval, evaluator_id: "alice@example.com")
      bob   = create(:curator_evaluation, retrieval: retrieval, evaluator_id: "bob@example.com")

      get "/curator/evaluations", params: { evaluator_id: "ALICE" }

      expect(response.body).to     include("evaluation_id=#{alice.id}")
      expect(response.body).not_to include("evaluation_id=#{bob.id}")
    end

    it "filters by failure_categories using ANY-of (array overlap) semantics" do
      hallu = create(:curator_evaluation,
                     retrieval:          retrieval,
                     rating:             "negative",
                     failure_categories: %w[hallucination])
      wrong = create(:curator_evaluation,
                     retrieval:          retrieval,
                     rating:             "negative",
                     failure_categories: %w[wrong_retrieval])
      both  = create(:curator_evaluation,
                     retrieval:          retrieval,
                     rating:             "negative",
                     failure_categories: %w[hallucination off_topic])
      none  = create(:curator_evaluation,
                     retrieval:          retrieval,
                     rating:             "negative",
                     failure_categories: %w[incomplete])

      get "/curator/evaluations",
          params: { failure_categories: %w[hallucination wrong_retrieval] }

      expect(response.body).to     include("evaluation_id=#{hallu.id}")
      expect(response.body).to     include("evaluation_id=#{wrong.id}")
      expect(response.body).to     include("evaluation_id=#{both.id}")
      expect(response.body).not_to include("evaluation_id=#{none.id}")
    end

    it "filters by chat_model + embedding_model on the joined retrieval" do
      r_match = create(:curator_retrieval,
                       chat_model:      "gpt-5-mini",
                       embedding_model: "text-embedding-3-small",
                       query:           "match-q")
      r_other = create(:curator_retrieval,
                       chat_model:      "gpt-5",
                       embedding_model: "text-embedding-3-large",
                       query:           "other-q")
      create(:curator_evaluation, retrieval: r_match)
      create(:curator_evaluation, retrieval: r_other)

      get "/curator/evaluations",
          params: { chat_model: "gpt-5-mini", embedding_model: "text-embedding-3-small" }

      expect(response.body).to     include("match-q")
      expect(response.body).not_to include("other-q")
    end

    it "filters by since/until date range on eval created_at" do
      old_eval = create(:curator_evaluation, retrieval: retrieval, created_at: 10.days.ago)
      new_eval = create(:curator_evaluation, retrieval: retrieval, created_at: 1.day.ago)

      get "/curator/evaluations", params: { since: 5.days.ago.to_date.iso8601 }

      expect(response.body).to     include("evaluation_id=#{new_eval.id}")
      expect(response.body).not_to include("evaluation_id=#{old_eval.id}")
    end

    it "round-trips filter state into pagination links" do
      create_list(:curator_evaluation, 3, retrieval: retrieval, rating: "negative")
      create(:curator_evaluation, retrieval: retrieval, rating: "positive")

      get "/curator/evaluations", params: { rating: "negative", per: 2 }

      expect(response).to have_http_status(:ok)
      # Pagination URL preserves the rating filter so page 2 keeps the
      # query scoped — the most common bug in hand-rolled paginators.
      expect(response.body).to include("rating=negative")
      expect(response.body).to include("page=2")
    end

    it "round-trips filter state into the form fields themselves" do
      kb = create(:curator_knowledge_base, name: "Alpha", slug: "alpha")
      # The chat_model dropdown is built from chat_models on retrievals
      # that already have at least one evaluation, so seed an evaluated
      # retrieval whose chat_model matches the filter input.
      r  = create(:curator_retrieval, knowledge_base: kb, chat_model: "gpt-5-mini")
      create(:curator_evaluation, retrieval: r)

      get "/curator/evaluations", params: {
        kb:                 "alpha",
        rating:             "negative",
        evaluator_role:     "end_user",
        evaluator_id:       "alice",
        chat_model:         "gpt-5-mini",
        embedding_model:    "text-embedding-3-small",
        since:              "2026-01-01",
        failure_categories: %w[hallucination]
      }

      expect(response).to have_http_status(:ok)
      # Selects: the matching option carries `selected="selected"`.
      expect(response.body).to match(/<option selected="selected" value="alpha">/)
      expect(response.body).to match(/<option selected="selected" value="negative">/)
      expect(response.body).to match(/<option selected="selected" value="end_user">/)
      expect(response.body).to match(/<option selected="selected" value="gpt-5-mini">/)
      # Text + date inputs: the value attribute reflects the submitted param.
      expect(response.body).to include(%(value="alice"))
      expect(response.body).to include(%(value="text-embedding-3-small"))
      expect(response.body).to include(%(value="2026-01-01"))
      # Multi-select checkbox: hallucination is checked.
      expect(response.body).to match(
        /<input[^>]*name="failure_categories\[\]"[^>]*value="hallucination"[^>]*checked/
      )
    end

    it "populates the chat_model dropdown from distinct evaluated chat_models only" do
      r1 = create(:curator_retrieval, chat_model: "gpt-5-mini")
      r2 = create(:curator_retrieval, chat_model: "gpt-5")
      _unevaluated = create(:curator_retrieval, chat_model: "claude-opus-4-7")
      create(:curator_evaluation, retrieval: r1)
      create(:curator_evaluation, retrieval: r2)

      get "/curator/evaluations"

      expect(response.body).to     include(%(<option value="gpt-5-mini">))
      expect(response.body).to     include(%(<option value="gpt-5">))
      # Models from never-evaluated retrievals don't surface — the
      # dropdown only offers values that can narrow the set.
      expect(response.body).not_to include(%(<option value="claude-opus-4-7">))
    end

    it "renders the empty state when filters match no rows" do
      create(:curator_evaluation, retrieval: retrieval, rating: "positive")

      get "/curator/evaluations", params: { rating: "negative" }

      expect(response.body).to include("No evaluations match")
    end
  end

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
