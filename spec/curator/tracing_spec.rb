require "rails_helper"

RSpec.describe Curator::Tracing do
  let(:retrieval) { create(:curator_retrieval) }

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
        retrieval: retrieval,
        step_type: :embed_query,
        payload_builder: ->(value) { { tokens: value * 2 } }
      ) { 7 }

      expect(result).to eq(7)
      step = retrieval.retrieval_steps.sole
      expect(step.step_type).to   eq("embed_query")
      expect(step.status).to      eq("success")
      expect(step.payload).to     eq("tokens" => 14)
      expect(step.duration_ms).to be >= 0
      expect(step.sequence).to    eq(0)
    end

    it "increments sequence per recorded step within a retrieval" do
      3.times { |i| described_class.record(retrieval: retrieval, step_type: :vector_search) { i } }
      expect(retrieval.retrieval_steps.order(:sequence).pluck(:sequence)).to eq([ 0, 1, 2 ])
    end

    it "writes an :error row, captures the message, and re-raises" do
      expect {
        described_class.record(retrieval: retrieval, step_type: :vector_search) { raise "boom" }
      }.to raise_error("boom")

      step = retrieval.retrieval_steps.sole
      expect(step.status).to        eq("error")
      expect(step.error_message).to eq("boom")
      expect(step.payload).to       eq({})
    end
  end

  context "trace_level :summary" do
    before { Curator.config.trace_level = :summary }

    it "writes a step row with an empty payload, ignoring the builder" do
      described_class.record(
        retrieval: retrieval,
        step_type: :vector_search,
        payload_builder: ->(_) { { sensitive: "data" } }
      ) { :ok }

      step = retrieval.retrieval_steps.sole
      expect(step.payload).to eq({})
    end
  end

  context "trace_level :off" do
    before { Curator.config.trace_level = :off }

    it "skips the step row entirely and returns the block result" do
      result = described_class.record(retrieval: retrieval, step_type: :vector_search) { :ok }
      expect(result).to eq(:ok)
      expect(retrieval.retrieval_steps.count).to eq(0)
    end

    it "does not capture errors" do
      expect {
        described_class.record(retrieval: retrieval, step_type: :vector_search) { raise "boom" }
      }.to raise_error("boom")
      expect(retrieval.retrieval_steps.count).to eq(0)
    end
  end

  context "retrieval is nil (config.log_queries = false path)" do
    it "passes the block through without writing anything" do
      result = described_class.record(retrieval: nil, step_type: :embed_query) { 99 }
      expect(result).to eq(99)
    end
  end

  describe ".subscribe" do
    let(:kb)             { create(:curator_knowledge_base) }
    let(:chat)           { Chat.create!(model_id: kb.chat_model) }
    let(:other_chat)     { Chat.create!(model_id: kb.chat_model) }
    let(:chat_retrieval) { create(:curator_retrieval, knowledge_base: kb, chat: chat) }
    let(:other_retrieval) { create(:curator_retrieval, knowledge_base: kb, chat: other_chat) }

    before { Curator.config.trace_level = :full }

    it "yields only events whose chat_id matches the chat scope, in sequence order" do
      received = []
      handle = described_class.subscribe(scope: chat) { |payload| received << payload }

      begin
        described_class.record(retrieval: chat_retrieval,  step_type: :embed_query)    { :a }
        described_class.record(retrieval: other_retrieval, step_type: :embed_query)    { :b }
        described_class.record(retrieval: chat_retrieval,  step_type: :vector_search)  { :c }
      ensure
        described_class.unsubscribe(handle)
      end

      expect(received.map { |p| p[:step_type] }).to eq([ :embed_query, :vector_search ])
      expect(received.map { |p| p[:chat_id] }).to all(eq(chat.id))
      expect(received.map { |p| p[:sequence] }).to eq([ 0, 1 ])
    end

    it "yields only events whose retrieval_id matches the retrieval scope" do
      received = []
      handle = described_class.subscribe(scope: chat_retrieval) { |payload| received << payload }

      begin
        described_class.record(retrieval: chat_retrieval,  step_type: :embed_query) { :a }
        described_class.record(retrieval: other_retrieval, step_type: :embed_query) { :b }
      ensure
        described_class.unsubscribe(handle)
      end

      expect(received.map { |p| p[:retrieval_id] }).to eq([ chat_retrieval.id ])
    end

    it "stops yielding after unsubscribe" do
      received = []
      handle = described_class.subscribe(scope: chat) { |payload| received << payload }
      described_class.record(retrieval: chat_retrieval, step_type: :embed_query) { :a }
      described_class.unsubscribe(handle)
      described_class.record(retrieval: chat_retrieval, step_type: :vector_search) { :b }

      expect(received.size).to eq(1)
    end

    it "yields error events alongside success events" do
      received = []
      handle = described_class.subscribe(scope: chat) { |payload| received << payload }

      begin
        described_class.record(retrieval: chat_retrieval, step_type: :embed_query) { :ok }
        expect {
          described_class.record(retrieval: chat_retrieval, step_type: :vector_search) { raise "boom" }
        }.to raise_error("boom")
      ensure
        described_class.unsubscribe(handle)
      end

      expect(received.map { |p| p[:status] }).to eq([ :success, :error ])
      expect(received.last[:error_message]).to eq("boom")
    end

    it "raises ArgumentError when called without a block" do
      expect { described_class.subscribe(scope: chat) }
        .to raise_error(ArgumentError, /block required/)
    end

    it "raises ArgumentError when scope is nil" do
      expect { described_class.subscribe(scope: nil) { } }
        .to raise_error(ArgumentError, /scope required/)
    end

    context "trace_level :summary" do
      before { Curator.config.trace_level = :summary }

      it "still emits an event, with empty payload contents" do
        received = []
        handle = described_class.subscribe(scope: chat) { |p| received << p }

        begin
          described_class.record(
            retrieval: chat_retrieval, step_type: :embed_query,
            payload_builder: ->(_) { { sensitive: "data" } }
          ) { :ok }
        ensure
          described_class.unsubscribe(handle)
        end

        expect(received.size).to eq(1)
        expect(received.first[:payload]).to eq({})
        expect(received.first[:step_type]).to eq(:embed_query)
      end
    end

    context "trace_level :off" do
      before { Curator.config.trace_level = :off }

      it "emits no events" do
        received = []
        handle = described_class.subscribe(scope: chat) { |p| received << p }

        begin
          described_class.record(retrieval: chat_retrieval, step_type: :embed_query) { :ok }
        ensure
          described_class.unsubscribe(handle)
        end

        expect(received).to be_empty
      end
    end
  end
end
