# Turbo broadcast suppression for the spec suite.
#
# Phases 3-6 of M5 mix `Turbo::Broadcastable` into Curator models that
# broadcast on `after_*_commit` (Curator::Document, ::KnowledgeBase,
# ::Embedding). Most M1-M4 specs exercise those models without caring
# about broadcasts; running them blind would flood the test cable
# adapter and slow the suite.
#
# `suppressing_turbo_broadcasts` is defined per class (the flag is
# `thread_mattr_accessor`-backed, scoped per model). Global silencing
# means iterating every broadcasting Curator model and nesting their
# blocks.
#
# Default: every example runs inside the nested suppression. Specs that
# want to assert a broadcast fired tag the example with `:broadcasts`.
#
# Eager-load timing: with Zeitwerk, `ActiveRecord::Base.descendants`
# only contains classes that have been touched. Computing the
# broadcasting set inside the around-each hook would miss any model
# that hadn't autoloaded yet — the very first spec to exercise a
# broadcasting model would slip past suppression. We eager-load the
# Curator engine once before the suite and cache the set.
module Curator
  module TurboBroadcastHelpers
    class << self
      def broadcasting_models
        @broadcasting_models ||= compute_broadcasting_models
      end

      def reset_cache!
        @broadcasting_models = nil
      end

      def with_suppression(&block)
        broadcasting_models.reduce(block) do |inner, model|
          -> { model.suppressing_turbo_broadcasts(&inner) }
        end.call
      end

      private

      def compute_broadcasting_models
        ActiveRecord::Base.descendants.select do |klass|
          klass.name&.start_with?("Curator::") &&
            klass.include?(Turbo::Broadcastable)
        end
      end
    end

    def suppress_turbo_broadcasts(&block)
      Curator::TurboBroadcastHelpers.with_suppression(&block)
    end
  end
end

RSpec.configure do |config|
  config.include Curator::TurboBroadcastHelpers

  config.before(:suite) do
    Curator::Engine.eager_load!
    Curator::TurboBroadcastHelpers.reset_cache!
  end

  config.around(:each) do |example|
    if example.metadata[:broadcasts]
      example.run
    else
      Curator::TurboBroadcastHelpers.with_suppression { example.run }
    end
  end
end
