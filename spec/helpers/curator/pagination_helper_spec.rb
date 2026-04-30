require "rails_helper"

RSpec.describe Curator::PaginationHelper, type: :helper do
  before do
    # 30 rows: with per=25 we get a second page of 5, which makes
    # boundary-clamp assertions unambiguous (vs. a single-page scope).
    30.times { |i| create(:curator_knowledge_base, slug: "kb-pag-#{i}") }
  end

  let(:scope) { Curator::KnowledgeBase.order(:id) }

  describe "#paginate" do
    it "returns 25 records on page 1 by default with sane metadata" do
      page = helper.paginate(scope, page: 1, per: 25)

      expect(page.records.to_a.size).to eq(25)
      expect(page.page).to eq(1)
      expect(page.per).to eq(25)
      expect(page.total).to eq(30)
      expect(page.pages).to eq(2)
    end

    it "returns the trailing 5 records on page 2" do
      page = helper.paginate(scope, page: 2, per: 25)

      expect(page.records.to_a.size).to eq(5)
      expect(page.page).to eq(2)
    end

    it "clamps page=0 up to page 1" do
      page = helper.paginate(scope, page: 0, per: 25)

      expect(page.page).to eq(1)
      expect(page.records.to_a.size).to eq(25)
    end

    it "clamps page > pages down to the last page" do
      page = helper.paginate(scope, page: 999, per: 25)

      expect(page.page).to eq(2)
      expect(page.records.to_a.size).to eq(5)
    end

    it "clamps per > 100 down to 100" do
      page = helper.paginate(scope, page: 1, per: 200)

      expect(page.per).to eq(100)
      expect(page.pages).to eq(1)
      expect(page.records.to_a.size).to eq(30)
    end

    it "treats per=0 as the default 25" do
      page = helper.paginate(scope, page: 1, per: 0)

      expect(page.per).to eq(25)
    end

    it "reports at least 1 page even on an empty scope" do
      Curator::KnowledgeBase.delete_all

      page = helper.paginate(Curator::KnowledgeBase.all, page: 1, per: 25)

      expect(page.total).to eq(0)
      expect(page.pages).to eq(1)
      expect(page.page).to eq(1)
    end

    it "accepts string params (forwarded from controller params blind)" do
      page = helper.paginate(scope, page: "2", per: "25")

      expect(page.page).to eq(2)
      expect(page.per).to eq(25)
    end
  end
end
