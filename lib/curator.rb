require "curator/version"
require "curator/errors"
require "curator/configuration"
require "curator/token_counter"
require "curator/extractors/extraction_result"
require "curator/extractors/basic"
require "curator/extractors/kreuzberg"
require "curator/chunkers/paragraph"

# Note: `curator/engine` and the `ruby_llm` / `neighbor` requires live in
# lib/curator-rails.rb, which Bundler.require loads *after* Rails boots.
# Requiring them here loses a race: if curator.rb gets preloaded before
# Rails (e.g. from a test helper), ruby_llm's railtie guard
# (`if defined?(Rails::Railtie)`) falls through — the Railtie class is never
# defined, so the `ActiveSupport.on_load(:active_record)` callback that
# installs `acts_as_chat` never registers.

module Curator
  class << self
    attr_writer :config

    def configure
      yield config
      config
    end

    def config
      @config ||= Configuration.new
    end

    # Test-only: reset the memoized configuration.
    def reset_config!
      @config = nil
    end
  end
end
