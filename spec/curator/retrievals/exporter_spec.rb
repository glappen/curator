require "rails_helper"
require "csv"
require "json"

RSpec.describe Curator::Retrievals::Exporter do
  let!(:kb)       { create(:curator_knowledge_base, slug: "default", is_default: true) }
  let!(:other_kb) { create(:curator_knowledge_base, slug: "scrolls", name: "Scrolls") }

  # The fixtures cover the three filter dimensions exercised below: KB,
  # status, and origin. Every other column on the row is exercised via
  # the all-rows happy-path spec.
  let!(:adhoc) do
    create(:curator_retrieval,
           knowledge_base:  kb,
           query:           "alpha question",
           chat_model:      "gpt-5-mini",
           embedding_model: "text-embedding-3-small",
           origin:          "adhoc",
           status:          "success")
  end
  let!(:console_run) do
    create(:curator_retrieval,
           knowledge_base:  kb,
           query:           "beta question",
           chat_model:      "gpt-5-nano",
           embedding_model: "text-embedding-3-small",
           origin:          "console",
           status:          "failed")
  end
  let!(:review_run) do
    create(:curator_retrieval,
           knowledge_base:  kb,
           query:           "gamma question",
           origin:          "console_review")
  end
  let!(:other_kb_run) do
    create(:curator_retrieval,
           knowledge_base: other_kb,
           query:          "delta question",
           origin:         "adhoc")
  end

  describe ".stream(format: :csv)" do
    it "writes a CSV header row matching COLUMNS" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      header = CSV.parse_line(io.string.lines.first)
      expect(header).to eq(described_class::COLUMNS.map(&:to_s))
    end

    it "writes one row per retrieval with the documented column shape" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      rows  = CSV.parse(io.string, headers: true)
      alpha = rows.find { |r| r["query"] == "alpha question" }

      expect(alpha).not_to be_nil
      expect(alpha["retrieval_id"]).to eq(adhoc.id.to_s)
      expect(alpha["kb_slug"]).to        eq("default")
      expect(alpha["chat_model"]).to     eq("gpt-5-mini")
      expect(alpha["embedding_model"]).to eq("text-embedding-3-small")
      expect(alpha["status"]).to eq("success")
      expect(alpha["origin"]).to eq("adhoc")
      expect(alpha["created_at"]).to be_present
    end

    # Streaming contract — `find_each` + `io.puts` must surface a
    # complete header before the cursor finishes opening the data
    # cursor, and must surface complete rows incrementally rather than
    # buffering. Asserted by writing into a StringIO whose `puts` has
    # been intercepted to record content sizes after each call.
    it "writes rows incrementally rather than buffering" do
      io             = StringIO.new
      sizes          = []
      original_write = io.method(:write)
      allow(io).to receive(:write) do |*args|
        original_write.call(*args)
        sizes << io.string.bytesize
      end

      described_class.stream(io: io, format: "csv")

      expect(sizes.size).to be >= 4 # header + 3 visible rows
      expect(sizes).to eq(sizes.uniq).and eq(sizes.sort)
    end

    it "hides :console_review rows by default" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      expect(io.string).not_to include("gamma question")
    end

    it "includes :console_review rows when show_review filter is truthy" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { show_review: "true" })

      expect(io.string).to include("gamma question")
    end

    it "filters by knowledge_base_id" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv",
                             filters: { knowledge_base_id: kb.id })

      expect(io.string).to     include("alpha question")
      expect(io.string).not_to include("delta question")
    end

    it "filters by KB slug (rake/CLI path)" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { kb_slug: "scrolls" })

      expect(io.string).to     include("delta question")
      expect(io.string).not_to include("alpha question")
    end

    it "filters by status" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { status: "failed" })

      expect(io.string).to     include("beta question")
      expect(io.string).not_to include("alpha question")
    end

    it "filters by ILIKE query substring" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { query: "alph" })

      expect(io.string).to     include("alpha question")
      expect(io.string).not_to include("beta question")
    end

    # Date filters mirror the controller — `from` is inclusive on the
    # day, `to` is exclusive on the day after, and a malformed value
    # drops the clause entirely.
    it "filters by `from` date inclusively" do
      adhoc.update!(created_at: 3.days.ago)

      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { from: 1.day.ago.to_date.iso8601 })

      expect(io.string).not_to include("alpha question")
      expect(io.string).to     include("beta question")
    end

    it "ignores a malformed `from` date instead of returning zero rows" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv", filters: { from: "garbage" })

      expect(io.string).to include("alpha question")
    end

    # Regression: an earlier draft set `.order(created_at: :desc)` on
    # the scope, but `find_each` silently drops non-PK orderings (and
    # warns "Scoped order is ignored"). The export now uses
    # `find_each(order: :desc)` to walk PK-descending — emitting newest
    # rows first without tripping the warning.
    it "emits rows in PK-descending order" do
      io = StringIO.new
      described_class.stream(io: io, format: "csv")

      ids = CSV.parse(io.string, headers: true)
                .map { |r| r["retrieval_id"].to_i }
      expect(ids).to eq(ids.sort.reverse)
    end
  end

  describe ".stream(format: :json)" do
    it "writes a single JSON document with one object per row" do
      io = StringIO.new
      described_class.stream(io: io, format: "json")

      parsed = JSON.parse(io.string)
      expect(parsed).to be_an(Array)
      expect(parsed.size).to eq(3) # console_review hidden by default

      alpha = parsed.find { |r| r["query"] == "alpha question" }
      expect(alpha).to include(
        "retrieval_id"        => adhoc.id,
        "kb_slug"             => "default",
        "chat_model"          => "gpt-5-mini",
        "embedding_model"     => "text-embedding-3-small",
        "status"              => "success",
        "origin"              => "adhoc",
        "retrieved_hit_count" => 0,
        "eval_count"          => 0
      )
    end
  end

  describe ".stream with answer truncation" do
    it "truncates the answer column to ANSWER_TRUNCATION characters" do
      chat = Chat.create!(model_id: "gpt-5-nano")
      message = chat.messages.create!(
        role:    "assistant",
        content: ("a" * 1000)
      )
      adhoc.update!(chat: chat, message: message)

      io = StringIO.new
      described_class.stream(io: io, format: "json", filters: { knowledge_base_id: kb.id })
      parsed = JSON.parse(io.string)
      alpha  = parsed.find { |r| r["query"] == "alpha question" }

      expect(alpha["answer"].length).to eq(Curator::Retrievals::Exporter::ANSWER_TRUNCATION)
      expect(alpha["answer"]).to end_with("…")
    end
  end

  it "raises ArgumentError on unknown formats" do
    expect { described_class.stream(io: StringIO.new, format: "xml") }
      .to raise_error(ArgumentError, /unknown format/)
  end
end
