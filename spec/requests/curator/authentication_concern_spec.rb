require "rails_helper"

# Exercises Curator::Authentication through real routing against a
# test-only stub controller in spec/dummy. Replaces the deprecated
# `controller(described_class)` anonymous-controller pattern.
RSpec.describe "Curator::Authentication concern", type: :request do
  let(:path) { "/__curator_test_admin" }

  before { Curator.reset_config! }
  after  { Curator.reset_config! }

  context "in test environment with no auth configured" do
    it "passes through silently" do
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ok")
    end
  end

  context "outside the test environment with no auth configured" do
    before do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    end

    it "raises Curator::AuthNotConfigured" do
      expect { get path }.to raise_error(Curator::AuthNotConfigured, /authenticate_admin_with/)
    end
  end

  context "when authenticate_admin_with is configured" do
    it "runs the block via instance_exec inside the controller" do
      captured_self = nil
      Curator.configure { |c| c.authenticate_admin_with { captured_self = self } }

      get path
      expect(response).to have_http_status(:ok)
      expect(captured_self).to be_a(ActionController::Metal)
    end

    it "lets the block halt with head :unauthorized" do
      Curator.configure { |c| c.authenticate_admin_with { head :unauthorized } }

      get path
      expect(response).to have_http_status(:unauthorized)
    end

    it "propagates unexpected exceptions from the block" do
      Curator.configure { |c| c.authenticate_admin_with { raise Curator::LLMError, "boom" } }

      expect { get path }.to raise_error(Curator::LLMError, "boom")
    end
  end
end
