module Curator
  module Documents
    # Service object for `IngestDocumentJob`'s extract → chunk → persist
    # pipeline. Owns extractor selection, tempfile materialization for
    # MIME-aware path-based extraction, paragraph chunking, and the
    # transactional persist of curator_chunks rows.
    class ExtractAndChunk
      def self.call(...) = new(...).call

      def initialize(document)
        @document = document
      end

      def call
        @document.update!(status: :extracting, stage_error: nil)
        # Idempotent cleanup: no-op for a fresh ingest, tears down the
        # prior pass's chunks (and their cascade to embeddings + retrieval
        # hits) on a reingest. Lives here rather than in `Curator.reingest`
        # so a destroy_all of thousands of chunks never blocks the request
        # handler that triggered the reingest.
        @document.chunks.destroy_all

        extraction = extract
        chunks     = chunk(extraction, @document.knowledge_base)

        raise Curator::ExtractionError, "no chunks produced for document #{@document.id}" if chunks.empty?

        ActiveRecord::Base.transaction do
          persist_chunks!(chunks)
          @document.update!(status: :embedding)
        end
      end

      private

      def extract
        extractor = build_extractor
        with_extractor_tempfile do |path|
          extractor.extract(path, mime_type: @document.mime_type)
        end
      end

      # ActiveStorage::Blob#open names the tempfile from the attachment's
      # filename extension, which is empty for URL ingests of bare URLs
      # (the upstream filename falls back to "download"). Kreuzberg sniffs
      # MIME from the path, so an extensionless tempfile makes it raise
      # ValidationError before we even get to extract. Download the bytes
      # to a tempfile we name ourselves with an extension derived from the
      # canonical, content-sniffed `document.mime_type`.
      def with_extractor_tempfile
        ext = mime_type_extension(@document.mime_type)
        Tempfile.create([ "curator-extract-", ext ]) do |tempfile|
          tempfile.binmode
          @document.file.download { |chunk| tempfile.write(chunk) }
          tempfile.flush
          yield tempfile.path
        end
      end

      def mime_type_extension(mime_type)
        candidate = Marcel::Magic.new(mime_type).extensions.first
        candidate ? ".#{candidate}" : ""
      end

      def chunk(extraction, knowledge_base)
        Curator::Chunkers::Paragraph.new(
          chunk_size:    knowledge_base.chunk_size,
          chunk_overlap: knowledge_base.chunk_overlap
        ).chunk(extraction)
      end

      def build_extractor
        case Curator.config.extractor
        when :basic
          Curator::Extractors::Basic.new
        when :kreuzberg
          Curator::Extractors::Kreuzberg.new(
            ocr:          Curator.config.ocr,
            ocr_language: Curator.config.ocr_language,
            force_ocr:    Curator.config.force_ocr
          )
        else
          raise Curator::ConfigurationError,
                "unsupported extractor #{Curator.config.extractor.inspect}; " \
                "expected :basic or :kreuzberg"
        end
      end

      def persist_chunks!(chunks)
        rows = chunks.each_with_index.map { |c, i| chunk_attrs(c, i) }
        validate_chunk_rows!(rows)
        rows.each { |row| Curator::Chunk.create!(row) }
      end

      # Pass `document:` (not `document_id:`) so the after_save tsvector
      # callback finds the parent association in-memory instead of issuing
      # a Document + KB SELECT per chunk.
      def chunk_attrs(chunk_data, sequence)
        {
          document:    @document,
          sequence:    sequence,
          content:     chunk_data[:content],
          token_count: chunk_data[:token_count],
          char_start:  chunk_data[:char_start],
          char_end:    chunk_data[:char_end],
          page_number: chunk_data[:page_number],
          status:      "pending"
        }
      end

      # Per-chunk create! triggers the after_save tsvector callback but
      # ActiveRecord's "must be >= 0" message loses the offending value.
      # This pre-check produces a more diagnostic stage_error.
      NON_NEGATIVE_INTEGER_FIELDS = %i[sequence token_count char_start char_end].freeze
      private_constant :NON_NEGATIVE_INTEGER_FIELDS

      def validate_chunk_rows!(rows)
        rows.each do |row|
          if row[:content].blank?
            raise Curator::ExtractionError,
                  "chunker produced empty content for document=#{@document.id} sequence=#{row[:sequence]}"
          end

          NON_NEGATIVE_INTEGER_FIELDS.each do |key|
            value = row[key]
            next if value.is_a?(Integer) && value >= 0
            raise Curator::ExtractionError,
                  "chunker produced invalid chunk for document=#{@document.id} " \
                  "sequence=#{row[:sequence]}: #{key}=#{value.inspect} must be a non-negative Integer"
          end
        end
      end
    end
  end
end
