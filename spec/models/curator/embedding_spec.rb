require "rails_helper"

RSpec.describe Curator::Embedding, type: :model do
  describe "validations" do
    it "requires embedding_model (own validation, not framework)" do
      e = build(:curator_embedding, embedding_model: nil)
      expect(e).not_to be_valid
      expect(e.errors.attribute_names).to include(:embedding_model)
    end
  end

  describe "nearest_neighbors" do
    let(:dimension) do
      Curator::Embedding.columns_hash["embedding"].sql_type[/\Avector\((\d+)\)\z/, 1].to_i
    end

    def vector(*leading)
      leading + Array.new(dimension - leading.size, 0.0)
    end

    it "returns rows ordered by cosine distance" do
      chunk1 = create(:curator_chunk)
      chunk2 = create(:curator_chunk)

      near = create(:curator_embedding, chunk: chunk1, embedding: vector(1.0, 0.0))
      far  = create(:curator_embedding, chunk: chunk2, embedding: vector(-1.0, 0.0))

      results = Curator::Embedding.nearest_neighbors(:embedding, vector(1.0, 0.0), distance: "cosine").to_a
      expect(results.first).to eq(near)
      expect(results.last).to eq(far)
    end
  end
end
