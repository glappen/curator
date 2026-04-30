require "turbo-rails"

module Curator
  class Engine < ::Rails::Engine
    isolate_namespace Curator

    # Default Rails inflector singularizes "bases" to "basis" (axes→axis,
    # bases→basis), which would generate route helpers like
    # `knowledge_basis_path`. Pin the irregular pair so URL helpers,
    # foreign keys, and partial paths all read correctly.
    initializer "curator.inflections", before: :load_config_initializers do
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.irregular("knowledge_base", "knowledge_bases")
      end
    end

    # The engine's two Stimulus controllers ship under app/javascript so
    # they read like every other Rails 7+ controller layout. Propshaft
    # only serves files in `config.assets.paths`, and importmap-rails
    # resolves pins through the same path set, so add the engine's
    # javascript root to both. Guarded for host apps without an asset
    # pipeline (`config.assets` is sprockets/propshaft territory).
    initializer "curator.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/javascript").to_s
      end
    end

    # Contribute engine-owned pins to the host's importmap. `before:
    # "importmap"` so our paths are registered before importmap-rails
    # draws the combined map at boot. Host pins take precedence on
    # collision (host's `config/importmap.rb` loads after the engine's),
    # so e.g. the host's `@hotwired/stimulus` version wins.
    #
    # No-op when importmap-rails is not loaded (jsbundling/esbuild host
    # apps): those will need to import "curator" from their own bundle.
    initializer "curator.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << root.join("config/importmap.rb")
        app.config.importmap.cache_sweepers << root.join("app/javascript")
      end
    end
  end
end
