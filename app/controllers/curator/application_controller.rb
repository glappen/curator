module Curator
  class ApplicationController < ActionController::Base
    include Curator::Authentication

    # `ActionController::Base.include_all_helpers` defaults to false in
    # this Rails version, so namespaced helpers (Curator::AdminHelper
    # etc.) are not auto-mixed-in. Opt back in at the engine boundary so
    # any helper added under app/helpers/curator/ is available to the
    # admin views without per-controller `helper Foo` plumbing.
    helper :all

    curator_authenticate :admin
  end
end
