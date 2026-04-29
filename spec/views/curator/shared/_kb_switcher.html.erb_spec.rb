require "rails_helper"

RSpec.describe "curator/shared/_kb_switcher.html.erb", type: :view do
  # Phase 4 owns the nested `kbs/:slug/documents` routes that put
  # `:knowledge_base_slug` into params; until that lands we exercise
  # the rendered branch directly via the helper, stubbing params on
  # the view's controller proxy.

  before { view.extend(Curator::AdminHelper) }

  it "renders nothing when no slug is in params" do
    render partial: "curator/shared/kb_switcher"

    expect(rendered).to be_blank
  end

  context "when a KB slug is set" do
    let!(:billing) { create(:curator_knowledge_base, name: "Billing", slug: "billing") }
    let!(:support) { create(:curator_knowledge_base, name: "Support", slug: "support") }

    before { controller.params[:knowledge_base_slug] = "support" }

    it "renders a Stimulus-wrapped <select> with the current KB selected" do
      render partial: "curator/shared/kb_switcher"

      expect(rendered).to include('data-controller="kb-switcher"')
      expect(rendered).to include('data-action="change->kb-switcher#change"')
      expect(rendered).to include('id="kb-switcher-select"')
      expect(rendered).to match(%r{<option value="support" selected>\s*Support\s*</option>})
      expect(rendered).to match(%r{<option value="billing"\s*>\s*Billing\s*</option>})
    end

    it "lists KBs in alphabetical order" do
      render partial: "curator/shared/kb_switcher"

      expect(rendered.index("Billing")).to be < rendered.index("Support")
    end
  end
end
