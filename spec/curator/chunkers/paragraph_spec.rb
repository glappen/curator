require "spec_helper"

RSpec.describe Curator::Chunkers::Paragraph do
  let(:ratio) { Curator::TokenCounter::CHARS_PER_TOKEN }

  def extraction(content, pages: [])
    Curator::Extractors::ExtractionResult.new(
      content: content, mime_type: "text/plain", pages: pages
    )
  end

  describe "#initialize" do
    it "rejects non-positive chunk_size" do
      expect { described_class.new(chunk_size: 0, chunk_overlap: 0) }
        .to raise_error(ArgumentError, /chunk_size/)
      expect { described_class.new(chunk_size: -1, chunk_overlap: 0) }
        .to raise_error(ArgumentError, /chunk_size/)
    end

    it "rejects chunk_overlap >= chunk_size or negative" do
      expect { described_class.new(chunk_size: 10, chunk_overlap: 10) }
        .to raise_error(ArgumentError, /chunk_overlap/)
      expect { described_class.new(chunk_size: 10, chunk_overlap: -1) }
        .to raise_error(ArgumentError, /chunk_overlap/)
    end
  end

  describe "#chunk — packing" do
    it "packs paragraphs smaller than chunk_size into one chunk until the next would overflow" do
      # chunk_size=10 tokens (~40 chars). Three 20-char paragraphs:
      # the first two pack together (joined with \n\n → 42 chars ≈ 11 tokens,
      # already over on its own; use three smaller paragraphs instead)
      para = "a" * 12 # 12 chars = 3 tokens
      content = [ para, para, para, para, para ].join("\n\n")
      chunker = described_class.new(chunk_size: 10, chunk_overlap: 0)

      chunks = chunker.chunk(extraction(content))

      # Each paragraph = 3 tokens, joined with "\n\n" (~0 extra tokens).
      # We can fit 3 paragraphs (≈ 9 tokens joined) per chunk before the
      # 4th would push past 10.
      expect(chunks.size).to be >= 2
      chunks.each { |c| expect(c[:token_count]).to be <= 12 }
    end

    it "splits a single paragraph larger than chunk_size at char boundaries" do
      # chunk_size=10 tokens = 40 chars target. One 100-char paragraph.
      content = "a" * 100
      chunker = described_class.new(chunk_size: 10, chunk_overlap: 0)

      chunks = chunker.chunk(extraction(content))

      # Expect (100 / 40).ceil = 3 chunks: 40 + 40 + 20.
      expect(chunks.size).to eq(3)
      expect(chunks[0][:content].length).to eq(40)
      expect(chunks[1][:content].length).to eq(40)
      expect(chunks[2][:content].length).to eq(20)
      expect(chunks[0][:char_start]).to eq(0)
      expect(chunks[0][:char_end]).to eq(40)
      expect(chunks[1][:char_start]).to eq(40)
      expect(chunks[2][:char_start]).to eq(80)
      expect(chunks[2][:char_end]).to eq(100)
    end

    it "snaps char-split boundaries to whitespace when possible (no mid-word cuts)" do
      # Ten-letter words joined by spaces, one long paragraph, forced to
      # char-split. Every slice should end at a whitespace — i.e., no
      # slice ends with a partial word (letters with no trailing space).
      word = "abcdefghij"
      content = ([ word ] * 100).join(" ")

      chunker = described_class.new(chunk_size: 100, chunk_overlap: 0)
      chunks  = chunker.chunk(extraction(content))

      expect(chunks.size).to be >= 2
      # All but the final slice should end at a whitespace char.
      chunks[0..-2].each do |c|
        expect(c[:content][-1]).to match(/\s/),
          "char-split slice ended mid-word: #{c[:content][-20..].inspect}"
      end
    end

    it "produces a deterministic chunk count for chunk_size=100, chunk_overlap=10 on a 1000-char input" do
      content = "a" * 1000
      chunker = described_class.new(chunk_size: 100, chunk_overlap: 10)

      chunks = chunker.chunk(extraction(content))

      # chunk_size=100 tokens = 400 chars. char_split: 400 + 400 + 200 = 3.
      expect(chunks.size).to eq(3)
    end
  end

  describe "#chunk — overlap" do
    it "prepends roughly chunk_overlap tokens' worth of chars from the previous chunk" do
      content = "a" * 1000
      overlap = 10
      chunker = described_class.new(chunk_size: 100, chunk_overlap: overlap)

      chunks = chunker.chunk(extraction(content))
      expect(chunks.size).to be >= 2

      expected_prefix_chars = overlap * ratio # 40
      chunks.each_cons(2) do |prev, curr|
        # Overlap spec: first N chars of `curr` should match the last N chars of `prev`.
        prefix = curr[:content][0, expected_prefix_chars]
        tail   = prev[:content][-expected_prefix_chars, expected_prefix_chars]
        expect(prefix).to eq(tail)
      end
    end

    it "applies no overlap when chunk_overlap is 0" do
      content = "a" * 1000
      chunker = described_class.new(chunk_size: 100, chunk_overlap: 0)

      chunks = chunker.chunk(extraction(content))

      expect(chunks.map { |c| c[:content].length }).to eq([ 400, 400, 200 ])
    end

    it "snaps the overlap prefix to a word boundary when one is nearby" do
      # One paragraph exceeds the effective budget, forcing a char-split —
      # the cut point lands inside a word. The overlap prefix for the
      # next chunk should begin at the next word, not mid-word.
      word = "abcdefghij" # 10 chars, no spaces within
      content = ([ word ] * 100).join(" ") # 100 words * (10+1) - 1 = 1099 chars

      chunker = described_class.new(chunk_size: 100, chunk_overlap: 10)
      chunks  = chunker.chunk(extraction(content))

      expect(chunks.size).to be >= 2
      # Every chunk past the first starts with either a word char or
      # whitespace — never a partial-word tail from the previous chunk.
      chunks[1..].each do |c|
        first_char = c[:content][0]
        prior_char_of_the_word = c[:content][/\A\S+/]
        # The content should start with a whole word (or leading whitespace).
        expect(first_char).to satisfy { |ch| ch == " " || c[:content].start_with?(word) || prior_char_of_the_word == word }
      end
    end

    it "keeps every chunk's token_count <= chunk_size even after overlap is prepended" do
      # Mix of a tiny paragraph, a paragraph exactly at chunk_size, and two
      # near-chunk_size paragraphs — the shape that used to push chunks
      # past chunk_size when overlap was layered on top of already-full packs.
      small    = "a" * 100                      # 25 tokens
      at_limit = "b" * 2048                     # 512 tokens — exactly chunk_size
      big_1    = "c" * 2000                     # 500 tokens
      big_2    = "d" * 2000                     # 500 tokens
      content  = [ small, at_limit, big_1, big_2 ].join("\n\n")

      chunker = described_class.new(chunk_size: 512, chunk_overlap: 50)
      chunks  = chunker.chunk(extraction(content))

      chunks.each do |c|
        expect(c[:token_count]).to be <= 512,
          "chunk exceeded chunk_size: token_count=#{c[:token_count]}, content.length=#{c[:content].length}"
      end
    end
  end

  describe "#chunk — pages" do
    it "sets page_number by binary-searching the page map" do
      page1 = "a" * 50
      page2 = "b" * 50
      page3 = "c" * 50
      content = [ page1, page2, page3 ].join("\n\n")
      pages = [
        { page_number: 1, content: page1 },
        { page_number: 2, content: page2 },
        { page_number: 3, content: page3 }
      ]
      chunker = described_class.new(chunk_size: 10, chunk_overlap: 0)

      chunks = chunker.chunk(extraction(content, pages: pages))

      # Each paragraph is 50 chars = 13 tokens, > chunk_size → char-split.
      # Within each paragraph, chunks carry that paragraph's page number.
      expect(chunks.map { |c| c[:page_number] }).to all(be_between(1, 3))

      first_chunk_of_page = chunks.find { |c| c[:content].start_with?("a") }
      expect(first_chunk_of_page[:page_number]).to eq(1)

      first_b_chunk = chunks.find { |c| c[:content].start_with?("b") }
      expect(first_b_chunk[:page_number]).to eq(2)

      first_c_chunk = chunks.find { |c| c[:content].start_with?("c") }
      expect(first_c_chunk[:page_number]).to eq(3)
    end

    it "returns page_number nil for every chunk when pages is empty (Basic extractor)" do
      content = "a" * 1000
      chunker = described_class.new(chunk_size: 100, chunk_overlap: 10)

      chunks = chunker.chunk(extraction(content, pages: []))

      expect(chunks.size).to be > 1
      expect(chunks.map { |c| c[:page_number] }).to all(be_nil)
    end
  end

  describe "#chunk — output shape" do
    it "returns hashes with content, token_count, char_start, char_end, page_number" do
      chunker = described_class.new(chunk_size: 10, chunk_overlap: 0)
      chunks = chunker.chunk(extraction("hello"))

      expect(chunks).to be_an(Array)
      expect(chunks.first.keys).to contain_exactly(
        :content, :token_count, :char_start, :char_end, :page_number
      )
    end

    it "reports accurate char_start/char_end offsets against the source content" do
      p1 = "a" * 20
      p2 = "b" * 20
      content = "#{p1}\n\n#{p2}"
      chunker = described_class.new(chunk_size: 100, chunk_overlap: 0)

      chunks = chunker.chunk(extraction(content))

      expect(chunks.size).to eq(1)
      expect(chunks.first[:char_start]).to eq(0)
      expect(chunks.first[:char_end]).to eq(content.length)
    end

    it "returns [] for empty content" do
      chunker = described_class.new(chunk_size: 10, chunk_overlap: 0)
      expect(chunker.chunk(extraction(""))).to eq([])
    end
  end
end
