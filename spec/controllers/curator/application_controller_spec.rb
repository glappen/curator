require "rails_helper"

RSpec.describe Curator::ApplicationController, type: :controller do
  controller(described_class) do
    def index
      render plain: "ok"
    end
  end

  before do
    routes.draw { get "index" => "curator/application#index" }
    Curator.reset_config!
  end

  after { Curator.reset_config! }

  context "in test environment with no auth configured" do
    it "passes through silently" do
      get :index
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("ok")
    end
  end

  context "outside the test environment with no auth configured" do
    before do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    end

    it "raises Curator::AuthNotConfigured" do
      expect { get :index }.to raise_error(Curator::AuthNotConfigured)
    end
  end

  context "when an admin auth block is configured" do
    it "runs the block via instance_exec — controller context is available" do
      seen = {}
      Curator.configure do |c|
        c.authenticate_admin_with do
          seen[:self_class] = self.class
          seen[:has_request] = respond_to?(:request)
          seen[:params_keys] = params.keys
        end
      end

      get :index
      expect(response).to have_http_status(:ok)
      expect(seen[:self_class].ancestors).to include(Curator::ApplicationController)
      expect(seen[:has_request]).to be true
      expect(seen[:params_keys]).to include("controller", "action")
    end

    it "lets the block halt the request with head" do
      Curator.configure do |c|
        c.authenticate_admin_with { head :unauthorized }
      end

      get :index
      expect(response).to have_http_status(:unauthorized)
    end

    it "propagates unexpected exceptions from the block" do
      Curator.configure do |c|
        c.authenticate_admin_with { raise "boom" }
      end

      expect { get :index }.to raise_error(RuntimeError, "boom")
    end

    it "does not call the api hook" do
      admin_calls = 0
      api_calls   = 0
      Curator.configure do |c|
        c.authenticate_admin_with { admin_calls += 1 }
        c.authenticate_api_with   { api_calls   += 1 }
      end

      get :index
      expect(admin_calls).to eq(1)
      expect(api_calls).to eq(0)
    end
  end
end
