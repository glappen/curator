require "rails_helper"
require "csv"
require "json"

RSpec.describe Curator::Evaluations::Exporter do
  let!(:kb)       { create(:curator_knowledge_base, slug: "default", is_default: true) }
  let!(:other_kb) { create(:curator_knowledge_base, slug: "scrolls", name: "Scrolls") }

  let!(:retrieval_alpha) do
    create(:curator_retrieval,
           knowledge_base:  kb,
           query:           "alpha question",
           chat_model:      "gpt-5-mini",
           embedding_model: "text-embedding-3-small")
  end
  let!(:retrieval_beta) do
    create(:curator_retrieval,
           knowledge_base:  kb,
           query:           "beta question",
           chat_model:      "gpt-5-nano",
           embedding_model: "text-embedding-3-small")
  end
  let!(:retrieval_other) do
    create(:curator_retrieval, knowledge_base: other_kb, query: "delta question")
  end

  let!(:positive_eval) do
    create(:curator_evaluation,
           retrieval:      retrieval_alpha,
           rating:         "positive",
           feedback:       "great answer",
           evaluator_id:   "alice@example.com",
           evaluator_role: "reviewer")
  end
  let!(:negative_eval) do
    create(:curator_evaluation,
           retrieval:          retrieval_beta,
           rating:             "negative",
           feedback:           "made stuff up",
           ideal_answer:       "the correct answer",
           failure_categories: %w[hallucination wrong_citation],
           evaluator_id:       "bob@example.com",
           evaluator_role:     "end_user")
  end
  let!(:other_kb_eval) do
    create(:curator_evaluation, retrieval: retrieval_other, rating: "positive")
  end

  describe ".stream(format: :csv)" do
    it "writes a header matching COLUMNS" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      header = CSV.parse_line(io.string.lines.first)
      expect(header).to eq(described_class::COLUMNS.map(&:to_s))
    end

    it "writes one row per evaluation" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      rows = CSV.parse(io.string, headers: true)
      expect(rows.size).to eq(3)
    end

    it "joins failure_categories with semicolons in CSV" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { rating: "negative" })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.size).to eq(1)
      expect(rows.first["failure_categories"]).to eq("hallucination;wrong_citation")
    end

    # An empty failure_categories list serializes as nil in CSV (renders
    # as a blank cell — semantically "no value") rather than an empty
    # string that round-trips through `CSV.parse` as `""`. JSON keeps
    # the empty array.
    it "renders an empty failure_categories list as a blank CSV cell" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { rating: "positive" })

      rows = CSV.parse(io.string, headers: true)
      alpha_row = rows.find { |r| r["query"] == "alpha question" }
      expect(alpha_row["failure_categories"]).to be_nil
    end

    it "writes rows incrementally rather than buffering" do
      io             = StringIO.new
      sizes          = []
      original_write = io.method(:write)
      allow(io).to receive(:write) do |*args|
        original_write.call(*args)
        sizes << io.string.bytesize
      end

      described_class.stream(io: io, format: "csv")

      expect(sizes.size).to eq(4) # header + 3 rows
      expect(sizes).to eq(sizes.sort.uniq)
    end

    it "filters by KB slug" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { kb: "scrolls" })

      expect(io.string).to     include("delta question")
      expect(io.string).not_to include("alpha question")
    end

    it "filters by rating" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { rating: "positive" })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.map { |r| r["rating"] }.uniq).to eq([ "positive" ])
    end

    it "filters by failure_categories with ANY-of semantics" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv",
                             filters: { failure_categories: [ "hallucination" ] })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.size).to eq(1)
      expect(rows.first["query"]).to eq("beta question")
    end

    it "filters by evaluator_id substring" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { evaluator_id: "alice" })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.map { |r| r["evaluator_id"] }).to eq([ "alice@example.com" ])
    end

    it "filters by evaluator_role" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { evaluator_role: "end_user" })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.size).to eq(1)
      expect(rows.first["evaluator_role"]).to eq("end_user")
    end

    it "filters by since" do
      positive_eval.update!(created_at: 3.days.ago)
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { since: 1.day.ago.to_date.iso8601 })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.map { |r| r["query"] }).not_to include("alpha question")
    end

    it "ignores a malformed since date instead of returning zero rows" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { since: "garbage" })

      rows = CSV.parse(io.string, headers: true)
      expect(rows.size).to eq(3)
    end

    # Regression: see the matching spec on `Curator::Retrievals::Exporter`.
    # Each fixture eval lives on its own retrieval, and both PK
    # sequences are inserted in the same order, so `eval.id DESC`
    # observes as `retrieval_id DESC` here.
    it "emits rows in PK-descending order" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      ids = CSV.parse(io.string, headers: true)
                .map { |r| r["retrieval_id"].to_i }
      expect(ids).to eq(ids.sort.reverse)
    end
  end

  describe ".stream(format: :json)" do
    it "writes a single JSON document with arrays for failure_categories" do
      io = StringIO.new
      described_class.stream(io: io, format: "json", filters: { rating: "negative" })

      parsed = JSON.parse(io.string)
      expect(parsed.size).to eq(1)
      row = parsed.first
      expect(row["failure_categories"]).to eq([ "hallucination", "wrong_citation" ])
      expect(row).to include(
        "rating"        => "negative",
        "feedback"      => "made stuff up",
        "ideal_answer"  => "the correct answer",
        "evaluator_id"  => "bob@example.com",
        "evaluator_role" => "end_user"
      )
    end
  end

  describe ".stream answer truncation" do
    it "truncates the answer column to ANSWER_TRUNCATION characters" do
      chat = Chat.create!(model_id: "gpt-5-nano")
      message = chat.messages.create!(role: "assistant", content: ("a" * 1000))
      retrieval_alpha.update!(chat: chat, message: message)

      io = StringIO.new
      described_class.stream(io: io, format: "json", filters: { kb: "default" })
      parsed = JSON.parse(io.string)

      alpha = parsed.find { |r| r["query"] == "alpha question" }
      expect(alpha["answer"].length).to eq(Curator::Evaluations::Exporter::ANSWER_TRUNCATION)
      expect(alpha["answer"]).to end_with("…")
    end
  end

  it "raises ArgumentError on unknown formats" do
    expect { described_class.stream(io: StringIO.new, format: "xml") }
      .to raise_error(ArgumentError, /unknown format/)
  end
end
