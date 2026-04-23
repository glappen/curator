require "spec_helper"

# Shared contract every Curator extractor adapter must satisfy.
#
# Including specs must define:
#   let(:extractor) { ... instance ... }
#
# Contract targets the common text formats both Basic and Kreuzberg handle.
# Adapter-specific behavior (page data, PDF rejection, gem-missing errors)
# belongs in the adapter's own spec.
RSpec.shared_examples "a Curator extractor" do
  let(:fixture_dir) { File.expand_path("../../fixtures", __dir__) }

  {
    "sample.md"   => "text/markdown",
    "sample.csv"  => "text/csv",
    "sample.html" => "text/html"
  }.each do |filename, expected_mime|
    context "with #{filename}" do
      let(:path) { File.join(fixture_dir, filename) }
      let(:result) { extractor.extract(path) }

      it "returns an ExtractionResult" do
        expect(result).to be_a(Curator::Extractors::ExtractionResult)
      end

      it "produces non-empty content" do
        expect(result.content).to be_a(String)
        expect(result.content.strip).not_to be_empty
      end

      it "reports mime_type as #{expected_mime}" do
        expect(result.mime_type).to eq(expected_mime)
      end

      it "returns pages as an Array" do
        expect(result.pages).to be_an(Array)
      end
    end
  end
end
