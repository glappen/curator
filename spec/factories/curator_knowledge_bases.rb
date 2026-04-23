FactoryBot.define do
  factory :curator_knowledge_base, class: "Curator::KnowledgeBase" do
    sequence(:name) { |n| "Knowledge Base #{n}" }
    sequence(:slug) { |n| "kb-#{n}" }
    embedding_model { "text-embedding-3-small" }
    chat_model      { "gpt-5-mini" }
  end
end
