# Code Quality Refactor — services, DRY, and Rails-omakase alignment

Cross-cutting cleanup pass after M5. No new user-facing surface; the
goal is to shrink `lib/curator.rb`, slim the ingest jobs and the
documents controller, and dedup the three KB-resolution and two
retrieval-row-lifecycle copies. Everything in this file is internal —
public APIs (`Curator.ingest`, `Curator.retrieve`, `Curator.ask`,
`Curator.reembed`) keep their current signatures and return shapes.

**Reference**: post-M5 structured code review (see `git log` around
the date this file lands). The review surfaced 7 DRY duplications, 9
ruby-skill rule findings, and 6 architectural deviations from
Rails-omakase. This file bundles the high-value subset; deferred items
are listed under "Out of Scope" at the bottom.

## Current Work

_(empty — promote a phase from Next Steps when starting)_

## Next Steps

- [x] **Phase 1 — Quick fixes (no-op private, strong-params relocation).**
   - `app/models/curator/knowledge_base.rb:114` — replace the bare
     `private` keyword (which is a no-op for class methods) with
     `private_class_method :with_default_lock` after the `def
     self.with_default_lock` body. The current code falsely advertises
     privacy on a public singleton method.
   - Move `EDITABLE_PARAMS` / `LOCKED_PARAMS` constants and the
     `KnowledgeBase.permitted_params(action:)` class method off the
     model and into `KnowledgeBasesController` as private constants +
     a `permitted_params(action:)` private method. HTTP/form policy
     belongs in the controller layer (`arch:layer:model`). The
     `disabled` form attributes in `_form.html.erb` already enforce
     the lock client-side; the controller is the right server-side
     enforcement seat.
   - **Validate**: full spec suite green; `bundle exec rubocop` clean.
     A request spec asserting that `PATCH knowledge_base#update` with
     `embedding_model:` and `slug:` in the params **silently drops
     them** (no 422, no error — strong params just filters) confirms
     the relocation didn't loosen the gate.

- [x] **Phase 2 — Lift KB resolution and embedding-dim lookup.**
   - Add `Curator::KnowledgeBase.resolve(arg)` that handles
     `nil → default!`, `KnowledgeBase → arg`, `String|Symbol → find_by!(slug:)`,
     else → `ArgumentError`. Replace three copy-pasted bodies:
     - `lib/curator.rb:332-345` (`resolve_knowledge_base`)
     - `lib/curator/retrievers/pipeline.rb:61-71` (`resolve_kb`)
     - `lib/curator/reembed.rb:52-62` (`resolve_kb`)
   - Replace `lib/curator/reembed.rb:112-114`'s
     `embedding_column_dim` with a call to the existing
     `Curator::Embedding.dimension`.
   - **Validate**: existing specs that exercise each call site
     (slug lookup, KB instance pass-through, nil → default, garbage
     input → ArgumentError) stay green without spec edits. Grep for
     `find_by!(slug:` to confirm only one call site remains.

- [x] **Phase 3 — Retrieval row lifecycle on `Curator::Retrieval`.**
   - Add `Curator::Retrieval.open_for(pipeline:, **chat_extras)` that
     creates the row with the snapshot columns
     (`knowledge_base`, `query`, `chat_model`, `embedding_model`,
     `retrieval_strategy`, `similarity_threshold`, `chunk_limit`)
     populated from the pipeline + KB, plus optional
     `strict_grounding` / `include_citations` / `chat_id` extras the
     ask path passes. Returns nil when `Curator.config.log_queries`
     is false so callers don't have to repeat the guard.
   - Add `Curator::Retrieval#mark_failed!(error, started_at:)` that
     replaces the byte-identical methods at
     `lib/curator/retriever.rb:69-76` and
     `lib/curator/asker.rb:227-234`.
   - Add `Curator::Retrieval#mark_success!(started_at:, **extras)`
     for the symmetric close path used by both Retriever and Asker.
   - Both `Retriever#run` and `Asker#run` shrink to: open row →
     pipeline.call → mark_success/mark_failed → build return value.
   - **Validate**: full retrieval + ask spec suites green with no
     spec edits. The `:failed`-row regression specs (mid-flight raise
     in vector_search, LLM error in ask) still see a row with the
     same column shape they assert today.

- [x] **Phase 4 — Service-object hygiene (`.call` shims, Hybrid → module).**
   - Add `def self.call(...) = new(...).call` shim to
     `Curator::Retriever`, `Curator::Asker`, `Curator::Reembed`,
     `Curator::Retrievers::Pipeline`. Update internal call sites
     (`lib/curator.rb` ask/retrieve/reembed) to use the shim.
     Public API unchanged; this is internal cleanup so service
     objects follow the standard `.call`-class-method idiom
     (`arch:service:interface`).
   - Convert `Curator::Retrievers::Hybrid` from a class with
     `#call` + `self.fuse` to `module Hybrid` with
     `module_function :fuse`. Delete the unused `#call` instance
     method (it's dead — `Pipeline#run_hybrid` runs Vector +
     Keyword directly so it can record candidate counts in the
     trace payload, then calls `Hybrid.fuse`).
   - **Validate**: `bundle exec rubocop` and full spec suite green.
     Grep for `Hybrid.new` to confirm zero callers remain.

- [x] **Phase 5 — Extract `Curator::Documents::Ingest` service.**
   - New `app/services/curator/documents/ingest.rb` (`.call`
     class method shim) owning what `lib/curator.rb`'s
     `ingest_from_file`, `ingest_from_url`, `enforce_size_precheck!`,
     `enforce_normalized_size!`, `derive_file_source_url`,
     `cheap_byte_size`, and `create_document!` currently do. Returns
     `Curator::IngestResult` — same return shape callers depend on.
   - `Curator.ingest(input, **kwargs)` becomes a 5-line facade:
     URL-vs-file dispatch + delegate to the service. Same for
     `Curator.ingest_directory`.
   - New `app/services/curator/documents/process_ingestion.rb`
     extracts `IngestDocumentJob#run_pipeline!` /
     `prepare_for_embedding` / `extract` / `chunk` /
     `with_extractor_tempfile` / `persist_chunks!` /
     `validate_chunk_rows!`. The job becomes ~10 lines:
     `find_by(id:)` → `ProcessIngestion.call(document)` → enqueue
     `EmbedChunksJob` if state is right. Per
     `arch:job:delegation` 🔴.
   - New `app/services/curator/documents/embed_chunks.rb` extracts
     `EmbedChunksJob`'s `embed_batch!` / `embed_one_by_one!` /
     `persist_embedding!` / `finalize_document!`. Job becomes a
     dispatcher.
   - **Validate**: full ingest spec suite green with no spec edits.
     The "duplicate content_hash" recovery, "URL ingest with
     `download` filename → falls back to URL as title", and
     "per-input rejection re-runs one-by-one" regressions all still
     pass. `app/jobs/curator/ingest_document_job.rb` ends up under
     20 lines; `lib/curator.rb` ends up under 200 lines.

- [x] **Phase 6 — Thin `DocumentsController#create` via `IngestBatch`.**
   - New `app/services/curator/documents/ingest_batch.rb` that takes
     `kb:` + `files:`, iterates `Curator.ingest(file, knowledge_base: kb)`,
     rescues `Curator::Error` / `ActiveRecord::RecordInvalid` per
     file, and returns a `Result(counts:, failures:)` value object.
     Subsumes `DocumentsController#ingest_one`.
   - Move `summary_flash` and the `FAILURE_REASONS_IN_FLASH`
     constant to a `Curator::DocumentsHelper` (or keep in the
     controller as a private formatter — formatting is the
     controller's job, while ingest orchestration is the service's).
   - `DocumentsController#create` becomes ~7 lines: `Array(files)`,
     blank-reject, early-return if empty, `IngestBatch.call`, build
     flash, redirect.
   - **Validate**: `spec/requests/curator/documents_spec.rb` and the
     M5 admin smoke spec green with no edits. The "no files
     selected" branch, the "mixed success + duplicate + failed"
     summary, and the "failures uniq + first-N truncation" behavior
     all still hold.

- [x] **Phase 7 — Small DRY cleanups.**
   - `Curator::Chunk.refresh_tsvector!(ids:, config:)` class method
     that runs the `to_tsvector(?::regconfig, content)` update.
     Replaces `app/models/curator/chunk.rb:28-31`'s instance
     callback body and `lib/curator/reembed.rb:125-128`'s `:all`
     branch.
   - `Curator::Hit.from_chunk(chunk, rank:, score:)` factory.
     Replaces `build_hit` private methods at
     `lib/curator/retrievers/vector.rb:39-52` and
     `lib/curator/retrievers/keyword.rb:47-59`.
   - `Curator::Document#status_badge_class` instance method
     returning the badge CSS class for the current status. Replaces
     the inlined `badge_class = { "pending" => …, … }.fetch(...)`
     hashes at `_document.html.erb:7-14` and `_header.html.erb:8-15`.
     Render-context-agnostic (no helper needed), so it survives the
     turbo-broadcast render path that doesn't carry the engine's
     helpers.
   - `app/helpers/curator/application_helper.rb` adds `def
     curator_routes; Curator::Engine.routes.url_helpers; end`.
     Replaces the `<% url = Curator::Engine.routes.url_helpers %>`
     incantations at `_card.html.erb:6` and `_document.html.erb:30`.
   - **Validate**: spec suite + rubocop clean. Visual smoke of the
     KB index, documents index (broadcast row replace), and document
     show (header replace via embedding broadcast) — all three were
     the original reasons the inlined workarounds existed.

## Out of Scope (deferred)

These came up in the review but don't fit this bundle:

- **Rename `is_default` column to `default`** — schema migration +
  `default?` predicate alignment (`style:naming:predicate`). Touches
  external callers (host-app SQL, dashboards) so it deserves its own
  migration ticket with a deprecation window, not a refactor commit.
- **`Document#chunk_status_counts` → query object** — boundary case
  per `arch:layer:model`. Defensible as a model method today;
  promote to `Curator::Documents::ChunkStatusCounts` only if a
  second consumer appears.
- **Consolidate `Document`'s six `after_*_commit` hooks** — debatable
  readability win at best. Rails community treats `Turbo::Broadcastable`
  as the canonical exception to `model:callbacks:no-external`.
- **`Tracing.write_step!` sequence-via-COUNT** — fine under v1's
  single-threaded-per-retrieval assumption. Revisit when M6 streaming
  or M7 evaluations introduce concurrent step writes against the
  same retrieval row.

## Implementation Notes

**Why now and not later**: M5 closed the first end-user-facing
surface. M6 (LLM token streaming, Query Console) will add
`/api/stream` plumbing and a new admin scope that both touch
`Curator::Asker` and the retrieval-row write path. Doing the
retrieval-lifecycle dedup (Phase 3) and the service-object hygiene
(Phase 4) before M6 means M6 builds on the cleaned shape rather than
pasting a third copy of `mark_failed!`.

**Ingest extraction (Phase 5) is the largest delta**: ~400 lines move
from `lib/curator.rb` and the two ingest jobs into three new service
objects. The public `Curator.ingest` / `ingest_directory` surface is
preserved. The risk is incidental behavior drift in error paths —
mitigated by leaving every existing spec untouched and fixing
regressions until they pass.

**No new dependencies**: every change is internal restructuring of
existing code. No new gems, no new generators, no schema changes.
This file should land in one or two PRs (Phases 1–4 in one, Phase 5
in its own, Phases 6–7 either bundled or split per appetite).

## Parallelization

Phase 1 and Phase 2 are independent. Phase 3 depends on Phase 2 (uses
the lifted `KnowledgeBase.resolve` indirectly through Pipeline).
Phase 4 depends on Phase 3 (the `.call` shim conversion includes
Retriever/Asker, which are simplest to convert *after* their bodies
shrink in Phase 3). Phase 5 is independent of 1–4 and is the largest
chunk; safe to run in parallel with 1–4 in a separate worktree.
Phases 6 and 7 depend on Phase 5 (Phase 6 calls `Curator.ingest`
which by then routes through `Documents::Ingest`; Phase 7's Hit
factory touches retrievers cleaned in Phase 4).

```
Phase 1 ─┐
Phase 2 ─┼─► Phase 3 ─► Phase 4 ─┐
                                   ├─► Phase 6 ─► Phase 7
Phase 5 ──────────────────────────┘
```

### Merge-conflict watch list

- **`lib/curator.rb`** — Phase 2 edits `resolve_knowledge_base`;
  Phase 5 deletes ~half the file. Rebase Phase 5 on top of Phase 2
  to make Phase 5's deletions a clean removal of an
  already-extracted helper.
- **`lib/curator/retriever.rb`** + **`asker.rb`** — Phase 3 rewrites
  both; Phase 4 adds `.call` shims to both. Bundle Phases 3 + 4 in
  one branch if running them sequentially; otherwise Phase 4 is a
  trivial append on top of Phase 3.
- **`app/jobs/curator/ingest_document_job.rb`** — Phase 5 strips it
  to a dispatcher. No other phase touches it.
- **`spec/`** — every phase asserts "specs green with no edits".
  If a spec needs updating, that's a signal the refactor changed
  observable behavior — pause and reconcile before continuing.
