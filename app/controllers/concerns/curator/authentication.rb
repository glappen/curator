module Curator
  # Shared auth dispatch for Curator's admin and API controllers. Each
  # including controller names its hook via `curator_authenticate :admin`
  # or `curator_authenticate :api`, which installs the before_action.
  #
  # At request time we look up `Curator.config.authenticate_#{hook}_with`:
  # a Proc stored from the host's initializer. If configured, it runs via
  # `instance_exec` inside the controller — `current_user`, `redirect_to`,
  # `session`, `main_app.*` helpers are all in scope.
  #
  # If nothing is configured: silent in `Rails.env.test?` (so specs don't
  # need to configure auth to exercise the engine); raise
  # `Curator::AuthNotConfigured` in dev/prod pointing at the initializer.
  #
  # Exceptions raised inside the host's block propagate. That's intentional:
  # Rails before_actions don't catch, and swallowing would hide bugs.
  module Authentication
    extend ActiveSupport::Concern

    class_methods do
      def curator_authenticate(hook_name)
        before_action { run_curator_authentication(hook_name) }
      end
    end

    private

    def run_curator_authentication(hook_name)
      block = Curator.config.public_send(:"authenticate_#{hook_name}_with")
      return instance_exec(&block) if block

      return if ::Rails.env.test?

      raise Curator::AuthNotConfigured,
            "Curator requires `authenticate_#{hook_name}_with` to be configured " \
            "in config/initializers/curator.rb before first use."
    end
  end
end
