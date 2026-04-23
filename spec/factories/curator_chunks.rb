FactoryBot.define do
  factory :curator_chunk, class: "Curator::Chunk" do
    document { association(:curator_document) }
    sequence(:sequence) { |n| n }
    content     { "Chunk content body." }
    token_count { 5 }
    char_start  { 0 }
    char_end    { 19 }
  end
end
