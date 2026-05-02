# M6 — Query Testing Console + Token Streaming

Hotwire-only milestone. Ships an admin-mounted **Query Testing
Console** (form + live-streaming answer + sources panel + per-run
parameter overrides) and a reusable **token-streaming module**
(`Curator::Streaming::TurboStream`) that future milestones (M8 chat
UI) consume without changes.

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

_(empty — promote a phase from Next Steps when starting)_

## Current Work

_(empty — promote a phase from Next Steps when starting)_

## Next Steps

- [ ] **Phase 0 — Spec amendments + API skeleton removal.** Sequential.
   Blocks Phase 1.
   - Edit `features/implementation.md` (living-document update):
     - "Implementation Milestones → M6": rewrite bullets to:
       `Query Testing Console (admin Turbo UI; live token streaming
       via ActionController::Live + Turbo Streams; per-run parameter
       overrides; runs persist as curator_retrievals rows).` and
       `Token-streaming module (Curator::Streaming::TurboStream)
       reusable by M8 chat UI.` Drop the REST API / envelope / API
       auth bullets.
     - "REST API" section (line ~528-575): replace with a one-paragraph
       note: *"v1 ships engine-internal Hotwire UI only. Host apps
       expose Curator to their end users via the in-process service
       object API (`Curator.ask`, `Curator.retrieve`, `Curator.chat`)
       wrapped in their own controllers, or via the M8
       `curator:chat_ui` generator. A first-class REST API
       (`/api/query`, `/api/retrieve`, `/api/stream`), JSON envelope,
       error format, and `authenticate_api_with` auth hook are
       deferred to v2+."*
     - "Configuration" example (line ~733): drop the
       `config.authenticate_api_with do … end` block.
     - "Gem Structure" tree: drop `app/controllers/curator/api/` and
       `base_controller.rb` lines.
     - "Implementation Milestones → M7": rewrite the
       `/api/evaluations` bullet to:
       `In-app feedback submission (admin UI thumbs/feedback form
       writes Curator::Evaluation directly; host apps that want
       end-user feedback wrap Curator::Evaluation.create! in their
       own controller).`
     - "Deferred to v2+ → Added during planning": add four entries:
       *REST API endpoints* (`/api/query`, `/api/retrieve`,
       `/api/stream`, `/api/evaluations`), *JSON success/error
       envelope*, *`authenticate_api_with` auth hook*,
       *non-Rails-client concerns* (CORS, OpenAPI/Swagger spec,
       rate limiting, API tokens).
   - Delete `app/controllers/curator/api/` (the `BaseController`
     skeleton).
   - Drop `authenticate_api_with` from
     `lib/curator/configuration.rb`.
   - Drop the `:api` branch from `Curator::Authentication` concern
     (`curator_authenticate :api`); audit for any specs that
     exercise the API auth path and remove them. M1 originally
     wired this; with the API gone, the `:admin` branch is the only
     remaining authenticator.
   - Drop the `authenticate_api_with` example from
     `lib/generators/curator/install/templates/curator.rb.tt`.
   - **Validate**: `bundle exec rspec --format progress` green;
     `bundle exec rubocop` clean. Grep `app/controllers/curator/api`
     returns zero matches. Grep `authenticate_api_with` returns zero
     matches outside `features/implementation.md` history.

- [ ] **Phase 1 — Contract scaffolding.** Sequential. Branches Phases
   2A and 2B fork from this commit.
   - `config/routes.rb` adds:
     ```ruby
     get  "console", to: "console#show", as: :console
     post "console/run", to: "console#run", as: :console_run
     # nested under knowledge_bases:
     resources :knowledge_bases, ... do
       get "console", to: "console#show", as: :console
     end
     ```
   - Skeleton `app/controllers/curator/console_controller.rb`:
     `show` action renders the form with KB defaults; `run` action
     is `include ActionController::Live` with a TODO body that
     returns 501 for now.
   - Skeleton view files under `app/views/curator/console/`:
     - `show.html.erb` — three-column shell scaffold; column
       contents are placeholder text.
     - `_form.html.erb` — placeholder form fields (no real values
       yet).
     - `_source.html.erb` — placeholder one-source partial.
     - `_status.html.erb` — placeholder status badge.
   - Skeleton `lib/curator/streaming/turbo_stream.rb` — module +
     class signatures only (`#append(text)`, `#replace(target:,
     html:)`, `#close`, `self.open(stream:, target:) { |pump| ... }`)
     with no-op bodies + a `# TODO Phase 2A` marker.
   - Add `require "curator/streaming/turbo_stream"` to `lib/curator.rb`.
   - Skeleton spec files at the right paths
     (`spec/curator/streaming/turbo_stream_spec.rb`,
     `spec/requests/curator/console_spec.rb`) with one trivially-passing
     example each, so test-collection structure is set.
   - **Validate**: `bundle exec rspec --format progress` green;
     `bundle exec rubocop` clean. Visit `/curator/console` in
     dummy app — placeholder shell renders without errors.

- [ ] **Phase 2A — Streaming module real impl.** Worktree A. Parallel
   with 2B. Branches from Phase 1.
   - Implement `Curator::Streaming::TurboStream`:
     - `#initialize(stream:, target:)` — stores stream + target.
     - `#append(text)` — writes one
       `<turbo-stream action="append" target="<%= target %>"><template><%= text %></template></turbo-stream>`
       frame to `stream`. HTML-escape `text`.
     - `#replace(target:, html:)` — writes a `replace` frame with
       the given target + raw HTML. (Caller is responsible for
       escaping; this is for server-rendered partials.)
     - `#close` — flushes and closes `stream`. Idempotent — second
       call is a no-op.
     - `self.open(stream:, target:)` block sugar — yields a pump,
       ensures `#close` in an `ensure` block, swallows
       `IOError` / `ActionController::Live::ClientDisconnected` on
       close (operator navigated away mid-stream).
   - Specs in `spec/curator/streaming/turbo_stream_spec.rb`:
     - Use `StringIO.new` as the `stream:` substitute. Assert
       frame bytes match expected `<turbo-stream>` shape exactly,
       including escape behavior on `#append`.
     - `.open` block sugar yields the pump and closes the stream.
     - Closing twice is a no-op.
     - `IOError` raised inside the block during `#append` is
       re-raised, but `#close` still happens.
   - **Validate**: streaming spec green; rubocop clean. No Console
     files touched in this worktree.

- [ ] **Phase 2B — Console UI + controller.** Worktree B. Parallel
   with 2A. Branches from Phase 1.
   - `Curator::ConsoleController#show`:
     - Resolves KB via `Curator::KnowledgeBase.resolve(params[:knowledge_base_slug] || params[:slug])`.
     - Falls back to `KnowledgeBase.default!` when no slug present
       (top-level `/curator/console`).
     - Pulls form defaults from KB columns (chunk_limit, threshold,
       strategy, system_prompt, chat_model) and the global KB list
       for the selector.
     - Builds the chat_model option list:
       `RubyLLM.models.chat_models` filtered to
       `RubyLLM::Provider.configured_providers(RubyLLM.config)`,
       grouped by `provider`. If `kb.chat_model` isn't in the
       resulting list, prepend it as a `(custom)` option so the
       form round-trips correctly.
   - `Curator::ConsoleController#run` — `include ActionController::Live`:
     - `response.headers["Content-Type"] = "text/vnd.turbo-stream.html"`
     - `response.headers["Cache-Control"] = "no-cache"` (per
       `ActionController::Live` guidance).
     - Calls `Curator::Streaming::TurboStream.open(stream:
       response.stream, target: "console-answer")` — uses the no-op
       pump from Phase 1. Inside the block: calls
       `Curator::Asker.call(query, knowledge_base:, limit:,
       threshold:, strategy:, system_prompt:, chat_model:) { |delta|
       pump.append(delta) }`. After Asker returns: writes a
       `replace` frame to `console-sources` with the rendered
       `_source` partial collection, then a `replace` frame to
       `console-status` with the "done" badge.
     - On `Curator::Error` rescue: writes a `replace` frame to
       `console-status` with the "failed" badge + error message,
       then `pump.close`.
     - `ensure` block does not need to re-close — block sugar
       handles it.
   - `app/views/curator/console/show.html.erb` — three-column
     layout. Left column: `<%= render "form", knowledge_base: @kb,
     knowledge_bases: @kbs, chat_model_options: @chat_model_options
     %>`. Center column: `<turbo-frame id="console-answer">` (empty
     initially; gets `append`ed during run). Right column:
     `<turbo-frame id="console-sources">` (empty initially; gets
     `replace`d after retrieval). Status badge `<turbo-frame
     id="console-status">` somewhere visible.
   - `app/views/curator/console/_form.html.erb`:
     - KB `<select>` from `@knowledge_bases`.
     - `chunk_limit` number input (placeholder = `kb.chunk_limit`).
     - `similarity_threshold` number input step=0.01 (placeholder
       = `kb.similarity_threshold`).
     - `strategy` `<select>` (`hybrid` / `vector` / `keyword`,
       default = `kb.retrieval_strategy`).
     - `system_prompt` `<textarea>` (placeholder = `kb.system_prompt`).
     - `chat_model` `<select>` with `<optgroup>` per provider
       (built from `@chat_model_options`).
     - `query` `<textarea>` (the actual question).
     - "Run" submit button. Form has `data-turbo-stream="true"` so
       Turbo handles the chunked response.
     - "Reset to KB defaults" button — JS-free; it's a link back to
       `console#show` for the current KB.
   - `app/views/curator/console/_source.html.erb` — chunk excerpt,
     score, document name, link to chunk inspector
     (`Curator::Engine.routes.url_helpers.knowledge_base_document_path(...)`
     anchored to `#chunk-<id>`).
   - `app/views/curator/console/_status.html.erb` — small badge
     with three states (`idle` / `streaming` / `failed`).
   - Request spec at `spec/requests/curator/console_spec.rb`:
     - `GET /curator/console` renders the form with default-KB
       defaults pre-filled.
     - `GET /curator/kbs/:slug/console` renders form with that
       KB's defaults.
     - `POST /curator/console/run` (with a stubbed Asker that yields
       fixed deltas via WebMock-stubbed RubyLLM):
       - response is chunked (`Transfer-Encoding: chunked`).
       - response body contains `<turbo-stream action="append">`
         frames in delta order.
       - response body ends with two `<turbo-stream action="replace">`
         frames (sources + status badge).
       - a `curator_retrievals` row was written with `status:
         :success`, snapshot config matching the form params.
     - Failure path: stubbed Asker raises `Curator::LLMError`;
       response includes a `replace` frame to `console-status`
       with the failed badge + error message; `curator_retrievals`
       row is `:failed`.
   - **Validate**: Console request spec green using a stub pump
     (the no-op from Phase 1 still returns frames in test
     environment via the StringIO substitute when the real pump
     hasn't merged yet — adjust the spec helper accordingly).
     Visit `/curator/console` in dummy app — form renders, submit
     produces no errors but no streaming yet (pump still no-op).

- [ ] **Phase 3 — Integration + end-to-end smoke.** Sequential.
   Runs after both 2A and 2B merge to main.
   - Verify the no-op pump from Phase 1 has been replaced by the
     real implementation from 2A — no merge conflict expected
     (2B's controller calls `Curator::Streaming::TurboStream.open`
     which now resolves to the real impl).
   - End-to-end request spec
     (`spec/requests/curator/console_smoke_spec.rb`):
     - Real form submission → real `Curator::Streaming::TurboStream`
       pump → stubbed RubyLLM streaming yields fixed deltas →
       assert real `<turbo-stream>` frames in chunked response,
       in order, with correct escape behavior.
     - `curator_retrievals` row present with snapshot config and
       `status: :success`.
     - The Console run shows up on the dashboard's recent activity
       feed (cross-feature regression).
   - Manual visual QA in dummy app:
     - `bin/rails s` from `spec/dummy`.
     - Hit `/curator/console`. Pick a KB, type a query, hit Run.
     - Tokens stream into the center column visibly.
     - Sources populate in the right column after the LLM finishes.
     - Status badge transitions idle → streaming → done.
     - Tweak the threshold, hit Run again — new run uses the
       overridden value (verify via `curator_retrievals.last`
       snapshot columns in `bin/rails c`).
     - Force a failure (point the KB at a bogus chat_model) — UI
       shows the failed badge with a readable error message.
   - **Validate**: full spec suite green; rubocop clean; visual
     smoke checklist above passes.

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
  routes.rb                                       # Phase 1: add console routes
lib/curator.rb                                    # Phase 1: require streaming module
lib/curator/
  configuration.rb                                # Phase 0: drop authenticate_api_with
  authentication.rb                               # Phase 0: drop :api branch
  streaming/
    turbo_stream.rb                               # Phase 1: skeleton; Phase 2A: real impl
lib/generators/curator/install/templates/
  curator.rb.tt                                   # Phase 0: drop authenticate_api_with example
app/controllers/curator/
  api/                                            # Phase 0: DELETE entire dir
  console_controller.rb                           # Phase 1: skeleton; Phase 2B: real
app/views/curator/console/
  show.html.erb                                   # Phase 1: skeleton; Phase 2B: real
  _form.html.erb                                  # Phase 1: skeleton; Phase 2B: real
  _source.html.erb                                # Phase 1: skeleton; Phase 2B: real
  _status.html.erb                                # Phase 1: skeleton; Phase 2B: real
spec/curator/streaming/
  turbo_stream_spec.rb                            # Phase 1: skeleton; Phase 2A: real
spec/requests/curator/
  console_spec.rb                                 # Phase 1: skeleton; Phase 2B: real
  console_smoke_spec.rb                           # Phase 3: end-to-end
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

**Why `ActionController::Live` over ActionCable broadcasts**:
Console runs are 1:1 (one operator, one browser tab, one query).
ActionCable's value is fan-out to many subscribers — wasted here.
Live + chunked Turbo Stream response gives single HTTP req/resp,
no subscription/teardown lifecycle, no per-run channel naming, no
orphaned subscriptions if the operator navigates away mid-stream
(disconnect just kills the stream and the controller's `ensure`
block runs). The cable adapter is still required (M5 admin
broadcasts), just not for token streaming. See Ideation Notes Q6.

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
- **Q7: Streaming transport (Turbo flavor)**. **B —
  `ActionController::Live` + chunked `text/vnd.turbo-stream.html`
  response.** Single HTTP request per query. ActionCable not used
  for token streaming (still used for M5 admin broadcasts elsewhere).
  Console runs are 1:1; ActionCable's fan-out value is wasted here.
  Cleanly parallelizes (the streaming module is a thin wrapper
  around `response.stream.write`; the Console UI worktree builds
  against a stub).
