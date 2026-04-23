# Test-only stub: routed in spec/dummy/config/routes.rb so request specs
# can exercise the Curator::Authentication concern through real Rack /
# routing, without RSpec's deprecated `controller(...)` anonymous-class
# pattern. Inherits from Curator::ApplicationController to pick up the
# admin auth before_action installed by the concern.
class CuratorTestAdminController < Curator::ApplicationController
  def index
    render plain: "ok"
  end
end
