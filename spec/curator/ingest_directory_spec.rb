require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Curator, ".ingest_directory" do
  include ActiveJob::TestHelper

  let(:kb) { create(:curator_knowledge_base) }

  before { Curator.configure { |c| c.extractor = :basic } }
  after  { Curator.reset_config! }

  def write(dir, relative, content)
    full = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
    full
  end

  it "ingests files matching the extractor's default extension list and returns IngestResults in walk order" do
    Dir.mktmpdir do |dir|
      write(dir, "a.md",          "# a\n")
      write(dir, "b.csv",         "x,y\n1,2\n")
      write(dir, "nested/c.html", "<p>c</p>")
      write(dir, "ignored.pdf",   "%PDF-fake")
      write(dir, ".DS_Store",     "junk")

      results = Curator.ingest_directory(dir, knowledge_base: kb)

      expect(results.map(&:status)).to all(eq(:created))
      titles = results.map { |r| r.document.title }
      expect(titles).to contain_exactly("a.md", "b.csv", "c.html")
    end
  end

  it "skips hidden files (leading dot) at any depth" do
    Dir.mktmpdir do |dir|
      write(dir, "visible.md",      "# v\n")
      write(dir, ".hidden.md",      "# h\n")
      write(dir, ".cache/inner.md", "# inside hidden dir\n")

      results = Curator.ingest_directory(dir, knowledge_base: kb)

      expect(results.map { |r| r.document.title }).to eq([ "visible.md" ])
    end
  end

  it "skips symlinks" do
    Dir.mktmpdir do |dir|
      write(dir, "real.md", "# r\n")
      File.symlink(File.join(dir, "real.md"), File.join(dir, "alias.md"))

      results = Curator.ingest_directory(dir, knowledge_base: kb)
      expect(results.map { |r| r.document.title }).to eq([ "real.md" ])
    end
  end

  it "honors an explicit pattern: kwarg" do
    Dir.mktmpdir do |dir|
      write(dir, "a.md",  "# a\n")
      write(dir, "b.csv", "x,y\n")

      results = Curator.ingest_directory(dir, knowledge_base: kb, pattern: "**/*.md")
      expect(results.map { |r| r.document.title }).to eq([ "a.md" ])
    end
  end

  it "limits the walk to the top level when recursive: false" do
    Dir.mktmpdir do |dir|
      write(dir, "top.md",         "# t\n")
      write(dir, "sub/nested.md",  "# n\n")

      results = Curator.ingest_directory(dir, knowledge_base: kb, recursive: false)
      expect(results.map { |r| r.document.title }).to eq([ "top.md" ])
    end
  end

  it "returns :duplicate on a second run over the same tree" do
    Dir.mktmpdir do |dir|
      write(dir, "a.md", "# a\n")
      write(dir, "b.md", "# b\n")

      Curator.ingest_directory(dir, knowledge_base: kb)
      results = Curator.ingest_directory(dir, knowledge_base: kb)

      expect(results.map(&:status)).to eq(%i[duplicate duplicate])
    end
  end

  it "captures per-file failures as IngestResult(:failed) without aborting the walk" do
    Dir.mktmpdir do |dir|
      write(dir, "ok.md",  "# ok\n")
      write(dir, "bad.md", "# bad\n")

      call_count = 0
      original   = Curator.method(:ingest)
      allow(Curator).to receive(:ingest) do |input, **kwargs|
        call_count += 1
        if input.to_s.end_with?("bad.md")
          raise Curator::ExtractionError, "boom"
        else
          original.call(input, **kwargs)
        end
      end

      results = Curator.ingest_directory(dir, knowledge_base: kb)

      expect(call_count).to eq(2)
      statuses = results.map(&:status)
      expect(statuses.sort).to eq(%i[created failed])
      failed = results.find(&:failed?)
      expect(failed.reason).to include("Curator::ExtractionError", "boom")
      expect(failed.document).to be_nil
    end
  end

  it "expands ~ and other shell-ish path forms before walking " \
     "(regression: bash doesn't expand tilde inside DIR=~/pdfs rake args)" do
    Dir.mktmpdir do |dir|
      write(dir, "a.md", "# a\n")

      # Stub HOME so `~` expands to our tmpdir without touching the real home.
      original_home = ENV["HOME"]
      ENV["HOME"] = dir
      begin
        results = Curator.ingest_directory("~", knowledge_base: kb)
        expect(results.map(&:status)).to eq([ :created ])
        expect(results.first.document.title).to eq("a.md")
      ensure
        ENV["HOME"] = original_home
      end
    end
  end

  it "raises ArgumentError when the path is not a directory" do
    expect {
      Curator.ingest_directory("/nonexistent/curator-test-#{SecureRandom.hex(4)}",
                               knowledge_base: kb)
    }.to raise_error(ArgumentError, /not a directory/)
  end

  it "resolves knowledge_base: from a slug string" do
    kb # realize
    Dir.mktmpdir do |dir|
      write(dir, "a.md", "# a\n")
      results = Curator.ingest_directory(dir, knowledge_base: kb.slug)
      expect(results.first).to be_created
      expect(results.first.document.knowledge_base).to eq(kb)
    end
  end

  it "uses the kreuzberg extension list when config.extractor = :kreuzberg" do
    Curator.configure { |c| c.extractor = :kreuzberg }
    Dir.mktmpdir do |dir|
      write(dir, "a.md",  "# a\n")
      write(dir, "b.pdf", "%PDF-fake")

      # We don't actually want to invoke the kreuzberg adapter — just verify
      # the glob picks up a .pdf which the basic extractor would skip.
      seen = []
      allow(Curator).to receive(:ingest) do |input, **|
        seen << File.basename(input.to_s)
        Curator::IngestResult.new(document: nil, status: :failed, reason: "stub")
      end

      Curator.ingest_directory(dir, knowledge_base: kb)
      expect(seen.sort).to eq(%w[a.md b.pdf])
    end
  end
end
