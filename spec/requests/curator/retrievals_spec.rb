require "rails_helper"

# Request spec for `Curator::RetrievalsController`. Covers index
# rendering + filter querystring round-trip + the default-hidden
# `:console_review` scope + show rendering + the "Re-run in Console"
# deep link's origin querystring.
RSpec.describe "Curator::RetrievalsController", type: :request do
  let!(:kb)       { create(:curator_knowledge_base, slug: "default", is_default: true) }
  let!(:other_kb) { create(:curator_knowledge_base, slug: "scrolls", name: "Scrolls") }

  describe "GET /curator/retrievals" do
    let!(:adhoc) do
      create(:curator_retrieval, knowledge_base: kb, query: "alpha question",
                                 chat_model: "gpt-5-mini", origin: "adhoc")
    end
    let!(:console_run) do
      create(:curator_retrieval, knowledge_base: kb, query: "beta question",
                                 chat_model: "gpt-5-nano", origin: "console")
    end
    let!(:review_run) do
      create(:curator_retrieval, knowledge_base: kb, query: "gamma question",
                                 origin: "console_review")
    end

    it "renders the index with all non-review retrievals listed by default" do
      get "/curator/retrievals"

      expect(response).to       have_http_status(:ok)
      expect(response.body).to  include("Retrievals")
      expect(response.body).to  include("alpha question")
      expect(response.body).to  include("beta question")
      # `:console_review` rows are hidden under the default scope so the
      # review-loop deep links don't drown out actual operator traffic.
      expect(response.body).not_to include("gamma question")
    end

    it "shows :console_review rows when show_review=true" do
      get "/curator/retrievals", params: { show_review: "true" }

      expect(response.body).to include("alpha question")
      expect(response.body).to include("beta question")
      expect(response.body).to include("gamma question")
    end

    it "filters by knowledge_base_id" do
      create(:curator_retrieval, knowledge_base: other_kb, query: "scrolls-only")

      get "/curator/retrievals", params: { knowledge_base_id: other_kb.id }

      expect(response.body).to     include("scrolls-only")
      expect(response.body).not_to include("alpha question")
    end

    it "filters by status" do
      create(:curator_retrieval, knowledge_base: kb, query: "broken run", status: "failed")

      get "/curator/retrievals", params: { status: "failed" }

      expect(response.body).to     include("broken run")
      expect(response.body).not_to include("alpha question")
    end

    it "filters by chat_model" do
      get "/curator/retrievals", params: { chat_model: "gpt-5-nano" }

      expect(response.body).to     include("beta question")
      expect(response.body).not_to include("alpha question")
    end

    it "filters by free-text query (ILIKE)" do
      get "/curator/retrievals", params: { query: "ALPHA" }

      expect(response.body).to     include("alpha question")
      expect(response.body).not_to include("beta question")
    end

    it "ignores a malformed date filter rather than silently broadening the result set" do
      old_row = create(:curator_retrieval, knowledge_base: kb, query: "ancient",
                                           created_at: 10.days.ago)

      get "/curator/retrievals", params: { to: "not-a-date" }

      # Bad input drops the clause entirely — the operator sees the full
      # set, same as if they hadn't typed a date. The earlier behavior
      # (fall back to today) effectively meant "< tomorrow" → matched
      # everything, indistinguishable from no filter, hiding the typo.
      expect(response.body).to include("ancient")
      expect(response.body).to include("alpha question")
      expect(old_row.reload.query).to eq("ancient")
    end

    it "filters by date range (from/to inclusive)" do
      old_row = create(:curator_retrieval, knowledge_base: kb, query: "ancient",
                                           created_at: 10.days.ago)
      _new_row = create(:curator_retrieval, knowledge_base: kb, query: "recent",
                                            created_at: Time.current)

      get "/curator/retrievals", params: {
        from: 11.days.ago.to_date.iso8601,
        to:   9.days.ago.to_date.iso8601
      }

      expect(response.body).to     include("ancient")
      expect(response.body).not_to include("recent")
      expect(response.body).not_to include("alpha question")
      expect(old_row.reload.query).to eq("ancient")
    end

    it "filters by rating (joins evaluations)" do
      create(:curator_evaluation, retrieval: adhoc, rating: "negative")
      get "/curator/retrievals", params: { rating: "negative" }

      expect(response.body).to     include("alpha question")
      expect(response.body).not_to include("beta question")
    end

    it "filters by unrated-only" do
      create(:curator_evaluation, retrieval: adhoc, rating: "positive")
      get "/curator/retrievals", params: { unrated: "true" }

      expect(response.body).not_to include("alpha question")
      expect(response.body).to     include("beta question")
    end

    it "round-trips current filters into the pagination links" do
      24.times { |i| create(:curator_retrieval, knowledge_base: kb, query: "page_#{i}") }
      get "/curator/retrievals", params: { knowledge_base_id: kb.id, per: "10" }

      # Pagination links carry the active filter so paging through a
      # filtered set doesn't reset the operator's view.
      expect(response.body).to match(%r{href="[^"]*knowledge_base_id=#{kb.id}[^"]*page=2})
    end

    it "renders the empty-state copy when no rows match" do
      get "/curator/retrievals", params: { query: "no-such-query" }

      expect(response.body).to include("No retrievals match these filters.")
    end
  end

  describe "GET /curator/retrievals/:id" do
    let(:retrieval) do
      create(:curator_retrieval,
             knowledge_base: kb,
             query: "what is alpha?",
             chat_model: "gpt-5-mini",
             retrieval_strategy: "vector",
             chunk_limit: 7,
             similarity_threshold: 0.42)
    end

    it "renders query, snapshot config, and Re-run-in-Console link with origin=console_review" do
      get "/curator/retrievals/#{retrieval.id}"

      expect(response).to       have_http_status(:ok)
      expect(response.body).to  include("what is alpha?")
      expect(response.body).to  include("gpt-5-mini")
      expect(response.body).to  include("vector")
      # Re-run deep link tags the resulting retrieval as :console_review
      # so it gets hidden from the default Retrievals index — the whole
      # point of the origin column.
      expect(response.body).to match(
        %r{href="/curator/kbs/default/console\?[^"]*origin=console_review[^"]*query=what[+%20]is[+%20]alpha}
      )
    end

    it "renders persisted hits via the shared console source partial" do
      doc = create(:curator_document, knowledge_base: kb, title: "manual.md")
      Curator::RetrievalHit.create!(
        retrieval:     retrieval,
        document:      doc,
        rank:          1,
        score:         0.91,
        document_name: "manual.md",
        page_number:   3,
        text:          "the snapshot text"
      )

      get "/curator/retrievals/#{retrieval.id}"

      expect(response.body).to include("[1]")
      expect(response.body).to include("manual.md")
      expect(response.body).to include("the snapshot text")
      expect(response.body).to include("0.910")
    end

    it "renders existing evaluations and an append-mode form for a new one" do
      create(:curator_evaluation, retrieval: retrieval, rating: "negative",
                                  feedback: "off the mark",
                                  failure_categories: %w[hallucination])

      get "/curator/retrievals/#{retrieval.id}"

      expect(response.body).to include("off the mark")
      expect(response.body).to include("Hallucination")
      # New-eval scaffold is unpersisted, so no `evaluation_id` hidden
      # field — POST will route through the create branch instead of
      # update-in-place.
      expect(response.body).to include("Add evaluation")
      # Append-mode scaffold defaults to :negative since SMEs hitting
      # the detail view are usually correcting something.
      rating_input = response.body[/<input[^>]*name="rating"[^>]*>/]
      expect(rating_input).to include('value="negative"')
      # Append-mode form omits the `evaluation_id` hidden field — POST
      # routes through the create branch instead of update-in-place.
      expect(response.body).not_to include('name="evaluation_id"')
    end

    it "anchors the focused evaluation when ?evaluation_id= is set" do
      eval_row = create(:curator_evaluation, retrieval: retrieval, rating: "positive")

      get "/curator/retrievals/#{retrieval.id}", params: { evaluation_id: eval_row.id }

      expect(response.body).to include(%(id="evaluation_#{eval_row.id}"))
      expect(response.body).to include("is-focused")
    end

    it "renders a placeholder when no message is linked (failed run)" do
      failed = create(:curator_retrieval, knowledge_base: kb, status: "failed",
                                          error_message: "LLM blew up", query: "fail")

      get "/curator/retrievals/#{failed.id}"

      expect(response.body).to include("LLM blew up")
      expect(response.body).to include("No persisted answer for this row.")
    end

    it "404s on unknown id" do
      get "/curator/retrievals/0"
      expect(response).to have_http_status(:not_found)
    end
  end
end
