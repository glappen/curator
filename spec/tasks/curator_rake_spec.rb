require "rails_helper"
require "rake"
require "tmpdir"
require "fileutils"

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

    it "deletes existing chunks, resets the document, and re-enqueues the job" do
      ENV["DOCUMENT"] = document.id.to_s

      out, _err = silently { task.invoke }

      expect(out).to include("Re-enqueued ingest for document=#{document.id}")
      expect(document.reload.status).to eq("pending")
      expect(document.chunks).to be_empty
      expect(Curator::IngestDocumentJob).to have_been_enqueued.with(document.id)
    end

    it "raises ActiveRecord::RecordNotFound on an unknown document id" do
      ENV["DOCUMENT"] = "999999999"
      expect { silently { task.invoke } }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
