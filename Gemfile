source "https://rubygems.org"

# Specify this gem's dependencies in curator-rails.gemspec.
gemspec

# spec/dummy host app deps
gem "puma"
gem "propshaft"

group :development, :test do
  gem "rspec-rails", "~> 7.0"
  gem "factory_bot_rails"
  gem "webmock"
  gem "rubocop-rails-omakase", require: false
  gem "debug", ">= 1.0.0"
  # Kreuzberg is a soft dependency: host apps opt in by adding
  # `gem "kreuzberg"` themselves. It lives here so the Kreuzberg adapter
  # and its contract spec can run in this engine's test suite.
  gem "kreuzberg"
end
