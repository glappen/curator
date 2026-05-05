module Curator
  class ApplicationController < ActionController::Base
    include Curator::Authentication

    # `ActionController::Base.include_all_helpers` defaults to false in
    # this Rails version, so namespaced helpers (Curator::AdminHelper
    # etc.) are not auto-mixed-in. Opt back in at the engine boundary so
    # any helper added under app/helpers/curator/ is available to the
    # admin views without per-controller `helper Foo` plumbing.
    helper :all

    curator_authenticate_admin

    helper_method :current_admin_evaluator_id

    # Resolves the configured admin-evaluator block against this
    # controller. Returns nil when the host leaves the hook at its
    # default `->(_controller) { nil }`.
    def current_admin_evaluator_id
      Curator.config.current_admin_evaluator.call(self)
    end
  end
end
