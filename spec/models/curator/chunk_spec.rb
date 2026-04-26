require "rails_helper"

RSpec.describe Curator::Chunk, type: :model do
  describe "validations" do
    it "requires content and numeric offsets" do
      chunk = build(:curator_chunk, content: nil, char_start: nil, char_end: nil)
      expect(chunk).not_to be_valid
      expect(chunk.errors.attribute_names).to include(:content, :char_start, :char_end)
    end

    it "enforces sequence uniqueness within a document" do
      doc = create(:curator_document)
      create(:curator_chunk, document: doc, sequence: 0)

      dup = build(:curator_chunk, document: doc, sequence: 0)
      expect(dup).not_to be_valid
      expect(dup.errors[:sequence]).to be_present
    end

    it "allows the same sequence across different documents" do
      create(:curator_chunk, document: create(:curator_document), sequence: 0)
      expect(build(:curator_chunk, document: create(:curator_document), sequence: 0)).to be_valid
    end
  end

  describe "status enum" do
    it "defaults to pending" do
      expect(build(:curator_chunk).status).to eq("pending")
    end
  end

  describe "associations" do
    it "destroys its embedding when destroyed" do
      chunk = create(:curator_chunk)
      create(:curator_embedding, chunk: chunk)

      expect { chunk.destroy! }.to change(Curator::Embedding, :count).by(-1)
    end
  end

  describe "content_tsvector (refreshed via after_save using KB config)" do
    def fetch_tsvector(chunk)
      described_class.connection.select_value(
        "SELECT content_tsvector::text FROM curator_chunks WHERE id = #{chunk.id}"
      )
    end

    it "stems content under spanish for a spanish-config KB" do
      kb    = create(:curator_knowledge_base, tsvector_config: "spanish")
      doc   = create(:curator_document, knowledge_base: kb)
      chunk = create(:curator_chunk, document: doc, content: "corriendo")

      tsv = fetch_tsvector(chunk)
      expect(tsv).to include("corr")
      expect(tsv).not_to include("corriendo")
    end

    it "leaves the same word unstemmed under english config" do
      kb    = create(:curator_knowledge_base, tsvector_config: "english")
      doc   = create(:curator_document, knowledge_base: kb)
      chunk = create(:curator_chunk, document: doc, content: "corriendo")

      expect(fetch_tsvector(chunk)).to include("corriendo")
    end

    it "refreshes when content changes on update" do
      kb    = create(:curator_knowledge_base, tsvector_config: "english")
      doc   = create(:curator_document, knowledge_base: kb)
      chunk = create(:curator_chunk, document: doc, content: "running")

      chunk.update!(content: "swimming")

      expect(fetch_tsvector(chunk)).to include("swim")
    end

    it "does not refresh when only status changes (no content_tsvector recomputation cost)" do
      kb    = create(:curator_knowledge_base, tsvector_config: "english")
      doc   = create(:curator_document, knowledge_base: kb)
      chunk = create(:curator_chunk, document: doc, content: "running")
      original = fetch_tsvector(chunk)

      expect(chunk).not_to receive(:refresh_content_tsvector)
      chunk.update!(status: :embedded)

      expect(fetch_tsvector(chunk)).to eq(original)
    end
  end
end
