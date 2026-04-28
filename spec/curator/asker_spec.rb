require "rails_helper"

RSpec.describe "Curator.ask" do
  let(:kb) do
    create(:curator_knowledge_base,
           retrieval_strategy:   "vector",
           similarity_threshold: 0.0,
           chunk_limit:          5,
           strict_grounding:     true,
           include_citations:    true)
  end
  let(:document) { create(:curator_document, knowledge_base: kb) }

  def make_chunk(content:, sequence:)
    chunk = create(:curator_chunk,
                   document: document,
                   sequence: sequence,
                   content:  content,
                   status:   :embedded)
    create(:curator_embedding,
           chunk:           chunk,
           embedding:       deterministic_vector(content, 1536),
           embedding_model: kb.embedding_model)
    chunk
  end

  before do
    stub_embed(model: kb.embedding_model)
    stub_chat_completion(model: kb.chat_model, content: "Stubbed answer with marker [1].")
  end

  describe "happy path" do
    let!(:chunk) { make_chunk(content: "alpha beta gamma", sequence: 0) }

    it "returns Curator::Answer with answer text and sources" do
      answer = Curator.ask("alpha beta gamma", knowledge_base: kb)

      expect(answer).to be_a(Curator::Answer)
      expect(answer.answer).to       eq("Stubbed answer with marker [1].")
      expect(answer.sources).not_to  be_empty
      expect(answer.sources.first.chunk_id).to eq(chunk.id)
      expect(answer.refused?).to be false
    end

    it "ties Answer.retrieval_id to the curator_retrievals row, populated with snapshots" do
      answer = Curator.ask("alpha beta gamma", knowledge_base: kb)

      row = Curator::Retrieval.sole
      expect(answer.retrieval_id).to     eq(row.id)
      expect(row).to                     be_success
      expect(row.chat_id).not_to         be_nil
      expect(row.message_id).not_to      be_nil
      expect(row.system_prompt_text).to  include(%([1] From))
      expect(row.system_prompt_hash).to  match(/\A[0-9a-f]{64}\z/)
      expect(row.strict_grounding).to    be true
      expect(row.include_citations).to   be true
      expect(row.chat_model).to          eq(kb.chat_model)
      expect(row.embedding_model).to     eq(kb.embedding_model)
      expect(row.retrieval_strategy).to  eq("vector")
      expect(row.chunk_limit).to         eq(5)
      expect(row.total_duration_ms).to   be >= 0
    end

    it "creates exactly one Chat with curator_scope: nil and persists user + assistant messages" do
      Curator.ask("alpha beta gamma", knowledge_base: kb)

      chat = Chat.sole
      expect(chat.curator_scope).to be_nil

      # acts_as_chat persists: system instruction + user + assistant
      messages = chat.messages.order(:id)
      roles    = messages.pluck(:role)
      expect(roles).to eq(%w[system user assistant])

      user_msg      = messages.find { |m| m.role == "user" }
      assistant_msg = messages.find { |m| m.role == "assistant" }
      expect(user_msg.content).to      eq("alpha beta gamma")
      expect(assistant_msg.content).to eq("Stubbed answer with marker [1].")
      expect(Curator::Retrieval.sole.message_id).to eq(assistant_msg.id)
    end

    it "emits the expected trace step sequence" do
      Curator.ask("alpha beta gamma", knowledge_base: kb)

      step_types = Curator::Retrieval.sole.retrieval_steps.order(:sequence).pluck(:step_type)
      expect(step_types).to eq(%w[embed_query vector_search prompt_assembly llm_call])
    end

    it "writes prompt_assembly + llm_call payloads at trace_level :full" do
      Curator.ask("alpha beta gamma", knowledge_base: kb)

      steps = Curator::Retrieval.sole.retrieval_steps.order(:sequence).to_a
      assembly = steps.find { |s| s.step_type == "prompt_assembly" }
      llm      = steps.find { |s| s.step_type == "llm_call" }

      expect(assembly.payload).to include("hit_count", "system_prompt_hash", "prompt_token_estimate")
      expect(assembly.payload["hit_count"]).to eq(1)
      expect(llm.payload).to include("model", "input_tokens", "output_tokens", "streamed", "finish_reason")
      expect(llm.payload["streamed"]).to      be false
      expect(llm.payload["finish_reason"]).to eq("stop")
    end
  end

  describe "finish_reason capture" do
    it "surfaces a non-stop finish_reason from the OpenAI raw response" do
      make_chunk(content: "alpha beta gamma", sequence: 0)
      stub_chat_completion(model: kb.chat_model,
                           content: "Truncated answer cut off mid-sen",
                           finish_reason: "length")

      Curator.ask("alpha beta gamma", knowledge_base: kb)

      llm_step = Curator::Retrieval.sole.retrieval_steps.find_by(step_type: "llm_call")
      expect(llm_step.payload["finish_reason"]).to eq("length")
    end

    # Direct unit coverage of the provider-shape dispatch, since the
    # integration specs above only exercise the OpenAI branch via
    # `stub_chat_completion`. When v2 adds non-OpenAI providers,
    # extend this describe block before generalizing the extractor.
    describe "#extract_finish_reason (provider-shape dispatch)" do
      let(:asker)         { Curator::Asker.new("q", knowledge_base: kb) }
      let(:raw_response)  { ->(body) { Struct.new(:body).new(body) } }
      let(:message_with)  { ->(body) { RubyLLM::Message.new(role: :assistant, content: "x", raw: raw_response[body]) } }

      it "extracts from OpenAI's choices[0].finish_reason path" do
        msg = message_with[{ "choices" => [ { "finish_reason" => "stop" } ] }]
        expect(asker.send(:extract_finish_reason, msg)).to eq("stop")
      end

      it "extracts from Anthropic's top-level stop_reason key" do
        msg = message_with[{ "stop_reason" => "end_turn" }]
        expect(asker.send(:extract_finish_reason, msg)).to eq("end_turn")
      end

      it "returns nil when neither shape is present" do
        msg = message_with[{ "unrelated" => "payload" }]
        expect(asker.send(:extract_finish_reason, msg)).to be_nil
      end
    end
  end

  describe "call-site overrides" do
    before { make_chunk(content: "alpha beta gamma", sequence: 0) }

    it "honors chat_model: override on the Chat row, the snapshot, and the LLM stub" do
      stub_chat_completion(model: "gpt-4o-mini", content: "Override reply.")

      answer = Curator.ask("alpha beta gamma", knowledge_base: kb, chat_model: "gpt-4o-mini")

      expect(answer.answer).to eq("Override reply.")
      expect(Chat.sole.model_id).to                          eq("gpt-4o-mini")
      expect(Curator::Retrieval.sole.chat_model).to          eq("gpt-4o-mini")
      expect(kb.reload.chat_model).to                        eq("gpt-5-mini")
      expect(WebMock).to have_requested(:post, RubyLLMStubs::CHAT_COMPLETION_URL)
        .with(body: hash_including("model" => "gpt-4o-mini"))
    end

    it "honors system_prompt: override as the instructions half of the assembled prompt" do
      Curator.ask("alpha beta gamma", knowledge_base: kb,
                                      system_prompt: "Custom override instructions.")

      row = Curator::Retrieval.sole
      expect(row.system_prompt_text).to start_with("Custom override instructions.")
      # Context block is still Curator-built, so the citation marker survives.
      expect(row.system_prompt_text).to include(%([1] From))
    end
  end

  describe "failure modes" do
    before { make_chunk(content: "alpha beta gamma", sequence: 0) }

    it "wraps RubyLLM::Error as Curator::LLMError, marks the row :failed with chat_id set" do
      stub_chat_completion_error(:server_error, model: kb.chat_model)

      expect { Curator.ask("alpha beta gamma", knowledge_base: kb) }
        .to raise_error(Curator::LLMError, /LLM call failed/)

      row = Curator::Retrieval.sole
      expect(row).to                  be_failed
      expect(row.error_message).to    match(/LLMError/)
      expect(row.chat_id).not_to      be_nil
      expect(row.message_id).to       be_nil
      expect(row.total_duration_ms).to be >= 0
    end

    it "raises ArgumentError on a blank query *before* opening a retrieval row" do
      expect { Curator.ask("   ", knowledge_base: kb) }.to raise_error(ArgumentError, /query/)
      expect(Curator::Retrieval.count).to eq(0)
      expect(Chat.count).to               eq(0)
    end
  end

  describe "retrieval-hit persistence + reconstruction" do
    let!(:chunk) { make_chunk(content: "alpha beta gamma", sequence: 0) }

    it "persists curator_retrieval_hits whose reconstruction matches the live Answer" do
      live = Curator.ask("alpha beta gamma", knowledge_base: kb)

      reconstructed = Curator::Answer.from_retrieval(Curator::Retrieval.find(live.retrieval_id))

      expect(reconstructed.answer).to            eq(live.answer)
      expect(reconstructed.strict_grounding).to  eq(live.strict_grounding)
      expect(reconstructed.sources.size).to      eq(live.sources.size)
      live.sources.zip(reconstructed.sources).each do |a, b|
        expect(b.rank).to          eq(a.rank)
        expect(b.chunk_id).to      eq(a.chunk_id)
        expect(b.document_name).to eq(a.document_name)
        expect(b.page_number).to   eq(a.page_number)
        expect(b.text).to          eq(a.text)
        expect(b.score).to         be_within(0.0001).of(a.score) if a.score
      end
    end

    it "survives Curator.reingest of the source document (chunk_id nil, snapshot intact)" do
      live = Curator.ask("alpha beta gamma", knowledge_base: kb)
      hit_row = Curator::Retrieval.find(live.retrieval_id).retrieval_hits.order(:rank).first
      expect(hit_row.chunk_id).to eq(chunk.id)

      Curator.reingest(chunk.document)

      hit_row.reload
      expect(hit_row.chunk_id).to    be_nil
      expect(hit_row.text).to        eq("alpha beta gamma")
      expect(hit_row.document_name).to eq(chunk.document.title)
    end

    it "survives document.destroy (chunk_id and document_id nil, snapshot intact)" do
      live = Curator.ask("alpha beta gamma", knowledge_base: kb)
      hit_row = Curator::Retrieval.find(live.retrieval_id).retrieval_hits.order(:rank).first

      chunk.document.destroy

      hit_row.reload
      expect(hit_row.chunk_id).to    be_nil
      expect(hit_row.document_id).to be_nil
      expect(hit_row.text).to        eq("alpha beta gamma")
    end

    it "is destroyed via the cascade when the knowledge_base is destroyed" do
      Curator.ask("alpha beta gamma", knowledge_base: kb)
      expect(Curator::RetrievalHit.count).to eq(1)

      kb.destroy

      expect(Curator::RetrievalHit.count).to eq(0)
      expect(Curator::Retrieval.count).to    eq(0)
    end

    it "marks the parent retrieval :failed when hit insert raises" do
      allow(Curator::RetrievalHit).to receive(:insert_all!)
        .and_raise(ActiveRecord::StatementInvalid, "hit insert boom")

      expect { Curator.ask("alpha beta gamma", knowledge_base: kb) }
        .to raise_error(ActiveRecord::StatementInvalid, /hit insert boom/)

      row = Curator::Retrieval.sole
      expect(row).to be_failed
      expect(row.error_message).to match(/hit insert boom/)
    end
  end

  describe "streaming block" do
    let!(:chunk) { make_chunk(content: "alpha beta gamma", sequence: 0) }

    before do
      WebMock.reset!
      stub_embed(model: kb.embedding_model)
      stub_chat_completion_stream(
        model:  kb.chat_model,
        deltas: [ "Stubbed ", "answer ", "with ", "marker [1]." ]
      )
    end

    it "yields String deltas whose concatenation equals Answer#answer" do
      collected = []
      answer = Curator.ask("alpha beta gamma", knowledge_base: kb) { |delta| collected << delta }

      expect(collected).to                all(be_a(String))
      expect(collected.size).to           be > 1
      expect(collected.join).to           eq(answer.answer)
      expect(answer.answer).to            eq("Stubbed answer with marker [1].")
      expect(answer.refused?).to          be false
      expect(answer.sources.first.chunk_id).to eq(chunk.id)
    end

    it "writes streamed: true in the llm_call trace payload" do
      Curator.ask("alpha beta gamma", knowledge_base: kb) { |_| }

      llm_step = Curator::Retrieval.sole.retrieval_steps.find_by(step_type: "llm_call")
      expect(llm_step.payload["streamed"]).to be true
    end

    it "persists user + assistant messages on the chat (acts_as_chat callbacks fire on stream too)" do
      Curator.ask("alpha beta gamma", knowledge_base: kb) { |_| }

      roles = Chat.sole.messages.order(:id).pluck(:role)
      expect(roles).to eq(%w[system user assistant])
      assistant_msg = Chat.sole.messages.find_by(role: :assistant)
      expect(assistant_msg.content).to              eq("Stubbed answer with marker [1].")
      expect(Curator::Retrieval.sole.message_id).to eq(assistant_msg.id)
    end
  end

  describe "Curator.config.llm_retry_count propagation" do
    let!(:chunk) { make_chunk(content: "alpha beta gamma", sequence: 0) }

    around do |ex|
      original = Curator.config.llm_retry_count
      Curator.config.llm_retry_count = 3
      ex.run
    ensure
      Curator.config.llm_retry_count = original
    end

    it "retries POSTs on 503 up to llm_retry_count and succeeds on the next 200" do
      WebMock.reset!
      stub_embed(model: kb.embedding_model)

      success_body = {
        "id"      => "chatcmpl-stub-success",
        "object"  => "chat.completion",
        "created" => Time.now.to_i,
        "model"   => kb.chat_model,
        "choices" => [ {
          "index"         => 0,
          "message"       => { "role" => "assistant", "content" => "Recovered after retries." },
          "finish_reason" => "stop"
        } ],
        "usage"   => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      }.to_json
      error_body = { "error" => { "type" => "service_unavailable", "message" => "stubbed" } }.to_json

      WebMock.stub_request(:post, RubyLLMStubs::CHAT_COMPLETION_URL)
             .with(body: hash_including("model" => kb.chat_model))
             .to_return(
               { status: 503, headers: { "Content-Type" => "application/json" }, body: error_body },
               { status: 503, headers: { "Content-Type" => "application/json" }, body: error_body },
               { status: 503, headers: { "Content-Type" => "application/json" }, body: error_body },
               { status: 200, headers: { "Content-Type" => "application/json" }, body: success_body }
             )

      answer = Curator.ask("alpha beta gamma", knowledge_base: kb)

      expect(answer.answer).to eq("Recovered after retries.")
      expect(WebMock).to have_requested(:post, RubyLLMStubs::CHAT_COMPLETION_URL).times(4)
    end
  end

  describe "streaming + mid-stream error" do
    let!(:chunk) { make_chunk(content: "alpha beta gamma", sequence: 0) }

    around do |ex|
      original = Curator.config.llm_retry_count
      # Disable retries so the documented "no replay" constraint holds —
      # faraday-retry does in fact replay on retryable exceptions even after
      # SSE bytes have flowed; setting the budget to zero is how callers opt
      # out for idempotency-sensitive streaming consumers.
      Curator.config.llm_retry_count = 0
      ex.run
    ensure
      Curator.config.llm_retry_count = original
    end

    it "surfaces Curator::LLMError after partial deltas have been yielded — no replay" do
      WebMock.reset!
      stub_embed(model: kb.embedding_model)
      stub_chat_completion_stream_error(
        model:          kb.chat_model,
        partial_deltas: [ "alpha ", "beta " ]
      )

      collected = []
      expect {
        Curator.ask("alpha beta gamma", knowledge_base: kb) { |delta| collected << delta }
      }.to raise_error(Curator::LLMError, /LLM call failed/)

      expect(collected).to eq([ "alpha ", "beta " ])
      expect(WebMock).to have_requested(:post, RubyLLMStubs::CHAT_COMPLETION_URL).once
      expect(Curator::Retrieval.sole).to be_failed
    end
  end

  describe "strict-grounding refusal path" do
    # No chunks are created in this describe — the retrieval pipeline
    # comes back empty and the refusal branch fires.
    it "skips the LLM and returns REFUSAL_MESSAGE when KB has strict_grounding: true" do
      answer = Curator.ask("alpha beta gamma", knowledge_base: kb)

      expect(answer.answer).to    eq(Curator::Prompt::Templates::REFUSAL_MESSAGE)
      expect(answer.refused?).to  be true
      expect(answer.sources).to   be_empty
      expect(WebMock).not_to have_requested(:post, RubyLLMStubs::CHAT_COMPLETION_URL)
    end

    it "persists user + assistant Message rows on the chat (no system message — with_instructions never ran)" do
      Curator.ask("alpha beta gamma", knowledge_base: kb)

      chat  = Chat.sole
      roles = chat.messages.order(:id).pluck(:role)
      expect(roles).to eq(%w[user assistant])

      assistant_msg = chat.messages.find_by(role: :assistant)
      expect(assistant_msg.content).to eq(Curator::Prompt::Templates::REFUSAL_MESSAGE)
      expect(chat.messages.find_by(role: :user).content).to eq("alpha beta gamma")
      expect(Curator::Retrieval.sole.message_id).to eq(assistant_msg.id)
    end

    it "emits prompt_assembly but no llm_call, marks the retrieval row :success" do
      Curator.ask("alpha beta gamma", knowledge_base: kb)

      row    = Curator::Retrieval.sole
      types  = row.retrieval_steps.order(:sequence).pluck(:step_type)
      expect(types).to     include("prompt_assembly")
      expect(types).not_to include("llm_call")
      expect(row).to be_success
      expect(row.chat_id).not_to    be_nil
      expect(row.message_id).not_to be_nil
    end

    it "calls a streaming block exactly once with REFUSAL_MESSAGE as a single delta" do
      collected = []
      answer = Curator.ask("alpha beta gamma", knowledge_base: kb) { |delta| collected << delta }

      expect(collected).to eq([ Curator::Prompt::Templates::REFUSAL_MESSAGE ])
      expect(answer.answer).to   eq(Curator::Prompt::Templates::REFUSAL_MESSAGE)
      expect(answer.refused?).to be true
    end

    context "when KB has strict_grounding: false" do
      let(:kb) do
        create(:curator_knowledge_base,
               retrieval_strategy:   "vector",
               similarity_threshold: 0.0,
               chunk_limit:          5,
               strict_grounding:     false,
               include_citations:    true)
      end

      it "calls the LLM normally with an empty context block and refused? is false" do
        answer = Curator.ask("alpha beta gamma", knowledge_base: kb)

        expect(WebMock).to have_requested(:post, RubyLLMStubs::CHAT_COMPLETION_URL).once
        expect(answer.answer).to    eq("Stubbed answer with marker [1].")
        expect(answer.refused?).to  be false
        expect(answer.sources).to   be_empty

        row = Curator::Retrieval.sole
        types = row.retrieval_steps.order(:sequence).pluck(:step_type)
        expect(types).to include("llm_call")
        # Assembler still ran with zero hits — instructions present, no
        # `[N] From` block since hits were empty.
        expect(row.system_prompt_text).not_to include(%([1] From))
      end
    end
  end

  describe "config.log_queries = false" do
    around do |ex|
      Curator.config.log_queries = false
      ex.run
    ensure
      Curator.config.log_queries = true
    end

    it "skips the curator_retrievals row but still returns an Answer with retrieval_id nil" do
      make_chunk(content: "alpha beta gamma", sequence: 0)

      answer = Curator.ask("alpha beta gamma", knowledge_base: kb)

      expect(Curator::Retrieval.count).to eq(0)
      expect(answer).to                   be_a(Curator::Answer)
      expect(answer.answer).to            eq("Stubbed answer with marker [1].")
      expect(answer.retrieval_id).to      be_nil
      expect(Chat.count).to               eq(1)
    end
  end
end
