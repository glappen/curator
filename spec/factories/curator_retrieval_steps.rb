FactoryBot.define do
  factory :curator_retrieval_step, class: "Curator::RetrievalStep" do
    retrieval { association(:curator_retrieval) }
    sequence(:sequence) { |n| n }
    step_type   { "vector_search" }
    started_at  { Time.current }
    duration_ms { 12 }
    status      { "success" }
    payload     { {} }
  end
end
