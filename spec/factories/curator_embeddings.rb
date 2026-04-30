FactoryBot.define do
  factory :curator_embedding, class: "Curator::Embedding" do
    chunk { association(:curator_chunk) }
    # `Curator::Embedding.dimension` reads the live column schema (cached
    # per-process), so factories stay correct under any install-time
    # `--embedding-dim` value without re-deriving it here.
    embedding       { Array.new(Curator::Embedding.dimension) { 0.0 } }
    embedding_model { "text-embedding-3-small" }
  end
end
