module Curator
  module Extractors
    # Value object returned by every extractor adapter.
    #
    # - `content`   : String of extracted text.
    # - `mime_type` : Canonical MIME string ("text/markdown", "application/pdf", ...).
    # - `pages`     : Array of `{ page_number:, char_start:, char_end: }` hashes
    #                 mapping page boundaries into `content`. Empty for adapters
    #                 (like Basic) that don't expose page structure.
    class ExtractionResult
      attr_reader :content, :mime_type, :pages

      def initialize(content:, mime_type:, pages: [])
        @content   = content
        @mime_type = mime_type
        @pages     = pages.freeze
        freeze
      end
    end
  end
end
