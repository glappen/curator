namespace :curator do
  desc "Create the default Curator knowledge base if one doesn't exist"
  task seed_defaults: :environment do
    kb = Curator::KnowledgeBase.seed_default!
    puts "Curator default KB ready: #{kb.slug} (id=#{kb.id})"
  end

  desc "Ingest a directory tree into a knowledge base. " \
       "DIR=<dir> [KB=<slug>] [PATTERN=<glob>] [RECURSIVE=true|false]"
  task ingest: :environment do
    # Note: we deliberately do NOT read ENV["PATH"] — that's the system
    # PATH and is always populated, which would mask a missing argument
    # *and* break any subprocess Rails boot might spawn.
    path = ENV["DIR"]
    abort "DIR is required, e.g. DIR=./docs KB=default" if path.nil? || path.empty?

    kb_slug   = ENV["KB"]
    pattern   = ENV["PATTERN"]
    recursive = ENV.fetch("RECURSIVE", "true").downcase != "false"

    # Validate DIR up front so an auto-created KB below isn't left
    # orphaned by a typo'd path. Mirrors the check inside
    # Curator.ingest_directory but runs before the create!.
    unless File.directory?(File.expand_path(path))
      abort "DIR is not a directory: #{path.inspect}"
    end

    # Auto-create the KB if the user named one explicitly and it
    # doesn't exist yet. Library callers don't get this — explicit setup
    # there — but on the CLI "rake curator:ingest DIR=./docs KB=support"
    # should just work without a separate seed step. Defaults match
    # KnowledgeBase.seed_default!.
    if kb_slug && !kb_slug.empty? && Curator::KnowledgeBase.find_by(slug: kb_slug).nil?
      kb = Curator::KnowledgeBase.create!(
        slug:            kb_slug,
        name:            kb_slug.tr("-_", "  ").split.map(&:capitalize).join(" "),
        embedding_model: Curator::KnowledgeBase::DEFAULT_EMBEDDING_MODEL,
        chat_model:      Curator::KnowledgeBase::DEFAULT_CHAT_MODEL
      )
      puts "Created knowledge base #{kb.slug.inspect} (id=#{kb.id})"
    end

    # Active Job's :async adapter (the Rails dev default) runs jobs on a
    # thread pool that dies with the process — so a rake task that just
    # enqueues and exits leaves chunks unprocessed. Detect that case and
    # swap to :inline for the duration of the task so the user gets a
    # task that actually finishes. Real workers (sidekiq, solid_queue,
    # good_job, resque) are left alone — that's where you want the
    # producer to enqueue fast and let the worker pool fan out in
    # parallel. :inline configured by the host is also left alone.
    adapter_name      = ActiveJob::Base.queue_adapter_name.to_s
    swap_to_inline    = adapter_name == "async"
    inline_processing = swap_to_inline || adapter_name == "inline"

    original_adapter = ActiveJob::Base.queue_adapter
    if swap_to_inline
      ActiveJob::Base.queue_adapter = :inline
      puts "Active Job adapter is :async; switching to :inline for this task so " \
           "jobs complete before exit (configure a real worker for parallel processing)."
    end

    begin
      results = Curator.ingest_directory(
        path,
        knowledge_base: kb_slug,
        pattern:        pattern,
        recursive:      recursive
      )
    ensure
      ActiveJob::Base.queue_adapter = original_adapter if swap_to_inline
    end

    counts = results.group_by(&:status).transform_values(&:size)
    summary = "created=#{counts.fetch(:created, 0)} " \
              "duplicate=#{counts.fetch(:duplicate, 0)} " \
              "failed=#{counts.fetch(:failed, 0)}"
    puts summary

    # Only relevant when jobs ran out-of-process — for inline/async-swapped
    # runs the work has already happened by the time we get here.
    if counts.fetch(:created, 0) > 0 && !inline_processing
      puts "Documents enqueued for processing — ensure your Active Job worker is running."
    end

    results.each do |r|
      next unless r.failed?
      warn "  failed: #{r.reason}"
    end

    exit(1) if counts.fetch(:failed, 0) > 0
  end

  desc "Re-embed chunks in a knowledge base. " \
       "KB=<slug> [SCOPE=stale|failed|all]"
  task reembed: :environment do
    kb_slug = ENV["KB"]
    abort "KB is required, e.g. KB=default SCOPE=stale" if kb_slug.nil? || kb_slug.empty?

    scope_str = ENV.fetch("SCOPE", "stale")
    scope_sym = scope_str.to_sym
    unless Curator::Reembed::SCOPES.include?(scope_sym)
      abort "SCOPE must be one of #{Curator::Reembed::SCOPES.join('|')} (got #{scope_str.inspect})"
    end

    kb = Curator::KnowledgeBase.find_by(slug: kb_slug)
    abort "no knowledge base with slug #{kb_slug.inspect}" if kb.nil?

    # Mirrors curator:ingest's adapter handling: :async dies with the
    # process, so a "rake & exit" pattern leaves jobs unprocessed. Swap
    # to :inline for the duration so the task actually finishes its
    # work; leave real workers alone.
    adapter_name     = ActiveJob::Base.queue_adapter_name.to_s
    swap_to_inline   = adapter_name == "async"
    original_adapter = ActiveJob::Base.queue_adapter
    if swap_to_inline
      ActiveJob::Base.queue_adapter = :inline
      puts "Active Job adapter is :async; switching to :inline for this task so " \
           "jobs complete before exit (configure a real worker for parallel processing)."
    end

    begin
      result = Curator.reembed(knowledge_base: kb, scope: scope_sym)
    ensure
      ActiveJob::Base.queue_adapter = original_adapter if swap_to_inline
    end

    if result.chunks_touched.zero?
      if scope_sym == :stale
        puts "no stale chunks found — try `SCOPE=failed` for partial-failure " \
             "cleanup or `SCOPE=all` for a full re-embed"
      else
        puts "no chunks matched scope=#{scope_sym}"
      end
    else
      puts "re-embedding #{result.chunks_touched} chunks across " \
           "#{result.documents_touched} documents (scope=#{scope_sym})"
    end
  end

  desc "Re-extract + re-chunk an existing document. DOCUMENT=<id>"
  task reingest: :environment do
    id = ENV["DOCUMENT"]
    abort "DOCUMENT is required, e.g. DOCUMENT=42" if id.nil? || id.empty?

    document = Curator::Document.find(id)
    Curator.reingest(document)
    puts "Re-enqueued ingest for document=#{document.id} (#{document.title.inspect})"
  end

  namespace :retrievals do
    desc "Export retrievals to STDOUT. " \
         "FORMAT=<csv|json> [KB=<slug>] [SINCE=<iso8601>]"
    task export: :environment do
      Curator::Tasks::Export.run(
        exporter: Curator::Retrievals::Exporter,
        env:      ENV,
        io:       $stdout
      )
    end
  end

  namespace :evaluations do
    desc "Export evaluations to STDOUT. " \
         "FORMAT=<csv|json> [KB=<slug>] [SINCE=<iso8601>]"
    task export: :environment do
      Curator::Tasks::Export.run(
        exporter: Curator::Evaluations::Exporter,
        env:      ENV,
        io:       $stdout
      )
    end
  end
end
