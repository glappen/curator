require "ruby_llm"
require "neighbor"

require "curator/version"
require "curator/errors"
require "curator/configuration"

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

require "curator/engine" if defined?(::Rails::Engine)
