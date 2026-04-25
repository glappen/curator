require "digest"

require "curator/version"
require "curator/errors"
require "curator/configuration"
require "curator/token_counter"
require "curator/extractors/extraction_result"
require "curator/extractors/basic"
require "curator/extractors/kreuzberg"
require "curator/chunkers/paragraph"
require "curator/file_normalizer"
require "curator/ingest_result"
require "curator/url_fetcher"

# Note: `curator/engine` and the `ruby_llm` / `neighbor` requires live in
# lib/curator-rails.rb, which Bundler.require loads *after* Rails boots.
# Requiring them here loses a race: if curator.rb gets preloaded before
# Rails (e.g. from a test helper), ruby_llm's railtie guard
# (`if defined?(Rails::Railtie)`) falls through — the Railtie class is never
# defined, so the `ActiveSupport.on_load(:active_record)` callback that
# installs `acts_as_chat` never registers.

module Curator
  URL_PATTERN = %r{\Ahttps?://}i

  class << self
    attr_writer :config

    def configure
      yield config
      config
    end

    def config
      @config ||= Configuration.new
    end

    # Test-only: reset the memoized configuration.
    def reset_config!
      @config = nil
    end

    # Ingest a file *or URL* into a knowledge base.
    #
    # If `input` is a String beginning with `http://` or `https://`, Curator
    # fetches it via `UrlFetcher` (max-size enforced, redirect-following,
    # SSRF-blocked) and ingests the response body. Anything else is treated
    # as a local file or in-memory blob.
    #
    # @param input [String, Pathname, File, IO, StringIO,
    #               ActionDispatch::Http::UploadedFile, ActiveStorage::Blob]
    #   A URL string (`https://…`), a filesystem path, or an in-memory blob.
    # @param knowledge_base [Curator::KnowledgeBase, String, Symbol, nil] Instance
    #   or slug. Slugs are looked up via `KnowledgeBase.find_by!(slug:)`. When
    #   omitted (nil), Curator routes to `KnowledgeBase.default!`.
    # @param title [String, nil] Defaults to the filename (with extension).
    # @param source_url [String, nil]
    #   For URL inputs: defaults to the resolved final URL (post-redirect).
    #   For path/File inputs: defaults to a `file:///<absolute path>` URL.
    #   For IO/blob/upload inputs: nil.
    # @param metadata [Hash]
    # @param filename [String, nil] Override for IO inputs without a path.
    # @return [Curator::IngestResult]
    def ingest(input, knowledge_base: nil, title: nil, source_url: nil, metadata: {}, filename: nil)
      if url_string?(input)
        return ingest_from_url(
          input,
          knowledge_base: knowledge_base, title: title,
          source_url:     source_url, metadata: metadata
        )
      end

      ingest_from_file(
        input,
        knowledge_base: knowledge_base, title: title,
        source_url:     source_url, metadata: metadata, filename: filename
      )
    end

    private

    def url_string?(input)
      input.is_a?(String) && input.match?(URL_PATTERN)
    end

    def ingest_from_file(file, knowledge_base:, title:, source_url:, metadata:, filename:)
      kb = resolve_knowledge_base(knowledge_base)

      # Cheap pre-check for inputs whose size we can read without slurping
      # the whole file into memory. Avoids OOMing on huge local paths /
      # blobs before FileNormalizer.call materializes the bytes.
      enforce_size_precheck!(file)

      normalized          = FileNormalizer.call(file, filename: filename)
      enforce_normalized_size!(normalized)

      resolved_source_url = source_url || derive_file_source_url(file)
      content_hash        = Digest::SHA256.hexdigest(normalized.bytes)

      existing = kb.documents.find_by(content_hash: content_hash)
      return IngestResult.new(document: existing, status: :duplicate) if existing

      document = create_document!(kb, normalized, content_hash, title: title, source_url: resolved_source_url, metadata: metadata)
      IngestResult.new(document: document, status: :created)
    rescue ActiveRecord::RecordNotUnique
      # Concurrent ingest of the same content_hash got there first. The
      # composite unique index on (knowledge_base_id, content_hash) makes
      # this safe to recover from — re-find and report :duplicate.
      existing = kb.documents.find_by(content_hash: content_hash)
      raise unless existing
      IngestResult.new(document: existing, status: :duplicate)
    end

    def ingest_from_url(url, knowledge_base:, title:, source_url:, metadata:)
      fetched = UrlFetcher.call(url, max_bytes: config.max_document_size)

      # When the URL has no usable path basename (e.g. bare homepages like
      # https://cnn.com/), UrlFetcher falls back to "download" as the
      # filename. Letting the file path derive the title from that would
      # leave every such doc titled "download" — fall back to the URL
      # itself, which is at least identifying.
      resolved_title = title
      if resolved_title.nil? && fetched.filename == UrlFetcher::FALLBACK_FILENAME
        resolved_title = fetched.final_url
      end

      ingest_from_file(
        StringIO.new(fetched.bytes),
        knowledge_base: knowledge_base,
        title:          resolved_title,
        source_url:     source_url || fetched.final_url,
        metadata:       metadata,
        filename:       fetched.filename
      )
    end

    def resolve_knowledge_base(kb)
      case kb
      when nil
        KnowledgeBase.default!
      when KnowledgeBase
        kb
      when String, Symbol
        KnowledgeBase.find_by!(slug: kb.to_s)
      else
        raise ArgumentError,
              "knowledge_base: must be a Curator::KnowledgeBase, String, or " \
              "Symbol slug (got #{kb.class})"
      end
    end

    # Inspect whatever the caller passed for a cheap size we can read
    # without slurping the whole payload. Skips types (StringIO, raw IO)
    # whose size is only knowable after read; FileNormalizer materializes
    # those, and a post-normalize size check catches them.
    def enforce_size_precheck!(file)
      size = cheap_byte_size(file)
      return if size.nil? || size <= config.max_document_size
      raise FileTooLargeError,
            "input is #{size} bytes; max_document_size is #{config.max_document_size}."
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
      return if normalized.byte_size <= config.max_document_size
      raise FileTooLargeError,
            "File #{normalized.filename.inspect} is #{normalized.byte_size} bytes; " \
            "max_document_size is #{config.max_document_size}."
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

    def create_document!(kb, normalized, content_hash, title:, source_url:, metadata:)
      document = nil
      ActiveRecord::Base.transaction do
        document = kb.documents.create!(
          title:        title || normalized.filename,
          source_url:   source_url,
          content_hash: content_hash,
          mime_type:    normalized.mime_type,
          byte_size:    normalized.byte_size,
          metadata:     metadata,
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
      IngestDocumentJob.perform_later(document.id)
      document
    end
  end
end
