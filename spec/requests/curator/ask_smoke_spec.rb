require "rails_helper"

# End-to-end smoke for the M4 Q&A pipeline. Drives the full chain
# inline against the dummy app:
#
#   Curator.ingest → IngestDocumentJob → EmbedChunksJob (real body,
#   RubyLLM stubbed at HTTP via the suite-level stub_embed and a
#   per-spec stub_chat_completion / stub_chat_completion_stream) →
#   Curator.ask non-streamed → streamed → strict-grounding refusal →
#   include_citations parity → reconstruction round-trip via
#   Curator::Answer.from_retrieval.
#
# The point is not answer quality — it's that every layer's outputs
# wire to the next layer's inputs and that one ask leaves exactly the
# expected DB shape (one Chat, two Messages, one Retrieval row, N
# RetrievalHit rows) regardless of streaming / refusal / citation
# config.
RSpec.describe "Curator Q&A end-to-end smoke", type: :request do
  include ActiveJob::TestHelper

  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }
  let(:md_path)     { fixture_dir.join("sample.md") }

  # Pinned to vector + threshold 0.0 because the deterministic embed
  # stub doesn't model real semantics — hybrid + the seeded 0.2
  # threshold gives flaky ranking on a fixture this small. Don't
  # "restore" to seeded defaults without also reworking the fixtures.
  let!(:default_kb) do
    Curator::KnowledgeBase.seed_default!.tap do |kb|
      kb.update!(retrieval_strategy: "vector", similarity_threshold: 0.0)
    end
  end

  before do
    Curator.configure { |c| c.extractor = :basic }
    perform_enqueued_jobs { Curator.ingest(md_path.to_s) }
  end
  after { Curator.reset_config! }

  describe "non-streamed happy path" do
    before { stub_chat_completion(content: "Sample answer with marker [1].") }

    it "returns a populated Answer, persists Chat + messages, snapshots the retrieval row, " \
       "and reconstructs identically via Curator::Answer.from_retrieval" do
      answer = Curator.ask("Sample Markdown", knowledge_base: default_kb)

      expect(answer).to be_a(Curator::Answer)
      expect(answer.answer).to       eq("Sample answer with marker [1].")
      expect(answer.refused?).to     be false
      expect(answer.sources).not_to  be_empty

      chat = Chat.sole
      expect(chat.curator_scope).to be_nil
      messages = chat.messages.order(:id)
      expect(messages.pluck(:role)).to eq(%w[system user assistant])

      user_msg      = messages.find_by(role: :user)
      assistant_msg = messages.find_by(role: :assistant)
      expect(user_msg.content).to      eq("Sample Markdown")
      expect(assistant_msg.content).to eq("Sample answer with marker [1].")

      row = Curator::Retrieval.find(answer.retrieval_id)
      expect(row).to                    be_success
      expect(row.chat_id).to            eq(chat.id)
      expect(row.message_id).to         eq(assistant_msg.id)
      expect(row.system_prompt_text).to include("[1] From")
      expect(row.system_prompt_hash).to match(/\A[0-9a-f]{64}\z/)
      expect(row.strict_grounding).to   be true
      expect(row.include_citations).to  be true
      expect(row.chat_model).to         eq(default_kb.chat_model)
      expect(row.embedding_model).to    eq(default_kb.embedding_model)
      expect(row.retrieval_strategy).to eq("vector")

      expect(row.retrieval_hits.count).to eq(answer.sources.size)
      reconstructed = Curator::Answer.from_retrieval(row.reload)
      expect(reconstructed.answer).to           eq(answer.answer)
      expect(reconstructed.strict_grounding).to eq(answer.strict_grounding)
      expect(reconstructed.sources.size).to     eq(answer.sources.size)
      answer.sources.zip(reconstructed.sources).each do |live, replayed|
        expect(replayed.rank).to          eq(live.rank)
        expect(replayed.chunk_id).to      eq(live.chunk_id)
        expect(replayed.document_name).to eq(live.document_name)
        expect(replayed.page_number).to   eq(live.page_number)
        expect(replayed.text).to          eq(live.text)
        expect(replayed.score).to         be_within(0.0001).of(live.score) if live.score
      end
    end
  end

  describe "streaming" do
    before do
      WebMock.reset!
      stub_embed
      stub_chat_completion_stream(deltas: [ "Sample ", "answer ", "with ", "marker [1]." ])
    end

    it "yields String deltas concatenating to Answer#answer and flips streamed: true on the trace" do
      collected = []
      answer = Curator.ask("Sample Markdown", knowledge_base: default_kb) { |delta| collected << delta }

      expect(collected).to      all(be_a(String))
      expect(collected.size).to be > 1
      expect(collected.join).to eq(answer.answer)
      expect(answer.answer).to  eq("Sample answer with marker [1].")

      llm_step = Curator::Retrieval.sole.retrieval_steps.find_by(step_type: "llm_call")
      expect(llm_step.payload["streamed"]).to be true

      assistant_msg = Chat.sole.messages.find_by(role: :assistant)
      expect(assistant_msg.content).to              eq("Sample answer with marker [1].")
      expect(Curator::Retrieval.sole.message_id).to eq(assistant_msg.id)
    end
  end

  describe "strict-grounding refusal against an empty KB" do
    let(:empty_kb) do
      create(:curator_knowledge_base,
             retrieval_strategy:   "vector",
             similarity_threshold: 0.0,
             strict_grounding:     true)
    end

    # No /v1/chat/completions stub: if the refusal path regresses and
    # the LLM is called, WebMock's net-connect block fails the test
    # loudly — that's the assertion we want.
    it "returns REFUSAL_MESSAGE without hitting /v1/chat/completions" do
      answer = Curator.ask("anything goes", knowledge_base: empty_kb)

      expect(answer.answer).to    eq(Curator::Prompt::Templates::REFUSAL_MESSAGE)
      expect(answer.refused?).to  be true
      expect(answer.sources).to   be_empty
      expect(WebMock).not_to have_requested(:post, RubyLLMStubs::CHAT_COMPLETION_URL)

      row    = Curator::Retrieval.find(answer.retrieval_id)
      types  = row.retrieval_steps.order(:sequence).pluck(:step_type)
      expect(row).to       be_success
      expect(types).to     include("prompt_assembly")
      expect(types).not_to include("llm_call")

      chat = Chat.sole
      expect(chat.messages.order(:id).pluck(:role)).to eq(%w[user assistant])
      expect(chat.messages.find_by(role: :assistant).content)
        .to eq(Curator::Prompt::Templates::REFUSAL_MESSAGE)
    end
  end

  describe "include_citations: false parity" do
    let(:no_cite_kb) do
      create(:curator_knowledge_base,
             retrieval_strategy:   "vector",
             similarity_threshold: 0.0,
             include_citations:    false)
    end

    before do
      stub_chat_completion(content: "Citation-free answer.")
      perform_enqueued_jobs { Curator.ingest(md_path.to_s, knowledge_base: no_cite_kb) }
    end

    it "assembles a prompt with the non-citing instructions template" do
      answer = Curator.ask("Sample Markdown", knowledge_base: no_cite_kb)

      expect(answer.answer).to eq("Citation-free answer.")

      row = Curator::Retrieval.where(knowledge_base_id: no_cite_kb.id).sole
      expect(row.include_citations).to be false
      expect(row.system_prompt_text)
        .to start_with(Curator::Prompt::Templates::DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS)
      # The citing template's `[N] markers that match the numbered context
      # entries below.` line must not appear when include_citations is off.
      expect(row.system_prompt_text).not_to include("[N] markers")
      # Context block is still Curator-built, so hits still render with
      # `[<rank>] From` headers — only the *instructions* half changes.
      expect(row.system_prompt_text).to include("[1] From")
    end
  end
end
