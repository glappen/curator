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
  end
end
