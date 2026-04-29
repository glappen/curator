require "rails_helper"

RSpec.describe "Curator admin layout", type: :request do
  it "renders the engine layout shell at GET /curator" do
    Curator::KnowledgeBase.seed_default!

    get "/curator"

    expect(response).to have_http_status(:ok)
    body = response.body

    expect(body).to include('<body class="curator-ui">')
    expect(body).to match(%r{<link[^>]+rel="stylesheet"[^>]*href="[^"]*curator/curator})
    expect(body).to include('class="app-header"')
    expect(body).to include('class="app-header__slot"')
    expect(body).to include('class="app-main"')
    expect(body).to include('class="app-footer"')
    expect(body).to include(Curator::VERSION)
  end

  describe "KB switcher" do
    it "is absent on GET /curator (no KB-scoped slug)" do
      Curator::KnowledgeBase.seed_default!

      get "/curator"

      expect(response.body).not_to include('data-controller="kb-switcher"')
    end

    it "is absent on GET /curator/kbs/new (slug param is :slug, not :knowledge_base_slug)" do
      get "/curator/kbs/new"

      expect(response.body).not_to include('data-controller="kb-switcher"')
    end
  end
end
