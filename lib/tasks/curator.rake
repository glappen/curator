namespace :curator do
  desc "Create the default Curator knowledge base if one doesn't exist"
  task seed_defaults: :environment do
    kb = Curator::KnowledgeBase.seed_default!
    puts "Curator default KB ready: #{kb.slug} (id=#{kb.id})"
  end
end

# Planned (see features/implementation.md):
#   curator:ingest PATH=... KB=...
#   curator:reembed KB=...
#   curator:reingest DOCUMENT=...
#   curator:evaluations:export KB=... FORMAT=csv|json
#   curator:stats
#   curator:vacuum KB=...
#   curator:build_assets
