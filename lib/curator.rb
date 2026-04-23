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

    # Ingest a file into a knowledge base.
    #
    # @param file [String, Pathname, File, IO, StringIO,
    #              ActionDispatch::Http::UploadedFile, ActiveStorage::Blob]
    # @param knowledge_base [Curator::KnowledgeBase, String, Symbol] Instance
    #   or slug. Slugs are looked up via `KnowledgeBase.find_by!(slug:)`.
    # @param title [String, nil] Defaults to the filename stem.
    # @param source_url [String, nil]
    # @param metadata [Hash]
    # @param filename [String, nil] Override for IO inputs without a path.
    # @return [Curator::IngestResult]
    def ingest(file, knowledge_base:, title: nil, source_url: nil, metadata: {}, filename: nil)
      kb         = resolve_knowledge_base(knowledge_base)
      normalized = FileNormalizer.call(file, filename: filename)

      if normalized.byte_size > config.max_document_size
        raise FileTooLargeError,
              "File #{normalized.filename.inspect} is #{normalized.byte_size} bytes; " \
              "max_document_size is #{config.max_document_size}."
      end

      content_hash = Digest::SHA256.hexdigest(normalized.bytes)

      existing = kb.documents.find_by(content_hash: content_hash)
      return IngestResult.new(document: existing, status: :duplicate) if existing

      document = kb.documents.create!(
        title:        title || File.basename(normalized.filename, ".*"),
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
      IngestDocumentJob.perform_later(document)

      IngestResult.new(document: document, status: :created)
    end

    # Fetch a URL and ingest its body. Thin wrapper around UrlFetcher +
    # Curator.ingest; `source_url:` defaults to the resolved final URL
    # (after redirects) so the document self-documents where it came from.
    #
    # @return [Curator::IngestResult]
    def ingest_url(url, knowledge_base:, title: nil, source_url: nil, metadata: {})
      fetched = UrlFetcher.call(url, max_bytes: config.max_document_size)

      # When the URL has no usable path basename (e.g. bare homepages like
      # https://cnn.com/), UrlFetcher falls back to "download" as the
      # filename. Letting Curator.ingest derive the title from that would
      # leave every such doc titled "download" — fall back to the URL
      # itself, which is at least identifying.
      resolved_title = title
      if resolved_title.nil? && fetched.filename == UrlFetcher::FALLBACK_FILENAME
        resolved_title = fetched.final_url
      end

      ingest(
        StringIO.new(fetched.bytes),
        knowledge_base: knowledge_base,
        title:          resolved_title,
        source_url:     source_url || fetched.final_url,
        metadata:       metadata,
        filename:       fetched.filename
      )
    end

    private

    def resolve_knowledge_base(kb)
      case kb
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
  end
end
