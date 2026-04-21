require "rails_helper"

RSpec.describe Curator::Api::BaseController, type: :controller do
  controller(described_class) do
    def index
      render json: { ok: true }
    end
  end

  before do
    routes.draw { get "index" => "curator/api/base#index" }
    Curator.reset_config!
  end

  after { Curator.reset_config! }

  context "in test environment with no auth configured" do
    it "passes through silently" do
      get :index
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("ok" => true)
    end
  end

  context "outside the test environment with no auth configured" do
    before do
      allow(::Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    end

    it "raises Curator::AuthNotConfigured" do
      expect { get :index }.to raise_error(Curator::AuthNotConfigured, /authenticate_api_with/)
    end
  end

  context "when an api auth block is configured" do
    it "runs the block via instance_exec in the controller" do
      captured_self = nil
      Curator.configure do |c|
        c.authenticate_api_with { captured_self = self }
      end

      get :index
      expect(response).to have_http_status(:ok)
      expect(captured_self).to be_a(Curator::Api::BaseController)
    end

    it "lets the block halt with head :unauthorized" do
      Curator.configure do |c|
        c.authenticate_api_with { head :unauthorized }
      end

      get :index
      expect(response).to have_http_status(:unauthorized)
    end

    it "propagates unexpected exceptions from the block" do
      Curator.configure do |c|
        c.authenticate_api_with { raise Curator::LLMError, "boom" }
      end

      expect { get :index }.to raise_error(Curator::LLMError, "boom")
    end

    it "does not call the admin hook" do
      admin_calls = 0
      api_calls   = 0
      Curator.configure do |c|
        c.authenticate_admin_with { admin_calls += 1 }
        c.authenticate_api_with   { api_calls   += 1 }
      end

      get :index
      expect(api_calls).to eq(1)
      expect(admin_calls).to eq(0)
    end
  end
end
