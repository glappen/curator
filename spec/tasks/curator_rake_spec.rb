require "rails_helper"
require "rake"
require "tmpdir"
require "fileutils"
require "csv"
require "json"

RSpec.describe "curator rake tasks" do
  include ActiveJob::TestHelper

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("curator:seed_defaults")
  end

  def silently
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [ $stdout.string, $stderr.string ]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  describe "curator:seed_defaults" do
    let(:task) { Rake::Task["curator:seed_defaults"] }

    after { task.reenable }

    it "creates exactly one default KB on a fresh DB" do
      expect { silently { task.invoke } }.to change(Curator::KnowledgeBase, :count).from(0).to(1)

      kb = Curator::KnowledgeBase.find_by(is_default: true)
      expect(kb.slug).to eq("default")
    end

    it "is a no-op on a second run" do
      silently { task.invoke }
      task.reenable

      expect { silently { task.invoke } }.not_to change(Curator::KnowledgeBase, :count)
    end
  end

  describe "curator:ingest" do
    let(:task) { Rake::Task["curator:ingest"] }
    let!(:kb)  { create(:curator_knowledge_base, slug: "rake-test") }

    before { Curator.configure { |c| c.extractor = :basic } }
    after do
      task.reenable
      Curator.reset_config!
      ENV.delete("DIR")
      ENV.delete("KB")
      ENV.delete("PATTERN")
      ENV.delete("RECURSIVE")
    end

    it "aborts with a helpful message when DIR is missing" do
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end

    it "aborts when DIR is set but is not a directory" do
      ENV["DIR"] = "/nonexistent-curator-dir-#{SecureRandom.hex(4)}"
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end

    describe "auto-creates the KB when an unknown slug is passed" do
      it "creates the KB with derived name + default models, prints confirmation, then ingests" do
        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "a.md"), "# a\n")
          ENV["DIR"] = dir
          ENV["KB"]  = "support-team"

          expect {
            out, _err = silently { task.invoke }
            expect(out).to include('Created knowledge base "support-team"')
            expect(out).to include("created=1 duplicate=0 failed=0")
          }.to change(Curator::KnowledgeBase, :count).by(1)

          new_kb = Curator::KnowledgeBase.find_by!(slug: "support-team")
          expect(new_kb.name).to eq("Support Team")
          expect(new_kb.embedding_model).to eq(Curator::KnowledgeBase::DEFAULT_EMBEDDING_MODEL)
          expect(new_kb.chat_model).to eq(Curator::KnowledgeBase::DEFAULT_CHAT_MODEL)
          expect(new_kb.is_default).to be(false)
          expect(new_kb.documents.count).to eq(1)
        end
      end

      it "does not auto-create when the slug already exists (re-uses the row)" do
        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "a.md"), "# a\n")
          ENV["DIR"] = dir
          ENV["KB"]  = kb.slug

          expect {
            silently { task.invoke }
          }.not_to change(Curator::KnowledgeBase, :count)
        end
      end

      it "does not auto-create when KB is omitted (falls through to default!)" do
        create(:curator_knowledge_base, is_default: true, slug: "default")

        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "a.md"), "# a\n")
          ENV["DIR"] = dir

          expect {
            silently { task.invoke }
          }.not_to change(Curator::KnowledgeBase, :count)
        end
      end

      it "does not leave an orphan KB if DIR is bogus " \
         "(regression: dir validation must run before the create!)" do
        ENV["DIR"] = "/nonexistent-curator-dir-#{SecureRandom.hex(4)}"
        ENV["KB"]  = "would-be-orphan"

        expect {
          expect { silently { task.invoke } }.to raise_error(SystemExit)
        }.not_to change(Curator::KnowledgeBase, :count)
      end
    end

    it "ingests a tree, prints a created/duplicate/failed summary, and exits zero on all-success" do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, "a.md"), "# a\n")
        File.binwrite(File.join(dir, "b.md"), "# b\n")
        ENV["DIR"] = dir
        ENV["KB"]  = kb.slug

        out, _err = silently { task.invoke }
        expect(out).to include("created=2 duplicate=0 failed=0")
        expect(kb.documents.count).to eq(2)
      end
    end

    it "groups duplicates on a re-run" do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, "a.md"), "# a\n")
        ENV["DIR"] = dir
        ENV["KB"]  = kb.slug

        silently { task.invoke }
        task.reenable

        out, _err = silently { task.invoke }
        expect(out).to include("created=0 duplicate=1 failed=0")
      end
    end

    it "exits non-zero and warns on failure when any file fails to ingest" do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, "ok.md"),  "# ok\n")
        File.binwrite(File.join(dir, "bad.md"), "# bad\n")

        original = Curator.method(:ingest)
        allow(Curator).to receive(:ingest) do |input, **kwargs|
          raise Curator::ExtractionError, "boom" if input.to_s.end_with?("bad.md")
          original.call(input, **kwargs)
        end

        ENV["DIR"] = dir
        ENV["KB"]  = kb.slug

        expect {
          silently { task.invoke }
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    it "enqueues IngestDocumentJob for each created document " \
       "(extraction + chunking happen async via the host's Active Job worker)" do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, "a.md"), "# a\n")
        ENV["DIR"] = dir
        ENV["KB"]  = kb.slug

        silently { task.invoke }

        expect(Curator::IngestDocumentJob).to have_been_enqueued.exactly(:once)
      end
    end

    describe "Active Job adapter handling" do
      it "swaps :async to :inline for the duration of the task and restores it after" do
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("async")
        original = ActiveJob::Base.queue_adapter

        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "a.md"), "# a\n")
          ENV["DIR"] = dir
          ENV["KB"]  = kb.slug

          out, _err = silently { task.invoke }

          expect(out).to include("switching to :inline")
          expect(out).not_to include("ensure your Active Job worker is running")
          expect(ActiveJob::Base.queue_adapter).to eq(original)
        end
      end

      it "leaves :inline alone and suppresses the worker reminder" do
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("inline")

        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "a.md"), "# a\n")
          ENV["DIR"] = dir
          ENV["KB"]  = kb.slug

          out, _err = silently { task.invoke }

          expect(out).not_to include("switching to :inline")
          expect(out).not_to include("ensure your Active Job worker is running")
        end
      end

      it "leaves a real worker adapter alone and prints the worker reminder" do
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("sidekiq")

        Dir.mktmpdir do |dir|
          File.binwrite(File.join(dir, "a.md"), "# a\n")
          ENV["DIR"] = dir
          ENV["KB"]  = kb.slug

          out, _err = silently { task.invoke }

          expect(out).not_to include("switching to :inline")
          expect(out).to include("ensure your Active Job worker is running")
        end
      end
    end

    it "honors PATTERN" do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, "a.md"),  "# a\n")
        File.binwrite(File.join(dir, "b.csv"), "x,y\n")

        ENV["DIR"]     = dir
        ENV["KB"]      = kb.slug
        ENV["PATTERN"] = "**/*.md"

        out, _err = silently { task.invoke }
        expect(out).to include("created=1 duplicate=0 failed=0")
      end
    end
  end

  describe "curator:reembed" do
    let(:task) { Rake::Task["curator:reembed"] }
    let!(:kb)  { create(:curator_knowledge_base, slug: "reembed-kb", embedding_model: "text-embedding-3-small") }
    let!(:document) { create(:curator_document, knowledge_base: kb, status: :complete) }

    after do
      task.reenable
      ENV.delete("KB")
      ENV.delete("SCOPE")
    end

    it "aborts when KB is missing" do
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end

    it "aborts on an unknown KB slug" do
      ENV["KB"] = "no-such-kb-#{SecureRandom.hex(4)}"
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end

    it "aborts on an invalid SCOPE" do
      ENV["KB"]    = kb.slug
      ENV["SCOPE"] = "bogus"
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end

    it "prints the failed/all suggestions when stale finds no work" do
      ENV["KB"] = kb.slug

      out, _err = silently { task.invoke }

      expect(out).to include("no stale chunks found")
      expect(out).to include("SCOPE=failed")
      expect(out).to include("SCOPE=all")
    end

    it "prints the re-embed summary when work is enqueued" do
      chunk = create(:curator_chunk, document: document, sequence: 0, status: :embedded)
      create(:curator_embedding, chunk: chunk, embedding_model: "old-model")

      ENV["KB"] = kb.slug

      out, _err = silently { task.invoke }

      expect(out).to include("re-embedding 1 chunks across 1 documents (scope=stale)")
      expect(chunk.reload.status).to eq("pending")
    end

    it "honors SCOPE=all" do
      chunk = create(:curator_chunk, document: document, sequence: 0, status: :embedded)
      create(:curator_embedding, chunk: chunk, embedding_model: kb.embedding_model)

      ENV["KB"]    = kb.slug
      ENV["SCOPE"] = "all"

      out, _err = silently { task.invoke }

      expect(out).to include("re-embedding 1 chunks across 1 documents (scope=all)")
    end

    describe "Active Job adapter handling" do
      it "swaps :async to :inline for the duration of the task and restores it after" do
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("async")
        original = ActiveJob::Base.queue_adapter

        chunk = create(:curator_chunk, document: document, sequence: 0, status: :embedded)
        create(:curator_embedding, chunk: chunk, embedding_model: "old-model")

        ENV["KB"] = kb.slug
        out, _err = silently { task.invoke }

        expect(out).to include("switching to :inline")
        expect(ActiveJob::Base.queue_adapter).to eq(original)
      end

      it "leaves :inline alone (no swap message; job enqueued exactly once)" do
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("inline")

        chunk = create(:curator_chunk, document: document, sequence: 0, status: :embedded)
        create(:curator_embedding, chunk: chunk, embedding_model: "old-model")

        ENV["KB"] = kb.slug
        out, _err = silently { task.invoke }

        expect(out).not_to include("switching to :inline")
        expect(Curator::EmbedChunksJob).to have_been_enqueued.with(document.id).exactly(:once)
      end
    end
  end

  describe "curator:reingest" do
    let(:task)     { Rake::Task["curator:reingest"] }
    let(:kb)       { create(:curator_knowledge_base) }
    let(:document) { create(:curator_document, knowledge_base: kb, status: :complete) }

    before { create(:curator_chunk, document: document, sequence: 0) }

    after do
      task.reenable
      ENV.delete("DOCUMENT")
    end

    it "aborts when DOCUMENT is missing" do
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end

    it "resets the document and re-enqueues the job" do
      ENV["DOCUMENT"] = document.id.to_s

      out, _err = silently { task.invoke }

      expect(out).to include("Re-enqueued ingest for document=#{document.id}")
      expect(document.reload.status).to eq("pending")
      # Chunk teardown is the job's responsibility now (Phase 5 moved it
      # out of `Curator.reingest` into `IngestDocumentJob#run_pipeline!`),
      # so it's covered there — not asserted here.
      expect(Curator::IngestDocumentJob).to have_been_enqueued.with(document.id)
    end

    it "raises ActiveRecord::RecordNotFound on an unknown document id" do
      ENV["DOCUMENT"] = "999999999"
      expect { silently { task.invoke } }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "curator:retrievals:export" do
    let(:task) { Rake::Task["curator:retrievals:export"] }
    let!(:kb)  { create(:curator_knowledge_base, slug: "exp-kb", is_default: false) }
    let!(:other_kb) { create(:curator_knowledge_base, slug: "other-kb", is_default: false) }
    let!(:retrieval) { create(:curator_retrieval, knowledge_base: kb, query: "alpha question") }
    let!(:other_retrieval) { create(:curator_retrieval, knowledge_base: other_kb, query: "delta question") }

    after do
      ENV.delete("FORMAT"); ENV.delete("KB"); ENV.delete("SINCE")
      task.reenable
    end

    it "writes CSV to STDOUT with FORMAT=csv" do
      ENV["FORMAT"] = "csv"
      out, _err = silently { task.invoke }

      expect(out.lines.first).to include("retrieval_id")
      expect(out).to include("alpha question")
      expect(out).to include("delta question")
    end

    it "filters by KB slug" do
      ENV["FORMAT"] = "csv"
      ENV["KB"]     = "exp-kb"
      out, _err = silently { task.invoke }

      expect(out).to include("alpha question")
      expect(out).not_to include("delta question")
    end

    it "writes a JSON document with FORMAT=json" do
      ENV["FORMAT"] = "json"
      out, _err = silently { task.invoke }

      parsed = JSON.parse(out)
      expect(parsed).to be_an(Array)
      expect(parsed.map { |r| r["query"] }).to contain_exactly("alpha question", "delta question")
    end

    it "aborts when FORMAT is missing or unsupported" do
      ENV["FORMAT"] = "xml"
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end
  end

  describe "curator:evaluations:export" do
    let(:task)      { Rake::Task["curator:evaluations:export"] }
    let!(:kb)       { create(:curator_knowledge_base, slug: "exp-kb", is_default: false) }
    let!(:other_kb) { create(:curator_knowledge_base, slug: "other-kb", is_default: false) }
    let!(:retrieval) { create(:curator_retrieval, knowledge_base: kb, query: "alpha question") }
    let!(:eval_row) do
      create(:curator_evaluation, retrieval: retrieval, rating: "negative",
                                  failure_categories: %w[hallucination])
    end

    after do
      ENV.delete("FORMAT"); ENV.delete("KB"); ENV.delete("SINCE")
      task.reenable
    end

    it "writes CSV to STDOUT with the documented column shape" do
      ENV["FORMAT"] = "csv"
      out, _err = silently { task.invoke }

      header = CSV.parse_line(out.lines.first)
      expect(header).to include("retrieval_id", "rating", "failure_categories")
      expect(out).to include("hallucination")
    end

    it "filters by KB slug" do
      other_retrieval = create(:curator_retrieval, knowledge_base: other_kb, query: "delta question")
      create(:curator_evaluation, retrieval: other_retrieval, rating: "positive")

      ENV["FORMAT"] = "csv"
      ENV["KB"]     = "exp-kb"
      out, _err = silently { task.invoke }

      expect(out).to include("alpha question")
      expect(out).not_to include("delta question")
    end

    it "writes a JSON document with FORMAT=json" do
      ENV["FORMAT"] = "json"
      out, _err = silently { task.invoke }

      parsed = JSON.parse(out)
      expect(parsed.first["failure_categories"]).to eq([ "hallucination" ])
    end

    it "aborts on bogus FORMAT" do
      ENV["FORMAT"] = "xml"
      expect { silently { task.invoke } }.to raise_error(SystemExit)
    end
  end
end
