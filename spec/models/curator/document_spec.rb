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

  describe "#chunk_status_counts" do
    let(:kb)  { create(:curator_knowledge_base, embedding_model: "model-current") }
    let(:doc) { create(:curator_document, knowledge_base: kb) }

    it "returns total + embedded counts for the KB's current model" do
      embedded_chunk = create(:curator_chunk, document: doc, sequence: 0)
      _missing_chunk = create(:curator_chunk, document: doc, sequence: 1)
      create(:curator_embedding, chunk: embedded_chunk, embedding_model: "model-current")

      expect(doc.chunk_status_counts(embedding_model: "model-current"))
        .to eq(total: 2, embedded: 1)
    end

    it "excludes embeddings from a stale model from the embedded count" do
      chunk = create(:curator_chunk, document: doc, sequence: 0)
      create(:curator_embedding, chunk: chunk, embedding_model: "model-old")

      expect(doc.chunk_status_counts(embedding_model: "model-current"))
        .to eq(total: 1, embedded: 0)
    end

    it "returns zeros for a chunkless document" do
      expect(doc.chunk_status_counts(embedding_model: "model-current"))
        .to eq(total: 0, embedded: 0)
    end

    # Locks in the COUNT(*) FILTER collapse — the naive form was two
    # separate COUNTs and that pair fired on every Embedding broadcast.
    it "issues exactly one query" do
      create_list(:curator_chunk, 3, document: doc).each_with_index do |c, i|
        create(:curator_embedding, chunk: c, embedding_model: "model-current") if i < 2
      end

      queries = []
      callback = ->(_, _, _, _, payload) { queries << payload[:sql] if payload[:sql].is_a?(String) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        doc.chunk_status_counts(embedding_model: "model-current")
      end
      counting = queries.grep(/curator_chunks/i).grep(/count/i)
      expect(counting.size).to eq(1),
        "expected one COUNT query for chunk_status_counts, got #{counting.size}:\n#{counting.join("\n")}"
    end
  end
end
