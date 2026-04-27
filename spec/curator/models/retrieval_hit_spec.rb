require "rails_helper"

RSpec.describe Curator::RetrievalHit do
  let(:kb)        { create(:curator_knowledge_base) }
  let(:retrieval) { create(:curator_retrieval, knowledge_base: kb) }
  let(:document)  { create(:curator_document, knowledge_base: kb) }
  let(:chunk) do
    create(:curator_chunk,
           document: document, sequence: 0,
           content: "body text", status: :embedded)
  end

  def build_hit(**overrides)
    {
      retrieval:     retrieval,
      chunk:         chunk,
      document:      document,
      rank:          1,
      score:         0.85,
      document_name: document.title,
      page_number:   2,
      text:          "body text",
      source_url:    nil
    }.merge(overrides)
  end

  describe "associations" do
    it "belongs to retrieval (required)" do
      hit = described_class.new(build_hit(retrieval: nil))
      expect(hit).not_to be_valid
      expect(hit.errors[:retrieval]).to be_present
    end

    it "belongs to chunk and document optionally" do
      hit = described_class.new(build_hit(chunk: nil, document: nil))
      expect(hit).to be_valid
    end
  end

  describe "validations" do
    it "requires rank, document_name, text" do
      hit = described_class.new(build_hit(rank: nil, document_name: nil, text: nil))
      expect(hit).not_to be_valid
      expect(hit.errors.attribute_names).to include(:rank, :document_name, :text)
    end

    it "rejects rank < 1" do
      hit = described_class.new(build_hit(rank: 0))
      expect(hit).not_to be_valid
    end
  end

  describe "FK behavior" do
    it "(retrieval_id, rank) is unique" do
      described_class.create!(build_hit(rank: 1))
      expect { described_class.create!(build_hit(rank: 1)) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "nullifies chunk_id when the chunk is destroyed" do
      hit = described_class.create!(build_hit)
      chunk.destroy
      expect(hit.reload.chunk_id).to be_nil
    end

    it "nullifies document_id when the document is destroyed" do
      hit = described_class.create!(build_hit)
      document.destroy
      expect(hit.reload.document_id).to be_nil
    end

    it "is destroyed when the parent retrieval is destroyed" do
      described_class.create!(build_hit)
      expect { retrieval.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
