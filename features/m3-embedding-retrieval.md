# M3 — Embedding + Retrieval

Real embedding pipeline (replacing M2's stub `EmbedChunksJob`) plus the
retrieval primitives that everything downstream depends on: vector,
keyword, and hybrid search backed by pgvector + tsvector, fused via
RRF. Ships `Curator.search` returning `Curator::SearchResults` and
`curator:reembed` for model swaps and partial-failure cleanup. No LLM
synthesis yet (M4 wires `Curator.ask` on top of these primitives).

**Reference**: `features/implementation.md` → "Implementation Milestones" → M3,
plus the "Retrieval Pipeline", "Service Object API", and "Database Schema"
(curator_searches / curator_search_steps) sections.

## Completed

_(none yet — M2 closed Phase 7, this milestone starts at P1)_

## Current Work

- [-] Phase 1 — KB schema (`chunk_limit`) + per-chunk tsvector_config + dimension-mismatch error
   - Add `chunk_limit` (integer, NOT NULL, default 5) to
     `curator_knowledge_bases` by editing the existing
     `create_curator_knowledge_bases.rb.tt` template under
     `lib/generators/curator/install/templates/`. Pre-v1 the schema
     is still mutable — no additive migration needed. Post-v1 this
     shortcut goes away (per CLAUDE.md), but for now editing the
     create template keeps the schema diff in one place.
   - `Curator::KnowledgeBase` validates
     `chunk_limit: { numericality: { only_integer: true,
     greater_than: 0 } }`. Default factory value 5.
   - **Tsvector config fix** — today
     `create_curator_chunks.rb.tt` defines the virtual column as
     `to_tsvector('english'::regconfig, content)`, hard-coding
     english regardless of the parent KB's `tsvector_config`. So
     a KB with `tsvector_config: "spanish"` would silently get an
     english-stemmed index, mismatched against its
     spanish-parsed queries. Fix by denormalizing the config
     onto chunks:
     - Add `tsvector_config string null: false` to
       `curator_chunks` (edit `create_curator_chunks.rb.tt`).
     - Change the virtual column to
       `to_tsvector(tsvector_config::regconfig, content)` — same
       row, generated-column rules satisfied.
     - `Curator::Chunk` `before_validation` callback copies
       `document.knowledge_base.tsvector_config` into the chunk
       on first save (or set explicitly by the chunker — TBD in
       P2 wiring).
     - KB-config flips become a reembed-class operation: the
       `:all` reembed scope (Phase 6) also rewrites
       `chunks.tsvector_config` before re-embedding, so the
       virtual column re-evaluates with the new regconfig.
     - Carve-up rationale: language-mixed corpora are modeled as
       sibling KBs (e.g. `support-en` / `support-es`), not one
       polyglot KB. Per-KB `tsvector_config` stays useful; we
       just have to honor it on the chunks side.
   - `Curator::EmbeddingDimensionMismatch < Curator::EmbeddingError`
     in `lib/curator/errors.rb`. Carries the expected and actual dim
     for an actionable message ("model 'voyage-3' produces 1024-dim
     vectors; column is 1536-dim — this requires a schema migration
     and full reembed").
   - `bin/reset-dummy` after the template edits land so
     `spec/dummy/db/**` reflects the new columns before any
     subsequent specs run.
   - **Validate:** see Phase 1 checklist below.

## Next Steps

- [ ] Phase 2 — `EmbedChunksJob` real body
   - **First: verify `RubyLLM.embed` batching contract** —
     does `RubyLLM.embed(array_of_strings, model: ...)` accept
     arrays and return parallel Embedding objects, or is it
     single-input only? If single-input, the batching loop
     dispatches one HTTP call per chunk but keeps
     `embedding_batch_size` as a back-pressure governor (chunked
     concurrency, not chunked payload). All downstream P2 work
     hangs on this — pin it before writing the loop.
   - Pull `document.chunks.where(status: :pending)` (filtering at the
     query naturally short-circuits AJ retries — already-embedded
     chunks are invisible on the second perform; no upsert dance
     needed).
   - Batch into `Curator.config.embedding_batch_size` (default 100)
     groups. For each batch: call `RubyLLM.embed(texts,
     model: kb.embedding_model)`, persist
     `curator_embeddings(chunk_id:, embedding:, embedding_model:)`,
     transition the chunks to `:embedded`. Embedding model is
     snapshotted per-row so mid-reembed retrieval can filter (Q7).
   - **Per-chunk rejection**: provider 4xx for one input out of a
     batch (token overflow, encoding, content moderation) → mark just
     that chunk `:failed`, continue with the rest of the batch.
     Provider error message persisted (added column `embed_error
     text` on `curator_chunks`? — see Phase 1 follow-up below).
     **Decision pending**: whether per-chunk error text lives in a
     new column on `curator_chunks` or only in `curator_search_steps`
     trace rows. Default plan: new `embed_error text nullable`
     column, surfaced in admin UI's chunk inspector. Track as P2
     sub-decision.
   - **Whole-batch failure** (rate-limit, 5xx, network, auth): raise.
     Active Job retry-with-backoff owns final disposition. Already-
     embedded chunks are skipped on retry by the `:pending` filter.
   - After the loop: if every chunk in the document is terminal
     (`:embedded` ∪ `:failed`), `document.update!(status: :complete)`.
     `Document#failed_chunk_count` (+ `#partially_embedded?`) computed
     from the chunks association — no denormalized column.
   - **Validate:** see Phase 2 checklist.

- [ ] Phase 3 — Vector retrieval + `Curator.search` (vector mode only)
   - `Curator::SearchResults` value object
     (`Data.define(:query, :hits, :duration_ms, :knowledge_base,
     :search_id)`). `#empty?`, `#each` delegating to `hits`.
   - `Curator::Hit` value object
     (`Data.define(:rank, :chunk_id, :document_id, :document_name,
     :page_number, :text, :score, :source_url)`). Built by
     retrieval strategies; ranks 1-indexed. Field names mirror
     the underlying columns (`chunks.page_number`,
     `documents.source_url`) for grep-ability.
   - `Curator::Retrieval::EmbeddingScoped` — shared concern (or
     module) that vector + hybrid include. Provides the scope
     `Curator::Embedding.where(embedding_model: kb.embedding_model)`,
     the mid-reembed safety guarantee. Keyword retrieval does
     **not** include this — it scopes through documents (P4),
     so `:pending` / `:failed` chunks remain visible to
     keyword search.
   - `Curator::Retrieval::Vector#call(kb, query_vec, limit:, threshold:)`:
     `nearest_neighbors(:embedding, query_vec, distance: "cosine")
     .limit(limit)`, then drops hits below `threshold` cosine.
     Builds Hit list with rank assigned in cosine-descending order
     and `score:` populated.
   - `Curator.search(query, knowledge_base: nil, limit: nil,
     threshold: nil, strategy: nil)`:
     - Default `knowledge_base:` → `KnowledgeBase.default!`.
     - Resolve KB by instance / slug string / symbol (mirror
       `Curator.ingest`'s pattern).
     - Empty / whitespace-only `query` → `ArgumentError`.
     - Wraps the call in a `curator_searches` row write
       (status, snapshot config — `chat_id` / `message_id` null on
       `.search`-only paths). `config.log_queries = false` skips
       the row write entirely.
     - `Curator::EmbeddingError` from RubyLLM → search row
       `:failed`, error re-raised.
   - Trace steps: `embed_query` (model, input_token_count,
     duration), `vector_search` (candidate_count, top-rank
     chunk_ids, duration). Gated by `Curator.config.trace_level`.
   - **Validate:** see Phase 3 checklist.

- [ ] Phase 4 — Keyword retrieval
   - `Curator::Retrieval::Keyword#call(kb, query, limit:)`:
     `Chunk.joins(:document).where(documents.knowledge_base_id =
     kb.id)` joined to `where("content_tsvector @@
     plainto_tsquery(?, ?)", kb.tsvector_config, query)`,
     ordered by `ts_rank(content_tsvector,
     plainto_tsquery(?, ?))` descending, limited to `limit`.
   - **Note**: keyword retrieval scopes through `documents`, not
     through `embeddings`, since chunks may exist without
     embeddings (status `:pending` / `:failed`). Document-level
     `knowledge_base_id` is the join column; embedding_model
     filtering doesn't apply to pure-keyword retrieval (no
     embeddings involved).
   - Hit `score: nil` (tsvector rank is length-dependent and not
     useful enough to surface — Q6).
   - `Curator.search(strategy: :keyword)` wired through. If
     `strategy: :keyword` is passed alongside a non-nil
     `threshold:`, raise `ArgumentError` (threshold is meaningless
     in pure-keyword mode; silent ignore would be a footgun).
   - Trace step: `keyword_search` (candidate_count, top-rank
     chunk_ids, duration).
   - **Validate:** see Phase 4 checklist.

- [ ] Phase 5 — Hybrid retrieval (RRF fusion)
   - **Query-embedding ownership**: `Curator.search` embeds the
     query *once* at the top, then passes both `query` (string,
     for keyword) and `query_vec` (for vector) into the
     strategy. Vector and Hybrid both consume `query_vec`;
     neither strategy re-embeds. Keyword ignores `query_vec`.
   - `Curator::Retrieval::Hybrid#call(kb, query, query_vec,
     limit:, threshold:)`: runs Vector and Keyword in sequence
     (no Threads / Async — the host's DB connection pool isn't
     guaranteed to support concurrent checkout from one request),
     fuses ID lists via `Neighbor::Reranking.rrf(vector_ids,
     keyword_ids)`, top-K from the fused list.
   - **Threshold applied to vector hits *before* fusion** (Q3) —
     filter the vector list, then hand the survivors plus the full
     keyword list to RRF.
   - Hit `score:` carries the underlying cosine for chunks that
     came through the vector half (Q6 — `score: nil` only if a
     hit was keyword-only and never appeared in the vector
     candidates).
   - `Curator.search` defaults to `strategy:` from the KB. The full
     three-way override allowlist (`%i[hybrid vector keyword]`) is
     validated at the top of `.search`.
   - Trace step: `rrf_fusion` (input list lengths, output count,
     duration).
   - **Validate:** see Phase 5 checklist.

- [ ] Phase 6 — `Curator.reembed` + `curator:reembed` rake task
   - `Curator.reembed(knowledge_base:, scope: :stale)` library
     API. Common control flow for every scope:
     1. **Resolve work first** — query the chunk set the scope
        names (see definitions below). If empty, return
        `{ documents_touched: 0, chunks_touched: 0, scope: }`
        immediately. No pre-flight, no provider call.
     2. **Pre-flight only when there's work** — embed a 1-token
        dummy with `kb.embedding_model`, assert dim matches
        column, else `Curator::EmbeddingDimensionMismatch`.
        Avoids paying a provider round-trip on a clean KB.
     3. Per-document: delete stale embedding rows in a
        transaction, mark chunks `:pending`, reset
        `document.status` to `:embedding`, enqueue
        `EmbedChunksJob`.
   - Scope definitions:
     - `:stale` — chunks whose embedding row has
       `embedding_model ≠ kb.embedding_model`, *plus* chunks in
       `:failed` (no usable embedding). **Excludes `:pending`** —
       those are mid-flight from normal ingestion; sweeping them
       up causes double-work with in-progress `EmbedChunksJob`s.
     - `:failed` — strict subset of `:stale`: only `Chunk.where(
       status: :failed)` for the KB. Use when the operator
       wants to retry just the failures without re-embedding
       model-stale chunks.
     - `:all` — every chunk in the KB. Nukes embeddings, all
       chunks → `:pending`, all documents → `:embedding`. Also
       rewrites `chunks.tsvector_config` from the KB's current
       value (this is the path operators take after flipping
       `kb.tsvector_config` — see Phase 1 fix).
   - Returns a result struct:
     `{ documents_touched:, chunks_touched:, scope: }`.
   - `curator:reembed KB=<slug> [SCOPE=stale|failed|all]` rake task
     delegates to the library. **When `stale` finds zero chunks**,
     stdout prints "no stale chunks found — try `SCOPE=failed`
     for partial-failure cleanup or `SCOPE=all` for a full
     re-embed". When work is enqueued, prints "re-embedding N
     chunks across M documents (scope=stale)". Adapter-aware
     execution mirrors `curator:ingest` (`:async` adapter swaps
     to `:inline` for the task duration so `bundle exec rake`
     finishes its own work; real workers left alone).
   - Admin UI hook is **deferred to M5+** (depends on document
     management views landing first). Ideation note in this
     file is the breadcrumb for the dropdown spec when M5
     reaches Document Management.
   - **Validate:** see Phase 6 checklist.

- [ ] Phase 7 — End-to-end retrieval smoke + parity sweep
   - `spec/requests/curator/retrieval_smoke_spec.rb` — full
     pipeline: ingest fixtures → `perform_enqueued_jobs` (real
     embed pipeline, RubyLLM stubbed at HTTP) → `Curator.search`
     across all three strategies, asserting non-empty hits, rank
     monotonicity, snapshot row presence. Reembed scope=all on the
     KB; assert all chunks transition through `:pending` →
     `:embedded`, document back to `:complete`, search still works
     against the new vectors.
   - Update `spec/requests/curator/ingestion_smoke_spec.rb`'s
     "advances doc to :complete" assertion: now `:complete` means
     real embeddings present (was: stub flip). Test the
     observable contract — count of embedding rows == count of
     chunks — not the implementation.
   - **Validate:** full `bundle exec rspec --format progress` +
     `bundle exec rubocop` green.

## Files Under Development

```
lib/
├── curator.rb                                # add Curator.search, Curator.reembed
├── curator/
│   ├── errors.rb                             # add EmbeddingDimensionMismatch
│   ├── search_results.rb                     # NEW Data.define
│   ├── hit.rb                                # NEW Data.define
│   ├── retrieval/
│   │   ├── embedding_scoped.rb               # NEW — concern: embedding_model scope (vector + hybrid)
│   │   ├── vector.rb                         # NEW
│   │   ├── keyword.rb                        # NEW
│   │   └── hybrid.rb                         # NEW (Neighbor::Reranking.rrf)
│   └── reembed.rb                            # NEW orchestrator
├── generators/curator/install/templates/
│   ├── create_curator_knowledge_bases.rb.tt   # add chunk_limit column
│   └── create_curator_chunks.rb.tt            # add embed_error + tsvector_config columns; virtual column reads tsvector_config
└── tasks/
    └── curator.rake                          # add curator:reembed task
app/
├── jobs/curator/
│   └── embed_chunks_job.rb                   # replace stub with real body
└── models/curator/
    ├── chunk.rb                              # before_validation: copy tsvector_config from KB
    ├── document.rb                           # add #failed_chunk_count, #partially_embedded?
    └── knowledge_base.rb                     # validates :chunk_limit
spec/
├── curator/
│   ├── retrieval/
│   │   ├── vector_spec.rb                    # NEW (real pgvector)
│   │   ├── keyword_spec.rb                   # NEW (real tsvector)
│   │   └── hybrid_spec.rb                    # NEW (RRF integration)
│   ├── search_results_spec.rb                # NEW
│   ├── hit_spec.rb                           # NEW
│   ├── search_spec.rb                        # NEW — Curator.search public API
│   └── reembed_spec.rb                       # NEW
├── jobs/curator/
│   └── embed_chunks_job_spec.rb              # rewrite — real-body coverage
├── tasks/
│   └── curator_reembed_rake_spec.rb          # NEW
├── requests/curator/
│   ├── ingestion_smoke_spec.rb               # update :complete assertion
│   └── retrieval_smoke_spec.rb               # NEW E2E
└── support/
    └── ruby_llm_stubs.rb                     # NEW — WebMock for /embeddings
```

## Validation Strategy

### Phase 1 — KB schema + tsvector fix + error type
- [ ] `bin/reset-dummy` succeeds; `spec/dummy/db/schema.rb` shows
      `chunk_limit` integer NOT NULL default 5 on
      `curator_knowledge_bases`, and `tsvector_config` string
      NOT NULL on `curator_chunks`.
- [ ] `KnowledgeBase.new(chunk_limit: 0).valid?` is false; error on
      `:chunk_limit`.
- [ ] `KnowledgeBase.create!(...)` without specifying `chunk_limit`
      uses the column default (5).
- [ ] Spanish-KB indexing parity: create a KB with
      `tsvector_config: "spanish"`, ingest a chunk containing
      "corriendo", inspect the row's `content_tsvector` — must
      contain the spanish stem `corr`, NOT `corriendo`. Same
      chunk text under an english KB stays as `corriendo` (no
      english stem). Proves the virtual column reads the
      per-chunk `tsvector_config`, not a hard-coded literal.
- [ ] `Curator::EmbeddingDimensionMismatch.new(expected: 1536,
      actual: 1024).message` contains the actionable pointer
      ("requires a schema migration and full reembed") plus both
      numbers.

### Phase 2 — `EmbedChunksJob` real body
- [ ] Happy path: ingest a 3-chunk fixture, `perform_enqueued_jobs`,
      every chunk transitions to `:embedded`, every chunk has a
      `curator_embeddings` row with `embedding_model` matching
      `kb.embedding_model`, document `:complete`.
- [ ] Per-chunk rejection: WebMock returns a 400 for one item in a
      batch of three; the other two embed cleanly, the rejected
      chunk lands `:failed`, document still progresses to
      `:complete`. `document.failed_chunk_count == 1`.
- [ ] Whole-batch failure: WebMock returns 503 for the whole batch;
      job raises, AJ retries, a subsequent successful run completes
      without re-embedding the chunks that succeeded on the first
      partial run (i.e. the `:pending` filter actually short-circuits).
- [ ] Embedding batch size honored: `config.embedding_batch_size = 2`
      on a 5-chunk doc → 3 batches (2/2/1), verified via WebMock
      request count.
- [ ] `EmbedChunksJob` is a no-op if the document was deleted
      mid-flight (mirrors P5 of M2's deleted-doc handling).
- [ ] `Document#partially_embedded?` returns true iff any
      `failed` chunks present, false on clean :complete docs.

### Phase 3 — Vector retrieval + `Curator.search`
- [ ] Empty / whitespace query raises `ArgumentError` before any DB
      write — no `curator_searches` row created.
- [ ] `Curator.search(query, knowledge_base: kb)` returns a
      `Curator::SearchResults` with hits ordered by descending
      cosine. `hits.first.rank == 1`.
- [ ] `threshold:` kwarg overrides the KB default; hits below the
      override cosine are dropped.
- [ ] `limit:` kwarg overrides KB.chunk_limit.
- [ ] KB with zero chunks → empty `hits`, status `:success`,
      `curator_searches` row written.
- [ ] Mid-reembed simulation: insert a chunk with embedding_model
      "old-model"; KB.embedding_model is "new-model". Search
      doesn't return that chunk.
- [ ] `RubyLLM.embed` raising → `Curator::EmbeddingError` re-raised,
      `curator_searches` row marked `:failed` with the error
      message.
- [ ] `config.log_queries = false` → no `curator_searches` row, hits
      still returned.
- [ ] Trace level `:full` → `embed_query` + `vector_search`
      `curator_search_steps` rows with non-empty payload.
- [ ] Trace level `:summary` → step rows present, payload `{}`.
- [ ] Trace level `:off` → no step rows.

### Phase 4 — Keyword retrieval
- [ ] `Curator.search(query, knowledge_base: kb, strategy:
      :keyword)` returns hits ordered by tsvector rank desc.
- [ ] `score` is `nil` on every hit.
- [ ] `strategy: :keyword` + non-nil `threshold:` → `ArgumentError`.
- [ ] Hits scope to KB: chunks in another KB don't appear.
- [ ] `:pending` / `:failed` chunks DO appear in keyword results
      (no embedding required).
- [ ] Tsvector config respected end-to-end (index AND query):
      KB with `tsvector_config: "simple"` indexes "running" as
      `running` and a query for "run" misses; same KB with
      `tsvector_config: "english"` indexes as `run` and the
      query hits. Proves Phase 1's index-side fix flows
      through to Phase 4's query-side `plainto_tsquery(
      kb.tsvector_config, query)`.
- [ ] `keyword_search` step row written when trace is on.

### Phase 5 — Hybrid retrieval
- [ ] Default `Curator.search(query, knowledge_base: kb)` runs
      hybrid (KB default), fuses results.
- [ ] Threshold filters the *vector* list before fusion: raise
      threshold to 0.99 → vector list empty → hybrid result equals
      keyword-only result.
- [ ] A chunk that's a top-1 vector hit AND a top-1 keyword hit
      ranks above either single-list strong hit (RRF fusion math
      verified end-to-end).
- [ ] `score:` populated for hits that came through the vector half;
      `nil` for keyword-only contributions.
- [ ] `strategy:` allowlist enforced — `Curator.search(..., strategy:
      :foo)` → `ArgumentError`.
- [ ] `rrf_fusion` step row written when trace is on, payload has
      input list lengths.

### Phase 6 — `Curator.reembed` + rake task
- [ ] `Curator.reembed(knowledge_base: kb)` (default `scope:
      :stale`) on a clean KB (everything matches) → no work,
      result struct shows `chunks_touched: 0`. **Pre-flight
      embed call is not made** — verify via WebMock that no
      `/embeddings` request was issued.
- [ ] After flipping `kb.embedding_model` → `:stale` re-embeds every
      stale chunk; embedding rows end up with the new model.
- [ ] `:stale` excludes `:pending` chunks: a chunk in `:pending`
      with no embedding row is left alone (no enqueue, no status
      flip), so a concurrent in-flight `EmbedChunksJob` doesn't
      collide with the reembed sweep.
- [ ] `:failed` scope only touches `:failed` chunks; model-stale
      `:embedded` chunks are left as-is.
- [ ] `:all` scope nukes and re-embeds even up-to-date chunks,
      and rewrites `chunks.tsvector_config` from the KB's
      current value (so a `kb.tsvector_config` flip followed by
      `SCOPE=all` reembed re-stems the corpus).
- [ ] Pre-flight dim mismatch: stub `RubyLLM.embed` to return a
      1024-dim vector when column is 1536; on a KB with at least
      one chunk in scope, `:stale` / `:failed` / `:all` all
      raise `Curator::EmbeddingDimensionMismatch` *before* any
      embedding row is touched.
- [ ] `bundle exec rake curator:reembed KB=default` exits 0 and
      prints `re-embedding N chunks across M documents`.
- [ ] `bundle exec rake curator:reembed KB=default` on a no-work KB
      prints the SCOPE=failed / SCOPE=all suggestions.
- [ ] `bundle exec rake curator:reembed KB=default SCOPE=all` works.
- [ ] Adapter swap: with `queue_adapter: :async` the rake task
      finishes synchronously; with `queue_adapter: :inline` it
      doesn't double-invoke.

### Phase 7 — End-to-end smoke
- [ ] `bundle exec rspec` exits 0.
- [ ] `bundle exec rubocop` exits 0.
- [ ] M2's ingestion smoke spec still green (assertion updated to
      check real embedding rows, not stubbed status flip).
- [ ] M3 retrieval smoke spec exercises ingest → embed → search
      across all three strategies + reembed cycle on a single test
      KB.

## Implementation Notes

**RubyLLM embed API**: batching contract verification is
pinned as the first sub-bullet of P2 (don't write the loop
until the array-vs-single-input behavior is known). Either
way, a single WebMock helper in
`spec/support/ruby_llm_stubs.rb` should expose
`stub_embed(model:, vectors:)` that fakes the OpenAI
`/embeddings` endpoint with whatever fixture vectors the test
supplies. Real provider HTTP must never hit the wire from specs.

**`embed_error` column on `curator_chunks`**: P2 adds a nullable
text column for per-chunk provider error messages (token-overflow
detail, encoding rejection, content-moderation refusal). Pre-v1
the column lands by editing the existing
`create_curator_chunks.rb.tt` template directly — no additive
migration. Surfaced in admin UI chunk inspector in M5; for now
it's just data, no UI yet.

**Why keyword scopes through documents, not embeddings**: pure
keyword retrieval doesn't need embeddings (the whole point —
it's the fallback when nothing has been embedded yet, or when
the operator wants exact-match semantics). Joining through
`documents.knowledge_base_id` keeps `:pending` / `:failed`
chunks visible to keyword search. The mid-reembed
`embedding_model` filter only applies to vector + hybrid.

**Hybrid concurrency**: vector and keyword run *sequentially*,
not in threads. Reasons: (1) the underlying ActiveRecord pool
doesn't guarantee a second connection is available without
explicit `with_connection`, (2) a 50ms vector + 30ms keyword
sequential is 80ms; the connection-checkout dance for parallel
saves maybe 30ms but adds real complexity. Threads are a v2
optimization if profiling demands it.

**`Neighbor::Reranking.rrf`**: confirm the API shape during P5.
Current understanding from neighbor README: takes ordered ID
arrays, returns the fused ID array. If it returns scores too,
`Hit#score` for keyword-only contributions can carry the RRF
score instead of nil — but that contradicts Q6's "cosine or
nil." Stick to nil for non-vector contributions even if RRF
exposes a fused score.

**Trace-level enforcement**: implement once in a
`Curator::Tracing.record(search:, step_type:, payload:, ...)`
helper that consults `Curator.config.trace_level` and either
no-ops, writes step_type+timing only, or persists the full
payload. Each retrieval strategy calls the helper; the
strategies don't know about trace levels themselves.

**Generated dummy schema reminder**: editing any migration
template under `lib/generators/curator/install/templates/`
means running `bin/reset-dummy` to rebuild `spec/dummy/db/**`
before specs see the change. Phase 1 (chunk_limit +
tsvector_config) and the P2 `embed_error` column all trigger
this. M1's standing rule.

**Tsvector config carve-up**: per-KB `tsvector_config` is
preserved (different KBs really do hold different languages),
but the column is *also* denormalized onto chunks so the
generated `content_tsvector` virtual column can read its own
config rather than a hard-coded literal. Mixed-language
corpora are modeled as sibling KBs (`support-en` /
`support-es`), not one polyglot KB — the keyword-search
query side can only reasonably parse one config per query, so
language separation at the KB boundary keeps both index and
query honest. Vector retrieval is cross-lingual via the
embedding model and unaffected.

**Strict-grounding interaction**: M3 doesn't ship the
"I don't have information on that" fallback prompt — that's
M4's prompt-assembler work. M3's contract: `SearchResults#hits`
is empty when nothing crosses threshold. M4 reads that and
emits the strict-grounding message.

## Ideation Notes

Captured from `/ideate` session on 2026-04-25.

| # | Question | Conclusion |
|---|---|---|
| 1 | Document terminal status when chunks fail | **`:complete` once every chunk is terminal** (`:embedded` ∪ `:failed`). No new status; partial state surfaced via `Document#failed_chunk_count` / `#partially_embedded?` and the admin "needs attention" panel. Per-chunk failures are infrequent and mostly deterministic (token-overflow, encoding, content moderation) — re-trying won't help, so blocking the document forever is wrong. |
| 2 | Does `Curator.search` write a `curator_searches` row? | **Always.** `chat_id` / `message_id` are nullable; `.search` rows have them null, `.ask` rows populate them. Unified observability — same admin table, same export pipeline. `config.log_queries = false` opts out for privacy-sensitive deployments. |
| 3 | `similarity_threshold` semantics across strategies | **Cosine cutoff applied pre-fusion to vector hits only.** Keyword hits enter RRF unfiltered. Pure-keyword mode ignores threshold. Tsvector ranks aren't probabilities and RRF scores are post-fusion artifacts — neither admits a sensible threshold without bespoke tuning. |
| 4 | `curator:reembed` shape | **Single task with `SCOPE=stale\|failed\|all`**, default `stale`. When `stale` finds no work, stdout points at `failed` and `all`. Admin UI exposes the same three scopes as a per-document "Re-embed" dropdown (deferred to M5+). Handles model swap, partial-failure retry, and full nuke through one mental model. |
| 5 | `Curator.search` kwargs | **`(query, knowledge_base:, limit:, threshold:, strategy:)`** — every KB default is overridable per-call. Effective values snapshotted on `curator_searches`. `ArgumentError` if `strategy: :keyword` and `threshold:` are both passed. Corpus filtering (`document_ids:` / `metadata:`) deferred to v2. (Revised mid-session: original answer was strategy-locked; flipped after weighing M5/M6 Query Testing Console UX.) |
| 5b | Default `chunk_limit` source | **Add `chunk_limit` column to `curator_knowledge_bases`** (default 5). Per-KB tunable — small precise KBs want fewer hits, sparse research KBs want more. Per-call `limit:` kwarg overrides the column. |
| 6 | `hit.score` semantics | **Cosine similarity when vector retrieval ran** (vector + hybrid); **`nil` for keyword-only.** RRF only changes ordering — the underlying vector hits in hybrid mode still have a meaningful cosine. Tsvector rank isn't useful enough to surface. Caller code already has to handle nil (pure-keyword KBs). |
| 7 | Mid-reembed search safety | **Filter `WHERE embedding_model = KB.embedding_model`** on every vector / hybrid retrieval query. During reembed, only already-migrated chunks are visible — KB temporarily shrinks then grows back, no garbage cosines from cross-model comparisons. Strict-grounding may correctly say "I don't know" mid-window. Free safety; no schema cost. |

**Inline decisions (made without asking):**

- **`EmbedChunksJob` retry idempotency**: filter chunks `WHERE
  status = :pending` at job start. Already-embedded chunks
  invisible naturally; no upsert / delete-insert dance needed.
- **Empty / whitespace `query`**: raises `ArgumentError` before
  any work — no `curator_searches` row, no embed call.
  Oversized queries (provider token-limit overflow) bubble up
  as `Curator::EmbeddingError`; the search row is `:failed`.
- **KB with zero queryable chunks**: empty `SearchResults#hits`,
  status `:success` (not `:failed`). Operator-visible
  distinction between "we ran but found nothing" and
  "we couldn't run."
- **`Curator::EmbeddingDimensionMismatch`**: new error type,
  inherits `Curator::EmbeddingError`. Raised from reembed
  pre-flight.
- **HNSW index params**: stay at pgvector defaults (no
  `m` / `ef_construction` tuning) for v1.
- **Embedding job spans only one document**: no cross-document
  batching. Keeps retry semantics scoped and admin UI
  per-document progress meaningful.
- **`embed_error` column on `curator_chunks`**: nullable text
  for per-chunk provider error message. Surfaced in admin
  chunk inspector in M5; M3 just persists the data.
- **Keyword retrieval scopes through documents**, not
  embeddings — keyword works on `:pending` / `:failed` chunks
  too; `embedding_model` filter is vector / hybrid only.
- **Hybrid concurrency**: vector + keyword run sequentially,
  not threaded. Threads are a v2 profiling-driven optimization.
