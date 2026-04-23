require "rails_helper"

RSpec.describe Curator::Embedding, type: :model do
  describe "validations" do
    it "requires a chunk and embedding_model" do
      e = build(:curator_embedding, chunk: nil, embedding_model: nil)
      expect(e).not_to be_valid
      expect(e.errors.attribute_names).to include(:chunk, :embedding_model)
    end
  end

  describe "nearest_neighbors" do
    it "returns rows ordered by cosine distance" do
      chunk1 = create(:curator_chunk)
      chunk2 = create(:curator_chunk)

      near = create(:curator_embedding, chunk: chunk1, embedding: [ 1.0, 0.0 ] + Array.new(1534, 0.0))
      far  = create(:curator_embedding, chunk: chunk2, embedding: [ -1.0, 0.0 ] + Array.new(1534, 0.0))

      results = Curator::Embedding.nearest_neighbors(:embedding, [ 1.0, 0.0 ] + Array.new(1534, 0.0), distance: "cosine").to_a
      expect(results.first).to eq(near)
      expect(results.last).to eq(far)
    end
  end
end
