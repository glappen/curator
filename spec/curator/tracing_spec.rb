require "rails_helper"

RSpec.describe Curator::Tracing do
  let(:search) { create(:curator_search) }

  around do |ex|
    original = Curator.config.trace_level
    ex.run
  ensure
    Curator.config.trace_level = original
  end

  context "trace_level :full" do
    before { Curator.config.trace_level = :full }

    it "writes a step row with the builder's payload and returns the block result" do
      result = described_class.record(
        search: search,
        step_type: :embed_query,
        payload_builder: ->(value) { { tokens: value * 2 } }
      ) { 7 }

      expect(result).to eq(7)
      step = search.search_steps.sole
      expect(step.step_type).to   eq("embed_query")
      expect(step.status).to      eq("success")
      expect(step.payload).to     eq("tokens" => 14)
      expect(step.duration_ms).to be >= 0
      expect(step.sequence).to    eq(0)
    end

    it "increments sequence per recorded step within a search" do
      3.times { |i| described_class.record(search: search, step_type: :vector_search) { i } }
      expect(search.search_steps.order(:sequence).pluck(:sequence)).to eq([ 0, 1, 2 ])
    end

    it "writes an :error row, captures the message, and re-raises" do
      expect {
        described_class.record(search: search, step_type: :vector_search) { raise "boom" }
      }.to raise_error("boom")

      step = search.search_steps.sole
      expect(step.status).to        eq("error")
      expect(step.error_message).to eq("boom")
      expect(step.payload).to       eq({})
    end
  end

  context "trace_level :summary" do
    before { Curator.config.trace_level = :summary }

    it "writes a step row with an empty payload, ignoring the builder" do
      described_class.record(
        search: search,
        step_type: :vector_search,
        payload_builder: ->(_) { { sensitive: "data" } }
      ) { :ok }

      step = search.search_steps.sole
      expect(step.payload).to eq({})
    end
  end

  context "trace_level :off" do
    before { Curator.config.trace_level = :off }

    it "skips the step row entirely and returns the block result" do
      result = described_class.record(search: search, step_type: :vector_search) { :ok }
      expect(result).to eq(:ok)
      expect(search.search_steps.count).to eq(0)
    end

    it "does not capture errors" do
      expect {
        described_class.record(search: search, step_type: :vector_search) { raise "boom" }
      }.to raise_error("boom")
      expect(search.search_steps.count).to eq(0)
    end
  end

  context "search is nil (config.log_queries = false path)" do
    it "passes the block through without writing anything" do
      result = described_class.record(search: nil, step_type: :embed_query) { 99 }
      expect(result).to eq(99)
    end
  end
end
