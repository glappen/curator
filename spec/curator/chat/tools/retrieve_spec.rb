require "rails_helper"

RSpec.describe Curator::Chat::Tools::Retrieve do
  let(:kb) do
    create(:curator_knowledge_base,
           retrieval_strategy:   "vector",
           similarity_threshold: 0.0,
           chunk_limit:          5)
  end
  let(:document) { create(:curator_document, knowledge_base: kb, title: "alpha-doc.md") }
  let(:retrieval) do
    create(:curator_retrieval,
           knowledge_base: kb,
           query:          "user-facing turn input",
           origin:         :chat_tool)
  end

  def make_chunk(content:, sequence:, page_number: nil)
    chunk = create(:curator_chunk,
                   document:    document,
                   sequence:    sequence,
                   content:     content,
                   page_number: page_number,
                   status:      :embedded)
    create(:curator_embedding,
           chunk:           chunk,
           embedding:       deterministic_vector(content, 1536),
           embedding_model: kb.embedding_model)
    chunk
  end

  before do
    stub_embed(model: kb.embedding_model)
    Curator.config.trace_level = :full
  end

  after { Curator.config.trace_level = :full }

  describe "#description and #parameters" do
    it "exposes a description that instructs the LLM to rephrase the user's question" do
      expect(described_class.description).to match(/search-optimized rephrasing/i)
      expect(described_class.description).to match(/hit_count/i)
    end

    it "declares a single required string param `query`" do
      expect(described_class.parameters.keys).to eq([ :query ])
      param = described_class.parameters[:query]
      expect(param.type).to eq(:string)
      expect(param.required).to be(true)
    end
  end

  describe "#execute return shape" do
    it "returns a Format-1 context block plus hit_count" do
      make_chunk(content: "alpha beta gamma", sequence: 0, page_number: 4)
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      result = tool.execute(query: "alpha beta gamma")

      expect(result).to be_a(Hash)
      expect(result.keys).to contain_exactly(:context, :hit_count)
      expect(result[:hit_count]).to be_a(Integer).and(be > 0)
      expect(result[:context]).to start_with("Context:\n\n")
      expect(result[:context]).to match(/\[1\] From "alpha-doc\.md" \(page 4\):\nalpha beta gamma/)
    end

    it "returns hit_count=0 and an empty context block on a KB with no matching chunks" do
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)
      result = tool.execute(query: "anything")

      expect(result[:hit_count]).to eq(0)
      expect(result[:context]).to eq("")
    end
  end

  describe "continuous rank renumbering across calls within a turn" do
    before do
      make_chunk(content: "alpha one",   sequence: 0)
      make_chunk(content: "alpha two",   sequence: 1)
      make_chunk(content: "alpha three", sequence: 2)
    end

    it "first invocation returns ranks [1..K], second returns [K+1..K+M]" do
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      first_result  = tool.execute(query: "alpha one alpha two alpha three")
      first_count   = first_result[:hit_count]
      expect(first_count).to be > 0

      first_ranks = first_result[:context].scan(/\[(\d+)\]/).flatten.map(&:to_i)
      expect(first_ranks).to eq((1..first_count).to_a)

      second_result = tool.execute(query: "alpha one alpha two alpha three")
      second_count  = second_result[:hit_count]
      expect(second_count).to be > 0

      second_ranks = second_result[:context].scan(/\[(\d+)\]/).flatten.map(&:to_i)
      expect(second_ranks).to eq(((first_count + 1)..(first_count + second_count)).to_a)
    end

    it "persists curator_retrieval_hits with renumbered ranks (uniqueness across calls)" do
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      tool.execute(query: "alpha one alpha two alpha three")
      first_count = retrieval.retrieval_hits.count

      tool.execute(query: "alpha one alpha two alpha three")
      total_count = retrieval.retrieval_hits.count

      ranks = retrieval.retrieval_hits.order(:rank).pluck(:rank)
      expect(ranks).to eq((1..total_count).to_a)
      expect(total_count).to eq(first_count * 2)
    end
  end

  describe "tracing brackets" do
    before { make_chunk(content: "alpha", sequence: 0) }

    it "writes :tool_call_started + :tool_call_completed with the documented payload schema" do
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      tool.execute(query: "alpha rephrase")

      bracket_steps = retrieval.retrieval_steps
                               .where(step_type: %w[tool_call_started tool_call_completed])
                               .order(:sequence)

      started   = bracket_steps.find { |s| s.step_type == "tool_call_started" }
      completed = bracket_steps.find { |s| s.step_type == "tool_call_completed" }

      expect(started.payload).to eq(
        "tool"       => "retrieve",
        "call_index" => 0,
        "query"      => "alpha rephrase"
      )
      expect(completed.payload["tool"]).to       eq("retrieve")
      expect(completed.payload["call_index"]).to eq(0)
      expect(completed.payload["hit_count"]).to  eq(retrieval.retrieval_hits.count)
      expect(completed.payload["rank_range"]).to eq([ 1, retrieval.retrieval_hits.count ])
    end

    it "increments call_index across multiple invocations on the same tool instance" do
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      tool.execute(query: "first rephrase")
      tool.execute(query: "second rephrase")

      indices = retrieval.retrieval_steps
                         .where(step_type: "tool_call_started")
                         .order(:sequence)
                         .map { |s| s.payload["call_index"] }

      expect(indices).to eq([ 0, 1 ])
    end

    it "captures rank_range reflecting cumulative renumbering on the second call" do
      make_chunk(content: "alpha extra", sequence: 1)
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      first_result = tool.execute(query: "alpha")
      tool.execute(query: "alpha")

      second_completed = retrieval.retrieval_steps
                                  .where(step_type: "tool_call_completed")
                                  .order(:sequence)
                                  .last

      first_count = first_result[:hit_count]
      total       = retrieval.retrieval_hits.count
      expect(second_completed.payload["rank_range"]).to eq([ first_count + 1, total ])
    end

    it "emits no bracket step rows when trace_level is :off" do
      Curator.config.trace_level = :off
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      tool.execute(query: "alpha")

      expect(retrieval.retrieval_steps.where(step_type: %w[tool_call_started tool_call_completed]))
        .to be_empty
    end
  end

  describe "failure path" do
    before { make_chunk(content: "alpha", sequence: 0) }

    it "writes :tool_call_started but no paired :tool_call_completed when the pipeline raises" do
      stub_embed_error(:server_error, model: kb.embedding_model)
      tool = described_class.new(knowledge_base: kb, retrieval: retrieval)

      expect { tool.execute(query: "alpha") }.to raise_error(Curator::EmbeddingError)

      step_types = retrieval.retrieval_steps.order(:sequence).pluck(:step_type)
      expect(step_types).to include("tool_call_started")
      expect(step_types).not_to include("tool_call_completed")
    end
  end

  describe "behavior with retrieval row absent (log_queries off)" do
    before { make_chunk(content: "alpha", sequence: 0) }

    it "still returns the rendered context + hit_count without persisting hits" do
      tool   = described_class.new(knowledge_base: kb, retrieval: nil)
      result = tool.execute(query: "alpha")

      expect(result[:hit_count]).to be > 0
      expect(result[:context]).to include("[1] From")
      expect(Curator::RetrievalHit.count).to eq(0)
    end
  end
end
