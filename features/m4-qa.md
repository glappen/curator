# M4 — Q&A

LLM synthesis on top of M3's retrieval primitives. Ships
`Curator.ask(query, knowledge_base:, ...)` returning
`Curator::Answer` (wraps `RetrievalResults` + answer text + chat / message
FKs), with optional streaming via a block that yields String deltas.
Adds the prompt assembler (`[N]` markers, strict-grounding refusal,
`include_citations` toggle), per-ask RubyLLM `Chat` + `Message`
persistence, and `prompt_assembly` / `llm_call` trace steps. The
shared retrieval seam between M3's `Retriever` and the new `Asker`
gets factored out so each entry point owns its own `curator_retrievals`
row from the start.

**Reference**: `features/implementation.md` → "Implementation
Milestones" → M4, plus the "Service Object API", "Citation System",
"Retrieval Pipeline → Strict grounding", and "Database Schema"
(curator_retrievals snapshot columns) sections.

## Next Steps

- [x] **Phase 1 — Schema additions + value objects + error wiring.**
   - Edit `create_curator_retrievals.rb.tt` to add two snapshot
     columns: `strict_grounding boolean` and
     `include_citations boolean`, both nullable (matches the existing
     pattern where snapshot columns can be null on a `:failed` row
     captured before the LLM step ran). `bin/reset-dummy` to
     regenerate `spec/dummy/db/schema.rb`.
   - `Curator::Answer` (`Data.define(:answer, :retrieval_results,
     :retrieval_id, :strict_grounding)`) with `def sources =
     retrieval_results.hits` and `def refused? = retrieval_results.empty?
     && strict_grounding`. Required at `lib/curator.rb` alongside
     `RetrievalResults` / `Hit`.
   - `Curator::LLMError` already exists — no new error type needed.
     Confirm `RubyLLM::Error` translation spot is the Asker's LLM
     call site (mirrors how `EmbeddingError` wraps in `Retriever`).
   - **No `Curator.ask` entry point yet** — this phase is just the
     foundational types and schema so later phases compile cleanly.

- [x] **Phase 2 — Extract shared retrieval core from `Retriever`.**
   - New `Curator::Retrievers::Pipeline` class encapsulates the
     M3 retrieval flow: validate query / strategy, resolve KB,
     compute effective `limit` / `threshold` / `strategy`, embed
     query when needed, run the chosen strategy, emit `embed_query`
     / `vector_search` / `keyword_search` / `rrf_fusion` trace
     steps. Takes the already-opened `curator_retrievals` row as an
     argument; doesn't open or close it itself.
   - `Retriever#call` becomes: open retrieval row → `Pipeline.new(...)
     .call(retrieval_row)` → close row with `:success` /
     `:failed`. Behavior identical for `Curator.retrieve` callers;
     pure refactor.
   - `Asker` (Phase 4) reuses `Pipeline` directly. Asker's
     retrieval row is opened *with* `chat_id` / `message_id` /
     `strict_grounding` / `include_citations` snapshots populated
     from the start — no backfill.
   - **Validate**: full M3 spec suite still green with no spec
     edits. Pipeline unit-tested for the four trace-emitting
     strategies (`vector` / `keyword` / `hybrid` / blank-query
     guard).

- [x] **Phase 3 — Prompt assembler (`Curator::Prompt::Assembler`).**
   - `Curator::Prompt::Templates` constants:
     - `DEFAULT_INSTRUCTIONS_WITH_CITATIONS` — citation rule
       ("Reference sources using `[N]` markers"), strict-grounding
       rule, no-context fallback phrasing.
     - `DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS` — same minus the
       citation rule.
     - `REFUSAL_MESSAGE` — hardcoded "I don't have information on
       that in the knowledge base." (per-KB override deferred to
       v2.)
   - `Curator::Prompt::Assembler#call(kb:, hits:)` returns
     `{ system_prompt_text:, system_prompt_hash:, prompt_token_estimate: }`:
     - **Instructions half**: `kb.system_prompt.presence ||
       (kb.include_citations ? DEFAULT_INSTRUCTIONS_WITH_CITATIONS
       : DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS)`. KB override
       replaces only this half — the context block format stays
       Curator-controlled so operators can't accidentally remove
       citation behavior.
     - **Context block**: rendered from `hits` as
       `[<rank>] From "<document_name>" (page <page_number>):\n
       <text>` joined by blank lines. Pages omitted when nil.
       Empty `hits` → empty context block (the LLM still gets the
       instructions; strict-grounding skip happens *before* the
       LLM call, in Phase 6).
     - **Hash**: `Digest::SHA256.hexdigest(system_prompt_text)`,
       grouping key for v2 analytics.
     - **Token estimate**: `Curator::TokenCounter.count(
       system_prompt_text)` — heuristic, used only for trace
       payload visibility, not enforcement.
   - Snapshotted to `curator_retrievals.system_prompt_text` +
     `system_prompt_hash` when the row is updated.
   - **No coupling to retrieval or LLM in this phase** — the
     assembler is a pure function over `(kb, hits)`.

- [x] **Phase 4 — `Curator.ask` non-streaming happy path.**
   - `Curator::Asker.new(query, knowledge_base:, limit:, threshold:,
     strategy:, system_prompt:, chat_model:)` orchestrator. KB
     resolution mirrors `Retriever` (instance / slug / symbol /
     nil → `default!`).
   - **Search row first, with snapshots**: opens
     `curator_retrievals` immediately (when
     `Curator.config.log_queries`), writing the effective
     `chat_model` / `embedding_model` / `retrieval_strategy` /
     `similarity_threshold` / `chunk_limit` /
     `strict_grounding` / `include_citations` snapshots up
     front. `chat_id` / `message_id` / `system_prompt_*` get
     filled in once those artifacts exist.
   - **Pipeline call**: `Curator::Retrievers::Pipeline.new(...)
     .call(retrieval_row)` returns hits + effective values.
     `effective_strategy` may differ from the override (e.g.
     KB-default fallthrough) — Asker uses what Pipeline
     resolves.
   - **Prompt assembly**: trace step
     `prompt_assembly` payload `{ hit_count, system_prompt_hash,
     prompt_token_estimate }`. Updates `retrieval_row` with
     `system_prompt_text` / `system_prompt_hash`.
   - **Persistence: RubyLLM `Chat` row** — `Chat.create!(model_id:
     resolved_chat_model_id, curator_scope: nil)`. Uses
     `RubyLLM::Models.resolve(chat_model)` to map the configured
     model name onto a `models` row. Tied to the retrieval row via
     `retrieval_row.update!(chat_id: chat.id)`.
   - **LLM call**: `chat.with_instructions(system_prompt_text)
     .ask(query)` (no block in this phase). RubyLLM's
     `acts_as_chat` persists the user message + assistant
     message rows automatically. Wrapped in
     `Curator::Tracing.record(step_type: :llm_call,
     payload_builder: ->(msg) { { model: msg.model_id,
     input_tokens: msg.input_tokens, output_tokens:
     msg.output_tokens, finish_reason: msg.finish_reason,
     streamed: false } })`. `RubyLLM::Error` re-raised as
     `Curator::LLMError`.
   - **Search row finalization**: `retrieval_row.update!(
     message_id: assistant_message.id, status: :success,
     total_duration_ms: ...)`.
   - Returns `Curator::Answer.new(answer: assistant_message.content,
     retrieval_results: <built from pipeline hits>, retrieval_id:
     retrieval_row.id, strict_grounding: kb.strict_grounding)`.
   - `Curator.ask(query, **kwargs)` module method delegates to
     `Asker.new(...).call`. Mirrors the `Curator.retrieve` shape.

- [x] **Phase 5 — Persistent retrieval-hit history (`curator_retrieval_hits`).**
   - **Why this phase exists**: with Phase 4 shipped, a past
     `Curator::Retrieval` row is missing the one thing M5 admin and
     M7 evaluations both need — the hits the LLM actually saw.
     Trace `top_chunk_ids` carries first-five chunk IDs at
     `:full` only, no scores, no rank-beyond-5, and breaks the
     moment a chunk is re-chunked or its document is deleted. A
     real audit trail needs its own table.
   - New `create_curator_retrieval_hits.rb.tt` migration template:
     ```
     t.references :retrieval, null: false,
                  foreign_key: { to_table: :curator_retrievals, on_delete: :cascade }
     t.bigint  :chunk_id                               # nullable
     t.bigint  :document_id                            # nullable
     t.integer :rank,           null: false
     t.decimal :score, precision: 7, scale: 6          # nullable; keyword-only is nil
     t.string  :document_name,  null: false            # snapshot
     t.integer :page_number                            # snapshot
     t.text    :text,           null: false            # snapshot
     t.string  :source_url                             # snapshot
     add_index [:retrieval_id, :rank], unique: true
     add_foreign_key :curator_retrieval_hits, :curator_chunks,
                     column: :chunk_id,    on_delete: :nullify
     add_foreign_key :curator_retrieval_hits, :curator_documents,
                     column: :document_id, on_delete: :nullify
     ```
     `document_name` / `page_number` / `text` / `source_url` are
     snapshotted at query time so the row survives downstream
     `Curator.reingest` (which destroys + recreates chunks) and
     `document.destroy`. Both FKs nullify-on-delete — `chunk_id`
     becomes nil when the chunk is gone, but the snapshot text
     keeps the hit reconstructable.
   - `Curator::RetrievalHit` AR model: `belongs_to :retrieval`,
     `belongs_to :chunk, optional: true`,
     `belongs_to :document, optional: true`. Add
     `has_many :retrieval_hits, dependent: :destroy` on
     `Curator::Retrieval`.
   - **Pipeline owns the write, not Asker / Retriever.**
     `Curator::Retrievers::Pipeline#call` bulk-inserts via
     `Curator::RetrievalHit.insert_all(rows)` immediately before
     returning, when `retrieval_row` is non-nil. One round-trip per
     ask; failure raises and propagates so the existing
     `mark_failed!` wrapper flips the row to `:failed`. Centralizing
     the write here means `Curator.retrieve` *also* gets the audit
     trail with no duplication — operators using retrieval-only
     flows (M5 query console, future API endpoints) get the same
     history shape.
   - New `Curator::Answer.from_retrieval(retrieval)` class method
     (and `Curator::Retrieval#to_answer` sugar):
     - `answer` from `retrieval.message.content`.
     - `retrieval_results.hits` from
       `retrieval.retrieval_hits.order(:rank).map { |h| Curator::Hit.new(...) }`.
     - `retrieval_results.duration_ms` / `knowledge_base` /
       `query` / `retrieval_id` from the row's snapshot columns.
     - `strict_grounding` from `retrieval.strict_grounding` snapshot.
     - Raises `ArgumentError` if `retrieval.message_id.nil?` —
       failed asks and `Curator.retrieve`-only rows have no Answer
       to reconstruct (the row has hits but no assistant text).
   - **Forward-only**: pre-Phase-5 `curator_retrievals` rows have no
     hit rows and reconstruct to an Answer with `sources == []`. No
     backfill — the trace `top_chunk_ids` payload is too lossy and
     dev/staging rows aren't worth a migration script.
   - **Validate**: round-trip parity — `Curator.ask(...)` →
     `Curator::Answer.from_retrieval(Curator::Retrieval.find(answer.retrieval_id))`
     returns an Answer whose `answer`, `sources` (rank, chunk_id,
     document_name, page_number, text, score), and
     `strict_grounding` match the original. `Curator.reingest` on
     the source document afterwards leaves the hit text intact and
     flips `chunk_id` to nil. `Curator.retrieve` writes hits too
     (M3 `retriever_spec` gains a hit-row assertion). Hit insert
     failure marks the row `:failed`.

- [x] **Phase 6 — Streaming block.**
   - `Asker#call(&block)` accepts an optional block. When given,
     the LLM call becomes
     `chat.with_instructions(system_prompt_text).ask(query) do
     |chunk| block.call(chunk.content) end` — Curator unwraps
     RubyLLM's `Chunk` to its `.content` `String` before yielding
     to the caller. Nil-content chunks (the final usage-only
     event) are filtered out.
   - `llm_call` trace payload sets `streamed: true` for the
     streaming branch.
   - **Retry interaction**: `Curator.config.llm_retry_count`
     wires into RubyLLM's faraday-retry middleware via
     `RubyLLM.context { |c| c.max_retries = ... }`, applied per
     ask by setting `chat.context = llm_context` before
     `with_instructions`/`ask`. **Note**: faraday-retry's
     "pre-body only" framing turns out to be aspirational for SSE
     streams — when an SSE error chunk raises a retryable
     RubyLLM error, the middleware *does* replay the request, and
     partial deltas already yielded to the caller's block will
     be re-yielded on the next attempt. Streaming consumers that
     need at-most-once delivery should set `llm_retry_count = 0`.
   - The block is called for every ask that runs to the LLM /
     refusal step. Zero block calls only when the ask raises
     before reaching `llm_call` / refusal (e.g. embedding
     failure). The aggregated answer text on
     `Curator::Answer#answer` is identical whether streaming was
     used or not — RubyLLM's stream accumulator builds the final
     `Message#content` regardless.

- [x] **Phase 7 — Strict-grounding refusal path.**
   - When `pipeline_hits.empty? && kb.strict_grounding`, Asker
     skips the LLM entirely:
     - Emits the `prompt_assembly` trace step (still useful — it
       captures that the assembler ran with zero hits and what
       the system prompt would have looked like).
     - **No `llm_call` step.** Absence of the row is the admin-UI
       signal for "we never asked the LLM."
     - Persists the refusal manually: `chat.add_message(role:
       :user, content: query)` then `chat.add_message(role:
       :assistant, content: REFUSAL_MESSAGE)`. RubyLLM's
       persistence hooks fire — the messages land in the same
       schema any other ask uses.
     - When a streaming block was given, yields
       `REFUSAL_MESSAGE` as a single chunk before returning.
     - Returns `Curator::Answer` as usual; `#refused?` → true
       (snapshotted strict_grounding flag + empty hits).
   - When `kb.strict_grounding == false` and hits are empty,
     the LLM is called normally with an empty context block —
     it answers from training data. `Answer#refused?` → false
     (strict_grounding snapshot is false).
   - **Why hardcode**: `REFUSAL_MESSAGE` lives as a constant on
     `Curator::Prompt::Templates`. v2 may add a per-KB override
     column once operators ask; the column doesn't earn its
     keep yet (zero feedback signal pre-v1).

- [x] **Phase 8 — End-to-end Q&A smoke + parity sweep.**
   - `spec/requests/curator/ask_smoke_spec.rb`: full chain
     `Curator.ingest` → IngestDocumentJob → EmbedChunksJob (suite
     `stub_embed`, plus a new `stub_chat_completion` for
     `/v1/chat/completions`) → `Curator.ask` happy path →
     `Curator.ask` with streaming block → `Curator.ask` against a
     KB with no relevant content (refusal path, asserts no
     `/v1/chat/completions` request via WebMock) →
     `Curator.ask(... include_citations: false)` parity (KB
     copy with `include_citations: false`, asserts assembled
     prompt uses non-citing template). Confirms one `Chat` +
     two `Message` rows + one `curator_retrievals` row (with
     `chat_id` / `message_id` / `system_prompt_*` populated)
     per ask, plus N `curator_retrieval_hits` rows whose
     reconstruction via `Curator::Answer.from_retrieval` matches
     the live Answer. Three KBs by construction: a populated
     default for happy/streaming, an empty KB for the refusal
     case (zero docs forces empty hits), and a populated copy
     with `include_citations: false` for the parity case.
   - **M3 retrieval smoke spec stays green** — Phase 2's
     extraction is a pure refactor, M3 specs assert no behavior
     change beyond Pipeline being where the work happens.
   - **Phase-1 schema parity in M3 ingestion smoke**: re-ingest
     after schema change must still drive docs to `:complete` —
     adding nullable columns to `curator_retrievals` doesn't
     touch ingestion, so the existing assertions hold.
   - **Validate**: `bundle exec rspec --format progress` exits 0,
     `bundle exec rubocop` reports no offenses.

## Files Under Development

```
app/models/curator/
├── retrieval.rb                               # add has_many :retrieval_hits (Phase 5)
└── retrieval_hit.rb                           # NEW AR model (Phase 5)
lib/
├── curator.rb                                 # add Curator.ask, require curator/asker, prompt/*, answer
├── curator/
│   ├── answer.rb                              # Data.define + .from_retrieval (Phase 5)
│   ├── asker.rb                               # NEW orchestrator
│   ├── prompt/
│   │   ├── assembler.rb                       # NEW pure-function assembler
│   │   └── templates.rb                       # NEW constants (DEFAULT_INSTRUCTIONS_*, REFUSAL_MESSAGE)
│   ├── retrievers/
│   │   └── pipeline.rb                        # extracted (Phase 2); bulk-inserts hits (Phase 5)
│   └── retriever.rb                           # row-lifecycle wrapper around Pipeline
└── generators/curator/install/templates/
    ├── create_curator_retrievals.rb.tt        # add strict_grounding + include_citations columns
    └── create_curator_retrieval_hits.rb.tt    # NEW (Phase 5)
spec/
├── curator/
│   ├── answer_spec.rb                         # add .from_retrieval coverage (Phase 5)
│   ├── asker_spec.rb                          # NEW — Curator.ask public API + Asker behaviors
│   ├── models/
│   │   └── retrieval_hit_spec.rb              # NEW (Phase 5)
│   ├── prompt/
│   │   └── assembler_spec.rb                  # NEW — pure-function tests
│   └── retrievers/
│       └── pipeline_spec.rb                   # add hit-write assertion (Phase 5)
├── requests/curator/
│   └── ask_smoke_spec.rb                      # NEW E2E
└── support/
    └── ruby_llm_stubs.rb                      # add stub_chat_completion / stub_chat_completion_stream
```

## Validation Strategy

### Phase 1 — Schema + Answer + error wiring
- [x] `bin/reset-dummy` succeeds; `spec/dummy/db/schema.rb` shows
      `strict_grounding boolean` and `include_citations boolean`
      (both nullable) on `curator_retrievals`.
- [x] `Curator::Answer.new(answer: "x", retrieval_results:
      <empty RetrievalResults>, retrieval_id: 1, strict_grounding: true)
      .refused?` is true.
- [x] Same with `strict_grounding: false` is false.
- [x] Same with non-empty retrieval_results regardless of
      strict_grounding is false.
- [x] `Curator::Answer#sources` returns `retrieval_results.hits`.

### Phase 2 — Pipeline extraction
- [x] Full M3 spec suite still green — no edits to existing M3
      specs (the refactor is observable only via internal
      reorganization).
- [x] `Curator::Retrievers::Pipeline` unit specs cover:
      blank query → ArgumentError, unknown strategy →
      ArgumentError, `:keyword` + `threshold:` → ArgumentError,
      `:vector` happy path emits `embed_query` + `vector_search`
      steps, `:keyword` happy path emits only `keyword_search`,
      `:hybrid` emits `embed_query` + `rrf_fusion`.
- [x] `Retriever#call` is now thin (validates, opens row,
      delegates to Pipeline, closes row). No retrieval-specific
      logic remains in Retriever.

### Phase 3 — Prompt assembler
- [x] With `kb.include_citations: true` and `kb.system_prompt: nil`,
      assembler returns prompt text containing the default
      citation rule string (`"[N]"` substring present).
- [x] With `kb.include_citations: false` and `kb.system_prompt: nil`,
      assembler returns prompt text *without* the citation rule.
- [x] With `kb.system_prompt: "Custom instructions."`, prompt
      starts with `"Custom instructions."` followed by the
      Curator-built context block — the override replaces only
      the instructions half.
- [x] Context block format: each hit rendered as
      `[<rank>] From "<document_name>" (page <page>):\n<text>`,
      blocks separated by blank lines.
- [x] Hits with `page_number: nil` render without the page
      parenthetical.
- [x] Empty `hits:` produces a prompt with instructions but no
      context block (assembler doesn't decide refusal — Asker
      does).
- [x] `system_prompt_hash` is stable across runs for identical
      inputs; differs for different KBs / hit sets.
- [x] `prompt_token_estimate` is positive integer matching
      `Curator::TokenCounter.count(system_prompt_text)`.

### Phase 4 — `Curator.ask` non-streaming
- [x] Happy path: `Curator.ask("...")` against a KB with
      relevant content returns `Curator::Answer` with non-empty
      `answer`, `sources` populated from retrieved hits, and
      `retrieval_id` referencing a `curator_retrievals` row whose
      `chat_id` / `message_id` / `system_prompt_text` /
      `system_prompt_hash` / `strict_grounding` /
      `include_citations` are all populated.
- [x] Exactly one `chats` row, one `messages` row with
      `role: "user"` and content == query, and one with
      `role: "assistant"` and content == answer text.
- [x] `chats.curator_scope` is nil.
- [x] Trace shows `embed_query` + retrieval-strategy step +
      `prompt_assembly` + `llm_call`, in order, all
      `status: :success`.
- [x] `chat_model:` override at call time → `chat.model_id`
      reflects the override; `curator_retrievals.chat_model`
      snapshot reflects the override; KB's column unchanged.
- [x] `system_prompt:` override at call time → assembled
      prompt uses the override as the instructions half;
      `curator_retrievals.system_prompt_text` reflects the
      override-derived prompt.
- [x] RubyLLM provider raising `RubyLLM::Error` →
      `Curator::LLMError` propagates; `curator_retrievals.status
      == "failed"`, `error_message` populated, `chat_id`
      populated, `message_id` nil (no assistant message ever
      persisted).
- [x] `config.log_queries = false` → no `curator_retrievals`
      row, but the Chat / Message / Answer round-trip still
      works. `Answer#retrieval_id` is nil.

### Phase 5 — Persistent retrieval-hit history
- [x] `bin/reset-dummy` succeeds; `spec/dummy/db/schema.rb` shows
      `curator_retrieval_hits` with the column set above and a
      unique index on `(retrieval_id, rank)`.
- [x] `Curator.ask("...")` writes one `curator_retrieval_hits`
      row per returned hit. `rank` matches the in-memory
      `Hit#rank` (1-indexed); `text`, `document_name`,
      `page_number`, `source_url` match the chunk / document
      state at query time; `score` matches for vector and hybrid
      contributors and is nil for keyword-only hits.
- [x] `Curator.retrieve("...")` (no LLM) writes hit rows too —
      Pipeline owns the persistence so retrieval-only callers
      get the audit trail. M3 `retriever_spec` gains an
      assertion for this.
- [x] `Curator::Answer.from_retrieval(retrieval)` returns an
      Answer whose `answer`, `sources` (rank, chunk_id,
      document_name, page_number, text, score),
      `retrieval_results.query`, `retrieval_results.knowledge_base`,
      `retrieval_results.duration_ms`, `retrieval_id`, and
      `strict_grounding` match the live Answer returned by the
      original `Curator.ask` call.
- [x] After `Curator.reingest(document)` on a doc that
      contributed hits, the `curator_retrieval_hits` rows survive
      with `chunk_id` nil and `text` / `document_name`
      unchanged. Reconstructed Answer still surfaces the
      original hit text.
- [x] After `document.destroy`, the retrieval_hits rows survive
      with both `chunk_id` and `document_id` nil; the snapshot
      columns still render. After
      `knowledge_base.destroy`, the cascade takes
      retrievals → retrieval_hits with it (gone).
- [x] `Curator::Answer.from_retrieval` raises `ArgumentError`
      when called on a row with `message_id: nil` (e.g. a
      `Curator.retrieve`-only row, or a `:failed` ask).
- [x] Forcing `RetrievalHit.insert_all` to raise (stub)
      propagates the error and marks the parent row
      `:failed` via the existing `mark_failed!` wrapper —
      hit persistence is part of the operation, not best-effort.
- [x] Pre-Phase-5 retrieval rows (no hit-table rows)
      reconstruct to an Answer with `sources == []` rather than
      raising — the migration is forward-only and historical
      rows degrade gracefully.

### Phase 6 — Streaming block
- [x] `Curator.ask("...") { |delta| collected << delta }` → the
      block is called multiple times with `String` deltas
      whose concatenation equals `Answer#answer`.
- [x] Trace `llm_call` payload has `streamed: true`.
- [x] Non-streaming `Curator.ask("...")` payload has
      `streamed: false`.
- [x] `Curator.config.llm_retry_count = 3` propagates to
      RubyLLM's retry config (verified via WebMock — three
      503 responses then a 200 → call succeeds).
- [x] Streaming + SSE error event with `llm_retry_count = 0`:
      partial deltas yielded once, `Curator::LLMError` raised,
      single HTTP request, retrieval row marked `:failed`.
      (Documents the at-most-once-delivery option for streaming
      consumers; with retries enabled the partial deltas can
      replay across attempts.)

### Phase 7 — Strict-grounding refusal
- [x] KB with `strict_grounding: true` + query that matches
      no chunks above threshold:
      - `Answer#answer == REFUSAL_MESSAGE`
      - `Answer#refused?` is true
      - `Answer#sources.empty?`
      - WebMock confirms zero requests to
        `/v1/chat/completions`
      - `chats` row exists with one `:user` and one
        `:assistant` message; assistant content is
        `REFUSAL_MESSAGE`
      - Trace has `prompt_assembly` step, no `llm_call` step
      - `curator_retrievals.status == "success"`
- [x] Same KB with `strict_grounding: false`, same empty-hits
      query:
      - LLM is called (one `/v1/chat/completions` request)
      - `Answer#refused?` is false
      - Context block in the assembled prompt is empty but
        instructions are present
- [x] Streaming refusal: `Curator.ask("...") { |delta|
      collected << delta }` against the strict-empty case →
      block called exactly once with `delta == REFUSAL_MESSAGE`.

### Phase 8 — End-to-end smoke
- [x] `bundle exec rspec` exits 0.
- [x] `bundle exec rubocop` exits 0.
- [x] M3 retrieval + ingestion smoke specs stay green —
      no behavior change beyond the new hit rows.
- [x] M4 ask smoke spec exercises ingest → embed → ask
      (streamed + non-streamed) → strict-refusal →
      include_citations parity, on a single test KB, plus a
      reconstruction round-trip via
      `Curator::Answer.from_retrieval`.

## Implementation Notes

**RubyLLM `acts_as_chat` persistence**: M2/M3 didn't touch the
`chats` / `messages` tables — M4 is the first milestone that
writes through them. The `Chat.create!` / `chat.ask(...)` path
relies on RubyLLM's `acts_as_chat` callbacks to persist the
user + assistant `Message` rows; we don't manually `Message.create!`.
For the strict-grounding refusal path (no LLM call) the messages
go through `chat.add_message(role:, content:)` which `acts_as_chat`
also persists — verified during Phase 7 against the dummy app.

**Pipeline factoring is a pure refactor**: Phase 2 is the only
phase that risks breaking M3, so its validation gate is the M3
spec suite running unchanged. Resist the temptation to also
"improve" Pipeline's tracing or kwarg shape mid-extraction —
behavior changes belong in their own phases.

**Assembler is a pure function**: `Curator::Prompt::Assembler#call`
takes `(kb:, hits:)` and returns a hash. No DB writes, no LLM
calls, no global state. This makes Phase 3 testable with plain
`build` factories and lets the Query Console (M5/M6) call it
directly to preview prompts before running them.

**Streaming + retry interaction**: faraday-retry's contract is
that retries happen *before* the response body begins streaming.
Once the first byte arrives, the request is committed. Document
this in the configuration comment for `llm_retry_count`. M6
(`/api/stream` endpoint) inherits the same constraint —
operators expecting "transparent retries during a stream" will
be surprised, so the docs need to call it out.

**`curator_scope: nil` reservation**: M8's `curator:chat_ui`
generator is the only thing that should populate `curator_scope`.
Tagging ad-hoc `Curator.ask` chats with `"ask"` would overload
the column with two semantic axes ("which UI" + "is this an API
ask"), forcing chat UIs to filter on conjunction. The KB
association is on `curator_retrievals.knowledge_base_id`;
`Chat.where(curator_scope: nil)` finds all ad-hoc asks across
all KBs.

**Hit snapshot vs. live FK (Phase 5)**: `curator_retrieval_hits`
denormalizes `text` / `document_name` / `page_number` /
`source_url` instead of joining through `chunk_id` at read time.
The reason is that chunks are mutable in M2/M3 — `Curator.reingest`
destroys + recreates them with current chunking settings, and
`document.destroy` removes them outright. Without the snapshot a
past Q&A loses its source text the moment its underlying document
changes, which defeats the audit-trail purpose of the table. The
live FK (`chunk_id`) is preserved with `on_delete: :nullify` so
admin UIs can still link to the current chunk *when it exists*
and render a "source no longer available" affordance otherwise.
Cost: ~1KB per hit row; for the v1 chunk_limit default of 5,
that's ~5KB per ask. Acceptable for the audit-trail value.

**Pipeline owns hit persistence, not Asker / Retriever (Phase 5)**:
the bulk insert lives in `Curator::Retrievers::Pipeline#call`, not
in either caller's wrapper. Two reasons: (1) `Curator.retrieve`
should also build the same audit trail, and pushing the write
into Pipeline gives both callers one shared write site;
(2) failure modes stay coherent — if the insert raises, the
existing `mark_failed!` at the Retriever / Asker level catches
it and flips the row to `:failed` without either caller needing
to know hit persistence happened. Phase 5 is the second pure-add
to Pipeline (after Phase 2's extraction); both callers stay thin.

**Snapshot column proliferation**: `curator_retrievals` now
carries chat_model, embedding_model, retrieval_strategy,
similarity_threshold, chunk_limit, system_prompt_text,
system_prompt_hash, strict_grounding, include_citations. This
is the M4 plateau — every per-call configuration that affects
the answer is captured at query time so v2 analytics can
A/B by any of them. New KB columns added in v2+ should add
matching snapshot columns here as a rule.

**`REFUSAL_MESSAGE` is a constant for v1**: per-KB override
column is a v2 add. The reasoning matches the M3 decision on
`hit.score`: ship the simplest thing that captures the
behavior, add the override once operators have hit the wall
on it. The constant lives on `Curator::Prompt::Templates` so
test code can reference it without string duplication.

**Token-window truncation deferred**: M3's default `chunk_limit:
5` keeps assembled prompts well under any realistic model's
context window. M4 doesn't trim chunks if the assembled prompt
overflows — the LLM call would fail and Curator surfaces
`LLMError`. v2 work: tokenizer-aware trimming of the lowest-
ranked hits until the prompt fits, with a trace step recording
which hits were dropped.

**Empty-string LLM response**: rare but possible (model
refuses, safety filter triggers post-check, etc.). Persist as-is
— assistant `Message` row exists with `content: ""`, retrieval row
is `:success`, `Answer#answer == ""`. Operators see this in the
admin search index and act on it via evaluations. Treating it
as a failure would force callers to handle a special case for
behavior that's already representable through the success path.

**Test-side LLM stubbing**: `spec/support/ruby_llm_stubs.rb`
gains `stub_chat_completion(model:, content:)` for non-streamed
responses and `stub_chat_completion_stream(model:, deltas:)`
for SSE-style streamed responses. Both follow the existing
`stub_embed` pattern (default-installed in `before(:each)` so
smoke specs work without per-spec wiring; tighter stubs in
specs that assert call counts).

## Ideation Notes

Captured from `/ideate` session on 2026-04-27.

| # | Question | Conclusion |
|---|---|---|
| 1 | `Curator.ask` ↔ `Curator.retrieve` row relationship | **Factor the retrieval core into a shared seam** (`Curator::Retrievers::Pipeline`). `Retriever` and `Asker` each open their own `curator_retrievals` row; Asker's row carries `chat_id` / `message_id` / `system_prompt_*` from creation — no backfill, no cross-coupling. M3's Retriever becomes a thin wrapper around Pipeline. |
| 2 | RubyLLM `Chat` persistence per ask | **New `Chat` row per `Curator.ask`, `curator_scope: nil`.** Spec is explicit: "every `Curator.ask` creates a real `Chat` + user and assistant `Message` rows." `curator_scope` reserved for M8 chat-UI generators; tagging ad-hoc asks would overload the column. Chat pruning is host-app responsibility. |
| 3 | Strict-grounding execution path | **Skip the LLM call entirely on no-hits.** Synthesize refusal in Ruby, persist as the assistant message via RubyLLM's `add_message`, yield as a single `String` chunk to streaming blocks, emit `prompt_assembly` trace step with no `llm_call`. Absence of `llm_call` is the admin-UI signal. `status: :success`. Hardcoded `REFUSAL_MESSAGE` constant; per-KB override deferred. |
| 4 | Streaming block protocol | **Block yields `String` deltas.** Curator unwraps RubyLLM's `Chunk` to `chunk.content`. Chunk-level metadata (token counts, finish reason) stays internal — captured in trace steps + persisted assistant `Message`. Refusal path yields exactly one string. M6's `/api/stream` becomes `Curator.ask(...) { \|delta\| stream.write(delta) }`. |
| 5 | `Curator.ask` kwarg signature | **`(query, knowledge_base:, limit:, threshold:, strategy:, system_prompt:, chat_model:)`** — search's signature plus per-call prompt + chat-model overrides. `chat_model:` snapshotted to power side-by-side comparison in M5/M6 Query Console. `strict_grounding` / `include_citations` stay KB-only for v1; revisit only if Query Console UX demands. |
| 6 | System-prompt template structure & KB override | **Two-part assembly; `kb.system_prompt` replaces only the *instructions* half.** Final prompt = `(kb.system_prompt \|\| DEFAULT_INSTRUCTIONS)` + context block. Curator always builds the context block — operators can never accidentally remove citation behavior. `include_citations: false` swaps the default instructions for a non-citing variant; context-block format unchanged. |
| 7 | LLM retry semantics | **Wire `llm_retry_count` into RubyLLM's faraday-retry middleware.** Pre-body retries only — once streaming starts, no replay. One `llm_call` trace step per ask regardless of retry count. Document the streaming-incompatibility explicitly in implementation notes + config comment. |
| 8 | `Curator::Answer` shape | **`Data.define(:answer, :retrieval_results, :retrieval_id, :strict_grounding)`** with `def sources = retrieval_results.hits` and `def refused? = retrieval_results.empty? && strict_grounding`. `strict_grounding` is the snapshotted value at query time so flipping the KB later doesn't retroactively change `refused?`. **Schema additive**: add `strict_grounding` + `include_citations` snapshot columns to `curator_retrievals`. |
| 9 | Trace step taxonomy for M4 | **`prompt_assembly` + `llm_call`.** Refusal path emits `prompt_assembly` only — absence of `llm_call` is the signal. `prompt_assembly` payload (at `:full`): `{ hit_count, system_prompt_hash, prompt_token_estimate }`. `llm_call` payload: `{ model, input_tokens, output_tokens, finish_reason, streamed: bool }`. |

**Inline decisions (made without asking):**

- **`curator_scope: nil` justification**: tagging ad-hoc asks with
  `"ask"` or `"ask:<slug>"` would overload the column with two
  meanings ("which UI" + "is this an API ask"), forcing M8 chat
  UIs to filter on disjunction. KB association is already on
  `curator_retrievals.knowledge_base_id`; `Chat.where(curator_scope:
  nil)` is the cheap query for "all ad-hoc asks."
- **Refusal text v1**: hardcoded constant
  `Curator::Prompt::Templates::REFUSAL_MESSAGE`. Per-KB override
  column is a v2 addition once operators ask for it.
- **Token-window truncation**: M4 does *not* trim chunks if the
  assembled prompt exceeds a model's context window. M3's
  `chunk_limit: 5` default keeps prompts well under any realistic
  window; window-aware truncation is v2 work.
- **Empty-string LLM response**: persist as-is — assistant
  `Message` row exists with `content: ""`, search succeeds,
  `Answer#answer == ""`. Operators surface this via M5 admin +
  M7 evaluations rather than treating it as an error.
- **Streaming + refusal block contract**: the block is *always*
  called at least once for every ask that runs to the LLM /
  refusal step. Zero block calls only when the ask raises before
  reaching that step (e.g. embedding failure).
- **Pipeline extraction is a pure refactor**: Phase 2 doesn't
  change M3 specs. Behavior changes go in their own phases.
- **Assembler is a pure function**: takes `(kb:, hits:)`, returns
  a hash. No DB writes, no LLM calls, no global state. Lets M5
  Query Console call it directly for prompt preview.
- **`Curator::LLMError` already exists**: M4 just uses it. No
  new error type added in this milestone.
