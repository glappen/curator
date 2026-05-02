require "active_support/core_ext/numeric/bytes"

module Curator
  # Holds runtime configuration for the engine. Populated via
  # `Curator.configure { |c| ... }` from a host app's initializer.
  class Configuration
    EXTRACTORS    = %i[kreuzberg basic].freeze
    TRACE_LEVELS  = %i[full summary off].freeze

    attr_reader :extractor, :trace_level, :ocr
    attr_accessor :max_document_size,
                  :log_queries,
                  :llm_retry_count,
                  :query_timeout,
                  :embedding_batch_size,
                  :ocr_language,
                  :force_ocr

    def initialize
      @extractor            = :kreuzberg
      @trace_level          = :full
      @max_document_size    = 50.megabytes
      @log_queries          = true
      @llm_retry_count      = 1
      @query_timeout        = nil
      @embedding_batch_size = 100
      @ocr                  = false
      @ocr_language         = "eng"
      @force_ocr            = false
    end

    def extractor=(value)
      unless EXTRACTORS.include?(value)
        raise ArgumentError, "extractor must be one of #{EXTRACTORS.inspect} (got #{value.inspect})"
      end
      @extractor = value
    end

    def trace_level=(value)
      unless TRACE_LEVELS.include?(value)
        raise ArgumentError, "trace_level must be one of #{TRACE_LEVELS.inspect} (got #{value.inspect})"
      end
      @trace_level = value
    end

    # OCR toggle for the Kreuzberg extractor. Accepts:
    #   - `false` (default): no OCR
    #   - `true`:             enable OCR with the default `:tesseract` backend
    #   - `:tesseract` / `:paddle`: enable OCR with a specific backend
    def ocr=(value)
      @ocr = Curator::Extractors::Kreuzberg.normalize_ocr(value)
    end

    # Dual-mode: with a block, stores the block as the admin auth hook.
    # Without a block, returns the stored proc (or nil).
    def authenticate_admin_with(&block)
      @authenticate_admin_with = block if block
      @authenticate_admin_with
    end
  end
end
