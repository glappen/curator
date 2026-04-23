FactoryBot.define do
  factory :curator_embedding, class: "Curator::Embedding" do
    # Read the embedding column dimension from the live schema so this
    # factory keeps working when a host installs with --embedding-dim != 1536.
    transient do
      dimension do
        sql = Curator::Embedding.columns_hash["embedding"].sql_type
        sql[/\Avector\((\d+)\)\z/, 1].to_i
      end
    end

    chunk { association(:curator_chunk) }
    embedding       { Array.new(dimension) { 0.0 } }
    embedding_model { "text-embedding-3-small" }
  end
end
