require "rails_helper"

# Console run end-to-end smoke. Drives `Curator::ConsoleStreamJob` against
# the dummy app top-to-bottom:
#
#   Curator.ingest sample.md (real ingest + embed jobs against the
#   default WebMock /embeddings stub) → ConsoleStreamJob.perform_now →
#   real Curator::Asker → RubyLLM /chat/completions stubbed at the SSE
#   wire → broadcasts emitted via Turbo::StreamsChannel against the
#   per-tab topic.
#
# The point is to verify the job's wiring: status flips to streaming,
# every Asker delta becomes one append broadcast in order (HTML-escaped),
# the sources panel and done-status broadcasts arrive after Asker
# finalizes, and the persisted `curator_retrievals` row carries the
# snapshot config the operator submitted.
RSpec.describe Curator::ConsoleStreamJob, :broadcasts, type: :job do
  include ActiveJob::TestHelper

  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }
  let(:md_path)     { fixture_dir.join("sample.md") }
  let(:topic)       { "console-test-#{SecureRandom.hex(4)}" }

  # Pinned to vector + 0.0 threshold: the deterministic embed stub
  # doesn't model real semantics, so hybrid + the seeded 0.2 threshold
  # gives flaky ranking on a one-document fixture. Same rationale as
  # ask_smoke_spec.rb.
  let!(:default_kb) do
    Curator::KnowledgeBase.seed_default!.tap do |kb|
      kb.update!(retrieval_strategy: "vector", similarity_threshold: 0.0)
    end
  end

  before do
    Curator.configure { |c| c.extractor = :basic }
    perform_enqueued_jobs { Curator.ingest(md_path.to_s) }
  end
  after { Curator.reset_config! }

  # `<marker>` checks real ERB-escape on the wire — the in-spec stub
  # in console_spec.rb only verifies the wire contract; this spec
  # verifies the real broadcast does the escape on the way through.
  let(:deltas) { [ "Sample ", "answer ", "with ", "<marker> [1]." ] }

  it "broadcasts streaming-status, per-delta appends, sources, then done-status" do
    stub_chat_completion_stream(deltas: deltas)

    described_class.perform_now(
      topic:                topic,
      knowledge_base_slug:  "default",
      query:                "Sample Markdown",
      chunk_limit:          3,
      similarity_threshold: 0.0,
      strategy:             "vector",
      chat_model:           "gpt-5-mini"
    )

    stream   = Turbo::StreamsChannel.send(:stream_name_from, topic)
    # Test pubsub stores broadcasts as JSON-serialized payloads; decode for
    # human-readable substring matching.
    payloads = ActionCable.server.pubsub.broadcasts(stream).map { |p| JSON.parse(p) }
    expect(payloads).not_to be_empty

    # Frame 1: status → streaming.
    expect(payloads.first).to include('action="update"')
    expect(payloads.first).to include('target="console-status"')
    expect(payloads.first).to include("console-status--streaming")

    # Frames 2..(2+deltas.size-1): one append per delta in order, ERB-escaped,
    # each delta wrapped in a `<span data-seq>` so the console-stream
    # Stimulus controller can reorder out-of-order Cable deliveries.
    append_frames = payloads.select { |p| p.include?('action="append"') }
    expect(append_frames.size).to eq(deltas.size)
    expect(append_frames[0]).to include(%(<span data-seq="1">Sample </span>))
    expect(append_frames[1]).to include(%(<span data-seq="2">answer </span>))
    expect(append_frames[2]).to include(%(<span data-seq="3">with </span>))
    expect(append_frames[3]).to     include(%(<span data-seq="4">&lt;marker&gt; [1].</span>))
    expect(append_frames[3]).not_to include("<marker>")

    # Tail-end ordering: sources update → eval-widget update → done status.
    update_targets = payloads.join.scan(/action="update" target="(console-[a-z]+)"/).flatten
    expect(update_targets.first).to eq("console-status") # streaming
    expect(update_targets.last(3)).to eq(%w[console-sources console-evaluation console-status])
    expect(payloads.last).to  include("console-status--done")
    expect(payloads[-2]).to   include("console-evaluation")
    expect(payloads[-2]).to   include("/curator/evaluations") # form action
    expect(payloads[-3]).to   include("sample.md")
  end

  it "broadcasts the evaluation widget bound to the persisted retrieval id on done" do
    stub_chat_completion_stream(deltas: deltas)

    described_class.perform_now(
      topic:                topic,
      knowledge_base_slug:  "default",
      query:                "Sample Markdown",
      chunk_limit:          3,
      similarity_threshold: 0.0,
      strategy:             "vector"
    )

    row      = Curator::Retrieval.sole
    stream   = Turbo::StreamsChannel.send(:stream_name_from, topic)
    payloads = ActionCable.server.pubsub.broadcasts(stream).map { |p| JSON.parse(p) }
    eval_frame = payloads.find { |p| p.include?('target="console-evaluation"') }

    expect(eval_frame).to     be_present
    expect(eval_frame).to     include('action="update"')
    expect(eval_frame).to     include(%(value="#{row.id}")) # retrieval_id hidden field
    expect(eval_frame).to     include("console-evaluation#setRating")
  end

  it "persists a successful Curator::Retrieval row with the submitted snapshot config" do
    stub_chat_completion_stream(deltas: deltas)

    described_class.perform_now(
      topic:                topic,
      knowledge_base_slug:  "default",
      query:                "Sample Markdown",
      chunk_limit:          3,
      similarity_threshold: 0.0,
      strategy:             "vector",
      chat_model:           "gpt-5-mini"
    )

    row = Curator::Retrieval.sole
    expect(row).to                    be_success
    expect(row.knowledge_base_id).to  eq(default_kb.id)
    expect(row.chunk_limit).to        eq(3)
    expect(row.similarity_threshold).to eq(0.0)
    expect(row.retrieval_strategy).to eq("vector")
    expect(row.chat_model).to         eq("gpt-5-mini")
    expect(row.chat_id).to            be_present
    expect(row.message_id).to         be_present

    llm_step = row.retrieval_steps.find_by(step_type: "llm_call")
    expect(llm_step.payload["streamed"]).to be true
    expect(row.system_prompt_text).to include("[1] From")

    assistant_msg = Chat.find(row.chat_id).messages.find_by(role: :assistant)
    expect(assistant_msg.content).to eq(deltas.join)
  end

  it "broadcasts a failed status frame and persists a :failed retrieval row when Asker raises" do
    allow(Curator::Asker).to receive(:call).and_raise(Curator::LLMError, "stubbed LLM blew up")

    described_class.perform_now(
      topic:                topic,
      knowledge_base_slug:  "default",
      query:                "anything"
    )

    stream   = Turbo::StreamsChannel.send(:stream_name_from, topic)
    payloads = ActionCable.server.pubsub.broadcasts(stream).map { |p| JSON.parse(p) }
    # streaming-status frame, then failed-status frame. No append, no sources.
    expect(payloads.size).to                        eq(2)
    expect(payloads.first).to                       include("console-status--streaming")
    expect(payloads.last).to                        include("console-status--failed")
    expect(payloads.last).to                        include("stubbed LLM blew up")
    expect(payloads.any? { |p| p.include?("append") }).to be false
    expect(payloads.any? { |p| p.include?("console-sources") }).to be false
    expect(payloads.any? { |p| p.include?("console-evaluation") }).to be false
  end

  it "broadcasts a failed status frame when the slug is unknown" do
    described_class.perform_now(
      topic:                topic,
      knowledge_base_slug:  "nonexistent",
      query:                "anything"
    )

    stream   = Turbo::StreamsChannel.send(:stream_name_from, topic)
    payloads = ActionCable.server.pubsub.broadcasts(stream).map { |p| JSON.parse(p) }
    expect(payloads.last).to include("console-status--failed")
  end
end
