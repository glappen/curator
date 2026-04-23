FactoryBot.define do
  factory :curator_search_step, class: "Curator::SearchStep" do
    search { association(:curator_search) }
    sequence(:sequence) { |n| n }
    step_type   { "vector_search" }
    started_at  { Time.current }
    duration_ms { 12 }
    status      { "success" }
    payload     { {} }
  end
end
