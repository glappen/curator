require "rails_helper"
require "tempfile"

RSpec.describe Curator::FileNormalizer do
  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }
  let(:md_path)     { fixture_dir.join("sample.md") }

  describe ".call" do
    it "normalizes a String path" do
      n = described_class.call(md_path.to_s)
      expect(n.filename).to eq("sample.md")
      expect(n.mime_type).to eq("text/markdown")
      expect(n.bytes).to eq(md_path.binread)
      expect(n.byte_size).to eq(md_path.size)
    end

    it "normalizes a Pathname" do
      n = described_class.call(md_path)
      expect(n.filename).to eq("sample.md")
      expect(n.mime_type).to eq("text/markdown")
    end

    it "normalizes an ActiveStorage::Blob" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("hello world"),
        filename: "hi.txt",
        content_type: "text/plain"
      )
      n = described_class.call(blob)
      expect(n.filename).to eq("hi.txt")
      expect(n.mime_type).to eq("text/plain")
      expect(n.bytes).to eq("hello world")
    end

    it "normalizes an ActionDispatch::Http::UploadedFile" do
      tempfile = Tempfile.new([ "upload", ".md" ])
      tempfile.write("# Hello\n")
      tempfile.rewind
      uploaded = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: "note.md",
        type: "text/markdown"
      )

      n = described_class.call(uploaded)
      expect(n.filename).to eq("note.md")
      expect(n.mime_type).to eq("text/markdown")
      expect(n.bytes).to eq("# Hello\n")
    ensure
      tempfile&.close!
    end

    it "normalizes a File handle and derives the filename from its path" do
      File.open(md_path) do |f|
        n = described_class.call(f)
        expect(n.filename).to eq("sample.md")
        expect(n.mime_type).to eq("text/markdown")
      end
    end

    it "normalizes a StringIO when filename: is passed" do
      io = StringIO.new("plain body")
      n = described_class.call(io, filename: "notes.txt")
      expect(n.filename).to eq("notes.txt")
      expect(n.mime_type).to eq("text/plain")
      expect(n.bytes).to eq("plain body")
    end

    it "raises ArgumentError for anonymous IO without a filename" do
      expect {
        described_class.call(StringIO.new("xxx"))
      }.to raise_error(ArgumentError, /filename/)
    end

    it "raises ArgumentError for unsupported inputs" do
      expect {
        described_class.call(12_345)
      }.to raise_error(ArgumentError, /cannot normalize/)
    end

    it "honors an explicit filename: override for String paths" do
      n = described_class.call(md_path.to_s, filename: "renamed.md")
      expect(n.filename).to eq("renamed.md")
    end
  end
end
