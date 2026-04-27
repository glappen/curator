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
