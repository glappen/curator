require "rails_helper"

RSpec.describe Curator::UrlFetcher do
  describe ".call" do
    it "returns bytes, filename, mime_type, and final_url on 200" do
      stub_request(:get, "https://example.com/doc.md")
        .to_return(
          status: 200,
          body: "# hello\n",
          headers: { "Content-Type" => "text/markdown; charset=utf-8" }
        )

      result = described_class.call("https://example.com/doc.md", max_bytes: 1_000)
      expect(result.bytes).to eq("# hello\n")
      expect(result.filename).to eq("doc.md")
      expect(result.mime_type).to eq("text/markdown")
      expect(result.final_url).to eq("https://example.com/doc.md")
    end

    it "prefers Content-Disposition filename over the URL path" do
      stub_request(:get, "https://example.com/download")
        .to_return(
          status: 200,
          body: "pdf bytes",
          headers: {
            "Content-Type" => "application/pdf",
            "Content-Disposition" => 'attachment; filename="report.pdf"'
          }
        )

      result = described_class.call("https://example.com/download", max_bytes: 1_000)
      expect(result.filename).to eq("report.pdf")
    end

    it "falls back to 'download' when the URL path is empty" do
      stub_request(:get, "https://example.com/")
        .to_return(status: 200, body: "x", headers: { "Content-Type" => "text/plain" })

      result = described_class.call("https://example.com/", max_bytes: 1_000)
      expect(result.filename).to eq("download")
    end

    it "follows redirects and reports the final URL" do
      stub_request(:get, "https://example.com/old")
        .to_return(status: 302, headers: { "Location" => "https://example.com/new" })
      stub_request(:get, "https://example.com/new")
        .to_return(status: 200, body: "moved", headers: { "Content-Type" => "text/plain" })

      result = described_class.call("https://example.com/old", max_bytes: 1_000)
      expect(result.bytes).to eq("moved")
      expect(result.final_url).to eq("https://example.com/new")
    end

    it "raises FetchError after too many redirects" do
      stub_request(:get, "https://example.com/loop")
        .to_return(status: 302, headers: { "Location" => "https://example.com/loop" })

      expect {
        described_class.call("https://example.com/loop", max_bytes: 1_000)
      }.to raise_error(Curator::FetchError, /too many redirects/)
    end

    it "raises FetchError on a non-2xx, non-redirect response" do
      stub_request(:get, "https://example.com/missing").to_return(status: 404)

      expect {
        described_class.call("https://example.com/missing", max_bytes: 1_000)
      }.to raise_error(Curator::FetchError, /404/)
    end

    it "raises FileTooLargeError when the body exceeds max_bytes" do
      stub_request(:get, "https://example.com/big")
        .to_return(status: 200, body: "a" * 2_000, headers: { "Content-Type" => "text/plain" })

      expect {
        described_class.call("https://example.com/big", max_bytes: 1_000)
      }.to raise_error(Curator::FileTooLargeError)
    end

    it "rejects non-http(s) URLs with ArgumentError" do
      expect {
        described_class.call("file:///etc/passwd", max_bytes: 1_000)
      }.to raise_error(ArgumentError, /http\(s\)/)
    end

    it "wraps socket-level errors as FetchError" do
      stub_request(:get, "https://example.com/unreachable").to_raise(SocketError.new("nope"))

      expect {
        described_class.call("https://example.com/unreachable", max_bytes: 1_000)
      }.to raise_error(Curator::FetchError, /SocketError/)
    end
  end
end
