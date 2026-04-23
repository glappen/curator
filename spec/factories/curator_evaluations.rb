FactoryBot.define do
  factory :curator_evaluation, class: "Curator::Evaluation" do
    search { association(:curator_search) }
    rating { "positive" }
  end
end
