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
end
