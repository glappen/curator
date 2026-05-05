# M6 — Query Testing Console + Token Streaming

Hotwire-only milestone. Ships an admin-mounted **Query Testing
Console** (form + live-streaming answer + sources panel + per-run
parameter overrides). Token streaming uses **Action Cable + Turbo
broadcasts** (the same pattern RubyLLM's `bin/rails g ruby_llm:chat_ui`
generates and `rubyllm.com/streaming` documents) so M8's chat UI shares
the streaming code path.

**Major spec amendment**: M6 drops the REST API surface entirely.
The originally-planned `/api/query`, `/api/retrieve`, `/api/stream`
controllers + JSON envelope + error format + `authenticate_api_with`
auth hook are deferred to v2+. Rationale: the engine is mounted in a
Rails host that already has in-process access to `Curator.ask`,
`Curator.retrieve`, `Curator.chat`. A REST API exists for callers
that aren't in-process (mobile apps, separate-origin SPAs, server-to-
server) — real but secondary use cases for v1, easy to add later
once shipped, hard to remove once shipped. Going Hotwire-only
collapses M6's surface area and gives one streaming code path
instead of two. See Ideation Notes Q3.

**Reference**: `features/implementation.md` → "Implementation
Milestones" → M6, plus the "REST API" and "Configuration" sections
that this milestone amends. M6 follows the M5 pattern of amending
implementation.md as a living document — Phase 0 ships those edits.

## Completed

- [x] **Phase 0 — Spec amendments + API skeleton removal.** Shipped in
   `64f54fd` — REST API skeleton deleted, `authenticate_api_with` removed
   from Configuration + install template, `Curator::Authentication`
   simplified to a single hardcoded admin path, `features/implementation.md`
   amended (M6 bullets, REST API → deferred-note, four "Deferred to v2+
   → Added during planning" entries).
- [x] **Phase 1 — Contract scaffolding.** Routes (`get console`,
   `post console/run`, nested `get kbs/:slug/console`), skeleton
   `Curator::ConsoleController` (`show` resolves KB; `run` includes
   `ActionController::Live` and returns 501), placeholder views
   (`show.html.erb`, `_form`, `_source`, `_status`), skeleton
   `Curator::Streaming::TurboStream` module with no-op
   `#append`/`#replace`/`#close` + `.open` block sugar (TODO Phase 2A
   markers), `lib/curator.rb` requires the module, skeleton specs at
   `spec/curator/streaming/turbo_stream_spec.rb` and
   `spec/requests/curator/console_spec.rb`. Contract is locked for
   2A/2B fork. `bundle exec rspec` 599 examples / 0 failures;
   `bundle exec rubocop` no offenses.
- [x] **Phase 2A — Streaming module real impl.** *Superseded by Phase 2C
   (see below).* Built `Curator::Streaming::TurboStream` pump against
   `response.stream` with `<turbo-stream action="append">` frame writes,
   ERB-escaped bodies, idempotent close swallowing IOError + ClientDisconnected,
   and `.open` block sugar. Module + spec deleted along with `lib/curator/streaming/`.
- [x] **Phase 2B — Console UI + controller.** Three-column
   `show.html.erb`, `_form` (KB selector + chunk_limit /
   similarity_threshold / strategy / chat_model grouped optgroups /
   system_prompt / query inputs + Run + Reset-to-defaults link),
   `_source` (rank + linked doc title anchored to `#curator_chunk_<id>` +
   score + page + excerpt), `_status` (state badge + optional message),
   `_empty_sources` partial. `ConsoleController#show` resolves KB, exposes
   `@knowledge_bases`, builds `@chat_model_options` from
   `RubyLLM.models.chat_models` filtered to providers in
   `RubyLLM::Provider.configured_providers(RubyLLM.config)` grouped by
   provider, with a `(custom)` group prepended when `kb.chat_model` isn't
   in the registry. `#run` originally used `ActionController::Live` +
   chunked turbo-stream response (Phase 2A pump); rewritten in Phase 2C
   to enqueue a job + return an initial turbo_stream — see below.
- [x] **Phase 3 (chunked-HTTP smoke).** *Superseded by Phase 3C.*
   `spec/requests/curator/console_smoke_spec.rb` asserted real
   `<turbo-stream>` frame bytes, append-per-delta ordering, ERB-escape,
   then sources + status replace frames, plus the snapshot
   `curator_retrievals` row. Spec deleted; equivalent assertions moved
   onto the broadcast surface in Phase 3C.
- [x] **Phase 2C — Cable broadcasts pivot.** Phase 2A's chunked-HTTP
   path didn't actually stream in browsers: Turbo's form-submit flow
   awaits the full response body via `FetchResponse#responseHTML`
   (`response.clone().text()`) before applying any `<turbo-stream>`
   elements (verified against turbo.js 8.0.23). Confirmed via curl that
   the server streams correctly and via browser that Turbo buffers
   regardless. Pivoted to the canonical RubyLLM-Rails pattern:
   `<%= turbo_stream_from @topic %>` in `show`, per-tab UUID round-tripped
   through a hidden `topic` field, `#run` enqueues
   `Curator::ConsoleStreamJob` and returns an initial turbo_stream that
   flips status to `:streaming` and clears the previous run's panes;
   the job calls `Curator::Asker` and broadcasts each delta via
   `Turbo::StreamsChannel.broadcast_append_to(topic, target: "console-answer")`,
   then sources + done-status replace broadcasts. Failures
   (`Curator::Error` / `RecordNotFound`) become a single `:failed`
   status broadcast. Deleted: `lib/curator/streaming/turbo_stream.rb` +
   spec, `ActionController::Live` from `ConsoleController`, the
   chunked-response headers, and `console-frame` markup (replaced with
   plain `<div>` targets since `broadcast_append_to` only needs a DOM id).
- [x] **Phase 3C — Integration + end-to-end smoke (automated).**
   `spec/jobs/curator/console_stream_job_spec.rb` drives the job
   top-to-bottom against the dummy app: `Curator.ingest sample.md`
   (real ingest + embed jobs against the default WebMock embeddings
   stub) → `Curator::ConsoleStreamJob.perform_now` → real
   `Curator::Asker` → RubyLLM `/chat/completions` stubbed at the SSE
   wire via `stub_chat_completion_stream(deltas: [...])`. Asserts the
   broadcast sequence (streaming-status → one append per delta in
   order with ERB-escape → sources → done-status), the persisted
   `Curator::Retrieval` row finalizes with the operator-submitted
   snapshot config (`chunk_limit: 3`, `similarity_threshold: 0.0`,
   `retrieval_strategy: "vector"`, `chat_model: "gpt-5-mini"`),
   linked `chat_id` / `message_id`, the `streamed: true` `llm_call`
   trace step, and the assistant Message persisted with concatenated
   deltas. Failure paths covered: Asker raise → streaming + failed
   status frames only, no append/sources; unknown slug → failed
   status frame. Tagged `:broadcasts` to opt past the suite-level
   `Turbo::Broadcastable` suppression. Dashboard recent-activity feed
   regression note (per Q6) preserved: row stays a normal
   `Curator::Retrieval` with no `origin` column.

- [x] **Manual visual QA in dummy app.** Exercised `/curator/console`
   in a browser against the dummy. Tokens stream visibly into the
   center column (not buffered), sources populate after the LLM
   finishes, status badge transitions idle → streaming → done,
   threshold overrides flow into `Curator::Retrieval.last`
   snapshot columns, and forcing a bogus chat_model surfaces the
   failed badge with a readable error message.

## Current Work

_(empty — M6 complete)_

## Next Steps

_(none — milestone closed)_

## Validation Strategy

### Per-phase

Each phase has its own bullet-level validation above. Common bar:
- `bundle exec rspec --format progress` green
- `bundle exec rubocop` clean (no offenses detected)

### Cross-phase regressions to watch

- **M5 admin broadcasts** must keep working — Phase 0's removal of
  `Curator::Api::BaseController` and `authenticate_api_with` does not
  touch the cable adapter or the admin authentication path, but
  re-run the M5 admin smoke spec (`spec/requests/curator/admin_smoke_spec.rb`)
  after Phase 0 to confirm.
- **`Curator::Asker` block-form streaming** must keep its existing
  behavior: each delta yielded once, retrieval row finalized after
  the LLM call, partial deltas yielded before a mid-stream raise.
  Phase 2B's controller is a new consumer; Asker stays untouched.
- **`curator_retrievals` snapshot columns** capture the *overridden*
  values when the operator tweaks them in the form (per Q5 →
  option A; the snapshot reflects what was actually run, not the
  KB's saved defaults).

## Files Under Development

```
config/
  routes.rb                                       # console routes
lib/curator.rb                                    # require list
lib/curator/
  configuration.rb                                # Phase 0: dropped authenticate_api_with
  authentication.rb                               # Phase 0: dropped :api branch
  streaming/                                      # Phase 2A: deleted in Phase 2C
lib/generators/curator/install/templates/
  curator.rb.tt                                   # Phase 0: dropped authenticate_api_with example
app/controllers/curator/
  api/                                            # Phase 0: deleted
  console_controller.rb                           # #show resolves KB + topic; #run enqueues job
app/jobs/curator/
  console_stream_job.rb                           # Phase 2C: streams broadcasts to per-tab topic
app/views/curator/console/
  show.html.erb                                   # turbo_stream_from @topic + form
  _form.html.erb                                  # hidden topic field + KB form
  _source.html.erb                                # source card
  _status.html.erb                                # state badge
  _empty_sources.html.erb                         # zero-hits placeholder
spec/jobs/curator/
  console_stream_job_spec.rb                      # Phase 3C: end-to-end via broadcasts ✓
spec/requests/curator/
  console_spec.rb                                 # GET form + POST enqueue/initial frame
features/
  implementation.md                               # Phase 0: spec amendments
```

## Parallelization

```
Phase 0 ──► Phase 1 ──┬──► Phase 2A ─┐
                       │               ├─► Phase 3
                       └──► Phase 2B ─┘
```

Phase 0 and Phase 1 are sequential foundation work — no parallel
benefit. Phase 1 deliberately ships a **contract** (route names,
controller class, view paths, streaming module signature) so 2A and
2B can fork without negotiating shapes mid-implementation. Phase 3
re-merges and validates end-to-end.

### Worktree split (2A and 2B)

After Phase 1 lands on `main`:

- **Worktree A — `m6-streaming-module`**:
  Owns `lib/curator/streaming/turbo_stream.rb` and
  `spec/curator/streaming/turbo_stream_spec.rb`. Builds the real
  pump against `StringIO`. Knows nothing about the Console.

- **Worktree B — `m6-console-ui`**:
  Owns `app/controllers/curator/console_controller.rb`,
  `app/views/curator/console/*`, and
  `spec/requests/curator/console_spec.rb`. Builds the form +
  controller + UI against the no-op pump from Phase 1 (or a test-
  local stub). Knows nothing about the streaming module's internals.

### Conflict-prone files

After Phase 1, **zero files overlap between 2A and 2B**. The shared
files (`lib/curator.rb`, `config/routes.rb`,
`lib/curator/streaming/turbo_stream.rb` skeleton) are all written in
Phase 1 and modified by exactly one downstream worktree.

If a merge conflict appears, that's a signal someone broke the
contract — pause and reconcile before continuing rather than
auto-resolving.

## Out of Scope (deferred to v2+)

These came up during ideation and are explicitly punted:

- **REST API endpoints** (`/api/query`, `/api/retrieve`,
  `/api/stream`, `/api/evaluations`) — for non-Rails clients.
  Easy to add later; hard to remove once shipped.
- **JSON success/error envelope + error code taxonomy** — depends on
  REST API.
- **`authenticate_api_with` auth hook + API tokens** — depends on
  REST API.
- **CORS, OpenAPI/Swagger spec, rate limiting** — non-Rails-client
  concerns; defer with the API.
- **Console run throttling / token batching** — `Curator::Asker`
  yields at provider rate (typically 10-100 tokens/sec). HTTP
  chunked-response backpressure handles flow control. Add buffering
  in the streaming module only if real-world latency profiles show
  it's needed.
- **`Asker#extract_finish_reason` for non-OpenAI/Anthropic providers**
  — currently nil for other providers, which leaves M5's
  `length`-truncation badge dark. Generalize when v2 broadens
  provider matrix.
- **Per-Console-run share-link / replay** — "send me a link to
  reproduce this exact retrieval-config." Useful but not in v1.
- **Multi-pane comparison** — run two configs side-by-side and
  diff. v2+ once base Console exists.

## Implementation Notes

**Why this order**: Phase 0 is sequential because the spec
amendments and API skeleton removal touch shared files
(`features/implementation.md`, `lib/curator/configuration.rb`,
`lib/curator/authentication.rb`,
`lib/generators/curator/install/templates/curator.rb.tt`) that
later phases would conflict with if interleaved. Phase 1 is also
sequential because it establishes the contract both 2A and 2B
build against — locking signatures upfront prevents the most
expensive class of merge conflict (rewriting a method's
parameters across two branches).

**Why ActionCable broadcasts over `ActionController::Live`** (reversed
in Phase 2C). The original Q7 decision picked Live + chunked
turbo-stream response on the theory that 1:1 console runs don't need
Cable's fan-out. That premise was correct *but irrelevant*: Turbo's
form-submission flow buffers the full response body
(`FetchResponse#responseHTML` calls `response.clone().text()`, verified
against turbo.js 8.0.23) before applying any `<turbo-stream>` elements,
so chunked responses don't render progressively in the browser. The
working paths are SSE, ActionCable broadcasts, or a custom Stimulus
controller that consumes `response.body.getReader()` and calls
`Turbo.renderStreamMessage` per frame. Cable broadcasts are RubyLLM's
documented pattern (`rubyllm.com/streaming`, `bin/rails g
ruby_llm:chat_ui`), already required for M5 admin broadcasts, and
share a single streaming code path with M8. Per-tab topic isolation
is handled with a UUID round-tripped through the form's hidden field.

**Why drop the API**: see Ideation Notes Q3 for the full reasoning.
The shortest version: the gem mounts in a Rails host that already
has in-process access to the service object API. A REST surface is
genuinely useful for non-Rails clients but is a meaningful design
+ docs + maintenance commitment (envelope versioning, error codes,
auth tokens, CORS, OpenAPI, rate limits) — easy to add later if
demand materializes, hard to remove once shipped. Deferring it
gives M6 a focused two-worktree shape and frees the engine to be
fully Hotwire-native.

## Ideation Notes

Q&A from the ideation session that produced this file (2026-05-02):

- **Q1: `/api/stream` transport** (SSE / NDJSON / Turbo Streams over
  WS / chunked plain text). *Moot — see Q3.* (Originally chose SSE.)
- **Q2: Console streaming path** (hits `/api/stream` / its own admin
  endpoint / Turbo Streams over cable). *Moot — see Q3.*
- **Q3: Drop the REST API entirely and go full Turbo?** **Yes.** API
  + envelope + error format + `authenticate_api_with` deferred to
  v2+. Engine becomes Hotwire-only for v1; non-Rails clients out of
  v1 scope. Rationale: gem mounts in a Rails host with in-process
  access to service objects; REST API is real but secondary; easy
  to add later, hard to remove once shipped; collapses M6's surface
  area; one streaming code path instead of two.
- **Q4: Pull `curator:chat_ui` (M8) forward into M6?** **No** — keep
  M6 tight. M6 ships only the streaming module + Console. The
  streaming module is M8's foundation; M8 inherits it for free.
  `chat_ui` is entangled with M8's persistent-chat work (history
  rendering, scope partitioning, multi-turn input) — splitting a
  single-turn widget out for M6 would mean two generators or one
  generator that grows mid-milestone.
- **Q5: Console editable params**. KB selector, `chunk_limit`,
  `similarity_threshold`, `strategy`, `system_prompt` (textarea),
  `chat_model` (dropdown). `strict_grounding` and `include_citations`
  stay KB-level (deployment-tier decisions, not per-query).
- **Q5b: Provider support / chat_model dropdown source**. Engine is
  provider-agnostic via RubyLLM (OpenAI, Anthropic, Google, Ollama,
  DeepSeek, OpenRouter, Bedrock, etc.). Dropdown filters to providers
  with API keys configured
  (`RubyLLM::Provider.configured_providers(RubyLLM.config)`),
  grouped by `<optgroup>`. KB's current `chat_model` pre-selected;
  if it's a custom model not in the registry, injected as a
  `(custom)` option so the form round-trips. Caveat:
  `Asker#extract_finish_reason` (asker.rb:197-201) only knows
  OpenAI's `choices[0].finish_reason` and Anthropic's top-level
  `stop_reason` — other providers return nil for that one trace
  field. Not a blocker for M6; flagged for v2.
- **Q6: Console run persistence**. **A — persist as normal
  `curator_retrievals` rows.** Snapshot config captured per Console
  run (operator overrides flow into the snapshot, not the KB's
  saved defaults). Operator probing flows into M7 evals naturally.
  No `origin` column.
- **Q7: Streaming transport (Turbo flavor)**. **Reversed in Phase 2C:
  ActionCable broadcasts**, not chunked `ActionController::Live`. The
  original Live decision didn't survive contact with the browser —
  Turbo 8.x's form-submit flow awaits the full response body via
  `FetchResponse#responseHTML` before applying any `<turbo-stream>`
  elements (turbo.js:499–504), so chunked frames buffer client-side
  even when the server streams them perfectly. Cable broadcasts (the
  pattern `bin/rails g ruby_llm:chat_ui` generates) actually stream
  progressively, share infrastructure with M5 admin broadcasts and
  M8's chat UI, and add only a per-tab UUID + a job class to the
  blast radius.
