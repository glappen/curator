require "spec_helper"
require "tempfile"
require_relative "contract"

RSpec.describe Curator::Extractors::Basic do
  let(:extractor) { described_class.new }
  let(:fixture_dir) { File.expand_path("../../fixtures", __dir__) }

  it_behaves_like "a Curator extractor"

  describe "#extract" do
    it "always returns pages: [] (Basic has no page metadata)" do
      result = extractor.extract(File.join(fixture_dir, "sample.md"))
      expect(result.pages).to eq([])
    end

    it "strips HTML tags from text/html input" do
      result = extractor.extract(File.join(fixture_dir, "sample.html"))
      expect(result.content).to include("Hello, Curator")
      expect(result.content).to include("alpha")
      expect(result.content).not_to match(/<\w+/)
    end

    it "raises UnsupportedMimeError on .pdf, pointing at Kreuzberg" do
      expect {
        extractor.extract(File.join(fixture_dir, "sample.pdf"))
      }.to raise_error(Curator::UnsupportedMimeError, /config\.extractor = :kreuzberg/)
    end

    it "raises UnsupportedMimeError on an extension it doesn't know" do
      Tempfile.create([ "weird", ".xyz" ]) do |f|
        f.write("whatever")
        f.close
        expect { extractor.extract(f.path) }.to raise_error(Curator::UnsupportedMimeError)
      end
    end
  end

  describe Curator::Extractors::ExtractionResult do
    it "is frozen with attr_readers for content, mime_type, pages" do
      result = Curator::Extractors::ExtractionResult.new(
        content: "hi", mime_type: "text/plain", pages: []
      )
      expect(result).to be_frozen
      expect(result.content).to eq("hi")
      expect(result.mime_type).to eq("text/plain")
      expect(result.pages).to eq([])
    end
  end
end
