require "curator/token_counter"

module Curator
  module Chunkers
    # Greedy paragraph-packing chunker.
    #
    # Splits content on blank-line paragraph boundaries, then packs
    # paragraphs into chunks until the next paragraph would push the
    # running total past an *effective* budget of
    # `chunk_size - chunk_overlap` tokens (measured via
    # `Curator::TokenCounter`). Paragraphs larger than the effective
    # budget fall through to a char-level split at
    # `(chunk_size - chunk_overlap) * CHARS_PER_TOKEN` char targets.
    # Overlap is applied post-pack as a char-count prefix from the prior
    # chunk's tail. Budgeting against `chunk_size - chunk_overlap` (not
    # `chunk_size`) keeps the final, post-overlap chunk at or under
    # `chunk_size` tokens — otherwise overlap silently inflates every
    # chunk past the budget.
    #
    # Pages from `ExtractionResult#pages` are consumed as metadata only —
    # they don't force chunk splits. Each emitted chunk's `page_number`
    # is the page its first "new" (non-overlap) char falls on, derived by
    # binary-searching a `[[char_offset, page_number], ...]` map built
    # from the pages array.
    #
    # Returns `Array<Hash>` with keys: `content`, `token_count`,
    # `char_start`, `char_end`, `page_number`. The `page_number` is
    # `nil` when `pages` is empty (e.g. the Basic extractor).
    class Paragraph
      PARAGRAPH_SEP = /\n\s*\n/

      # When splitting inside a paragraph — either for char-split of an
      # oversized paragraph or when carving out an overlap prefix — the
      # nominal cut point may land mid-word. Snap to the nearest
      # whitespace within a tolerance window of the nominal position.
      # The tolerance is a small percentage of the target length, capped
      # so long chunks don't search excessively; if no whitespace is
      # found in-window, the exact char boundary is kept (e.g. for
      # content with no whitespace at all, like a long base64 blob).
      BOUNDARY_TOLERANCE_RATIO = 0.20
      BOUNDARY_TOLERANCE_CAP   = 64

      def initialize(chunk_size:, chunk_overlap:)
        unless chunk_size.is_a?(Integer) && chunk_size.positive?
          raise ArgumentError, "chunk_size must be a positive Integer (got #{chunk_size.inspect})"
        end
        unless chunk_overlap.is_a?(Integer) && chunk_overlap >= 0 && chunk_overlap < chunk_size
          raise ArgumentError,
                "chunk_overlap must be a non-negative Integer < chunk_size (got #{chunk_overlap.inspect})"
        end

        @chunk_size     = chunk_size
        @chunk_overlap  = chunk_overlap
        @effective_size = chunk_size - chunk_overlap
      end

      def chunk(extraction_result)
        content   = extraction_result.content
        page_map  = build_page_map(content, extraction_result.pages)

        packed    = pack(content)
        with_over = apply_overlap(packed)

        with_over.map do |text, char_start, char_end|
          {
            content:     text,
            token_count: TokenCounter.count(text),
            char_start:  char_start,
            char_end:    char_end,
            page_number: page_for(char_start, page_map)
          }
        end
      end

      private

      # Returns Array<[text, char_start, char_end]>.
      def pack(content)
        chunks        = []
        buffer        = []
        buffer_tokens = 0

        paragraphs_with_offsets(content).each do |para, start|
          tokens = TokenCounter.count(para)

          if tokens > @effective_size
            flush(chunks, buffer) unless buffer.empty?
            buffer = []
            buffer_tokens = 0
            chunks.concat(char_split(para, start))
            next
          end

          if !buffer.empty? && buffer_tokens + tokens > @effective_size
            flush(chunks, buffer)
            buffer = []
            buffer_tokens = 0
          end

          buffer << [ para, start, start + para.length ]
          buffer_tokens += tokens
        end

        flush(chunks, buffer) unless buffer.empty?
        chunks
      end

      def flush(chunks, buffer)
        text = buffer.map(&:first).join("\n\n")
        chunks << [ text, buffer.first[1], buffer.last[2] ]
      end

      def char_split(text, base_offset)
        target    = @effective_size * TokenCounter::CHARS_PER_TOKEN
        tolerance = boundary_tolerance(target)
        result    = []
        offset    = 0

        while offset < text.length
          remaining = text.length - offset
          if remaining <= target
            result << [ text[offset..], base_offset + offset, base_offset + text.length ]
            break
          end

          nominal = offset + target
          split_at = snap_back_to_whitespace(text, nominal, tolerance, floor: offset + 1) || nominal
          result << [ text[offset...split_at], base_offset + offset, base_offset + split_at ]
          offset = split_at
        end

        result
      end

      def apply_overlap(chunks)
        return chunks if @chunk_overlap.zero? || chunks.length < 2

        overlap_chars = @chunk_overlap * TokenCounter::CHARS_PER_TOKEN
        tolerance     = boundary_tolerance(overlap_chars)
        result        = [ chunks.first ]

        chunks[1..].each do |text, cs, ce|
          prev_text, = result.last
          nominal_start = [ prev_text.length - overlap_chars, 0 ].max
          start = snap_forward_to_word_start(prev_text, nominal_start, tolerance)
          prefix = prev_text[start..] || ""
          result << [ prefix + text, cs, ce ]
        end

        result
      end

      def boundary_tolerance(target)
        [ (target * BOUNDARY_TOLERANCE_RATIO).ceil, BOUNDARY_TOLERANCE_CAP ].min
      end

      # Walk `pos` backward to just after the nearest whitespace within
      # `tolerance` chars. Returns the snapped position, or nil if no
      # whitespace was found in-window (caller falls back to `pos`).
      # `floor:` prevents the snap from collapsing a slice to zero width.
      def snap_back_to_whitespace(text, pos, tolerance, floor: 0)
        window_start = [ pos - tolerance, floor ].max
        return nil if pos <= window_start
        idx = text.rindex(/\s/, pos - 1)
        return nil if idx.nil? || idx < window_start
        idx + 1
      end

      # If `pos` lands mid-word, nudge forward to just after the next
      # whitespace within `tolerance` chars. Returns the snapped position,
      # or `pos` unchanged if it's already at a word start or no
      # whitespace is found in-window.
      def snap_forward_to_word_start(text, pos, tolerance)
        return pos if pos <= 0 || pos >= text.length
        return pos if text[pos - 1] =~ /\s/
        window_end = [ pos + tolerance, text.length ].min
        idx = text.index(/\s/, pos)
        return pos if idx.nil? || idx >= window_end
        idx + 1
      end

      # Returns Array<[paragraph_text, char_start]>. Whitespace-only
      # "paragraphs" (e.g. runs between separators that the separator
      # regex didn't swallow) are skipped but still advance the cursor.
      def paragraphs_with_offsets(content)
        results = []
        pos     = 0

        content.split(/(\n\s*\n)/, -1).each do |part|
          if part.empty?
            next
          elsif part.match?(/\A\n\s*\n\z/) || part.strip.empty?
            pos += part.length
          else
            results << [ part, pos ]
            pos += part.length
          end
        end

        results
      end

      def build_page_map(content, pages)
        return [] if pages.nil? || pages.empty?

        map    = []
        cursor = 0
        pages.each do |page|
          idx = content.index(page[:content], cursor) || cursor
          map << [ idx, page[:page_number] ]
          cursor = idx + page[:content].length
        end
        map
      end

      # Binary search for the largest map entry whose offset <= target.
      def page_for(offset, page_map)
        return nil if page_map.empty?

        lo = 0
        hi = page_map.length - 1
        found = nil
        while lo <= hi
          mid = (lo + hi) / 2
          if page_map[mid][0] <= offset
            found = page_map[mid][1]
            lo = mid + 1
          else
            hi = mid - 1
          end
        end
        found
      end
    end
  end
end
