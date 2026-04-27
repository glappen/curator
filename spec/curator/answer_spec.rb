require "rails_helper"

RSpec.describe Curator::Answer do
  let(:kb) { build_stubbed(:curator_knowledge_base) }
  let(:hit) do
    Curator::Hit.new(
      rank: 1, chunk_id: 1, document_id: 1, document_name: "doc",
      page_number: nil, text: "body", score: 0.8, source_url: nil
    )
  end

  def results(hits)
    Curator::RetrievalResults.new(
      query: "q", hits: hits, duration_ms: 12,
      knowledge_base: kb, retrieval_id: 99
    )
  end

  def answer(hits:, strict_grounding:)
    described_class.new(
      answer:            "x",
      retrieval_results: results(hits),
      retrieval_id:      99,
      strict_grounding:  strict_grounding
    )
  end

  describe "#refused?" do
    it "is true when strict_grounding and hits are empty" do
      expect(answer(hits: [], strict_grounding: true).refused?).to be true
    end

    it "is false when strict_grounding is false (empty hits)" do
      expect(answer(hits: [], strict_grounding: false).refused?).to be false
    end

    it "is false when hits are non-empty regardless of strict_grounding" do
      expect(answer(hits: [ hit ], strict_grounding: true).refused?).to  be false
      expect(answer(hits: [ hit ], strict_grounding: false).refused?).to be false
    end

    it "coerces non-boolean strict_grounding to a boolean (defensive)" do
      expect(answer(hits: [], strict_grounding: nil).refused?).to be false
    end
  end

  describe "#sources" do
    it "returns retrieval_results.hits" do
      a = answer(hits: [ hit ], strict_grounding: false)
      expect(a.sources).to eq([ hit ])
    end

    it "is empty when retrieval_results has no hits" do
      a = answer(hits: [], strict_grounding: true)
      expect(a.sources).to eq([])
    end
  end

  it "exposes the constructor fields" do
    a = answer(hits: [ hit ], strict_grounding: true)
    expect(a.answer).to eq("x")
    expect(a.retrieval_results.hits).to eq([ hit ])
    expect(a.retrieval_id).to eq(99)
    expect(a.strict_grounding).to be true
  end

  describe ".from_retrieval" do
    let(:kb_real)        { create(:curator_knowledge_base, strict_grounding: true) }
    let(:document_real)  { create(:curator_document, knowledge_base: kb_real) }
    let(:chunk_real) do
      create(:curator_chunk,
             document: document_real, sequence: 0,
             content: "snapshot text", status: :embedded)
    end

    def make_assistant_message
      chat = Chat.create!(model: kb_real.chat_model, curator_scope: nil)
      chat.add_message(role: :user,      content: "q")
      chat.add_message(role: :assistant, content: "stored answer")
    end

    def make_retrieval_with_hit(strict_grounding: true)
      assistant = make_assistant_message
      retrieval = create(:curator_retrieval,
                         knowledge_base: kb_real,
                         query: "q",
                         total_duration_ms: 42,
                         strict_grounding: strict_grounding,
                         message_id: assistant.id,
                         chat_id: assistant.chat_id)
      Curator::RetrievalHit.create!(
        retrieval:     retrieval,
        chunk:         chunk_real,
        document:      document_real,
        rank:          1,
        score:         0.85,
        document_name: document_real.title,
        page_number:   2,
        text:          "snapshot text",
        source_url:    "https://example.com/doc"
      )
      [ retrieval, assistant ]
    end

    it "round-trips an Answer whose fields match the persisted snapshot" do
      retrieval, assistant = make_retrieval_with_hit

      reconstructed = described_class.from_retrieval(retrieval)

      expect(reconstructed.answer).to                           eq("stored answer")
      expect(reconstructed.retrieval_id).to                     eq(retrieval.id)
      expect(reconstructed.strict_grounding).to                 be true
      expect(reconstructed.retrieval_results.query).to          eq("q")
      expect(reconstructed.retrieval_results.duration_ms).to    eq(42)
      expect(reconstructed.retrieval_results.knowledge_base).to eq(kb_real)

      expect(reconstructed.sources.size).to eq(1)
      source = reconstructed.sources.first
      expect(source.rank).to          eq(1)
      expect(source.chunk_id).to      eq(chunk_real.id)
      expect(source.document_id).to   eq(document_real.id)
      expect(source.document_name).to eq(document_real.title)
      expect(source.page_number).to   eq(2)
      expect(source.text).to          eq("snapshot text")
      expect(source.score).to         be_within(0.0001).of(0.85)
      expect(source.source_url).to    eq("https://example.com/doc")
      expect(assistant).to be_persisted
    end

    it "raises ArgumentError on a row with message_id: nil" do
      retrieve_only = create(:curator_retrieval, knowledge_base: kb_real, message_id: nil)

      expect { described_class.from_retrieval(retrieve_only) }
        .to raise_error(ArgumentError, /no assistant message/)
    end

    it "raises ArgumentError when message_id points at a deleted Message row" do
      retrieval, assistant = make_retrieval_with_hit
      assistant.destroy

      expect { described_class.from_retrieval(retrieval.reload) }
        .to raise_error(ArgumentError, /no longer exists/)
    end

    it "is also callable via Curator::Retrieval#to_answer" do
      retrieval, _ = make_retrieval_with_hit
      expect(retrieval.to_answer.answer).to eq("stored answer")
    end

    it "returns sources == [] for pre-Phase-5 rows with no hit rows" do
      assistant = make_assistant_message
      retrieval = create(:curator_retrieval,
                         knowledge_base:    kb_real,
                         message_id:        assistant.id,
                         chat_id:           assistant.chat_id,
                         total_duration_ms: 1,
                         strict_grounding:  false)

      reconstructed = described_class.from_retrieval(retrieval)
      expect(reconstructed.sources).to  eq([])
      expect(reconstructed.refused?).to be false
    end
  end
end
