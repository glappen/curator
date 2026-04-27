FactoryBot.define do
  factory :curator_evaluation, class: "Curator::Evaluation" do
    retrieval { association(:curator_retrieval) }
    rating { "positive" }
  end
end
