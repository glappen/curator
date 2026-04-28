require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "dummy/config/environment"

abort("Rails is running in production mode!") if ::Rails.env.production?

require "rspec/rails"
require "webmock/rspec"
require "factory_bot_rails"

# RubyLLM logs `WARN -- RubyLLM: API call failed, destroying message`
# whenever a spec deliberately stubs a chat-completion error — the
# library is right to log it in production but it's noise in tests.
RubyLLM.config.log_level = Logger::ERROR

FactoryBot.definition_file_paths = [ Curator::Engine.root.join("spec/factories") ]
FactoryBot.find_definitions

Dir[Curator::Engine.root.join("spec/support/**/*.rb")].each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  warn e.to_s.strip
  exit 1
end

RSpec.configure do |config|
  config.fixture_paths = [ Curator::Engine.root.join("spec/fixtures") ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
end
