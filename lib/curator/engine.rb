require "turbo-rails"

module Curator
  class Engine < ::Rails::Engine
    isolate_namespace Curator
  end
end
