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

      search = create(:curator_search, knowledge_base: kb)
      create(:curator_search_step, search: search)
      create(:curator_evaluation, search: search)

      kb.destroy!

      expect(Curator::Document.count).to    eq(0)
      expect(Curator::Chunk.count).to       eq(0)
      expect(Curator::Embedding.count).to   eq(0)
      expect(Curator::Search.count).to      eq(0)
      expect(Curator::SearchStep.count).to  eq(0)
      expect(Curator::Evaluation.count).to  eq(0)
    end
  end
end
