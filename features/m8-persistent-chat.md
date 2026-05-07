# M8 — Persistent Chat

Multi-turn chat surface with **tool-driven retrieval**: the LLM decides
when to call the retrieval tool inside a turn (vs. M4's "always
retrieve once upfront" pattern). Ships `Curator::Chat` wrapper, a
`Curator::Chat::Tools::Retrieve` RubyLLM tool, a new
`Curator::Tracing.subscribe(...)` extension hook for tool-call
lifecycle UX, and the `curator:chat_ui` generator (both unscoped and
scoped invocations — scoped generation pulled forward from M9).

M8 Phase 0 retires the `chats.curator_scope` column (originally
landed in M1) in favor of a Curator-owned `curator_chat_bindings`
table. Same partition data, but it lives in our schema rather than
mutating RubyLLM's `chats`.

**Reference**: `features/implementation.md` → "Implementation
Milestones" → M8, plus the "Service Object API", "Generators →
`curator:chat_ui`", and "REST API" sections that this milestone amends.
M8 follows the M5/M6/M7 pattern of amending implementation.md as a
living document — Phase 0 ships those edits.

## Completed

- **Phase 0 — Spec amendments + schema additions.** `features/implementation.md`
  amended (M8/M9 boundary, `:chat_tool` origin, `:tool_call_started`/
  `:tool_call_completed` step types with payload schemas, new
  `curator_chat_bindings` table, chat-mode strict-grounding rider,
  continuous citation renumbering, `Curator.chat(id:)` resumption
  example, Streaming section with Tier 2 `Curator::Tracing.subscribe`
  hook). Schema: deleted `add_curator_scope_to_chats.rb.tt` and never
  shipped `add_curator_kb_slug_to_chats.rb.tt`; both replaced by new
  `create_curator_chat_bindings.rb.tt` (chat_id unique + knowledge_base_id
  FK + nullable indexed curator_scope). Models extended (`Retrieval::ORIGINS
  += :chat_tool`, `RetrievalStep::STEP_TYPES += :tool_call_started,
  :tool_call_completed`). Removed `curator_scope: nil` from `Curator.ask`
  Chat.create! call sites + spec assertions. CLAUDE.md, M1 doc, and M4 doc
  updated to reflect the binding-table architecture.

## Current Work

_(none — Block B starts next)_

## Next Steps

Phases run as four blocks. Block B and Block C each contain multiple
parallel tracks; the contract-first 3a/3b split lets the generator
(Phase 4) develop concurrently with Asker (Phase 3b) by programming
against a frozen `Curator::Chat` public API.

### Block A — must land first

- [x] **Phase 0 — Spec amendments + schema additions.**
  - `features/implementation.md` amended:
    - M8 / M9 boundary revised (scoped generator pulled into M8;
      M9 becomes pure release polish — dashboard, rake tasks, docs,
      RubyGems checklist).
    - `curator_retrievals.origin` enum gains `:chat_tool`.
    - `curator_retrieval_steps.step_type` gains `:tool_call_started`
      and `:tool_call_completed` (payload schemas documented).
    - `curator_chat_bindings` table documented (chat_id unique,
      knowledge_base_id FK, nullable indexed curator_scope) —
      replaces the original M1 plan of mutating RubyLLM's
      `chats` table.
    - "Strict grounding" section amended: in chat mode, enforcement
      is via system-prompt instruction (LLM-owned refusal). Tool
      return payload includes `hit_count`. `Curator.ask`'s
      hard-refusal path is unchanged.
    - "Citation marker `[N]`" section amended: in chat mode,
      ranks are renumbered continuously across tool calls within a
      turn, preserving `retrieval_hits.rank` global uniqueness.
    - "Service Object API" → `Curator.chat` example expanded to
      cover `id:` resumption.
    - "Streaming" section gains a Tier 2 hook description for
      `Curator::Tracing.subscribe(...)`.
  - `lib/generators/curator/install/templates/create_curator_retrievals.rb.tt`
    — origin enum check constraint extended to include `chat_tool`.
  - `app/models/curator/retrieval.rb` — `ORIGINS` constant gains
    `:chat_tool`.
  - `app/models/curator/retrieval_step.rb` — STEP_TYPES (or
    equivalent) extended.
  - Delete legacy templates
    `lib/generators/curator/install/templates/add_curator_scope_to_chats.rb.tt`
    and (never-shipped intermediate) `add_curator_kb_slug_to_chats.rb.tt`.
  - New install template
    `lib/generators/curator/install/templates/create_curator_chat_bindings.rb.tt`
    — Curator-owned table with `chat_id` (bigint, unique indexed),
    `knowledge_base_id` (FK → `curator_knowledge_bases`, cascade),
    `curator_scope` (string, nullable, indexed).
  - `lib/generators/curator/install/install_generator.rb` —
    drop the old migration registrations, register the new one.
  - `lib/curator/asker.rb` and `lib/curator.rb` — drop `curator_scope:
    nil` from the `Chat.create!` call (column no longer exists).
  - Spec call sites updated: `spec/curator/asker_spec.rb`,
    `spec/curator/answer_spec.rb`, `spec/requests/curator/ask_smoke_spec.rb`.
  - `bin/reset-dummy` regenerates dummy schema cleanly.
  - **Validate:** install template spec asserts new
    `curator_chat_bindings` table + new origin enum value; existing
    spec count grows by ~3 (binding-table fragments + step-type
    coverage) net of the dropped `curator_scope` assertion;
    `bundle exec rubocop` clean.

### Block B — three parallel tracks (after Phase 0)

- [ ] **Phase 1 — `Curator::Tracing.subscribe(...)` hook.**
  - `lib/curator/tracing.rb` — `Tracing.record(...)` (already used
    by Asker / Pipeline) emits an `ActiveSupport::Notifications`
    event on `"curator.step"` channel on each step write.
    Backwards-compatible: existing callers unchanged.
  - `Tracing.subscribe(scope:, &block)` — class method that wraps
    `ActiveSupport::Notifications.subscribe("curator.step")` and
    filters by scope (chat_id or retrieval_id passed in payload).
    Returns a subscriber handle; `Tracing.unsubscribe(handle)`
    releases.
  - **Validate:** spec asserts subscribe-with-chat-scope receives
    only events for that chat; running an unrelated `Curator.ask`
    yields no events to the subscriber. Sequence-order assertion
    on the events received.

- [ ] **Phase 2 — Retrieval tool + Assembler extraction.**
  - `lib/curator/prompt/assembler.rb` — extract
    `Assembler.render_context_block(hits:, rank_offset: 0)` as a
    public class method. Existing `#call` refactored to use it
    (no behavior change). Spec covers `rank_offset: > 0` case
    (continuous renumbering).
  - New `lib/curator/chat/tools/retrieve.rb` —
    `Curator::Chat::Tools::Retrieve < RubyLLM::Tool`. Single param
    `query: String` with description that instructs the LLM to
    pass a search-optimized rephrasing of the user's most recent
    message. `#execute` delegates to
    `Curator::Retrievers::Pipeline`, applies cumulative rank
    renumbering against tool-instance state, returns a hash
    `{ context: <Format-1 string>, hit_count: N }`. Wraps the
    invocation in `Tracing.record(:tool_call_started)` ... body ...
    `Tracing.record(:tool_call_completed)`.
  - **Validate:** unit spec instantiates the tool with a fixture
    KB + retrieval row, invokes `#execute` twice, asserts:
    - First invocation returns ranks `[1..K]`.
    - Second invocation returns ranks `[K+1..K+M]`.
    - Format-1 string matches `[N] From "..." (page N): ...`.
    - Step rows written with payloads matching the documented
      schema.

- [ ] **Phase 3a — `Curator::Chat` public API contract.**
  - `lib/curator/chat.rb` — wrapper class with `self.create`,
    `self.find`, `#ask`, `#history`, `#id`, `#knowledge_base`,
    `#raw` method signatures. `#ask` raises `NotImplementedError`
    until Phase 3b lands.
  - `lib/curator.rb` — `Curator.chat(knowledge_base: nil, id:
    nil)` delegator. Picks `Chat.create` vs `Chat.find` based on
    `id` presence; raises `ArgumentError` if both or neither are
    passed.
  - Frozen contract spec at
    `spec/curator/chat_contract_spec.rb` — asserts
    `Curator.chat(...)` returns a `Curator::Chat`, asserts
    `wrapper.knowledge_base` resolves correctly, asserts `#ask`
    raises until Phase 3b.
  - **Validate:** contract spec passes; rubocop clean. Lets
    Phase 4 start in parallel.

### Block C — two parallel tracks (after Block B)

- [ ] **Phase 3b — `Curator::Chat::Asker` real implementation.**
  - `app/services/curator/chat_asker.rb` — service object (per
    project memory: engine service objects called from controllers
    belong under `app/services/curator/`, not `lib/curator/`).
    Orchestrates one turn:
    - Build chat-flavored system prompt (`Prompt-X`):
      `kb.system_prompt` + Curator-owned tool-use preamble +
      strict-grounding rider when `kb.strict_grounding`.
    - Open *tentative* `curator_retrievals` row in memory; do not
      INSERT yet.
    - Wire `Curator::Chat::Tools::Retrieve` onto the underlying
      RubyLLM `Chat` with the in-memory row + cumulative rank
      cursor latched into the tool's instance state.
    - `chat.with_instructions(prompt).with_tools(tool).ask(text)
      { |delta| stream_block&.call(delta) }`.
    - On first tool invocation: INSERT the retrieval row,
      `origin: :chat_tool`. Subsequent invocations append step
      brackets to the same row.
    - After turn completes: if retrieval row was created,
      `mark_success!` with the final assistant message id. If
      zero tool calls fired, the tentative row is discarded
      (per Q2-C).
  - `lib/curator/chat.rb` — `#ask` body now delegates to
    `ChatAsker.call(...)`. `#history` walks assistant messages and
    builds `Curator::Answer` per turn (`retrieval_id: nil` and
    `hits: []` for chitchat).
  - **Validate:** integration spec (WebMock-stubbed LLM):
    - Chitchat turn ("hi!") — no `curator_retrievals` row written;
      `chat.history` includes a `Curator::Answer` with
      `retrieval_id: nil`, `hits: []`.
    - Single-tool-call turn — one row, one
      `:tool_call_started`/`_completed` step bracket, hits ranked
      `[1..K]`.
    - Two-tool-call turn — one row, two step brackets, hits
      ranked `[1..K]` then `[K+1..K+M]`.
    - Strict grounding instruction is present in the system
      prompt when `kb.strict_grounding` is true.

- [ ] **Phase 4 — `curator:chat_ui` generator (scoped + unscoped).**
  - `lib/generators/curator/chat_ui/chat_ui_generator.rb` —
    accepts optional positional `scope` arg + optional `--kb=<slug>`
    flag. `nil` scope produces top-level namespaced output;
    non-nil produces `<Scope>::`-namespaced output and writes
    `curator_scope: "<scope>"` on the corresponding
    `curator_chat_bindings` rows.
  - Templates (each branches on scope):
    - `chats_controller.rb.tt` — `index` (sidebar list), `show`
      (chat surface + `turbo_stream_from`), `create` (resolves
      KB from form param when not pinned, calls
      `Curator.chat(knowledge_base:)`, redirects), `destroy`.
    - `messages_controller.rb.tt` — `create` writes user message
      synchronously (turbo_stream append), enqueues
      `ChatResponseJob`.
    - `chat_response_job.rb.tt` — opens
      `Curator::Tracing.subscribe(scope: chat)`, calls
      `Curator.chat(id:).ask(text) { |delta| broadcast }`.
      Broadcasts `:user_message_appended`, `:tool_call_started`
      (renders "🔍 searching for '<rephrased>'..."),
      `:tool_call_completed` (replaces with "Found N sources"),
      `:answer_delta`, `:sources`, `:done` / `:failed`.
    - Views: `index.html.erb` (sidebar + new chat),
      `show.html.erb` (three-region: messages + composer +
      sources), `new.html.erb` (KB selector when not pinned),
      `_message.html.erb` (user vs assistant rendering with
      `[N]` → anchor linkify), `_source.html.erb`,
      `_empty_sources.html.erb`.
    - Routes additions (scope-aware): top-level or namespaced
      `resources :chats` with nested `resources :messages`.
  - Generator does not opt views into `.curator-ui` scoped CSS —
    host pages render in the host's layout. Starter
    `chats.css` shipped with minimal layout primitives.
  - **Validate:** generator spec invokes:
    - `rails g curator:chat_ui --kb=default` → top-level
      `ChatsController` etc.
    - `rails g curator:chat_ui support --kb=default` → namespaced
      `Support::ChatsController`, route at `/support/chats`.
    - Second scoped invocation (`legal --kb=...`) doesn't clobber
      the first — distinct namespace, distinct route.
    - Generated `ChatResponseJob` references
      `Curator::Tracing.subscribe`.

### Block D — final

- [ ] **Phase 5 — End-to-end manual QA against dummy host.**
  - `bin/reset-dummy`, `bundle exec rails g curator:chat_ui --kb=default`
    in `spec/dummy`, boot dummy server.
  - Single-instance flow: navigate to `/chats`, click "New chat",
    ask a question. Observe streaming deltas + tool-call
    lifecycle frames + sources sidebar populating. Click a `[N]`
    citation, verify it scrolls to / highlights the correct
    source.
  - Chitchat flow: ask "hi!" or "thanks". Verify no
    `curator_retrievals` row is written (`Curator::Retrieval.count`
    unchanged after the turn).
  - Strict grounding flow: temporarily set `kb.system_prompt`
    such that the LLM is steered to never call the tool, ask a
    factual question, verify refusal language appears and no
    retrieval row was written.
  - History flow: revisit the chat after server restart, confirm
    full history renders with citations preserved.
  - Multi-instance flow: in a fresh dummy,
    `rails g curator:chat_ui support --kb=default` and
    `rails g curator:chat_ui legal --kb=default`. Boot, verify
    `/support/chats` and `/legal/chats` are independent —
    chats created in one don't appear in the other's sidebar.
    Confirm `curator_chat_bindings.curator_scope` is populated
    correctly and RubyLLM's `chats` table remains unmodified by
    Curator-specific columns.
  - **Validate:** subjective end-to-end check; capture any
    defects as Phase 5.5 (per M7 Phase 6.5 precedent).

## Validation Strategy

Each phase has its own validation checklist embedded in the bullet
above. Standing rule per project CLAUDE.md: after every phase,
`bundle exec rspec --format progress` (no failures) and
`bundle exec rubocop` (no offenses). Existing pre-M8 spec count is
721 examples; expected post-M8 increment is roughly +40 examples
(7 for Phase 1, 8 for Phase 2, 4 for Phase 3a, 12 for Phase 3b, 8
for Phase 4 generator spec).

## Files Under Development

```
lib/
├── curator.rb                                    # +Curator.chat delegator
├── curator/
│   ├── chat.rb                                   # NEW (Phase 3a/3b)
│   ├── chat/
│   │   └── tools/
│   │       └── retrieve.rb                       # NEW (Phase 2)
│   ├── tracing.rb                                # +subscribe (Phase 1)
│   └── prompt/
│       └── assembler.rb                          # +render_context_block (Phase 2)
├── generators/
│   └── curator/
│       ├── install/
│       │   └── templates/
│       │       ├── create_curator_retrievals.rb.tt        # +chat_tool origin (Phase 0)
│       │       └── create_curator_chat_bindings.rb.tt     # NEW (Phase 0; replaces add_curator_scope_to_chats + add_curator_kb_slug_to_chats)
│       └── chat_ui/
│           ├── chat_ui_generator.rb              # NEW (Phase 4)
│           └── templates/
│               ├── chats_controller.rb.tt        # NEW
│               ├── messages_controller.rb.tt    # NEW
│               ├── chat_response_job.rb.tt      # NEW
│               ├── index.html.erb.tt            # NEW
│               ├── show.html.erb.tt             # NEW
│               ├── new.html.erb.tt              # NEW
│               ├── _message.html.erb.tt         # NEW
│               ├── _source.html.erb.tt          # NEW
│               └── _empty_sources.html.erb.tt   # NEW
app/
├── models/
│   └── curator/
│       ├── retrieval.rb                          # +chat_tool ORIGINS (Phase 0)
│       └── retrieval_step.rb                     # +step types (Phase 0)
└── services/
    └── curator/
        └── chat_asker.rb                         # NEW (Phase 3b)
spec/
├── curator/
│   ├── chat_contract_spec.rb                    # NEW (Phase 3a)
│   ├── chat_spec.rb                              # NEW (Phase 3b integration)
│   ├── chat/
│   │   └── tools/
│   │       └── retrieve_spec.rb                 # NEW (Phase 2)
│   ├── tracing_spec.rb                           # +subscribe coverage (Phase 1)
│   └── prompt/
│       └── assembler_spec.rb                    # +rank_offset coverage (Phase 2)
└── generators/
    └── curator/
        └── chat_ui_generator_spec.rb            # NEW (Phase 4)
features/
├── implementation.md                             # amended (Phase 0)
└── m8-persistent-chat.md                         # this file
```

## Ideation Notes

Eight design questions and two scope decisions resolved during
ideation. The conclusions inform the design above; the full
question text and rationale is preserved here for future reviewers
who want to understand *why* the milestone landed where it did.

### Q1 — KB binding for a chat → A (pinned at chat creation)

A chat is locked to a single KB at creation time. Multi-KB
selector UI is a chat-creation-time concern; the chat itself is
single-KB. Tool's JSON schema therefore takes only `query`.
Alternative shapes considered:

- **B (per-message KB selection)** — rejected: muddies the trace
  semantics (same `chats` row spanning multiple KBs) and conflicts
  with `curator_scope`'s 1:1 chat ↔ scope assumption.
- **C (LLM-chosen KB via tool param)** — rejected: gives the LLM
  unnecessary control over a routing decision the host already
  made when picking the chat UI.

### Q2 — Retrieval row granularity per turn → C (one row per turn iff ≥1 tool call fired)

A turn with N tool calls produces N step-bracket groups under one
`curator_retrievals` row. Chitchat turns ("thanks!") leave only
the underlying `chats`/`messages` rows. The row's `query` column
stores the **user's original turn input**, not the LLM's
rephrasings — per-call rephrased queries live in
`curator_retrieval_steps.payload`. Alternatives:

- **A (one row per tool invocation)** — rejected: clean retrieval
  semantics but breaks the 1:1 `assistant_message ↔ retrieval`
  assumption M7's evaluation surfaces are built around.
- **B (one row per turn, even chitchat)** — rejected: dead rows
  for greeting turns pollute the Retrievals tab and skew
  eval-quality metrics.

### Q3 — Strict grounding semantics → A (LLM-owned refusal via prompt instruction)

`strict_grounding`'s chat-mode enforcement is a *prompted* rule,
not a *post-hoc* check. The retrieval tool's return payload
includes `hit_count` so the system-prompt instruction has
something concrete to react to. Tool choice is `auto` (LLM may
skip retrieval for chitchat). `Curator.ask`'s hard-refusal path
is unchanged. Alternatives:

- **B (post-hoc hard refusal)** — rejected: clunky; discards real
  LLM messages that may have correctly refused already.
- **C (force tool, then check)** — rejected: makes chitchat turns
  impossible (every "hi" fires a vector search) and conflicts
  with Q2-C.
- **D (disable strict grounding for chats)** — rejected: silently
  drops a guarantee end users may have assumed transitively.

The honest tradeoff vs. A: strict grounding becomes *prompted*
not *enforced*. Curator's pitch is "production-ready RAG with
strict grounding," so this is a real value tradeoff. Mitigated by
M7's evaluation surfaces — reviewers can flag hallucinations in
practice — and by RubyLLM's idiom that expects the LLM to react
to tool results.

### Q4 — Citation numbering across multiple tool calls → B (continuous renumbering)

Curator increments a rank cursor across tool calls within a turn
so the LLM always sees globally unique `[N]` markers. The wire
format stays identical to M4 (one citation = one integer);
`_source.html.erb` from M4 carries over unchanged;
`retrieval_hits.rank` keeps its uniqueness guarantee within the
row. Per-call breakdown lives in step payloads. Alternatives:

- **A (per-call namespacing `[1.3]`)** — rejected: marker syntax
  brittle (LLMs mis-format), unfamiliar.
- **C (reset per call, dedupe at end)** — rejected: marker
  rewriting in the assistant message is fragile string surgery.
- **D (last call wins)** — rejected: loses real grounding info
  when the answer cites earlier-call material.

### Q5 — `chat.history` shape → A (one `Curator::Answer` per turn)

Single value object across `Curator.ask` and `Curator.chat`.
Chitchat answers carry `retrieval_id: nil` and `hits: []`.
Templates branch on `hits.any?` (already supported by existing
`_empty_sources` partial); no new shape needed. Alternatives:

- **B (heterogeneous array)** — rejected: extra value object,
  two-way template branching for a small benefit.
- **C (raw RubyLLM messages)** — rejected: leaks RubyLLM types
  into Curator's public API.
- **D (`Curator::Chat::Turn` value object)** — rejected:
  premature abstraction with no precedent in M1–M7.

### Q6 — Streaming surface granularity → D (text deltas via block; lifecycle via new `Curator::Tracing.subscribe` hook)

The `chat.ask { |chunk| }` block stays text-delta-only — same
contract as `Curator.ask`. Tool-call lifecycle is exposed via a
**new** `Curator::Tracing.subscribe(scope:, &block)` extension API
implemented as a thin wrapper over `ActiveSupport::Notifications`
(channel `"curator.step"`). Generated `ChatResponseJob` consumes
both channels in parallel and emits Turbo broadcast frames for
both. Alternatives:

- **A (text deltas only)** — rejected: opaque UX for multi-second
  retrievals.
- **B (heterogeneous block payloads)** — rejected: changes the
  contract of the streaming block; new public value types just
  for one UX choice.
- **C (two-block API)** — rejected: two-block ceremony is
  uncommon in Ruby; only one consumer (the generator's job)
  actually reads the second block in practice.

D bets that one well-shaped extension point covers more future
"react to retrieval lifecycle" use cases (custom-host progress
bars, OpenTelemetry, custom logging) than a second block param
does. The hook is "Tier 2" — documented advanced API, not the
headline `Curator.chat` surface.

### Q7 — `curator:chat_ui` generator output scope → B (history list + new/delete + truncated labels)

Generator emits `ChatsController#index` (sidebar listing), `#show`
(chat surface), `#create` (new chat), `#destroy` (hard delete) +
`MessagesController#create` + `ChatResponseJob` + views. Sidebar
labels = first user message truncated to ~40 chars (no LLM-
generated titles). No regenerate-last-response. Alternatives:

- **A (MVP, no history list)** — rejected: too thin to land as
  M8 ("persistent chat" with no list of past chats is a
  half-shipped feature).
- **C (B + LLM-generated titles)** — deferred to v2: another LLM
  call per chat, another job, another error path. Sidebar labels
  can be improved post-release without schema changes.
- **D (B + regenerate last)** — deferred to v2: retrieval-row
  semantics for "regenerate" deserve their own design pass (does
  it re-retrieve or reuse hits?).

### Q8 — Tool format + chat system prompt → Format-1 + Prompt-X

**Format-1** (pre-rendered M4-style text block): tool returns
`[1] From "doc" (page N): text...\n\n[2] From ...` as the
context payload + a `hit_count` field. Citation marker injection
stays Curator-controlled, not LLM-formatted. Reuses
`Curator::Prompt::Assembler.render_context_block(hits:, rank_offset:)`
extracted as a public class method.

**Prompt-X** (reuse `kb.system_prompt`): the chat's system prompt
is `kb.system_prompt` (instructions, overridable per-call) +
Curator-injected tool-use preamble (always present) + strict-
grounding rider (when `kb.strict_grounding`). M4 templates evolve;
no parallel chat-template tree. Alternatives:

- **Format-2 (structured JSON array)** — rejected: marker
  formatting in LLM hands is fragile (the very repo's strict-
  grounding refusal exists because LLMs misbehave).
- **Format-3 (hybrid)** — rejected: over-engineered.
- **Prompt-Y (separate chat-flavored templates)** — rejected:
  doubles maintenance for marginal gain.

### Scope decision 1 — M8 / M9 boundary → collapse scoped generator into M8

The implementation.md M8 / M9 split (unscoped generator in M8,
scoped in M9) was a within-development sequencing choice with no
user-facing benefit, since all milestones ship together as v1.0.0.
Adding scoping later means re-touching every generator template,
renaming default output paths, and rewriting half the M8 specs.
Doing it once in M8 — `scope` as an optional positional arg,
`nil` scope produces today's "M8" output, non-nil produces M9-
flavored namespaced output — is one pass. M9 becomes pure release
polish (rich dashboard, remaining rake tasks, README, RubyGems
checklist). Net effect: same v1 surface, less rework.

### Scope decision 2 — phase plan parallelization → 4-block plan with contract-first 3a/3b split

5 sequential phases collapse into 4 wall-clock blocks with up to
3 parallel tracks in the middle. The load-bearing trick: Phase 3a
ships an empty `Curator::Chat` wrapper with frozen method
signatures and a contract spec (`#ask` raises `NotImplementedError`),
which lets the generator (Phase 4) develop concurrently with the
real Asker implementation (Phase 3b) by programming against the
contract. Costs one small contract spec; saves ~1 wall-clock
block of parallelism.

| Block | Phases | Parallel? |
|-------|--------|-----------|
| A | 0 | sequential (must land first) |
| B | 1, 2, 3a | three parallel tracks |
| C | 3b, 4 | two parallel tracks |
| D | 5 | sequential (manual QA) |
