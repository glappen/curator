module Curator
  class IngestDocumentJob < ApplicationJob
    # Phase 5: extract -> chunk -> persist curator_chunks rows -> hand off
    # to EmbedChunksJob. Failures of any stage land the document in
    # :failed with stage_error populated and an error log entry; the job
    # does not re-raise extraction failures so ActiveJob retries don't
    # churn on what are usually deterministic input-quality failures
    # (bad PDF, unsupported MIME, empty file).
    def perform(document_id)
      # find_by(id:) instead of find: a doc deleted between enqueue and
      # execution should be a silent no-op, not RecordNotFound (which
      # would still be a StandardError but would crash the failure-path
      # rescue in prepare_for_embedding since `document` would be unbound).
      document = Curator::Document.find_by(id: document_id)
      return unless document

      prepare_for_embedding(document) if document.pending?

      # Enqueue is intentionally outside the rescue and outside the
      # transaction. Two reasons:
      #
      # 1. If perform_later raises (queue down), the chunks are already
      #    persisted — propagating the error to ActiveJob lets the queue
      #    adapter retry the job. On retry, document.pending? is false
      #    but document.embedding? is true, so we hit the recovery path
      #    here and just re-enqueue without re-extracting.
      # 2. Enqueueing inside the transaction races: a worker could pick
      #    up the doc before COMMIT made its chunks visible.
      EmbedChunksJob.perform_later(document.id) if document.embedding? && document.chunks.exists?
    end

    private

    def prepare_for_embedding(document)
      run_pipeline!(document)
    rescue StandardError => e
      Rails.logger.error(
        "[Curator] IngestDocumentJob failed for document=#{document.id}: #{e.class}: #{e.message}"
      )
      document.update!(status: :failed, stage_error: "#{e.class}: #{e.message}")
    end

    def run_pipeline!(document)
      document.update!(status: :extracting, stage_error: nil)

      extraction = extract(document)
      chunks     = chunk(extraction, document.knowledge_base)

      raise ExtractionError, "no chunks produced for document #{document.id}" if chunks.empty?

      ActiveRecord::Base.transaction do
        persist_chunks!(document, chunks)
        document.update!(status: :embedding)
      end
    end

    def extract(document)
      extractor = build_extractor
      with_extractor_tempfile(document) do |path|
        extractor.extract(path, mime_type: document.mime_type)
      end
    end

    # ActiveStorage::Blob#open names the tempfile from the attachment's
    # filename extension, which is empty for URL ingests of bare URLs
    # (the upstream filename falls back to "download"). Kreuzberg sniffs
    # MIME from the path, so an extensionless tempfile makes it raise
    # ValidationError before we even get to extract. Download the bytes
    # to a tempfile we name ourselves with an extension derived from the
    # canonical, content-sniffed `document.mime_type`.
    def with_extractor_tempfile(document)
      ext = mime_type_extension(document.mime_type)
      Tempfile.create([ "curator-extract-", ext ]) do |tempfile|
        tempfile.binmode
        document.file.download { |chunk| tempfile.write(chunk) }
        tempfile.flush
        yield tempfile.path
      end
    end

    def mime_type_extension(mime_type)
      candidate = Marcel::Magic.new(mime_type).extensions.first
      candidate ? ".#{candidate}" : ""
    end

    def chunk(extraction, knowledge_base)
      Chunkers::Paragraph.new(
        chunk_size:    knowledge_base.chunk_size,
        chunk_overlap: knowledge_base.chunk_overlap
      ).chunk(extraction)
    end

    def build_extractor
      case Curator.config.extractor
      when :basic
        Extractors::Basic.new
      when :kreuzberg
        Extractors::Kreuzberg.new(
          ocr:          Curator.config.ocr,
          ocr_language: Curator.config.ocr_language,
          force_ocr:    Curator.config.force_ocr
        )
      else
        raise ConfigurationError,
              "unsupported extractor #{Curator.config.extractor.inspect}; " \
              "expected :basic or :kreuzberg"
      end
    end

    def persist_chunks!(document, chunks)
      rows = chunks.each_with_index.map { |c, i| chunk_attrs(document, c, i) }
      validate_chunk_rows!(document, rows)
      rows.each { |row| Curator::Chunk.create!(row) }
    end

    # Pass `document:` (not `document_id:`) so the after_save tsvector
    # callback finds the parent association in-memory instead of issuing
    # a Document + KB SELECT per chunk.
    def chunk_attrs(document, chunk_data, sequence)
      {
        document:    document,
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

    def validate_chunk_rows!(document, rows)
      rows.each do |row|
        if row[:content].blank?
          raise ExtractionError,
                "chunker produced empty content for document=#{document.id} sequence=#{row[:sequence]}"
        end

        NON_NEGATIVE_INTEGER_FIELDS.each do |key|
          value = row[key]
          next if value.is_a?(Integer) && value >= 0
          raise ExtractionError,
                "chunker produced invalid chunk for document=#{document.id} " \
                "sequence=#{row[:sequence]}: #{key}=#{value.inspect} must be a non-negative Integer"
        end
      end
    end
  end
end
