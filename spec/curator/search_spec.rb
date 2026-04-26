require "rails_helper"

RSpec.describe "Curator.search" do
  let(:kb) do
    create(:curator_knowledge_base,
           retrieval_strategy:   "vector",
           similarity_threshold: 0.0,
           chunk_limit:          5)
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
    # Default stub_embed produces deterministic vectors keyed off the
    # query text, matching deterministic_vector. So embedding "alpha"
    # at query time gives the same projection as embedding "alpha" at
    # ingest time — cosine ordering is meaningful end-to-end.
    stub_embed(model: kb.embedding_model)
  end

  describe "input validation" do
    it "raises on a blank query before writing any rows" do
      expect { Curator.search("   ", knowledge_base: kb) }
        .to raise_error(ArgumentError, /query/i)
      expect(Curator::Search.count).to eq(0)
    end

    it "raises on a non-string query" do
      expect { Curator.search(nil, knowledge_base: kb) }.to raise_error(ArgumentError)
    end

    it "raises on a non-{KB,String,Symbol,nil} knowledge_base argument" do
      expect { Curator.search("hi", knowledge_base: 42) }
        .to raise_error(ArgumentError, /knowledge_base/)
    end

    it "raises on an unknown strategy" do
      expect { Curator.search("hi", knowledge_base: kb, strategy: :foo) }
        .to raise_error(ArgumentError, /strategy/)
      expect(Curator::Search.count).to eq(0)
    end

    it "raises when strategy: :keyword is paired with a non-nil threshold" do
      kb_kw = create(:curator_knowledge_base, retrieval_strategy: "keyword")
      expect { Curator.search("hi", knowledge_base: kb_kw, strategy: :keyword, threshold: 0.5) }
        .to raise_error(ArgumentError, /threshold/)
    end
  end

  describe "KB resolution" do
    it "looks up by symbol slug" do
      kb_named = create(:curator_knowledge_base, slug: "support", retrieval_strategy: "vector")
      results  = Curator.search("hi", knowledge_base: :support)
      expect(results.knowledge_base).to eq(kb_named)
    end

    it "looks up by string slug" do
      kb_named = create(:curator_knowledge_base, slug: "marketing", retrieval_strategy: "vector")
      results  = Curator.search("hi", knowledge_base: "marketing")
      expect(results.knowledge_base).to eq(kb_named)
    end

    it "falls back to KnowledgeBase.default! when nil" do
      default_kb = create(:curator_knowledge_base, is_default: true, retrieval_strategy: "vector")
      results    = Curator.search("hi")
      expect(results.knowledge_base).to eq(default_kb)
    end
  end

  describe "vector retrieval (KB default)" do
    it "returns hits ordered by cosine descending with rank starting at 1" do
      near = make_chunk(content: "alpha beta gamma", sequence: 0)
      _far = make_chunk(content: "epsilon zeta",     sequence: 1)

      results = Curator.search("alpha beta gamma", knowledge_base: kb)

      expect(results).to be_a(Curator::SearchResults)
      expect(results.hits.first.rank).to     eq(1)
      expect(results.hits.first.chunk_id).to eq(near.id)
      expect(results.hits.first.score).to    be > 0.5
    end

    it "honors the limit override over kb.chunk_limit" do
      3.times { |i| make_chunk(content: "alpha word#{i}", sequence: i) }
      expect(Curator.search("alpha", knowledge_base: kb, limit: 2).size).to eq(2)
    end

    it "honors the threshold override (drops below-threshold hits)" do
      _near = make_chunk(content: "alpha beta gamma", sequence: 0)
      _far  = make_chunk(content: "epsilon zeta",     sequence: 1)

      results = Curator.search("alpha beta gamma", knowledge_base: kb, threshold: 0.99)
      expect(results.size).to be <= 1
    end

    it "returns empty results on a KB with no chunks (status :success)" do
      results = Curator.search("anything", knowledge_base: kb)
      expect(results).to be_empty

      row = Curator::Search.sole
      expect(row).to be_success
    end
  end

  describe "curator_searches row write" do
    it "snapshots config and marks success" do
      make_chunk(content: "alpha", sequence: 0)
      Curator.search("alpha beta", knowledge_base: kb, limit: 3, threshold: 0.1)

      row = Curator::Search.sole
      expect(row.knowledge_base).to       eq(kb)
      expect(row.query).to                eq("alpha beta")
      expect(row.embedding_model).to      eq(kb.embedding_model)
      expect(row.chat_model).to           eq(kb.chat_model)
      expect(row.retrieval_strategy).to   eq("vector")
      expect(row.chunk_limit).to          eq(3)
      expect(row.similarity_threshold).to eq(0.1)
      expect(row).to                      be_success
      expect(row.total_duration_ms).to    be >= 0
      expect(row.chat_id).to              be_nil
      expect(row.message_id).to           be_nil
    end

    it "skips the row write when config.log_queries is false" do
      Curator.config.log_queries = false
      results = Curator.search("alpha", knowledge_base: kb)
      expect(Curator::Search.count).to eq(0)
      expect(results.search_id).to be_nil
    ensure
      Curator.config.log_queries = true
    end

    it "marks the row :failed and re-raises on embedding error" do
      stub_embed_error(:server_error, model: kb.embedding_model)

      expect { Curator.search("alpha", knowledge_base: kb) }
        .to raise_error(Curator::EmbeddingError)

      row = Curator::Search.sole
      expect(row).to                   be_failed
      expect(row.error_message).to     match(/EmbeddingError/)
      expect(row.total_duration_ms).to be >= 0
    end

    it "marks the row :failed on non-EmbeddingError failures and re-raises" do
      # Force the retrieval step to raise something that isn't
      # Curator::EmbeddingError. Without the broad rescue the row
      # would sit at the column default status: success.
      allow(Curator::Retrieval::Vector).to receive(:new).and_raise(RuntimeError, "boom")
      make_chunk(content: "alpha", sequence: 0)

      expect { Curator.search("alpha", knowledge_base: kb) }
        .to raise_error(RuntimeError, "boom")

      row = Curator::Search.sole
      expect(row).to                   be_failed
      expect(row.error_message).to     match(/RuntimeError.*boom/)
      expect(row.total_duration_ms).to be >= 0
    end
  end

  describe "keyword retrieval (KB default)" do
    let(:kb) do
      create(:curator_knowledge_base,
             retrieval_strategy: "keyword",
             tsvector_config:    "english",
             chunk_limit:        5)
    end

    it "returns hits ordered by tsvector rank without invoking the embed API" do
      hi   = make_chunk(content: "alpha alpha gamma", sequence: 0)
      _lo  = make_chunk(content: "alpha sometimes",   sequence: 1)
      _far = make_chunk(content: "epsilon zeta",      sequence: 2)
      expect(RubyLLM).not_to receive(:embed)

      results = Curator.search("alpha", knowledge_base: kb)

      expect(results.hits.first.chunk_id).to eq(hi.id)
      expect(results.hits.map(&:rank)).to    eq((1..results.size).to_a)
    end

    it "leaves every hit's score nil" do
      make_chunk(content: "alpha beta", sequence: 0)
      results = Curator.search("alpha", knowledge_base: kb)
      expect(results.hits.map(&:score)).to all(be_nil)
    end

    it "snapshots strategy=keyword on the curator_searches row with similarity_threshold nil" do
      make_chunk(content: "alpha", sequence: 0)
      Curator.search("alpha", knowledge_base: kb)

      row = Curator::Search.sole
      expect(row.retrieval_strategy).to   eq("keyword")
      expect(row.similarity_threshold).to be_nil
      expect(row).to                      be_success
    end

    describe "tracing" do
      around do |ex|
        original = Curator.config.trace_level
        ex.run
      ensure
        Curator.config.trace_level = original
      end

      it "writes a keyword_search step row with non-empty payload at :full" do
        make_chunk(content: "alpha", sequence: 0)
        Curator.config.trace_level = :full

        Curator.search("alpha", knowledge_base: kb)

        steps = Curator::Search.sole.search_steps.order(:sequence)
        expect(steps.map(&:step_type)).to eq(%w[keyword_search])
        expect(steps.first.payload).to    include("candidate_count")
      end

      it "writes a keyword_search step row with empty payload at :summary" do
        make_chunk(content: "alpha", sequence: 0)
        Curator.config.trace_level = :summary

        Curator.search("alpha", knowledge_base: kb)

        row = Curator::Search.sole
        expect(row.search_steps.count).to eq(1)
        expect(row.search_steps.pluck(:payload)).to all(eq({}))
      end

      it "writes no step rows at :off" do
        make_chunk(content: "alpha", sequence: 0)
        Curator.config.trace_level = :off

        Curator.search("alpha", knowledge_base: kb)

        expect(Curator::Search.sole.search_steps.count).to eq(0)
      end
    end

    it "surfaces :pending / :failed chunks (no embeddings required)" do
      pending_chunk = create(:curator_chunk, document: document, sequence: 0,
                                             content: "alpha pending", status: :pending)
      failed_chunk  = create(:curator_chunk, document: document, sequence: 1,
                                             content: "alpha failed",  status: :failed)

      hit_ids = Curator.search("alpha", knowledge_base: kb).hits.map(&:chunk_id)

      expect(hit_ids).to include(pending_chunk.id, failed_chunk.id)
    end
  end

  describe "tracing" do
    around do |ex|
      original = Curator.config.trace_level
      ex.run
    ensure
      Curator.config.trace_level = original
    end

    it "writes embed_query + vector_search step rows with non-empty payloads at :full" do
      make_chunk(content: "alpha", sequence: 0)
      Curator.config.trace_level = :full

      Curator.search("alpha", knowledge_base: kb)

      row   = Curator::Search.sole
      steps = row.search_steps.order(:sequence)
      expect(steps.map(&:step_type)).to eq(%w[embed_query vector_search])
      expect(steps[0].payload).to       include("model", "input_tokens")
      expect(steps[1].payload).to       include("candidate_count")
    end

    it "writes step rows with empty payload at :summary" do
      make_chunk(content: "alpha", sequence: 0)
      Curator.config.trace_level = :summary

      Curator.search("alpha", knowledge_base: kb)

      row = Curator::Search.sole
      expect(row.search_steps.count).to eq(2)
      expect(row.search_steps.pluck(:payload)).to all(eq({}))
    end

    it "writes no step rows at :off" do
      make_chunk(content: "alpha", sequence: 0)
      Curator.config.trace_level = :off

      Curator.search("alpha", knowledge_base: kb)

      expect(Curator::Search.sole.search_steps.count).to eq(0)
    end
  end
end
