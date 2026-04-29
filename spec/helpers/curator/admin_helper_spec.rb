require "rails_helper"

RSpec.describe Curator::AdminHelper, type: :helper do
  describe "#current_kb_for_switcher" do
    it "returns nil when no slug param is present" do
      expect(helper.current_kb_for_switcher).to be_nil
    end

    it "returns nil when the slug param is blank" do
      controller.params[:knowledge_base_slug] = ""
      expect(helper.current_kb_for_switcher).to be_nil
    end

    context "when params[:knowledge_base_slug] is set" do
      let!(:billing) { create(:curator_knowledge_base, name: "Billing", slug: "billing") }
      let!(:support) { create(:curator_knowledge_base, name: "Support", slug: "support") }

      before { controller.params[:knowledge_base_slug] = "support" }

      it "returns a struct with current and the full list ordered by name" do
        result = helper.current_kb_for_switcher

        expect(result.current).to eq(support)
        expect(result.all.to_a).to eq([ billing, support ])
      end

      it "raises ActiveRecord::RecordNotFound when no KB matches the slug" do
        controller.params[:knowledge_base_slug] = "no-such-kb"

        expect { helper.current_kb_for_switcher }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
