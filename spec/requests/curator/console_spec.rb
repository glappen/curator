require "rails_helper"

# Phase 2B request spec. Drives the Console form (GET) + run action
# (POST) through Rails integration testing.
#
# Streaming pump: Phase 1's `Curator::Streaming::TurboStream` is still
# a no-op when this worktree is on its own. Phase 2A — running in
# parallel in a sibling worktree — replaces those stubs. So the spec
# substitutes a minimal in-spec pump via `allow(...).to receive(:open)`,
# which writes real `<turbo-stream>` frames to the response stream.
# When 2A merges the spec keeps passing because the substitute and the
# real impl produce the same wire shape.
RSpec.describe "Curator::ConsoleController", type: :request do
  before { allow(Curator::Streaming::TurboStream).to receive(:open, &test_pump_open) }

  # Real `<turbo-stream>` writer for the response stream. Mirrors the
  # frame shape Phase 2A is implementing — append wraps text in
  # `<template>` (HTML-escaped), replace passes raw HTML through.
  let(:test_pump_open) do
    lambda do |stream:, target:, &block|
      pump = Class.new do
        def initialize(stream, target)
          @stream = stream
          @target = target
        end

        def append(text)
          @stream.write(
            %(<turbo-stream action="append" target="#{@target}">) +
            %(<template>#{ERB::Util.html_escape(text)}</template></turbo-stream>)
          )
        end

        def replace(target:, html:)
          @stream.write(
            %(<turbo-stream action="replace" target="#{target}">) +
            %(<template>#{html}</template></turbo-stream>)
          )
        end

        def close
          @stream.close
        rescue IOError
          # Operator navigated away — nothing to flush.
        end
      end.new(stream, target)

      begin
        block.call(pump)
      ensure
        pump.close
      end
    end
  end

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

    it "renders the form with default-KB defaults pre-filled" do
      get "/curator/console"

      expect(response).to                                 have_http_status(:ok)
      expect(response.body).to                            include("Query Testing Console")
      expect(response.body).to                            include('placeholder="7"')
      expect(response.body).to                            include('placeholder="0.42"')
      expect(response.body).to                            include('selected="selected" value="hybrid"')
      expect(response.body).to                            include('selected="selected" value="default"')
      expect(response.body).to                            include('action="/curator/console/run"')
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

  describe "POST /curator/console/run — happy path" do
    let!(:default_kb) do
      create(:curator_knowledge_base,
             slug:                 "default",
             is_default:           true,
             retrieval_strategy:   "vector",
             similarity_threshold: 0.0,
             chunk_limit:          5)
    end

    let(:fake_hits) do
      [
        Curator::Hit.new(rank: 1, chunk_id: 11, document_id: 21,
                         document_name: "Doc A", page_number: 2,
                         text: "alpha excerpt", score: 0.81, source_url: nil),
        Curator::Hit.new(rank: 2, chunk_id: 12, document_id: 22,
                         document_name: "Doc B", page_number: nil,
                         text: "beta excerpt", score: nil, source_url: nil)
      ]
    end

    let(:fake_results) do
      Curator::RetrievalResults.new(
        query:          "what is alpha?",
        hits:           fake_hits,
        duration_ms:    42,
        knowledge_base: default_kb,
        retrieval_id:   nil
      )
    end

    let(:fake_answer) do
      Curator::Answer.new(
        answer:            "alpha. beta.",
        retrieval_results: fake_results,
        retrieval_id:      nil,
        strict_grounding:  false
      )
    end

    before do
      # Stub Asker at the call site: the controller's responsibility is
      # to wire form params into Asker and stream Asker's deltas. Asker
      # itself + retrieval-row persistence is covered by ask_smoke_spec
      # and Phase 3's end-to-end smoke.
      allow(Curator::Asker).to receive(:call) do |query, **kwargs, &block|
        @captured_query  = query
        @captured_kwargs = kwargs
        block.call("alpha. ")
        block.call("beta.")
        fake_answer
      end
    end

    it "streams append frames in delta order then replaces sources + status" do
      post "/curator/console/run", params: {
        knowledge_base_slug:   "default",
        query:                 "what is alpha?",
        chunk_limit:           "9",
        similarity_threshold: "0.25",
        strategy:              "hybrid",
        system_prompt:         "be terse",
        chat_model:            "gpt-5-nano"
      }

      expect(response).to                            have_http_status(:ok)
      expect(response.headers["Content-Type"]).to    eq("text/vnd.turbo-stream.html")
      expect(response.headers["Cache-Control"]).to   include("no-cache")

      body = response.body

      # Append frames carry the deltas in order, HTML-escaped inside <template>.
      append_frames = body.scan(%r{<turbo-stream action="append" target="console-answer">.*?</turbo-stream>}m)
      expect(append_frames.size).to eq(2)
      expect(append_frames[0]).to   include("alpha. ")
      expect(append_frames[1]).to   include("beta.")

      # Two replace frames after the deltas: sources, then status.
      replace_frames = body.scan(%r{<turbo-stream action="replace" target="(console-sources|console-status)">.*?</turbo-stream>}m)
      expect(replace_frames.map(&:first)).to eq(%w[console-sources console-status])

      expect(body).to include("Doc A")
      expect(body).to include("Doc B")
      expect(body).to include("console-status--done")

      expect(@captured_query).to eq("what is alpha?")
      expect(@captured_kwargs[:knowledge_base]).to eq(default_kb)
      expect(@captured_kwargs[:limit]).to      eq(9)
      expect(@captured_kwargs[:threshold]).to  eq(0.25)
      expect(@captured_kwargs[:strategy]).to   eq("hybrid")
      expect(@captured_kwargs[:system_prompt]).to eq("be terse")
      expect(@captured_kwargs[:chat_model]).to eq("gpt-5-nano")
    end

    it "blanks override params pass through to Asker as nil" do
      post "/curator/console/run", params: {
        knowledge_base_slug: "default",
        query:               "go",
        chunk_limit:         "",
        similarity_threshold: "",
        strategy:            "vector",
        system_prompt:       "",
        chat_model:          "gpt-5-mini"
      }

      expect(@captured_kwargs[:limit]).to         be_nil
      expect(@captured_kwargs[:threshold]).to     be_nil
      expect(@captured_kwargs[:system_prompt]).to be_nil
    end
  end

  describe "POST /curator/console/run — failure path" do
    let!(:default_kb) do
      create(:curator_knowledge_base, slug: "default", is_default: true)
    end

    before do
      allow(Curator::Asker).to receive(:call)
        .and_raise(Curator::LLMError, "stubbed LLM blew up")
    end

    it "replaces console-status with the failed badge + error message" do
      post "/curator/console/run", params: {
        knowledge_base_slug: "default",
        query:               "anything"
      }

      expect(response).to have_http_status(:ok)
      body = response.body

      expect(body).to     match(%r{<turbo-stream action="replace" target="console-status">})
      expect(body).to     include("console-status--failed")
      expect(body).to     include("stubbed LLM blew up")
      # No `done` frame — the failed branch short-circuits before
      # the success replace frames.
      expect(body).not_to include("console-status--done")
    end

    # Regression for the stream-leak bug: KB resolution must happen
    # inside `TurboStream.open`'s block so a `RecordNotFound` flips to
    # a failed status frame rather than escaping the pump's
    # `ensure pump.close` and leaving the Live stream hanging.
    it "replaces console-status with the failed badge when the slug is unknown" do
      post "/curator/console/run", params: {
        knowledge_base_slug: "nonexistent",
        query:               "anything"
      }

      expect(response).to      have_http_status(:ok)
      expect(response.body).to include("console-status--failed")
      expect(response.body).to match(
        %r{<turbo-stream action="replace" target="console-status">}
      )
    end
  end
end
