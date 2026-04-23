module Curator
  # Char-based heuristic token counter. A dependency-free stand-in for
  # tiktoken-style counters — close enough for chunk sizing where absolute
  # token accuracy doesn't matter, and swappable later if it does.
  #
  # The ratio (~4 chars per token) is OpenAI's published rule of thumb for
  # English prose. For code or non-Latin scripts it's looser, but chunk
  # boundaries don't need to be exact.
  module TokenCounter
    CHARS_PER_TOKEN = 4

    module_function

    def count(text)
      return 0 if text.nil? || text.empty?
      (text.length.to_f / CHARS_PER_TOKEN).ceil
    end
  end
end
