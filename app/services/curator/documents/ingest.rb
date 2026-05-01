module Curator
  module Documents
    # Service object for `Curator.ingest`. Owns URL-vs-file dispatch,
    # size pre-check + post-normalize size enforcement, dedup against
    # the KB's existing content_hash, document row creation, and
    # IngestDocumentJob enqueue. Returns `Curator::IngestResult`.
    class Ingest
      URL_PATTERN = %r{\Ahttps?://}i

      def self.call(...) = new(...).call

      def initialize(input, knowledge_base: nil, title: nil, source_url: nil, metadata: {}, filename: nil)
        @input              = input
        @knowledge_base_arg = knowledge_base
        @title              = title
        @source_url         = source_url
        @metadata           = metadata
        @filename           = filename
      end

      def call
        if url_string?(@input)
          ingest_from_url
        else
          ingest_from_file(@input, title: @title, source_url: @source_url, filename: @filename)
        end
      end

      private

      def url_string?(input)
        input.is_a?(String) && input.match?(URL_PATTERN)
      end

      def ingest_from_url
        fetched = Curator::UrlFetcher.call(@input, max_bytes: Curator.config.max_document_size)

        # When the URL has no usable path basename (e.g. bare homepages like
        # https://cnn.com/), UrlFetcher falls back to "download" as the
        # filename. Letting the file path derive the title from that would
        # leave every such doc titled "download" — fall back to the URL
        # itself, which is at least identifying.
        resolved_title = @title
        if resolved_title.nil? && fetched.filename == Curator::UrlFetcher::FALLBACK_FILENAME
          resolved_title = fetched.final_url
        end

        ingest_from_file(
          StringIO.new(fetched.bytes),
          title:      resolved_title,
          source_url: @source_url || fetched.final_url,
          filename:   fetched.filename
        )
      end

      def ingest_from_file(file, title:, source_url:, filename:)
        kb = Curator::KnowledgeBase.resolve(@knowledge_base_arg)

        # Cheap pre-check for inputs whose size we can read without slurping
        # the whole file into memory. Avoids OOMing on huge local paths /
        # blobs before FileNormalizer.call materializes the bytes.
        enforce_size_precheck!(file)

        normalized          = Curator::FileNormalizer.call(file, filename: filename)
        enforce_normalized_size!(normalized)

        resolved_source_url = source_url || derive_file_source_url(file)
        content_hash        = Digest::SHA256.hexdigest(normalized.bytes)

        existing = kb.documents.find_by(content_hash: content_hash)
        return Curator::IngestResult.new(document: existing, status: :duplicate) if existing

        document = create_document!(kb, normalized, content_hash, title: title, source_url: resolved_source_url)
        Curator::IngestResult.new(document: document, status: :created)
      rescue ActiveRecord::RecordNotUnique
        # Concurrent ingest of the same content_hash got there first. The
        # composite unique index on (knowledge_base_id, content_hash) makes
        # this safe to recover from — re-find and report :duplicate.
        existing = kb.documents.find_by(content_hash: content_hash)
        raise unless existing
        Curator::IngestResult.new(document: existing, status: :duplicate)
      end

      # Inspect whatever the caller passed for a cheap size we can read
      # without slurping the whole payload. Skips types (StringIO, raw IO)
      # whose size is only knowable after read; FileNormalizer materializes
      # those, and a post-normalize size check catches them.
      def enforce_size_precheck!(file)
        size = cheap_byte_size(file)
        return if size.nil? || size <= Curator.config.max_document_size
        raise Curator::FileTooLargeError,
              "input is #{size} bytes; max_document_size is #{Curator.config.max_document_size}."
      end

      def cheap_byte_size(file)
        case file
        when String, Pathname             then File.size(file.to_s)
        when File                         then file.size
        when ActiveStorage::Blob          then file.byte_size
        when ActionDispatch::Http::UploadedFile then file.size
        end
      rescue Errno::ENOENT
        nil
      end

      def enforce_normalized_size!(normalized)
        return if normalized.byte_size <= Curator.config.max_document_size
        raise Curator::FileTooLargeError,
              "File #{normalized.filename.inspect} is #{normalized.byte_size} bytes; " \
              "max_document_size is #{Curator.config.max_document_size}."
      end

      # Build a file:/// URL from a path-like input so a file ingested off
      # disk self-documents where it came from. Returns nil for inputs
      # without an on-disk path (IO/StringIO/UploadedFile/Blob) — those
      # don't have a meaningful "source" for the human reader, and the URL
      # ingest path overrides source_url with the resolved final URL anyway.
      # Not URL-encoded: this is an informational hint, not a fetchable URL.
      def derive_file_source_url(file)
        path = case file
        when String, Pathname then file.to_s
        when File             then file.path
        end
        return nil if path.nil? || path.empty?
        "file://#{File.expand_path(path)}"
      end

      def create_document!(kb, normalized, content_hash, title:, source_url:)
        document = nil
        ActiveRecord::Base.transaction do
          document = kb.documents.create!(
            title:        title || normalized.filename,
            source_url:   source_url,
            content_hash: content_hash,
            mime_type:    normalized.mime_type,
            byte_size:    normalized.byte_size,
            metadata:     @metadata,
            status:       :pending
          )
          document.file.attach(
            io:           StringIO.new(normalized.bytes),
            filename:     normalized.filename,
            content_type: normalized.mime_type
          )
        end
        # Enqueue outside the transaction so the job can't pick up the doc
        # before the commit is visible to the worker.
        Curator::IngestDocumentJob.perform_later(document.id)
        document
      end
    end
  end
end
