# M2 — Ingestion

Extract + chunk pipeline for curator-rails: a developer calls
`Curator.ingest(file, knowledge_base:)` or runs `curator:ingest` against a
directory, and ends up with `curator_documents` rows whose `curator_chunks`
children are populated and ready for embedding. No real retrieval yet (M3),
but the full async pipeline runs end-to-end with a stub `EmbedChunksJob`
that immediately marks documents `:complete`.

**Reference**: `features/implementation.md` → "Implementation Milestones" → M2,
plus the "Ingestion Pipeline" and "Extractor contract" sections.

## Completed

- [x] Phase 4 — `Curator.ingest` + SHA-256 dedup + stub embed job
   - `Curator.ingest(file, knowledge_base:, title:, source_url:, metadata:, filename:)`
     module method in `lib/curator.rb`. Accepts String, Pathname, File,
     IO, StringIO, `ActionDispatch::Http::UploadedFile`, and
     `ActiveStorage::Blob`; `filename:` is an escape hatch for anonymous
     IO inputs.
   - `knowledge_base:` accepts a `KnowledgeBase` instance **or** a
     slug (`String`/`Symbol`). Slugs resolve via
     `KnowledgeBase.find_by!(slug:)` — a missing slug raises
     `ActiveRecord::RecordNotFound`. This makes the console ergonomic
     path (`Curator.ingest(path, knowledge_base: "default")`) work
     without the caller having to fetch the record first.
   - `Curator::FileNormalizer` (`lib/curator/file_normalizer.rb`)
     produces a `Normalized(bytes, filename, mime_type)` struct. MIME
     detection prefers the caller's `content_type` (UploadedFile / Blob)
     and falls back to `Marcel::MimeType.for` — the latter is already
     loaded transitively by ActiveStorage, so no new gemspec dep.
   - SHA-256 over `normalized.bytes`. Size check against
     `config.max_document_size` runs after normalization (simpler than
     per-input-type presizing) but before any DB write — oversized
     inputs raise `FileTooLargeError` with zero side effects.
   - Dedup via `knowledge_base.documents.find_by(content_hash:)`. Hit →
     `IngestResult(status: :duplicate)` referencing the existing doc,
     no job enqueued. Dedup is **per knowledge base**; the same file in
     two KBs creates two documents (regression spec).
   - Miss path: create `curator_documents` row with `status: :pending`,
     attach `has_one_attached :file` from a `StringIO` wrapper, enqueue
     `Curator::IngestDocumentJob.perform_later(document)`, return
     `IngestResult(status: :created)`. Title defaults to the filename
     stem (`File.basename(name, ".*")`) when not supplied.
   - `Curator::IngestResult` (`lib/curator/ingest_result.rb`) is a
     `Data.define(:document, :status, :reason)` with a status allowlist
     (`:created`, `:duplicate`) and `#created?` / `#duplicate?` predicates.
     Strict status validation so future additions (e.g. `:skipped`)
     have to land in the allowlist explicitly.
   - Stubs under `app/jobs/curator/` to keep the pipeline enqueueable
     before Phase 5 lands the real body:
     - `ApplicationJob` parent class.
     - `IngestDocumentJob#perform` just advances `status: :embedding` and
       enqueues `EmbedChunksJob`. Real extract → chunk → insert lands in
       Phase 5 (marked with an inline `TODO(Phase 5)`).
     - `EmbedChunksJob#perform` flips the document to `:complete`. Real
       embedding pipeline lands in M3 (`TODO(M3)`).
   - **URL ingest** (pulled forward from Phase 6):
     `Curator.ingest_url(url, knowledge_base:, title:, source_url:, metadata:)`
     plus `Curator::UrlFetcher` (`lib/curator/url_fetcher.rb`). Net::HTTP
     GET with up to 5 redirect hops, 10s open / 30s read timeouts.
     Filename comes from `Content-Disposition` (filename / filename*=),
     falling back to the URL path basename, then `"download"`. `source_url:`
     defaults to the resolved final URL so documents self-document their
     origin. Enforces `max_document_size` against the response body;
     socket errors wrap as `Curator::FetchError`. SSRF hardening
     (private-range blocklist, metadata endpoint guard) is explicitly
     deferred to v2 — host apps pick which URLs they trust today.
   - Full `rspec` (244 examples) + `rubocop` green.

- [x] Phase 3 — Chunker
   - `Curator::TokenCounter` shipped at `lib/curator/token_counter.rb`
     as a char-based heuristic (`CHARS_PER_TOKEN = 4`, `.count` ceils
     `length / 4.0`). Swappable behind the module method when a real
     tokenizer is wanted later.
   - `Curator::Chunkers::Paragraph` at `lib/curator/chunkers/paragraph.rb`.
     Greedy paragraph packing (split on `/\n\s*\n/`) with whitespace-only
     paragraph filtering, char-level fallback for single paragraphs that
     exceed the effective budget, and token-measured packing via
     `TokenCounter`.
   - **Packing budgets against `chunk_size - chunk_overlap`, not
     `chunk_size`.** The original pass used `chunk_size` and then layered
     overlap on top, which let every non-first chunk exceed the budget
     by up to `chunk_overlap` tokens (verified against a Kreuzberg PDF
     extraction with near-limit paragraphs). Budgeting against the
     effective size guarantees every chunk — including after the overlap
     prepend — is `<= chunk_size` tokens. Covered by a regression spec.
   - Overlap applied as a post-pack pass: last `chunk_overlap * CHARS_PER_TOKEN`
     chars of the prior chunk's content prepended to the next chunk's content.
     `char_start` / `char_end` track the source region the chunk's *new*
     (non-overlap) content covers; overlap is purely text-level.
   - **Whitespace-aware snapping** on both char-split boundaries and
     overlap-prefix starts: the nominal cut point is snapped to the
     nearest whitespace within a tolerance window (20% of the target,
     capped at 64 chars) so slices don't end mid-word and overlap
     prefixes don't begin mid-word. If no whitespace exists in-window
     (e.g. a run of non-prose chars, a long base64 blob) the exact char
     boundary is kept, so whitespace-free inputs stay deterministic.
   - Page metadata consumed by scanning `ExtractionResult#pages` into a
     `[[char_offset, page_number], ...]` map, then binary-searching each
     chunk's `char_start` to set `page_number`. Empty `pages` → every
     chunk's `page_number == nil` (Basic extractor path).
   - Chunker returns `Array<Hash>` with `content`, `token_count`,
     `char_start`, `char_end`, `page_number`. `sequence` is assigned by
     the caller (Phase 5's `IngestDocumentJob`).
   - Full `rspec` (203 examples) + `rubocop` green.

- [x] Phase 2 — Kreuzberg adapter
   - `gem "kreuzberg"` added to `Gemfile` under `:development, :test`
     only (verified by a regression spec that also asserts the gemspec
     does not reference it).
   - `Curator::Extractors::Kreuzberg` lazy-requires the gem on first
     use; `LoadError` is translated into `ExtractionError` with a
     Gemfile-pointing message. Other `StandardError`s from kreuzberg
     are also wrapped as `ExtractionError`.
   - API: `::Kreuzberg.extract_file_sync(path: ...)` — keyword arg,
     returns `Kreuzberg::Result` with `.content`, `.mime_type`, and
     optional `.pages` (`Array<PageContent>` or `nil`).
   - Pages normalized to `[{ page_number:, content: }, ...]` — the
     shape Phase 3's chunker will scan against. Empty for formats
     kreuzberg doesn't paginate.
   - Shared contract runs live against kreuzberg for `.md` / `.csv` /
     `.html` fixtures.
   - **OCR plumbing (added in-phase after Phase 2 ideation):**
     `Curator::Configuration` gained `ocr` (`false`/`true`/`:tesseract`/`:paddle`),
     `ocr_language` (default `"eng"`), `force_ocr` (default `false`).
     Adapter constructor accepts the same kwargs and translates them
     into `Kreuzberg::Config::OCR` + `Kreuzberg::Config::Extraction`,
     passed via `config:` kwarg to `extract_file_sync`. Phase 5's
     `IngestDocumentJob` will read `Curator.config.*` when it
     instantiates the adapter.
   - README documents the `:basic` vs `:kreuzberg` split plus OCR
     system deps (tesseract / paddle).
   - Full `rspec` (183 examples) + `rubocop` green.

- [x] Phase 1 — Extractor contract + Basic extractor
   - `Curator::Extractors::ExtractionResult` value object
     (`content`, `mime_type`, `pages`) under `lib/curator/extractors/`.
   - `Curator::Extractors::Basic` handling `text/plain`, `text/markdown`,
     `text/csv`, `text/html` (HTML stripped via Nokogiri). Strict
     whitelist; unknown MIME raises `Curator::UnsupportedMimeError`
     pointing at `config.extractor = :kreuzberg`.
   - `Curator::ExtractionError`, `Curator::UnsupportedMimeError`,
     `Curator::FileTooLargeError` added to `lib/curator/errors.rb`
     (all inherit `Curator::Error`; `UnsupportedMimeError` also inherits
     `ExtractionError`).
   - Shared contract spec at `spec/curator/extractors/contract.rb` plus
     `spec/curator/extractors/basic_spec.rb`, fixtures
     `spec/fixtures/sample.{md,csv,html,pdf}`.
   - Full `rspec` (154 examples) + `rubocop` green.

## Current Work

_Phase 4 done; awaiting go-ahead on Phase 5._

## Next Steps

- [ ] Phase 5 — `IngestDocumentJob`
   - `app/jobs/curator/ingest_document_job.rb` inheriting
     `ApplicationJob` (create `app/jobs/curator/application_job.rb` too).
   - Steps:
     1. Update document status to `:extracting`.
     2. Download blob to a tempfile; invoke configured extractor
        (`Curator.config.extractor`) — `:basic` → `Curator::Extractors::Basic`,
        `:kreuzberg` → `Curator::Extractors::Kreuzberg`.
     3. Build chunks via `Curator::Chunkers::Paragraph` configured from
        `document.knowledge_base.chunk_size` / `chunk_overlap`.
     4. Insert `curator_chunks` rows (`status: :pending`, `sequence` 0..N,
        `content_tsvector` populated by the DB generated column).
     5. Update document status to `:embedding`; enqueue
        `EmbedChunksJob.perform_later(document)`.
   - Failures (any step): rescue, set `status: :failed`, populate
     `stage_error` with the exception message + stage name, re-raise so
     Active Job's retry/backoff policy owns final disposition. No
     custom retry logic in M2 — host app's job adapter decides.
- [ ] Phase 6 — `ingest_directory`, `reingest`, rake tasks
   - `Curator.ingest_directory(path, knowledge_base:, pattern: nil, recursive: true)`:
     walks `path`. Default glob is extractor-aware extension list,
     recursive. `pattern:` overrides with an explicit Ruby glob
     (`"**/*.md"`). Hidden files (leading `.`) and symlinks skipped.
     Hands each file to `Curator.ingest`. Returns
     `Array<Curator::IngestResult>` in walk order.
   - `Curator.reingest(document)`: transaction — `document.chunks.destroy_all`
     (cascade will handle embeddings post-M3), reset
     `document.update!(status: :pending, stage_error: nil)`, enqueue
     `IngestDocumentJob.perform_later(document)`. No re-hash; the attached
     blob is canonical.
   - `curator:ingest PATH=<dir> KB=<slug>` rake task — delegates to
     `ingest_directory`, prints `created=N duplicate=M failed=K` summary
     grouped by `IngestResult#status`, exits non-zero if any `:failed`.
   - `curator:reingest DOCUMENT=<id>` rake task — delegates to
     `Curator.reingest`. Exits zero if enqueued.
- [ ] Phase 7 — End-to-end smoke
   - Request/job-level spec that, against the `spec/dummy` test DB:
     1. Seeds the default KB.
     2. `Curator.ingest` on a fixture `.md` file — asserts `IngestResult#status == :created`,
        drives jobs inline via `perform_enqueued_jobs`, asserts
        `document.reload.status == :complete`, asserts
        `document.chunks.count > 0` and chunks are populated.
     3. `Curator.ingest` on the same file again — asserts
        `IngestResult#status == :duplicate`, no new document or chunks
        created.
     4. `Curator.ingest` on an oversized file — asserts
        `Curator::FileTooLargeError` raised and no row created.
     5. `Curator.ingest` on an unsupported MIME (e.g. a `.pdf` under
        Basic) — asserts `Curator::UnsupportedMimeError`.
     6. `Curator.ingest_directory` on a small fixture tree — asserts
        mixed `:created` / `:duplicate` statuses.
     7. `Curator.reingest(doc)` — asserts chunks replaced, document
        returns to `:complete`.
   - **Validate**: Phase 7 checklist below, plus `bundle exec rspec` +
     `bundle exec rubocop` both green. **M2 complete.**

## Files Under Development

```
lib/
├── curator.rb                               # augment with .ingest / .ingest_directory / .reingest
├── curator/
│   ├── errors.rb                            # add ExtractionError, UnsupportedMimeError, FileTooLargeError
│   ├── ingest_result.rb                     # NEW value object
│   ├── file_normalizer.rb                   # NEW — path/IO/Blob → { bytes, filename, mime_type }
│   ├── token_counter.rb                     # NEW — char-based heuristic, already referenced in CLAUDE.md
│   ├── extractors/
│   │   ├── extraction_result.rb             # NEW value object
│   │   ├── basic.rb                         # NEW
│   │   └── kreuzberg.rb                     # NEW (P2)
│   └── chunkers/
│       └── paragraph.rb                     # NEW
├── tasks/
│   └── curator.rake                         # add ingest + reingest tasks
app/
└── jobs/curator/
    ├── application_job.rb                   # NEW base
    ├── ingest_document_job.rb               # NEW
    └── embed_chunks_job.rb                  # NEW — stub in M2, real body in M3
spec/
├── curator/
│   ├── extractors/
│   │   ├── contract.rb                      # shared examples
│   │   ├── basic_spec.rb
│   │   └── kreuzberg_spec.rb                # tagged `:kreuzberg`, skipped if gem absent
│   ├── chunkers/
│   │   └── paragraph_spec.rb
│   ├── file_normalizer_spec.rb
│   ├── ingest_result_spec.rb
│   └── token_counter_spec.rb
├── jobs/curator/
│   ├── ingest_document_job_spec.rb
│   └── embed_chunks_job_spec.rb             # stub behavior only in M2
├── tasks/
│   └── curator_ingest_rake_spec.rb
├── requests/curator/
│   └── ingestion_smoke_spec.rb              # P7 E2E
└── fixtures/
    ├── sample.md
    ├── sample.csv
    ├── sample.html
    ├── sample.pdf                           # for Kreuzberg (P2) and MIME-rejection (Basic)
    └── oversized.txt                        # > max_document_size for the size-check spec
Gemfile                                      # add kreuzberg to :development, :test (P2)
```

## Validation Strategy

### Phase 1 — Extractor contract + Basic
- [ ] `Curator::Extractors::Basic.new.extract(path_to_sample_md)` returns an
      `ExtractionResult` with non-empty `content`, `mime_type == "text/markdown"`,
      `pages == []`.
- [ ] Same for `.csv`, `.html` (HTML comes back as plain text, tags
      stripped).
- [ ] `.pdf` input raises `Curator::UnsupportedMimeError` with a message
      that includes `config.extractor = :kreuzberg`.
- [ ] `ExtractionResult` is frozen; `content` / `mime_type` / `pages`
      attr_readers present.

### Phase 2 — Kreuzberg adapter
- [ ] With `kreuzberg` loaded, `Curator::Extractors::Kreuzberg.new.extract(path_to_sample_pdf)`
      returns an `ExtractionResult` with non-empty `content` and
      `pages` populated.
- [ ] With `kreuzberg` not loaded, first use raises with message pointing
      at the Gemfile.
- [ ] Shared contract spec runs green against both adapters.
- [ ] `kreuzberg` appears in `Gemfile` under `:development, :test`, not
      in the gemspec.

### Phase 3 — Chunker
- [ ] Paragraphs smaller than `chunk_size` pack into one chunk until next
      would overflow.
- [ ] A single paragraph larger than `chunk_size` splits at char
      boundaries.
- [ ] Overlap prepends ~`chunk_overlap` tokens' worth of chars from the
      previous chunk (within ±1 token of the configured value, since
      TokenCounter is heuristic).
- [ ] `page_number` on each chunk matches the page the chunk's first
      char falls on (canned `pages` fixture).
- [ ] Empty `pages` ⇒ all chunks have `page_number == nil`.
- [ ] `chunk_size=100, chunk_overlap=10` on a 1000-char input produces
      a deterministic chunk count.

### Phase 4 — `Curator.ingest` + dedup + stub embed job
- [ ] `Curator.ingest(path_string, knowledge_base: kb)` returns
      `IngestResult` with `status: :created`, document persisted,
      Active Storage attachment present, `IngestDocumentJob` enqueued.
- [ ] Same file ingested again in same KB: `status: :duplicate`, no new
      document row, no job enqueued.
- [ ] Same file ingested in a *different* KB: `status: :created`, new
      document row.
- [ ] File > `Curator.config.max_document_size` raises
      `Curator::FileTooLargeError` before any DB write.
- [ ] Normalizer accepts: path string, `Pathname`, open `File`, `IO`,
      `ActiveStorage::Blob`. Each path has a spec example.
- [ ] Stub `EmbedChunksJob.perform_now(doc)` marks doc `:complete`.

### Phase 5 — `IngestDocumentJob`
- [ ] On a happy-path fixture: status transitions `:pending → :extracting
      → :embedding → :complete` (last hop via the stub job), chunks
      persisted with monotonic `sequence`, `content_tsvector` non-null
      (via generated column).
- [ ] Extraction failure: document ends `:failed` with `stage_error`
      populated; no chunks inserted.
- [ ] Chunker failure (e.g. extractor returns empty content): document
      ends `:failed`; chunks empty.
- [ ] `chunk_size` / `chunk_overlap` pulled from the document's KB, not
      from config defaults — verify by setting non-default values on
      the KB row and asserting chunk sizes reflect them.

### Phase 6 — Directory ingest + re-ingest + rake tasks
- [ ] `ingest_directory(tmpdir, knowledge_base: kb)` with a mixed tree
      of `.md`, `.csv`, and `.DS_Store` returns `IngestResult`s only for
      the allowed extensions; hidden files skipped.
- [ ] `pattern: "**/*.md"` filters correctly.
- [ ] Second run returns all `:duplicate`.
- [ ] `Curator.reingest(doc)` deletes old chunks and re-enqueues the
      job; after perform, chunks are newly inserted (different IDs)
      and doc is `:complete` again.
- [ ] `bundle exec rake curator:ingest PATH=./spec/fixtures/tree KB=default`
      prints `created=N duplicate=M failed=K`, exits 0 on all-success.
- [ ] `bundle exec rake curator:reingest DOCUMENT=<id>` enqueues the
      job and exits 0.

### Phase 7 — End-to-end smoke
- [ ] `bundle exec rspec` exits 0.
- [ ] `bundle exec rubocop` exits 0.
- [ ] Full smoke spec covering ingest → complete, dedup, oversize,
      MIME reject, directory, reingest passes.

## Implementation Notes

**Kreuzberg soft-dep loading**: `Curator::Extractors::Kreuzberg` should
`require "kreuzberg"` lazily inside the adapter's first method call
(not at file load), wrapped in a rescue `LoadError` that re-raises with
the gem-install message. Loading at top-level would crash `require
"curator"` in any host app that doesn't use Kreuzberg.

**`content_tsvector` in tests**: the column is `GENERATED ALWAYS AS`,
so we don't set it from Ruby — AR insert writes the other columns and
Postgres populates the tsvector. Specs reload the chunk to see the
value. Verified in M1's schema templates.

**`TokenCounter` lands here**: `Curator::TokenCounter.count(text)` is
mentioned in `CLAUDE.md` as a char-based heuristic behind a swappable
interface, but isn't implemented yet. P3 ships it (single method,
~5 lines) because the chunker is the first real caller. A dedicated
spec covers the heuristic constant + basic inputs.

**`FileNormalizer` edge cases**: `ActionDispatch::Http::UploadedFile`
exposes `.read`, `.original_filename`, `.content_type` — straightforward.
For `IO` without a path, `filename:` kwarg on `Curator.ingest` fills the
gap; otherwise `FileNormalizer` raises a clear error. `ActiveStorage::Blob`
already knows its filename + checksum + byte_size — short-circuit those.

**Dedup scope**: `(knowledge_base_id, content_hash)`, not global. Same
file in two different KBs produces two documents — intentional. DB
constraint: add `add_index :curator_documents, [:knowledge_base_id,
:content_hash], unique: true` if not already in the M1 schema
templates. _Check the existing migration before writing a new one;
it may already be there._

**Generated dummy schema**: editing any migration template under
`lib/generators/curator/install/templates/` means running
`bin/reset-dummy` to rebuild `spec/dummy/db/**` before specs see the
change. Standing rule from M1.

## Ideation Notes

Captured from `/ideate` session on 2026-04-23.

| # | Question | Conclusion |
|---|---|---|
| 1 | M2/M3 boundary for `IngestDocumentJob` | **Stub `EmbedChunksJob` in M2.** `IngestDocumentJob` enqueues it as it will forever; the M2 stub immediately marks the document `:complete` without embedding. M3 replaces the stub body. Status machine is correct from day one. |
| 2 | Extractor scope in M2 | **Both adapters; Kreuzberg as a soft dep.** `kreuzberg` goes in curator-rails's `Gemfile` dev/test group, not the gemspec. Host apps that want it add the gem themselves. Adapter raises a clear "add `gem \"kreuzberg\"`" message if the gem isn't loaded. Contract spec runs against both. |
| 3 | `Curator.ingest` return semantics | **Async.** Writes `curator_documents` row with `status: :pending`, attaches via Active Storage, enqueues `IngestDocumentJob`, returns immediately. Rails-idiomatic. Tests drive inline via `perform_enqueued_jobs`. |
| 4 | `file` arg type to `Curator.ingest` | **Anything `has_one_attached` accepts**: path `String`, `Pathname`, `File`, `IO`, `ActionDispatch::Http::UploadedFile`, `ActiveStorage::Blob`. Normalize internally — read bytes, SHA-256, derive filename + mime, attach. |
| 5 | `ingest_directory` walk rules | **Recursive by default, extension filter, explicit `pattern:` kwarg override.** Extension list is extractor-aware. Hidden files and symlinks skipped. Dedup falls through to `Curator.ingest`'s per-KB SHA-256 check. |
| 6 | Chunker splitting + page interaction | **Greedy paragraph packing + char-level fallback; pages as metadata, not split points.** Chunks span page boundaries freely; `page_number` = the page of the chunk's first char, derived by binary-searching into a char-offset map built from `ExtractionResult#pages`. |
| 7 | Build vs. depend on baran | **Write our own `Curator::Chunkers::Paragraph`**; read baran's source first to steal overlap math + edge-case list. Chunking is a core primitive; ~150 lines is token-native (against `Curator::TokenCounter`) and page-aware in one pass. |
| 8 | Basic extractor format scope | **`text/plain`, `text/markdown`, `text/csv`, `text/html`** (HTML via Nokogiri text-strip, already a Rails transitive dep). PDF and docx rejected with `Curator::UnsupportedMimeError` pointing at `config.extractor = :kreuzberg`. No new runtime deps on `pdf-reader`/`docx`. |
| 9 | Dedup surface + `ingest_directory` return | **`Curator::IngestResult` value object** (`document:, status: :created\|:duplicate\|:failed, reason:`). `Curator.ingest` and `Curator.ingest_directory` both return `IngestResult`(s). Rake task groups by `status` for summary output. No `DuplicateDocument` exception — duplicates are expected flow. |
| 10 | Re-ingestion in M2 | **In scope.** `Curator.reingest(document)` + `curator:reingest DOCUMENT=<id>` rake task. Transactionally deletes chunks (cascade handles future embeddings), resets status to `:pending`, re-enqueues `IngestDocumentJob` against the existing attached blob. No re-hash. Needed in-house for M3/M4 chunker iteration. |

Inline decisions (made without asking):

- **Per-KB extractor override**: out of scope for M2; schema has no
  per-KB extractor field. `config.extractor` is global. Revisit in v2.
- **`config.max_document_size`** enforced in `Curator.ingest` *before*
  any DB write; oversize raises `Curator::FileTooLargeError`.
- **Active Job adapter**: whatever the host configures. Curator does
  not prescribe one.
- **Chunk size / overlap**: read from `document.knowledge_base` at job
  time, not from globals. Per-KB values already exist in the schema.
- **No `DuplicateDocument` exception**: dedup is expected flow; surfaced
  as an `IngestResult#status`, not an error.
- **Error hierarchy**: all new errors (`ExtractionError`,
  `UnsupportedMimeError`, `FileTooLargeError`) inherit `Curator::Error`.
