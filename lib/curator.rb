require "digest"
require "pathname"

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
require "curator/hit"
require "curator/retrieval_results"
require "curator/answer"
require "curator/tracing"
require "curator/retrievers/embedding_scoped"
require "curator/retrievers/vector"
require "curator/retrievers/keyword"
require "curator/retrievers/hybrid"
require "curator/retrievers/pipeline"
require "curator/retriever"
require "curator/prompt/templates"
require "curator/prompt/assembler"
require "curator/asker"
require "curator/reembed"

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

    # Walk a directory tree and hand each matching file to `Curator.ingest`.
    #
    # Default glob is extractor-aware (driven by the configured extractor's
    # EXTENSIONS list). Callers can override with an explicit `pattern:`
    # like `"**/*.md"` or `"reports/*.pdf"`. Hidden files (any path
    # component starting with `.`), symlinks, and directories are skipped.
    #
    # Per-file `Curator.ingest` errors do **not** abort the walk — they're
    # caught and surfaced as `IngestResult(status: :failed)` so the caller
    # (and the rake task) can summarize across the whole tree.
    #
    # Walk is sequential and `Curator.ingest` is itself async — each
    # match enqueues an `IngestDocumentJob` and returns immediately.
    # Throughput is bounded by the host's Active Job adapter (Sidekiq
    # concurrency, Solid Queue threads, etc.), not by this method.
    #
    # @return [Array<Curator::IngestResult>] in walk order.
    def ingest_directory(path, knowledge_base: nil, pattern: nil, recursive: true)
      # File.expand_path handles `~`, `~user`, and resolves relative
      # paths against CWD — Pathname.new doesn't do tilde expansion on
      # its own, so a bare `Pathname.new("~/pdfs").directory?` is false
      # even when the directory exists.
      base = Pathname.new(File.expand_path(path.to_s))
      raise ArgumentError, "ingest_directory: #{base} is not a directory" unless base.directory?

      kb            = resolve_knowledge_base(knowledge_base)
      glob_patterns = directory_glob_patterns(pattern, recursive)

      files_to_ingest(base, glob_patterns).map { |fp| ingest_one_for_directory(fp, kb) }
    end

    # Retrieve chunks relevant to `query` from a knowledge base.
    #
    # @param query [String] non-empty user query.
    # @param knowledge_base [Curator::KnowledgeBase, String, Symbol, nil]
    #   Instance, slug, or nil → `KnowledgeBase.default!`.
    # @param limit [Integer, nil] Override `kb.chunk_limit`.
    # @param threshold [Float, nil] Cosine cutoff (0..1). Override
    #   `kb.similarity_threshold`. Meaningless for `strategy: :keyword`
    #   — passing both raises ArgumentError.
    # @param strategy [:vector, :keyword, :hybrid, nil] Override the
    #   KB's `retrieval_strategy`. nil → use the KB default.
    # @return [Curator::RetrievalResults]
    def retrieve(query, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil)
      Retriever.new(
        query,
        knowledge_base: knowledge_base,
        limit:          limit,
        threshold:      threshold,
        strategy:       strategy
      ).call
    end

    # Run a retrieval-grounded LLM ask against a knowledge base.
    # Mirrors `Curator.retrieve`'s signature, plus per-call
    # `system_prompt:` (replaces only the instructions half — the
    # context block stays Curator-controlled) and `chat_model:`
    # overrides. Returns `Curator::Answer` wrapping the assistant
    # text, the underlying `RetrievalResults`, and bookkeeping FKs.
    #
    # Persists one `chats` row (`curator_scope: nil`) plus user +
    # assistant `messages` rows per ask, and (when
    # `Curator.config.log_queries`) one `curator_retrievals` row
    # snapshotting every column that affects the answer at query time.
    #
    # When given a block, streams the assistant response: the block
    # is called with each `String` delta as it arrives, and
    # `Answer#answer` still holds the fully concatenated text on
    # return. `Curator.config.llm_retry_count` controls how many
    # times faraday-retry will retry a failed request; for a
    # mid-stream error this means partial deltas may be replayed
    # across attempts. Streaming consumers that need at-most-once
    # delivery should set `llm_retry_count = 0`.
    def ask(query, knowledge_base: nil, limit: nil, threshold: nil, strategy: nil,
            system_prompt: nil, chat_model: nil, &block)
      Asker.new(
        query,
        knowledge_base: knowledge_base,
        limit:          limit,
        threshold:      threshold,
        strategy:       strategy,
        system_prompt:  system_prompt,
        chat_model:     chat_model
      ).call(&block)
    end

    # Re-embed chunks in a knowledge base.
    #
    # @param knowledge_base [Curator::KnowledgeBase, String, Symbol, nil]
    # @param scope [:stale, :failed, :all] Default `:stale`.
    #   - `:stale`  — :failed chunks plus :embedded chunks whose
    #                 `embedding_model` no longer matches `kb.embedding_model`.
    #                 Excludes :pending (mid-flight from ingest).
    #   - `:failed` — only :failed chunks.
    #   - `:all`    — every chunk; also re-stems `content_tsvector` from
    #                 the KB's current `tsvector_config`.
    # @return [Curator::Reembed::Result] documents_touched, chunks_touched, scope
    def reembed(knowledge_base: nil, scope: :stale)
      Reembed.new(knowledge_base: knowledge_base, scope: scope).call
    end

    # Re-run extraction + chunking for an existing document. Uses the
    # blob already attached to the document; no re-hash, no re-fetch.
    # The doc flips back to :pending and the job re-enqueues; the prior
    # chunks (and their cascade to embeddings/retrievals) are torn down
    # inside IngestDocumentJob#run_pipeline!, not here, so reingest stays
    # cheap to call from a request handler.
    def reingest(document)
      # Reload first: callers may hold a stale `document` reference whose
      # in-memory status hasn't caught up with what the IngestDocumentJob
      # / EmbedChunksJob wrote (a fresh-from-create document will still
      # have status=:pending in memory after the pipeline has flipped it
      # to :complete in the DB). AR's dirty-tracking on update! compares
      # against the in-memory snapshot, not the DB row, so without this
      # `update!(status: :pending, ...)` is a no-op when the in-memory
      # status already happens to be :pending — the document would never
      # get re-enqueued.
      document.reload
      document.update!(status: :pending, stage_error: nil)
      IngestDocumentJob.perform_later(document.id)
      document
    end

    private

    def url_string?(input)
      input.is_a?(String) && input.match?(URL_PATTERN)
    end

    def directory_glob_patterns(pattern, recursive)
      return Array(pattern) if pattern

      exts     = configured_extractor_extensions
      brace    = "{#{exts.map { |e| e.delete_prefix('.') }.join(',')}}"
      relative = recursive ? "**/*.#{brace}" : "*.#{brace}"
      [ relative ]
    end

    def configured_extractor_extensions
      case config.extractor
      when :basic     then Extractors::Basic::EXTENSIONS
      when :kreuzberg then Extractors::Kreuzberg::EXTENSIONS
      else
        raise ConfigurationError,
              "unsupported extractor #{config.extractor.inspect}; expected :basic or :kreuzberg"
      end
    end

    # Materialize the list once so we can dedupe (a path that matches
    # multiple patterns shouldn't be ingested twice) and enforce a stable
    # walk order. Filtering against `base` lets us reject hidden segments
    # in the *relative* path even when `base` itself happens to live under
    # a dotted directory (e.g. /tmp/.cache/...).
    def files_to_ingest(base, glob_patterns)
      candidates = glob_patterns.flat_map do |pat|
        Dir.glob(pat, File::FNM_CASEFOLD, base: base.to_s)
      end
      candidates
        .uniq
        .sort
        .map { |rel| base.join(rel) }
        .reject { |p| ingest_skip?(p, base) }
    end

    def ingest_skip?(path, base)
      return true unless path.file?
      return true if path.symlink?
      relative_segments = path.relative_path_from(base).each_filename.to_a
      relative_segments.any? { |seg| seg.start_with?(".") }
    end

    def ingest_one_for_directory(file_path, kb)
      ingest(file_path.to_s, knowledge_base: kb)
    rescue Curator::Error, ActiveRecord::RecordInvalid => e
      # Per-file failures we can keep walking past: bad MIME, oversized
      # blob, extractor barfing on one file, validation collision on this
      # row. Anything outside this list (DB connection drop, ENOSPC, OOM,
      # programming errors) propagates and aborts the walk — masking
      # those as N "failed" entries would hide real outages.
      IngestResult.new(
        document: nil,
        status:   :failed,
        reason:   "#{e.class}: #{e.message}"
      )
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
