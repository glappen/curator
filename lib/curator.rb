require "ruby_llm"
require "neighbor"

require "curator/version"
require "curator/errors"
require "curator/configuration"

# Note: `curator/engine` is loaded by lib/curator-rails.rb *after* Rails is
# available, not here. Requiring it conditionally from this file loses a race:
# if curator.rb gets preloaded before Rails boots (e.g. from a test helper),
# the conditional skips and there's no re-trigger — Rails.application.initialize!
# then runs without Curator::Engine registered, and app/* paths never get
# added to the autoloader.

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
