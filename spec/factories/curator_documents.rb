FactoryBot.define do
  factory :curator_document, class: "Curator::Document" do
    knowledge_base { association(:curator_knowledge_base) }
    sequence(:title) { |n| "Document #{n}" }
    sequence(:content_hash) { |n| "hash-#{n}" }
    mime_type { "text/plain" }
    byte_size { 1_024 }
  end
end
