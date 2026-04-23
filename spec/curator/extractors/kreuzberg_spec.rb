require "spec_helper"
require_relative "contract"

RSpec.describe Curator::Extractors::Kreuzberg do
  let(:extractor) { described_class.new }
  let(:fixture_dir) { File.expand_path("../../fixtures", __dir__) }

  if defined?(::Kreuzberg) || begin
    require "kreuzberg"; true
  rescue LoadError
    false
  end
    it_behaves_like "a Curator extractor"
  else
    pending "kreuzberg gem not installed — contract spec skipped"
  end

  describe "#extract" do
    it "passes path-only kwargs to kreuzberg when OCR is disabled (default)" do
      allow(::Kreuzberg).to receive(:extract_file_sync).and_return(
        double(content: "", mime_type: "text/plain", pages: nil)
      )
      extractor.extract("x.txt")
      expect(::Kreuzberg).to have_received(:extract_file_sync).with(path: "x.txt")
    end

    it "wraps low-level kreuzberg failures as Curator::ExtractionError" do
      allow(::Kreuzberg).to receive(:extract_file_sync).and_raise(RuntimeError, "boom")
      expect {
        extractor.extract("irrelevant.pdf")
      }.to raise_error(Curator::ExtractionError, /Kreuzberg extraction failed.*boom/)
    end

    it "normalizes pages into [{ page_number:, content: }] when present" do
      page_class = Struct.new(:page_number, :content)
      fake_result = double(
        "Kreuzberg::Result",
        content: "page one body\npage two body",
        mime_type: "application/pdf",
        pages: [
          page_class.new(1, "page one body"),
          page_class.new(2, "page two body")
        ]
      )
      allow(::Kreuzberg).to receive(:extract_file_sync).and_return(fake_result)

      result = extractor.extract("multi-page.pdf")
      expect(result).to be_a(Curator::Extractors::ExtractionResult)
      expect(result.mime_type).to eq("application/pdf")
      expect(result.pages).to eq([
        { page_number: 1, content: "page one body" },
        { page_number: 2, content: "page two body" }
      ])
    end

    it "returns pages: [] when kreuzberg reports no pages" do
      fake_result = double(
        "Kreuzberg::Result",
        content: "hello",
        mime_type: "text/markdown",
        pages: nil
      )
      allow(::Kreuzberg).to receive(:extract_file_sync).and_return(fake_result)
      expect(extractor.extract("x.md").pages).to eq([])
    end

    it "raises ExtractionError pointing at the Gemfile when kreuzberg isn't available" do
      hide_const("::Kreuzberg")
      allow(extractor).to receive(:require).with("kreuzberg").and_raise(LoadError)
      expect {
        extractor.extract("anything.pdf")
      }.to raise_error(Curator::ExtractionError, /gem "kreuzberg"/)
    end
  end

  describe "OCR configuration" do
    let(:fake_result) { double(content: "", mime_type: "application/pdf", pages: nil) }

    before do
      allow(::Kreuzberg).to receive(:extract_file_sync).and_return(fake_result)
    end

    it "builds a Kreuzberg::Config::Extraction with tesseract OCR when ocr: :tesseract" do
      described_class.new(ocr: :tesseract).extract("x.pdf")

      expect(::Kreuzberg).to have_received(:extract_file_sync) do |path:, config:|
        expect(path).to eq("x.pdf")
        expect(config).to be_a(::Kreuzberg::Config::Extraction)
        expect(config.ocr.backend).to eq("tesseract")
        expect(config.ocr.language).to eq("eng")
        expect(config.force_ocr).to be(false)
      end
    end

    it "treats ocr: true as :tesseract shorthand" do
      described_class.new(ocr: true).extract("x.pdf")
      expect(::Kreuzberg).to have_received(:extract_file_sync) do |config:, **|
        expect(config.ocr.backend).to eq("tesseract")
      end
    end

    it "passes ocr_language through to the OCR config" do
      described_class.new(ocr: :tesseract, ocr_language: "deu").extract("x.pdf")
      expect(::Kreuzberg).to have_received(:extract_file_sync) do |config:, **|
        expect(config.ocr.language).to eq("deu")
      end
    end

    it "passes force_ocr through without requiring an OCR backend" do
      described_class.new(force_ocr: true).extract("x.pdf")
      expect(::Kreuzberg).to have_received(:extract_file_sync) do |config:, **|
        expect(config.force_ocr).to be(true)
        expect(config.ocr).to be_nil
      end
    end

    it "supports :paddle backend" do
      described_class.new(ocr: :paddle).extract("x.pdf")
      expect(::Kreuzberg).to have_received(:extract_file_sync) do |config:, **|
        expect(config.ocr.backend).to eq("paddle")
      end
    end

    it "rejects unknown ocr values at construction time" do
      expect { described_class.new(ocr: :aws_textract) }.to raise_error(ArgumentError, /ocr must be one of/)
    end
  end

  describe "Gemfile placement" do
    it "declares kreuzberg only in the :development, :test group (never the gemspec)" do
      gemfile = File.read(File.expand_path("../../../Gemfile", __dir__))
      gemspec = File.read(File.expand_path("../../../curator-rails.gemspec", __dir__))

      expect(gemfile).to match(/group :development, :test.*gem "kreuzberg"/m)
      expect(gemspec).not_to include("kreuzberg")
    end
  end
end
