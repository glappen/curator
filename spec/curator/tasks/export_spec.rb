require "rails_helper"
require "csv"
require "json"

RSpec.describe Curator::Tasks::Export do
  let!(:kb) { create(:curator_knowledge_base, slug: "default") }

  let!(:retrieval) do
    create(:curator_retrieval,
           knowledge_base: kb,
           query:          "alpha",
           status:         :success,
           origin:         :adhoc)
  end

  describe ".run(format: :csv)" do
    it "writes a header and one row per record" do
      io = StringIO.new

      described_class.run(
        format:  "csv",
        io:      io,
        scope:   Curator::Retrieval.where(id: retrieval.id),
        columns: %i[retrieval_id query status]
      ) { |r| { retrieval_id: r.id, query: r.query, status: r.status } }

      rows = CSV.parse(io.string, headers: true)
      expect(rows.size).to eq(1)
      expect(rows.first["query"]).to eq("alpha")
      expect(rows.first["status"]).to eq("success")
    end
  end

  describe ".run(format: :json)" do
    it "writes a single JSON array" do
      io = StringIO.new

      described_class.run(
        format:  "json",
        io:      io,
        scope:   Curator::Retrieval.where(id: retrieval.id),
        columns: %i[retrieval_id query]
      ) { |r| { retrieval_id: r.id, query: r.query } }

      parsed = JSON.parse(io.string)
      expect(parsed).to eq([ { "retrieval_id" => retrieval.id, "query" => "alpha" } ])
    end
  end

  it "raises ArgumentError on an unknown format" do
    expect {
      described_class.run(
        format:  "xml",
        io:      StringIO.new,
        scope:   Curator::Retrieval.none,
        columns: %i[id]
      ) { |r| { id: r.id } }
    }.to raise_error(ArgumentError, /unknown format/)
  end
end
