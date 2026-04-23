# Test-only stub for the API auth concern. See curator_test_admin_controller.rb.
class CuratorTestApiController < Curator::Api::BaseController
  def index
    render json: { ok: true }
  end
end
