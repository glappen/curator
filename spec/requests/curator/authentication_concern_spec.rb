require "rails_helper"

# Exercises Curator::Authentication through real routing against test-only
# stub controllers in spec/dummy. Replaces the deprecated
# `controller(described_class)` anonymous-controller pattern.
RSpec.describe "Curator::Authentication concern", type: :request do
  before { Curator.reset_config! }
  after  { Curator.reset_config! }

  shared_examples "an auth-gated endpoint" do |path:, hook_name:, success_body:|
    context "in test environment with no auth configured" do
      it "passes through silently" do
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(success_body)
      end
    end

    context "outside the test environment with no auth configured" do
      before do
        allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      end

      it "raises Curator::AuthNotConfigured" do
        expect { get path }.to raise_error(Curator::AuthNotConfigured, /authenticate_#{hook_name}_with/)
      end
    end

    context "when the matching auth block is configured" do
      it "runs the block via instance_exec inside the controller" do
        captured_self = nil
        Curator.configure do |c|
          c.public_send(:"authenticate_#{hook_name}_with") { captured_self = self }
        end

        get path
        expect(response).to have_http_status(:ok)
        expect(captured_self).to be_a(ActionController::Metal)
      end

      it "lets the block halt with head :unauthorized" do
        Curator.configure do |c|
          c.public_send(:"authenticate_#{hook_name}_with") { head :unauthorized }
        end

        get path
        expect(response).to have_http_status(:unauthorized)
      end

      it "propagates unexpected exceptions from the block" do
        Curator.configure do |c|
          c.public_send(:"authenticate_#{hook_name}_with") { raise Curator::LLMError, "boom" }
        end

        expect { get path }.to raise_error(Curator::LLMError, "boom")
      end
    end
  end

  describe "admin hook" do
    include_examples "an auth-gated endpoint",
                     path: "/__curator_test_admin",
                     hook_name: "admin",
                     success_body: "ok"

    it "does not call the api hook" do
      admin_calls = 0
      api_calls   = 0
      Curator.configure do |c|
        c.authenticate_admin_with { admin_calls += 1 }
        c.authenticate_api_with   { api_calls   += 1 }
      end

      get "/__curator_test_admin"
      expect(admin_calls).to eq(1)
      expect(api_calls).to eq(0)
    end
  end

  describe "api hook" do
    include_examples "an auth-gated endpoint",
                     path: "/__curator_test_api",
                     hook_name: "api",
                     success_body: "ok"

    it "does not call the admin hook" do
      admin_calls = 0
      api_calls   = 0
      Curator.configure do |c|
        c.authenticate_admin_with { admin_calls += 1 }
        c.authenticate_api_with   { api_calls   += 1 }
      end

      get "/__curator_test_api"
      expect(api_calls).to eq(1)
      expect(admin_calls).to eq(0)
    end
  end
end
