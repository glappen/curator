FactoryBot.define do
  factory :curator_retrieval, class: "Curator::Retrieval" do
    knowledge_base { association(:curator_knowledge_base) }
    query { "What is our refund policy?" }
    status { "success" }
  end
end
