FactoryBot.define do
  factory :curator_search, class: "Curator::Search" do
    knowledge_base { association(:curator_knowledge_base) }
    query { "What is our refund policy?" }
    status { "success" }
  end
end
