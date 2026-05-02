# Dev-only overrides for the dummy host app.
#
# `bin/reset-dummy` regenerates `curator.rb` (the canonical, host-app-style
# initializer) but leaves *this* file alone. Loaded after `curator.rb`
# (alphabetical), so the values here win — but only in development. Test
# env is unaffected: the auth concern short-circuits on `Rails.env.test?`
# and most ingestion specs override the extractor inline.
#
# Auth bypass: lets contributors hit `/curator/*` in `bin/rails s` without
# wiring a fake `current_user`. Production hosts MUST configure real auth
# blocks in `curator.rb` — Curator raises `AuthNotConfigured` otherwise.
#
# Extractor: the engine default is `:kreuzberg`, which needs the
# `kreuzberg` gem (not in the dummy Gemfile). Switching to `:basic` keeps
# `.md` / `.txt` / `.csv` / `.html` ingestion working out of the box for
# manual smoke testing.
return unless Rails.env.development?

Curator.configure do |config|
  config.authenticate_admin_with { true }
  config.extractor = :basic
end
