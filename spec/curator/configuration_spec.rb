require "spec_helper"

RSpec.describe Curator::Configuration do
  let(:config) { described_class.new }

  describe "defaults" do
    it "sets extractor to :kreuzberg" do
      expect(config.extractor).to eq(:kreuzberg)
    end

    it "sets trace_level to :full" do
      expect(config.trace_level).to eq(:full)
    end

    it "sets max_document_size to 50 megabytes" do
      expect(config.max_document_size).to eq(50.megabytes)
    end

    it "enables query logging" do
      expect(config.log_queries).to be(true)
    end

    it "sets llm_retry_count to 1" do
      expect(config.llm_retry_count).to eq(1)
    end

    it "leaves query_timeout unset" do
      expect(config.query_timeout).to be_nil
    end

    it "sets embedding_batch_size to 100" do
      expect(config.embedding_batch_size).to eq(100)
    end

    it "has no auth hook configured" do
      expect(config.authenticate_admin_with).to be_nil
    end

    it "disables OCR and force_ocr, defaulting ocr_language to eng" do
      expect(config.ocr).to be(false)
      expect(config.force_ocr).to be(false)
      expect(config.ocr_language).to eq("eng")
    end
  end

  describe "#ocr=" do
    it "accepts false, nil -> false" do
      config.ocr = true
      config.ocr = false
      expect(config.ocr).to be(false)

      config.ocr = true
      config.ocr = nil
      expect(config.ocr).to be(false)
    end

    it "maps true to :tesseract" do
      config.ocr = true
      expect(config.ocr).to eq(:tesseract)
    end

    it "accepts explicit backend symbols" do
      config.ocr = :tesseract
      expect(config.ocr).to eq(:tesseract)
      config.ocr = :paddle
      expect(config.ocr).to eq(:paddle)
    end

    it "rejects unknown values" do
      expect { config.ocr = :aws_textract }.to raise_error(ArgumentError, /ocr must be one of/)
      expect { config.ocr = "tesseract" }.to raise_error(ArgumentError, /ocr must be one of/)
    end
  end

  describe "#extractor=" do
    it "accepts valid values" do
      config.extractor = :basic
      expect(config.extractor).to eq(:basic)
    end

    it "rejects unknown extractors" do
      expect { config.extractor = :unknown }.to raise_error(ArgumentError, /extractor must be one of/)
    end
  end

  describe "#trace_level=" do
    it "accepts :full, :summary, :off" do
      Curator::Configuration::TRACE_LEVELS.each do |level|
        config.trace_level = level
        expect(config.trace_level).to eq(level)
      end
    end

    it "rejects unknown levels" do
      expect { config.trace_level = :verbose }.to raise_error(ArgumentError, /trace_level must be one of/)
    end
  end

  describe "#authenticate_admin_with" do
    it "stores a block and returns it on subsequent calls without args" do
      block = -> { "admin auth" }
      config.authenticate_admin_with(&block)
      expect(config.authenticate_admin_with).to eq(block)
    end

    it "returns nil before a block is provided" do
      expect(config.authenticate_admin_with).to be_nil
    end
  end
end

RSpec.describe "Curator module configuration" do
  around do |example|
    Curator.reset_config!
    example.run
    Curator.reset_config!
  end

  it "exposes a memoized Curator.config" do
    first = Curator.config
    second = Curator.config
    expect(first).to be_a(Curator::Configuration)
    expect(first).to equal(second)
  end

  it "yields the configuration to Curator.configure" do
    yielded = nil
    Curator.configure { |c| yielded = c }
    expect(yielded).to equal(Curator.config)
  end

  it "persists values set inside the configure block" do
    Curator.configure do |c|
      c.max_document_size = 10.megabytes
      c.trace_level       = :summary
    end
    expect(Curator.config.max_document_size).to eq(10.megabytes)
    expect(Curator.config.trace_level).to eq(:summary)
  end

  it "persists a block-valued auth hook through configure" do
    block = -> { "custom auth" }
    Curator.configure do |c|
      c.authenticate_admin_with(&block)
    end
    expect(Curator.config.authenticate_admin_with).to eq(block)
  end
end
