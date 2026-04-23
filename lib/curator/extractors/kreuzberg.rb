module Curator
  module Extractors
    # Adapter over the `kreuzberg` gem (a soft dependency). Handles 50+
    # formats including PDF, Office, and image OCR.
    #
    # The `kreuzberg` gem is NOT declared in curator-rails.gemspec — host
    # apps that want Kreuzberg support add it themselves. This adapter
    # lazy-requires the gem on first use so loading curator.rb never fails
    # for apps that only use the Basic extractor.
    class Kreuzberg
      MISSING_GEM_MESSAGE =
        "Extractor :kreuzberg requires the kreuzberg gem — " \
        "add `gem \"kreuzberg\"` to your Gemfile."

      OCR_BACKENDS = %i[tesseract paddle].freeze

      # Canonicalize an OCR setting from one of the accepted shapes:
      #   - false / nil   -> false (OCR off)
      #   - true          -> :tesseract (default backend)
      #   - :tesseract / :paddle -> the literal backend
      # Shared by Configuration#ocr= so the validation rules live in one place.
      def self.normalize_ocr(value)
        case value
        when false, nil       then false
        when true             then :tesseract
        when *OCR_BACKENDS    then value
        else
          raise ArgumentError,
                "ocr must be one of false, true, #{OCR_BACKENDS.map(&:inspect).join(', ')} (got #{value.inspect})"
        end
      end

      # @param ocr [false, true, :tesseract, :paddle]
      #   OCR backend to use. `false` disables OCR entirely, `true` is
      #   shorthand for `:tesseract`. The chosen backend must be installed
      #   system-side (kreuzberg does not ship engines).
      # @param ocr_language [String] Tesseract/Paddle language code ("eng", "deu", ...).
      # @param force_ocr [Boolean] Re-OCR pages that already carry embedded
      #   text. Useful for PDFs whose embedded text is garbage.
      def initialize(ocr: false, ocr_language: "eng", force_ocr: false)
        @ocr          = self.class.normalize_ocr(ocr)
        @ocr_language = ocr_language
        @force_ocr    = force_ocr
      end

      def extract(path)
        ensure_gem!
        result = ::Kreuzberg.extract_file_sync(**extract_kwargs(path))
        build_result(result)
      rescue Curator::Error
        raise
      rescue StandardError => e
        raise ExtractionError, "Kreuzberg extraction failed: #{e.class}: #{e.message}"
      end

      private

      def ensure_gem!
        return if defined?(::Kreuzberg)
        load_kreuzberg_gem
      end

      def load_kreuzberg_gem
        require "kreuzberg"
      rescue LoadError
        raise ExtractionError, MISSING_GEM_MESSAGE
      end

      def extract_kwargs(path)
        kwargs = { path: path.to_s }
        config = build_kreuzberg_config
        kwargs[:config] = config if config
        kwargs
      end

      def build_kreuzberg_config
        return nil unless @ocr || @force_ocr
        ::Kreuzberg::Config::Extraction.new(
          ocr: ocr_config,
          force_ocr: @force_ocr
        )
      end

      def ocr_config
        return nil unless @ocr
        ::Kreuzberg::Config::OCR.new(backend: @ocr.to_s, language: @ocr_language)
      end

      def build_result(result)
        ExtractionResult.new(
          content: result.content,
          mime_type: result.mime_type,
          pages: normalize_pages(result.pages)
        )
      end

      # Kreuzberg returns `nil` for formats that aren't paginated, or an
      # Array<PageContent> (page_number, content, ...). We keep only the
      # fields Phase 3 consumes.
      def normalize_pages(pages)
        return [] if pages.nil?
        pages.map { |p| { page_number: p.page_number, content: p.content } }
      end
    end
  end
end
