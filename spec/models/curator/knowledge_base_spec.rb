require "rails_helper"

RSpec.describe Curator::KnowledgeBase, type: :model do
  describe "validations" do
    it "requires a name" do
      kb = build(:curator_knowledge_base, name: nil)
      expect(kb).not_to be_valid
      expect(kb.errors[:name]).to be_present
    end

    it "requires a slug matching the allowed format" do
      expect(build(:curator_knowledge_base, slug: "Has Spaces")).not_to be_valid
      expect(build(:curator_knowledge_base, slug: "UPPER")).not_to be_valid
      expect(build(:curator_knowledge_base, slug: "ok_slug-1")).to be_valid
    end

    it "enforces slug uniqueness at the model level" do
      create(:curator_knowledge_base, slug: "support")
      dup = build(:curator_knowledge_base, slug: "support")
      expect { dup.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "rejects non-positive chunk_size" do
      expect(build(:curator_knowledge_base, chunk_size: 0)).not_to be_valid
      expect(build(:curator_knowledge_base, chunk_size: -1)).not_to be_valid
    end

    it "rejects chunk_overlap values that are not smaller than chunk_size" do
      kb = build(:curator_knowledge_base, chunk_size: 100, chunk_overlap: 100)
      expect(kb).not_to be_valid
      expect(kb.errors[:chunk_overlap]).to include("must be less than chunk_size")
    end

    it "rejects unknown retrieval_strategy values" do
      expect(build(:curator_knowledge_base, retrieval_strategy: "semantic")).not_to be_valid
    end

    it "rejects non-positive chunk_limit" do
      expect(build(:curator_knowledge_base, chunk_limit: 0)).not_to be_valid
      expect(build(:curator_knowledge_base, chunk_limit: -1)).not_to be_valid
    end

    it "rejects unknown tsvector_config values" do
      expect(build(:curator_knowledge_base, tsvector_config: "klingon")).not_to be_valid
      expect(build(:curator_knowledge_base, tsvector_config: "spanish")).to be_valid
    end
  end

  describe "column defaults" do
    it "defaults chunk_limit to 5 when unspecified" do
      kb = described_class.create!(
        name:            "kb-default-cl",
        slug:            "kb-default-cl",
        embedding_model: "text-embedding-3-small",
        chat_model:      "gpt-5-mini"
      )
      expect(kb.chunk_limit).to eq(5)
    end

    # Real OpenAI text-embedding-3-small cosines for relevant query/
    # chunk pairs sit in 0.2–0.5; an aggressive default like 0.7
    # silently filters every result on a fresh install.
    it "defaults similarity_threshold to 0.2 when unspecified" do
      kb = described_class.create!(
        name:            "kb-default-st",
        slug:            "kb-default-st",
        embedding_model: "text-embedding-3-small",
        chat_model:      "gpt-5-mini"
      )
      expect(kb.similarity_threshold).to eq(0.2)
    end
  end

  describe "single-default enforcement" do
    it "flips the prior default off when a second KB becomes default" do
      kb1 = create(:curator_knowledge_base, slug: "a")
      kb2 = create(:curator_knowledge_base, slug: "b")

      kb1.update!(is_default: true)
      kb2.update!(is_default: true)

      expect(kb1.reload.is_default).to be(false)
      expect(kb2.reload.is_default).to be(true)
    end

    it "does not touch the other KB on an unrelated save" do
      default = create(:curator_knowledge_base, slug: "default", is_default: true)
      other   = create(:curator_knowledge_base, slug: "other")

      other.update!(name: "Renamed")

      expect(default.reload.is_default).to be(true)
    end
  end

  describe ".seed_default!" do
    it "creates a Default KB when none has is_default: true" do
      expect { described_class.seed_default! }.to change(described_class, :count).by(1)

      kb = described_class.find_by(is_default: true)
      expect(kb.slug).to eq("default")
      expect(kb.name).to eq("Default")
      expect(kb.embedding_model).to eq("text-embedding-3-small")
      expect(kb.chat_model).to eq("gpt-5-mini")
    end

    it "is idempotent — returns the existing default without creating another" do
      first  = described_class.seed_default!
      second = described_class.seed_default!

      expect(second).to eq(first)
      expect(described_class.where(is_default: true).count).to eq(1)
    end

    it "returns the existing default KB even if its slug is not 'default'" do
      existing = create(:curator_knowledge_base, slug: "support", is_default: true)

      expect { described_class.seed_default! }.not_to change(described_class, :count)
      expect(described_class.seed_default!).to eq(existing)
    end

    it "returns the existing default when a concurrent create raced first" do
      existing = create(:curator_knowledge_base, slug: "support", is_default: true)

      allow(described_class).to receive(:find_by).and_call_original
      allow(described_class).to receive(:find_by).with({ is_default: true }).and_return(nil, existing)
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      expect(described_class.seed_default!).to eq(existing)
    end
  end

  describe "associations" do
    it "cascades destroys to documents" do
      kb = create(:curator_knowledge_base)
      doc = create(:curator_document, knowledge_base: kb)

      expect { kb.destroy! }.to change(Curator::Document, :count).by(-1)
      expect(Curator::Document.exists?(doc.id)).to be(false)
    end

    it "cascades through the full graph with zero orphans" do
      kb       = create(:curator_knowledge_base)
      document = create(:curator_document, knowledge_base: kb)
      chunk    = create(:curator_chunk, document: document)
      create(:curator_embedding, chunk: chunk)

      retrieval = create(:curator_retrieval, knowledge_base: kb)
      create(:curator_retrieval_step, retrieval: retrieval)
      create(:curator_evaluation, retrieval: retrieval)

      kb.destroy!

      expect(Curator::Document.count).to       eq(0)
      expect(Curator::Chunk.count).to          eq(0)
      expect(Curator::Embedding.count).to      eq(0)
      expect(Curator::Retrieval.count).to      eq(0)
      expect(Curator::RetrievalStep.count).to  eq(0)
      expect(Curator::Evaluation.count).to     eq(0)
    end
  end

  describe "#to_param" do
    it "returns the slug so URL helpers honor `param: :slug` in routes" do
      kb = create(:curator_knowledge_base, slug: "support")
      expect(kb.to_param).to eq("support")
    end
  end

  describe "Phase 3 broadcasts to curator_knowledge_bases_index", :broadcasts do
    # turbo-rails broadcasts to the literal stream name on ActionCable —
    # the signed_stream_name is only used for the client's subscription
    # identifier, not for the pubsub topic.
    let(:stream) { "curator_knowledge_bases_index" }

    it "broadcasts a prepend on KB create" do
      expect {
        create(:curator_knowledge_base, slug: "broadcast-create")
      }.to have_broadcasted_to(stream).from_channel(Turbo::StreamsChannel).exactly(:once)
    end

    it "broadcasts a replace on KB update" do
      kb = create(:curator_knowledge_base, slug: "broadcast-update")

      expect {
        kb.update!(name: "Renamed")
      }.to have_broadcasted_to(stream).from_channel(Turbo::StreamsChannel).exactly(:once)
    end

    it "broadcasts a remove on KB destroy" do
      kb = create(:curator_knowledge_base, slug: "broadcast-destroy")

      expect {
        kb.destroy!
      }.to have_broadcasted_to(stream).from_channel(Turbo::StreamsChannel).exactly(:once)
    end

    it "broadcasts a card refresh when a document is created on a KB" do
      kb = create(:curator_knowledge_base, slug: "doc-broadcasts")

      expect {
        create(:curator_document, knowledge_base: kb)
      }.to have_broadcasted_to(stream).from_channel(Turbo::StreamsChannel).exactly(:once)
    end

    # Cascade guard: when a KB is destroyed, its documents are destroyed
    # via dependent: :destroy in the same transaction. Each doc's
    # after_destroy_commit would otherwise try to render the card partial
    # against a destroyed KB. The guard skips those, leaving only the KB's
    # own remove broadcast.
    it "broadcasts exactly once per destroyed KB even with documents" do
      kb = create(:curator_knowledge_base, slug: "cascade-broadcasts")
      create_list(:curator_document, 2, knowledge_base: kb)

      expect {
        kb.destroy!
      }.to have_broadcasted_to(stream).from_channel(Turbo::StreamsChannel).exactly(:once)
    end
  end
end
