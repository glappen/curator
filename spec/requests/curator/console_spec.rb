require "rails_helper"

# Request spec for `Curator::ConsoleController`. Token streaming is
# tested in `spec/jobs/curator/console_stream_job_spec.rb` against the
# Action Cable broadcast surface — this spec covers only the
# controller's responsibilities: render the form (#show), enqueue the
# job + return the initial turbo-stream that flips status to :streaming
# and clears the previous run (#run).
RSpec.describe "Curator::ConsoleController", type: :request do
  include ActiveJob::TestHelper

  describe "GET /curator/console" do
    let!(:default_kb) do
      create(:curator_knowledge_base,
             slug:                 "default",
             is_default:           true,
             chunk_limit:          7,
             similarity_threshold: 0.42,
             retrieval_strategy:   "hybrid",
             chat_model:           "gpt-5-mini")
    end

    it "renders the form with default-KB defaults pre-filled and a turbo_stream_from subscription" do
      get "/curator/console"

      expect(response).to                                 have_http_status(:ok)
      expect(response.body).to                            include("Query Testing Console")
      expect(response.body).to                            include('placeholder="7"')
      expect(response.body).to                            include('placeholder="0.42"')
      expect(response.body).to                            include('selected="selected" value="hybrid"')
      expect(response.body).to                            include('selected="selected" value="default"')
      expect(response.body).to                            include('action="/curator/console/run"')
      # Per-tab broadcast topic UUID round-trips through the form's hidden field
      # so #run can address the correct Cable channel.
      expect(response.body).to match(%r{<turbo-cable-stream-source[^>]*signed-stream-name="[^"]+"})
      # Per-tab UUID in a hidden `topic` field — round-tripped to #run as the
      # broadcast channel name. Attribute order varies; assert each piece
      # individually rather than a brittle order-pinned regex.
      hidden_input = response.body[/<input[^>]*name="topic"[^>]*>/]
      expect(hidden_input).to be_present
      expect(hidden_input).to include('type="hidden"')
      expect(hidden_input).to match(/value="[0-9a-f-]{36}"/)
      # Answer pane binds the console-stream Stimulus controller — the JS
      # side reorders out-of-sequence chunks back into delta order.
      expect(response.body).to match(
        %r{<div id="console-answer"[^>]*data-controller="console-stream"}
      )
    end

    it "falls back to the default KB even when no slug is in the URL" do
      get "/curator/console"
      expect(response.body).to include('selected="selected" value="default"')
    end
  end

  describe "GET /curator/kbs/:slug/console" do
    let!(:_default) do
      create(:curator_knowledge_base, slug: "default", is_default: true)
    end
    let!(:other) do
      create(:curator_knowledge_base,
             slug:                 "scrolls",
             chunk_limit:          12,
             similarity_threshold: 0.18,
             retrieval_strategy:   "vector")
    end

    it "renders the form with that KB's defaults" do
      get "/curator/kbs/scrolls/console"

      expect(response).to       have_http_status(:ok)
      expect(response.body).to  include('placeholder="12"')
      expect(response.body).to  include('placeholder="0.18"')
      expect(response.body).to  include('selected="selected" value="vector"')
      expect(response.body).to  include('selected="selected" value="scrolls"')
    end
  end

  describe "POST /curator/console/run" do
    let!(:default_kb) do
      create(:curator_knowledge_base,
             slug:                 "default",
             is_default:           true,
             retrieval_strategy:   "vector",
             similarity_threshold: 0.0,
             chunk_limit:          5)
    end
    let(:topic) { "abcd-1234" }

    it "enqueues ConsoleStreamJob with form params and returns an initial streaming turbo_stream" do
      expect {
        post "/curator/console/run", params: {
          topic:                topic,
          knowledge_base_slug:  "default",
          query:                "what is alpha?",
          chunk_limit:          "9",
          similarity_threshold: "0.25",
          strategy:             "hybrid",
          system_prompt:        "be terse",
          chat_model:           "gpt-5-nano"
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to have_enqueued_job(Curator::ConsoleStreamJob).with(
        topic:                topic,
        knowledge_base_slug:  "default",
        query:                "what is alpha?",
        chunk_limit:          9,
        similarity_threshold: 0.25,
        strategy:             "hybrid",
        system_prompt:        "be terse",
        chat_model:           "gpt-5-nano"
      )

      expect(response).to                          have_http_status(:ok)
      expect(response.headers["Content-Type"]).to  include("text/vnd.turbo-stream.html")

      body = response.body
      # Initial frame flips status to streaming and clears prior run state.
      # All three actions are `update` (inner-content swap) not `replace` —
      # see ConsoleController#run for the rationale.
      expect(body).to include('<turbo-stream action="update" target="console-status">')
      expect(body).to include("console-status--streaming")
      expect(body).to include('<turbo-stream action="update" target="console-answer">')
      expect(body).to include('<turbo-stream action="update" target="console-sources">')
    end

    it "blanks override params enqueue with nil instead of empty string / zero" do
      post "/curator/console/run", params: {
        topic:                topic,
        knowledge_base_slug:  "default",
        query:                "go",
        chunk_limit:          "",
        similarity_threshold: "",
        strategy:             "vector",
        system_prompt:        "",
        chat_model:           "gpt-5-mini"
      }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to                       eq(Curator::ConsoleStreamJob)
      expect(job[:args].first["chunk_limit"]).to be_nil
      expect(job[:args].first["similarity_threshold"]).to be_nil
      expect(job[:args].first["system_prompt"]).to be_nil
    end

    it "rejects with 400 and enqueues no job when topic is absent" do
      expect {
        post "/curator/console/run", params: {
          knowledge_base_slug: "default",
          query:               "anything"
        }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.not_to have_enqueued_job(Curator::ConsoleStreamJob)
      expect(response).to have_http_status(:bad_request)
    end
  end
end
