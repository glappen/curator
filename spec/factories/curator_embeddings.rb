FactoryBot.define do
  factory :curator_embedding, class: "Curator::Embedding" do
    chunk { association(:curator_chunk) }
    embedding       { Array.new(1536) { 0.0 } }
    embedding_model { "text-embedding-3-small" }
  end
end
