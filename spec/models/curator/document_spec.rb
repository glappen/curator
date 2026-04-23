require "rails_helper"

RSpec.describe Curator::Document, type: :model do
  describe "validations" do
    it "requires title, content_hash, and mime_type" do
      doc = build(:curator_document, title: nil, content_hash: nil, mime_type: nil)
      expect(doc).not_to be_valid
      expect(doc.errors.attribute_names).to include(:title, :content_hash, :mime_type)
    end

    it "requires a knowledge base" do
      expect(build(:curator_document, knowledge_base: nil)).not_to be_valid
    end
  end

  describe "status enum" do
    it "defaults to pending" do
      expect(build(:curator_document).status).to eq("pending")
    end

    it "accepts every declared state" do
      Curator::Document::STATUSES.each do |state|
        expect(build(:curator_document, status: state)).to be_valid
      end
    end
  end

  describe "associations" do
    it "destroys dependent chunks" do
      doc = create(:curator_document)
      create(:curator_chunk, document: doc)

      expect { doc.destroy! }.to change(Curator::Chunk, :count).by(-1)
    end

    it "attaches a file via Active Storage" do
      doc = create(:curator_document)
      doc.file.attach(io: StringIO.new("hello"), filename: "hello.txt", content_type: "text/plain")

      expect(doc.file).to be_attached
    end
  end
end
