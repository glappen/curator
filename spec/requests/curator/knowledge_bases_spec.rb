require "rails_helper"

RSpec.describe "Curator::KnowledgeBases", type: :request do
  let(:valid_attrs) do
    {
      name:            "Support",
      slug:            "support",
      description:     "Tickets and runbooks",
      embedding_model: "text-embedding-3-small",
      chat_model:      "gpt-5-mini"
    }
  end

  describe "GET /curator/kbs/new" do
    it "renders the tiered form with all four fieldsets" do
      get "/curator/kbs/new"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("<legend>Display</legend>")
      expect(body).to include("<legend>Retrieval</legend>")
      expect(body).to include("<legend>Advanced</legend>")
      expect(body).to include("<legend>Identity (locked after creation)</legend>")
    end

    it "renders embedding_model and slug as editable inputs" do
      get "/curator/kbs/new"

      %w[embedding_model slug].each do |field|
        tag = response.body[%r{<input[^>]+name="knowledge_base\[#{field}\]"[^>]*>}]
        expect(tag).to be_present, "expected an <input> for #{field}"
        expect(tag).not_to include("disabled")
        expect(tag).not_to include("readonly")
      end
    end
  end

  describe "POST /curator/kbs" do
    it "creates a KB with valid attrs and redirects to show" do
      expect {
        post "/curator/kbs", params: { knowledge_base: valid_attrs }
      }.to change(Curator::KnowledgeBase, :count).by(1)

      kb = Curator::KnowledgeBase.find_by!(slug: "support")
      expect(response).to redirect_to("/curator/kbs/support")
      follow_redirect!
      expect(response.body).to include(kb.name)
    end

    it "re-renders new with errors when invalid" do
      post "/curator/kbs", params: { knowledge_base: valid_attrs.merge(name: "") }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("error")
      expect(response.body).to include("<legend>Display</legend>")
    end
  end

  describe "GET /curator/kbs/:slug" do
    it "shows the requested KB" do
      kb = create(:curator_knowledge_base, slug: "support", name: "Support")

      get "/curator/kbs/support"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(kb.name)
      expect(response.body).to include("support")
    end

    it "404s on an unknown slug" do
      get "/curator/kbs/missing"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /curator/kbs/:slug/edit" do
    it "renders embedding_model and slug as disabled+readonly" do
      create(:curator_knowledge_base, slug: "support")

      get "/curator/kbs/support/edit"

      expect(response).to have_http_status(:ok)
      body = response.body

      %w[embedding_model slug].each do |field|
        tag = body[%r{<input[^>]+name="knowledge_base\[#{field}\]"[^>]*>}]
        expect(tag).to be_present, "expected an <input> for #{field}"
        expect(tag).to include('disabled="disabled"')
        expect(tag).to include('readonly="readonly"')
      end
    end
  end

  describe "PATCH /curator/kbs/:slug" do
    it "updates editable attrs" do
      kb = create(:curator_knowledge_base, slug: "support", name: "Support")

      patch "/curator/kbs/support",
            params: { knowledge_base: { name: "Renamed", chunk_limit: 9 } }

      expect(response).to redirect_to("/curator/kbs/support")
      kb.reload
      expect(kb.name).to        eq("Renamed")
      expect(kb.chunk_limit).to eq(9)
    end

    # Defense-in-depth: form `disabled` attributes alone would let a
    # hand-crafted POST overwrite locked fields. The controller's strong
    # params permit list must drop them.
    it "ignores embedding_model and slug on update" do
      kb = create(:curator_knowledge_base,
                  slug:            "support",
                  embedding_model: "text-embedding-3-small")

      patch "/curator/kbs/support", params: {
        knowledge_base: {
          name:            "Renamed",
          embedding_model: "text-embedding-3-large",
          slug:            "hijack"
        }
      }

      kb.reload
      expect(kb.embedding_model).to eq("text-embedding-3-small")
      expect(kb.slug).to            eq("support")
      expect(kb.name).to            eq("Renamed")
    end

    it "re-renders edit with errors when invalid" do
      create(:curator_knowledge_base, slug: "support")

      patch "/curator/kbs/support",
            params: { knowledge_base: { name: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("<legend>Display</legend>")
    end

    # Controller-level proof that `is_default` survives the strong-params
    # permit list and the model's single-default flip fires through HTTP.
    # The model spec covers the invariant directly; this guards against a
    # future permit-list edit accidentally dropping `is_default`.
    it "flips the prior default when promoting another KB via update" do
      prior = create(:curator_knowledge_base, slug: "old", is_default: true)
      other = create(:curator_knowledge_base, slug: "new", is_default: false)

      patch "/curator/kbs/new",
            params: { knowledge_base: { is_default: "1" } }

      expect(other.reload.is_default).to be(true)
      expect(prior.reload.is_default).to be(false)
    end
  end

  describe "DELETE /curator/kbs/:slug" do
    it "destroys the KB synchronously and redirects to root" do
      kb = create(:curator_knowledge_base, slug: "support")
      doc = create(:curator_document, knowledge_base: kb)

      expect {
        delete "/curator/kbs/support"
      }.to change(Curator::KnowledgeBase, :count).by(-1)

      expect(Curator::Document.exists?(doc.id)).to be(false)
      expect(response).to have_http_status(:see_other).or have_http_status(:found)
      expect(response.location).to match(%r{/curator/?\z})
    end
  end
end
