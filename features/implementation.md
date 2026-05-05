# Curator — Implementation Plan (v1)

Companion to `features/initial.md`. The initial spec captures product vision; this
document captures the concrete technical decisions driven out in planning:
database schema, API shapes, generators, configuration, milestones, and v2
deferrals.

Every decision here is the result of an explicit design choice. Where
alternatives were considered and rejected, the rationale is captured.

---

## Technology & Dependencies

| Area | Choice |
|---|---|
| Rails | 7.0+ (Rails 8 recommended) |
| Ruby | 3.1+ |
| Database | PostgreSQL with pgvector extension |
| LLM layer | RubyLLM `~> 1` (latest stable as of writing: 1.14) |
| Vector search | `neighbor` gem (ActiveRecord wrapper for pgvector) |
| Default extractor | `kreuzberg` (Rust core, 97+ formats, built-in OCR) |
| Fallback extractor | `pdf-reader` + `ruby-docx` |
| Background jobs | ActiveJob (any backend; Solid Queue recommended on Rails 8) |
| File storage | Active Storage (S3, R2, or local disk) |
| Admin UI stack | Hotwire (Turbo + Stimulus), vanilla CSS namespaced under `.curator-ui` |
| Test framework | RSpec + `spec/dummy` host app |
| Lint / style | Rails Omakase (`rubocop-rails-omakase`) |

---

## Gem Structure

```
curator-rails/
├── app/
│   ├── controllers/
│   │   └── curator/
│   │       ├── application_controller.rb    # applies auth hook
│   │       ├── dashboard_controller.rb
│   │       ├── knowledge_bases_controller.rb
│   │       ├── documents_controller.rb
│   │       ├── chunks_controller.rb         # chunk inspector
│   │       ├── console_controller.rb        # query testing console (M6)
│   │       └── evaluations_controller.rb
│   ├── jobs/
│   │   └── curator/
│   │       ├── ingest_document_job.rb       # extract + chunk
│   │       └── embed_chunks_job.rb          # batched embedding
│   ├── models/
│   │   └── curator/
│   │       ├── knowledge_base.rb
│   │       ├── document.rb
│   │       ├── chunk.rb
│   │       ├── embedding.rb
│   │       ├── retrieval.rb
│   │       ├── retrieval_step.rb
│   │       └── evaluation.rb
│   ├── views/
│   │   └── curator/                         # Hotwire views
│   └── assets/
│       └── stylesheets/
│           └── curator/
│               └── curator.css              # vanilla CSS, scoped under .curator-ui
├── lib/
│   ├── curator.rb                            # top-level API
│   ├── curator/
│   │   ├── version.rb
│   │   ├── engine.rb
│   │   ├── configuration.rb
│   │   ├── answer.rb                         # Curator::Answer value object
│   │   ├── retrieval_results.rb              # Curator::RetrievalResults value object
│   │   ├── chat.rb                           # Curator::Chat wrapper
│   │   ├── token_counter.rb                  # heuristic (swappable)
│   │   ├── extractors/
│   │   │   ├── base.rb
│   │   │   ├── kreuzberg.rb
│   │   │   ├── basic.rb
│   │   │   └── extraction_result.rb          # value object
│   │   ├── chunkers/
│   │   │   └── paragraph_aware.rb
│   │   ├── retrievers/
│   │   │   ├── vector.rb
│   │   │   ├── keyword.rb
│   │   │   ├── hybrid.rb
│   │   │   └── rrf.rb
│   │   ├── prompt/
│   │   │   ├── assembler.rb                  # builds system prompt + [N] markers
│   │   │   └── templates.rb
│   │   ├── evaluations/
│   │   │   └── exporter.rb                   # shared CSV/JSON export
│   │   └── errors.rb
│   ├── generators/
│   │   └── curator/
│   │       ├── install/
│   │       └── chat_ui/
│   └── tasks/
│       └── curator.rake
├── config/
│   └── routes.rb
└── spec/
    ├── dummy/                                # test host app
    └── ...
```

---

## Database Schema

### Curator-owned tables

All prefixed `curator_`. Hard delete with cascade (KB delete → documents →
chunks → embeddings → retrievals → evaluations).

#### `curator_knowledge_bases`

```
id                     bigint PK
name                   string           # display name
slug                   string unique    # stable identifier for code
description            text
is_default             boolean default false  # only one KB has this true
embedding_model        string           # e.g. "text-embedding-3-small"
chunk_model            string           # e.g. "gpt-5-mini"
chunk_size             integer default 512    # target token count
chunk_overlap          integer default 50
similarity_threshold   decimal default 0.2  # M3 P3: lowered from 0.7 — real OpenAI cosines for relevant pairs sit 0.2–0.5
retrieval_strategy     string default "hybrid"  # hybrid | vector | keyword
tsvector_config        string default "english"
strict_grounding       boolean default true
include_citations      boolean default true
system_prompt          text             # overridable citation template
created_at, updated_at
```

#### `curator_documents`

```
id, knowledge_base_id (FK)
title                  string
source_url             string nullable  # for citation click-through
content_hash           string           # sha256, for upload dedup
mime_type              string
byte_size              integer
status                 string           # :pending | :extracting | :embedding
                                        # | :complete | :failed
stage_error            text nullable
metadata               jsonb default {} # host-app arbitrary data
                                        # (author, tags, etc.)
created_at, updated_at
```

Active Storage attaches the binary file via `has_one_attached :file`.

#### `curator_chunks`

```
id, document_id (FK)
sequence               integer          # ordinal within document
content                text
content_tsvector       tsvector         # generated column:
                                        # GENERATED ALWAYS AS
                                        # to_tsvector(config, content) STORED
token_count            integer          # heuristic approximation
page_number            integer nullable # from extractor's pages array
char_start             integer          # byte offset in original text
char_end               integer          # byte offset in original text
status                 string           # :pending | :embedded | :failed
created_at, updated_at
```

Index: GIN on `content_tsvector` for keyword search.

#### `curator_embeddings`

```
id, chunk_id (FK)
embedding              vector(N)        # N chosen at install time
                                        # (default 1536)
embedding_model        string           # model used to create this vector
created_at
```

Index: HNSW or IVFFlat on `embedding` (configurable; default HNSW on pgvector
0.5+). Single table, single fixed dimension — swapping embedding dimension
requires migration + re-embed (documented).

#### `curator_retrievals`

Captures a full config snapshot per query so v2 analytics can A/B by
prompt/model without schema changes.

```
id, knowledge_base_id (FK)
chat_id                bigint           # FK to RubyLLM chats
message_id             bigint           # FK to RubyLLM messages
                                        # (assistant message this retrieval
                                        # produced)
query                  text             # user's question
chat_model             string           # snapshot at query time
embedding_model        string           # snapshot
system_prompt_text     text             # snapshot of assembled prompt
system_prompt_hash     string           # digest for grouping
retrieval_strategy     string           # snapshot (hybrid|vector|keyword)
similarity_threshold   decimal          # snapshot
chunk_limit            integer          # snapshot
total_duration_ms      integer
status                 string           # :success | :failed
error_message          text nullable
origin                 string default 'adhoc' indexed
                                        # :adhoc | :console | :console_review
                                        # — :adhoc covers Curator.ask /
                                        # API / host-app callers, :console
                                        # marks Query Testing Console runs,
                                        # :console_review marks "Re-run in
                                        # Console" deep-links from a
                                        # Retrievals-tab detail view.
                                        # Default Retrievals/Evaluations
                                        # admin tabs hide :console_review.
created_at
```

#### `curator_retrieval_steps`

Structured per-step trace for observability. Gated by
`config.trace_level` (`:full` | `:summary` | `:off`).

```
id, retrieval_id (FK)
sequence               integer          # ordinal within retrieval
step_type              string           # embed_query | vector_search
                                        # | keyword_search | rrf_fusion
                                        # | prompt_assembly | llm_call
                                        # | tool_call
started_at             timestamp
duration_ms            integer
status                 string           # :success | :error
payload                jsonb            # step-specific data
error_message          text nullable
```

#### `curator_evaluations`

Multiple evaluations per retrieval allowed (end-user thumbs + SME review both
create rows).

```
id, retrieval_id (FK)
rating                 string           # :positive | :negative
feedback               text nullable
ideal_answer           text nullable    # golden dataset source
evaluator_id           string nullable  # opaque host-app user ID
evaluator_role         string nullable  # :end_user | :reviewer
failure_categories     string[] default '{}'  # zero-or-more, only on :negative
                                        # — see taxonomy below. Postgres text[]
                                        # (Rails native), GIN-indexable.
created_at, updated_at
```

### RubyLLM-owned tables

Managed by `ruby_llm:install`. Curator does not modify these, except one
additive migration for scoped chat UIs:

`chats` gets `curator_scope string nullable` — populated by scoped
`curator:chat_ui` generator runs, used to partition chat lists per UI namespace.

---

## Service Object API

```ruby
# One-shot Q&A (streaming optional via block)
result = Curator.ask("What is our refund policy?", knowledge_base: :support)
result = Curator.ask("...") do |chunk|
  # stream delta to client; result still returned after block completes
end
# => Curator::Answer

# Semantic search only (no LLM call)
results = Curator.retrieve("refund policy",
                         knowledge_base: :legal,
                         limit: 10,
                         threshold: 0.7)
# => Curator::RetrievalResults

# Multi-turn persistent chat (retrieval wired as a RubyLLM tool)
chat = Curator.chat(knowledge_base: :support)
answer1 = chat.ask("What's our refund policy?") { |c| ... }
answer2 = chat.ask("How long do I have to claim?") { |c| ... }
chat.history   # => [Curator::Answer, Curator::Answer]

# Ingestion
Curator.ingest(file,
               knowledge_base: :support,
               title: "Refund Policy",
               source_url: "https://docs.acme.com/refunds",
               metadata: { author: "Legal Team", tags: ["policy"] })
Curator.ingest_directory("./docs", knowledge_base: :support)

# Evaluation — canonical write path shared by admin UI and host
# controllers exposing end-user feedback. Returns the persisted
# Curator::Evaluation; raises on validation failure.
Curator.evaluate(
  retrieval:          retrieval_or_id,
  rating:             :positive,           # | :negative
  evaluator_role:     :reviewer,           # | :end_user (required)
  evaluator_id:       "alice@acme.com",    # opaque host-app user id
  feedback:           "matched our policy doc",
  ideal_answer:       nil,                 # populate on :negative
  failure_categories: []                   # zero-or-more on :negative
)
```

### Value objects

```ruby
class Curator::Answer
  attr_reader :answer, :retrieval_results, :retrieval_id
  def sources; retrieval_results.hits; end
end

class Curator::RetrievalResults
  attr_reader :hits, :query, :duration_ms, :knowledge_base
end

# Hit shape (shared between Answer#sources and RetrievalResults#hits)
{
  rank:          1,
  chunk_id:      305,
  document_id:   42,
  document_name: "Refund Policy",
  page:          3,
  text:          "All purchases are refundable within 30 days...",
  score:         0.87,
  source_url:    "/curator/documents/42#chunk-305"
}
```

Citation marker `[N]` in LLM prompts equals `hit.rank` — no separate marker
concept.

Every `Curator.ask` and `Curator.chat#ask` creates a real RubyLLM `Chat` + user
and assistant `Message` rows. `curator_retrievals` FKs to the assistant message
so traceability is always present, even for one-shot calls.

---

## Retrieval Pipeline

### Hybrid (default)

1. Embed the query using the KB's `embedding_model`.
2. Vector search: `Curator::Embedding.nearest_neighbors(:embedding, query_vec,
   distance: "cosine").limit(N)`.
3. Keyword search: Postgres full-text against `content_tsvector`, limited to N.
4. Fuse results via `Neighbor::Reranking.rrf(vector_ids, keyword_ids)`
   (parameterless for v1).
5. Filter by `similarity_threshold`.

### Vector-only / keyword-only

Same as above, skipping the unused stage and the RRF step.

### Strict grounding

If `strict_grounding: true` (default) and retrieval returns zero hits crossing
the threshold:
- The prompt assembler emits a system message instructing the LLM to respond
  "I don't have information on that in the knowledge base."
- `curator_retrievals` still captures the no-hit state.
- `Curator::Answer#sources` is empty.

If `strict_grounding: false`, the LLM is allowed to answer from training data
(with a prompt instruction to clearly indicate uncited content).

---

## Ingestion Pipeline

### Upload path

1. Host app or admin UI passes a file to `Curator.ingest(file, knowledge_base:)`.
2. Engine computes SHA-256 of the byte stream.
3. Dedup check: if a `curator_documents` row exists in the same KB with that
   hash, return existing record with a warning (admin UI surfaces "Already
   ingested as X"). No new row created.
4. Else: create `curator_documents` row with `status: :pending`, attach file
   via Active Storage, enqueue `IngestDocumentJob`.

### `IngestDocumentJob` (extract + chunk)

1. Update status to `:extracting`.
2. Run the configured extractor.
3. Build chunks via paragraph-aware chunker (target 512 tokens, 50 overlap).
4. Persist `curator_chunks` rows (`status: :pending`).
5. Update document status to `:embedding`; enqueue `EmbedChunksJob`.

### `EmbedChunksJob` (batched embedding)

1. Pull all `status: :pending` chunks for the document.
2. Split into provider-appropriate batches (configurable, default 100).
3. For each batch, call the embedding provider via RubyLLM, persist
   `curator_embeddings` rows, mark chunks `:embedded`.
4. On completion, mark document `:complete`.
5. On partial failure: failed chunks marked `:failed`, job retried with
   backoff — already-embedded chunks are skipped on retry.

### Re-ingestion

Re-ingest triggered from admin UI or `curator:reingest DOCUMENT=123`:
1. Delete existing chunks + embeddings in a transaction (keeps `curator_documents`
   row and its historical `curator_retrievals` links valid).
2. Run the full pipeline on the stored Active Storage blob.

### File size and MIME handling

- Default max file size: 50 MB (`config.max_document_size`, configurable).
- MIME rejection behavior is extractor-aware:
  - **Basic extractor**: strict whitelist (`text`, `md`, `pdf`, `docx`, `html`, `csv`). Rejects unknown with clear error.
  - **Kreuzberg extractor**: permissive. Attempts extraction; rejects only on failure or empty output.

### Extractor contract

```ruby
module Curator::Extractors
  class Kreuzberg
    def extract(file_path)
      result = ::Kreuzberg.extract_file_sync(
        file_path,
        config: Kreuzberg::Config::Extraction.new(extract_pages: true)
      )
      ExtractionResult.new(
        content:   result.content,
        mime_type: result.mime_type,
        pages:     (result.pages || []).map { |p|
          { number: p.page_number, content: p.content }
        }
      )
    end
  end
end
```

`ExtractionResult` is the only type the chunker sees. Extractors are swappable
without touching the chunking or embedding pipeline.

### What's indexed implicitly via Kreuzberg

- **Image text**: Kreuzberg's built-in OCR pulls text from images; it lands in
  `content` and is chunked/embedded normally. Documents about "Q3 revenue chart"
  will match even if the chart is a scanned image.
- **Table text**: Kreuzberg flattens tables into the `content` stream. Searchable
  via keyword, parseable by the LLM.

First-class table chunks and multimodal image embeddings are v2 work.

---

## Citation System

### Prompt format (when `include_citations: true`)

Retrieved chunks are injected into the system prompt as:

```
[1] From "Refund Policy" (page 3):
All purchases are refundable within 30 days of delivery, provided...

[2] From "Terms of Service" (page 7):
Refunds exclude services already rendered...
```

The LLM is instructed to reference `[N]` markers when making claims. Internally
Curator holds the mapping `{ 1 => chunk_id, 2 => chunk_id, ... }` and returns
it via `Curator::Answer#sources`.

When `include_citations: false`, chunks are injected without markers and the
LLM is not instructed to cite. `sources` is still populated in the return value
so the host app can display source metadata if it wishes.

### Per-KB overrides

The `system_prompt` column on `curator_knowledge_bases` lets users fully replace
the default citation template with their own, per KB.

---

## Evaluation System

### Feedback sources

- **End users** — submit thumbs up/down via the REST API from the host app's
  frontend. Minimal friction.
- **SMEs** — review queries in the admin UI, add feedback, ideal answers, and
  failure categories.

One `curator_retrievals` row can have many evaluations (end-user thumb + SME
review + additional reviewers).

### Rating

Binary: `:positive` | `:negative`. (Considered 4-point and 5-point scales;
rejected due to calibration problems and lower submission rates. Richer
signal lives in `feedback` text and `ideal_answer`.)

### Failure categories (only on `:negative`)

SME-facing **multi-select** checkbox list in the admin UI — real failures
often compound (e.g. `:wrong_retrieval` causes `:hallucination`; `:incomplete`
co-occurs with `:wrong_citation`). Forcing a single dominant category would
be lossy. Stored as a Postgres `text[]` array column (`failure_categories`),
GIN-indexable. Tooltips surfaced on each choice via hover.

| Category | Tooltip |
|---|---|
| `:hallucination` | The answer states facts that aren't supported by any retrieved source. |
| `:wrong_retrieval` | The retrieved sources aren't relevant to the question. |
| `:incomplete` | The right sources were retrieved, but the answer omits relevant information from them. |
| `:wrong_citation` | A citation marker points to a source that doesn't actually support the claim. |
| `:refused_incorrectly` | The answer says "I don't know" but the information exists in the knowledge base. |
| `:off_topic` | The answer doesn't address the question being asked. |
| `:other` | Something else is wrong — please describe in the feedback field. |

Tooltips stored as an i18n-able constant `Curator::Evaluation::FAILURE_CATEGORY_TOOLTIPS`.

Analytics queries use `'hallucination' = ANY(failure_categories)` rather than
equality. This surfaces correlations — e.g. "75% of `:wrong_retrieval`
evaluations also carry `:hallucination`" → retrieval quality drives
hallucination rates.

### Write path — `Curator.evaluate`

All evaluation writes (admin UI, host-app end-user feedback) go through the
same service object: `Curator::Evaluator.call(...)`, exposed as
`Curator.evaluate(...)` (delegator matching `Curator.ingest` /
`Curator.ask`). It validates the rating against
`Curator::Evaluation::RATINGS`, normalizes `failure_categories` against
`FAILURE_CATEGORIES`, and enforces the "categories empty unless `:negative`"
constraint. Returns the persisted `Curator::Evaluation`; raises
`Curator::Evaluation::ValidationError` on bad input.

Two configuration hooks resolve the evaluator id symmetrically:

- `current_admin_evaluator` — block called with the controller; returns an
  opaque id to stamp on admin-side evals (typically `current_user&.email`).
- `current_end_user_evaluator` — block called with the host's controller;
  returns an opaque id for end-user feedback evals.

Both default to `->(_controller) { nil }` so zero-config hosts get
nil-evaluator evals everywhere with no breakage.

### Admin surfaces

Three admin entry points, all writing through `Curator.evaluate`:

1. **Console inline rating** — after a Query Testing Console run completes
   (`done` broadcast), a thumbs widget (👍 / 👎) is injected. Either thumb
   POSTs immediately and reveals an optional rating-aware "Add details"
   expansion. Same operator session edits the same eval row in place
   (POST returns id; subsequent submits PATCH); a fresh load appends a
   new row.
2. **Retrievals tab** — paginated list of every `curator_retrievals` row
   with filters (KB, date range, status, chat_model, embedding_model,
   rating join, unrated-only, free-text query). Detail view renders the
   query, persisted answer, ranked sources (reused `_source` partial),
   collapsible snapshot config, "Re-run in Console" deep-link (tagged
   `origin: :console_review`), trace timeline behind a "Show trace"
   toggle, and an annotation form for SME evals. Default scope hides
   `:console_review` rows.
3. **Evaluations tab** — paginated list of every `curator_evaluations` row
   joined to its retrieval, with rating / evaluator_role /
   failure_categories filters. Each row links to the Retrievals-tab
   detail view with `?evaluation_id=` so the matching eval scrolls into
   view.

End-user feedback in v1: hosts wire ~5 lines of controller calling
`Curator.evaluate(..., evaluator_role: :end_user)`; the README ships the
canonical example. A turnkey `curator:feedback_widget` generator is
deferred to v2+.

### Export

Two exporters, two rake tasks, two admin "Export" buttons:

- `Curator::Retrievals::Exporter` — every retrieval row (CSV / JSON);
  rake `curator:retrievals:export`.
- `Curator::Evaluations::Exporter` — every eval joined to retrieval
  (CSV / JSON); rake `curator:evaluations:export`.

CSV streams via `ActionController::Live`; JSON is a single response
(v1 sizes — large export queue-and-email is deferred to v2+). Exports
respect current admin UI filters (KB, date range, rating,
evaluator_role, failure_categories — filter matches rows where any
selected category is present).

Eval columns: `retrieval_id, query, answer (truncated), knowledge_base,
chat_model, embedding_model, rating, feedback, ideal_answer,
failure_categories (semicolon-joined in CSV; JSON array in JSON),
evaluator_id, evaluator_role, created_at`.

Retrieval columns: `retrieval_id, query, answer (truncated), knowledge_base,
chat_model, embedding_model, status, origin, retrieved_hit_count,
eval_count, created_at`.

---

## REST API

v1 ships engine-internal Hotwire UI only. Host apps expose Curator to their
end users via the in-process service object API (`Curator.ask`,
`Curator.retrieve`, `Curator.chat`) wrapped in their own controllers, or
via the M8 `curator:chat_ui` generator. A first-class REST API
(`/api/query`, `/api/retrieve`, `/api/stream`), JSON envelope, error
format, and `authenticate_api_with` auth hook are deferred to v2+ —
rationale: the gem mounts in a Rails host that already has in-process
access to the service objects, so a REST surface is genuinely useful only
for non-Rails clients (mobile, separate-origin SPAs, server-to-server)
and brings real design / docs / maintenance commitments (envelope
versioning, error codes, API tokens, CORS, OpenAPI, rate limits) — easy
to add later if demand materializes, hard to remove once shipped. See
the "Deferred to v2+ → Added during planning" section below for the full
list of v2+ API surface area.

---

## Admin UI

### Mount

```ruby
mount Curator::Engine, at: "/curator"
```

Configurable via `--mount-at` generator flag.

### Landing page (`/curator`)

Empty-state aware:
- **No KBs**: onboarding screen with "Create your first knowledge base" CTA.
- **Has KBs**: dashboard with
  - Global tiles (KB count, document count, chunk count)
  - "Needs attention" panel (failed ingestions, recent `:negative` evals)
  - Recent activity feed (last 20 ingestions + last 20 queries interleaved by
    timestamp)
  - Per-KB nav cards (name, doc count, last query time)

### Global nav

- KB switcher in top bar, always visible after a KB is selected.
- All other sections operate within the currently-selected KB's scope.

### Sections

- **Knowledge Base management** — CRUD + per-KB config
- **Document management** — upload (drag-drop), ingestion status, re-ingest,
  delete
- **Chunk Inspector** — browse chunks from a document, view text + token count +
  page number + char offsets
- **Query Testing Console** — streams response alongside retrieved chunks; tweak
  chunk count / threshold / prompt template live
- **Response Evaluation** — three surfaces sharing the `Curator.evaluate`
  write path:
  - Console inline thumbs (rating-aware expansion injected on `done`
    broadcast)
  - Retrievals tab — list/filter every retrieval; detail view with
    "Re-run in Console" deep-link (tagged `origin: :console_review`)
  - Evaluations tab — list/filter every eval, click-through to the
    retrieval detail view
  Both tabs ship CSV + JSON export buttons.

### Asset strategy

- **CSS**: vanilla `app/assets/stylesheets/curator/curator.css` shipped in
  the engine and served via the host's asset pipeline (Propshaft or
  Sprockets). Every rule is scoped under `.curator-ui` (the `<body>`
  class on every engine view), giving deterministic isolation from the
  host's stylesheets without a Node toolchain. Color, typography, and
  spacing tokens defined as custom properties on `:root` so a future
  `prefers-color-scheme: dark` rule is a one-block addition.
- **JS**: importmap pins for Turbo + Stimulus controllers shipped by the engine.

---

## Generators

### `curator:install`

```bash
rails g curator:install [options]
  --embedding-dim=N     # default 1536; vector column dimension
  --mount-at=/path      # default /curator
  --skip-sample-controller
```

Chain-runs `ruby_llm:install` first (chats, messages, tool_calls, models).

Creates:
- `config/initializers/curator.rb` — heavily annotated, commented examples for
  OpenAI / Anthropic / Voyage / Ollama
- Migrations (one per table for clean rollback):
  - Adds pgvector extension check (generates `CREATE EXTENSION vector` migration
    if missing)
  - `curator_knowledge_bases`
  - `curator_documents`
  - `curator_chunks`
  - `curator_embeddings`
  - `curator_retrievals`
  - `curator_retrieval_steps`
  - `curator_evaluations`
  - Adds `curator_scope string nullable` to `chats`
- `app/controllers/knowledge_controller.rb` (sample — unless `--skip-sample-controller`)
- Seeds a default KB via `curator:seed_defaults` rake task (not inline in a
  migration)

Modifies:
- `config/routes.rb` — adds mount line

Does NOT:
- Configure auth (unconfigured requests raise `Curator::AuthNotConfigured`
  in non-test envs)
- Install ActiveJob backend (user chooses)
- Install Active Storage (prints warning with install command, exits non-zero
  if missing)

### `curator:chat_ui`

RAG-aware equivalent of `ruby_llm:chat_ui`. Generates a branded frontend
scaffold wired to `Curator.chat`.

```bash
rails g curator:chat_ui [scope] [model_names...] [options]
  --kb=<slug>      # pin this chat UI to a single KB; omit for a selector UI
```

**Unscoped examples**:
```bash
rails g curator:chat_ui                      # multi-KB selector UI
rails g curator:chat_ui --kb=support         # single KB pinned
```

**Scoped examples** (for multiple chat UIs in one host app):
```bash
rails g curator:chat_ui support --kb=support
rails g curator:chat_ui legal   --kb=legal
rails g curator:chat_ui research             # multi-KB selector, scoped
```

Scoped output lands under `Support::` (etc.) — controllers, views, jobs,
routes all namespaced. RubyLLM Chat / Message models are shared across scopes
(one underlying schema) but each scoped controller partitions lists via
`curator_scope` column on `chats`.

Custom model name overrides:
```bash
rails g curator:chat_ui support chat:Conversation message:Reply --kb=support
```

Generated output (per invocation):
- `ChatsController` + `MessagesController`
- Views with citation rendering (`[N]` → clickable link, sources sidebar)
- KB selector dropdown (when not `--kb`-pinned)
- `ChatResponseJob` (background RAG response)
- Routes (scoped or top-level)

### Deferred to v2+

- `curator:feedback_widget` — turnkey end-user thumbs widget that emits
  a controller + view + Stimulus into the host. v1 hosts wire ~5 lines
  themselves calling `Curator.evaluate(..., evaluator_role: :end_user)`;
  the README ships the canonical example.

---

## Rake Tasks

```
curator:reembed KB=<slug>               # re-embed all chunks in a KB
                                        # (after embedding model change)
curator:reingest DOCUMENT=<id>          # re-run full pipeline on one doc
curator:retrievals:export KB=<slug> FORMAT=<csv|json> [SINCE=<iso>]
curator:evaluations:export KB=<slug> FORMAT=<csv|json> [SINCE=<iso>]
curator:stats                           # print KB/doc/chunk/retrieval counts
curator:ingest PATH=<dir> KB=<slug>     # CLI equivalent of Curator.ingest_directory
curator:vacuum KB=<slug>                # remove orphaned chunks/embeddings
```

Deferred to v2:
```
curator:eval:run GOLDEN=<path>          # golden dataset + LLM-as-judge
```

---

## Configuration

```ruby
Curator.configure do |config|
  # Extractor — :kreuzberg (default) | :basic
  config.extractor = :kreuzberg

  # Auth hook for the admin UI. v1 is Hotwire-only; the API auth hook
  # was removed alongside the REST API surface (see M6 amendment).
  config.authenticate_admin_with do
    redirect_to main_app.login_path unless current_user&.admin?
  end

  # Identity hooks for evaluations (M7). Both default to
  # ->(_controller) { nil } so zero-config hosts get nil-evaluator evals
  # everywhere, no breakage. Stamp opaque host-app user ids onto evals.
  config.current_admin_evaluator    = ->(controller) { controller.current_user&.email }
  config.current_end_user_evaluator = ->(controller) { controller.current_user&.id&.to_s }

  # Document handling
  config.max_document_size = 50.megabytes

  # Tracing / logging
  config.trace_level = :full     # :full | :summary | :off
  config.log_queries = true      # create curator_retrievals rows (can be false
                                 # for privacy-sensitive deployments)

  # LLM reliability
  config.llm_retry_count = 1     # retries on 5xx / timeout
  config.query_timeout   = nil   # nil defers to RubyLLM's / HTTP defaults

  # Embedding batch size
  config.embedding_batch_size = 100
end
```

---

## Error Handling

Fail loud, not silent. Every failure creates a `curator_retrievals` row with
`status: :failed` and an `error_message`, so the admin UI surfaces what went
wrong.

| Failure mode | Behavior |
|---|---|
| Query embedding fails | Raise `Curator::EmbeddingError`; retrieval row marked `:failed` |
| DB retrieval fails | Raise `Curator::RetrievalError` |
| No chunks above threshold | Not a failure; strict_grounding decides behavior |
| LLM provider 5xx / timeout | Retry `llm_retry_count` times; on final failure raise `Curator::LLMError`. Retrieval steps remain recorded (admin UI shows "retrieval OK, LLM failed") |
| Streaming interrupted mid-stream | Partial content already yielded; raise `Curator::LLMError` after |
| Curator-level timeout | Configurable via `config.query_timeout` (nil by default) |
| Ingestion extraction fails | Document status → `:failed`; `stage_error` text populated |
| Embedding partial batch fails | Failed chunks marked `:failed`; job retried with backoff; already-embedded chunks skipped |

---

## Testing Strategy

- **RSpec** in `spec/`.
- **`spec/dummy`** Rails host app mounts the engine, used for integration specs.
- **Per-extractor adapter tests** — same test suite runs against both Kreuzberg
  and basic, asserting `ExtractionResult` contract.
- **Real Postgres with pgvector** for retrieval tests (no mocking of vector
  search behavior — that's the whole point of pgvector integration).
- **RubyLLM provider stubbing** at the HTTP layer (WebMock / VCR cassettes)
  so tests don't hit real LLM APIs.
- **Factory Bot** for model fixtures.
- **System specs** with Capybara + headless Chrome for admin UI flows.

---

## Implementation Milestones

Ordered so each milestone is independently shippable/testable and gives
something visible.

Principle: each milestone is independently shippable and self-testable. Rake
tasks are assigned to the milestone whose work they support (so each milestone
is demo-able end-to-end via CLI).

### M1 — Foundation
- Gem skeleton (RSpec, `spec/dummy`, RuboCop Omakase, gemspec)
- `curator:install` generator (chains `ruby_llm:install`, verifies pgvector,
  writes initializer, migrations, sample controller, mount line)
- Migrations for all Curator tables + `chats.curator_scope` additive migration
- Model classes with associations + validations (no business logic yet)
- `curator:seed_defaults` rake task (seeds default KB; invoked post-install)
- Auth hook plumbing (`ApplicationController`, `Api::BaseController`
  dispatching to configured blocks via a shared `Curator::Authentication`
  concern; unconfigured envs raise `Curator::AuthNotConfigured` in dev/prod
  and no-op in test)

### M2 — Ingestion
- Pluggable extractor adapters (Kreuzberg + basic) and `ExtractionResult`
  value object contract
- Paragraph-aware chunker (512 target / 50 overlap default)
- `Curator.ingest` + `Curator.ingest_directory`
- `IngestDocumentJob` (extract + chunk pipeline)
- Active Storage wiring, SHA-256 content-hash dedup
- `curator:ingest` rake task (CLI equivalent of `ingest_directory`)

### M3 — Embedding + Retrieval
- `EmbedChunksJob` with batched provider calls + partial-retry semantics
- pgvector column (install-time dimension) + HNSW index
- `Curator::Embedding` via `neighbor` gem
- All retrieval strategies: vector, keyword (tsvector GIN), hybrid (RRF via
  `Neighbor::Reranking.rrf`)
- `Curator.retrieve` returning `Curator::RetrievalResults`
- `curator:reembed` rake task

### M4 — Q&A
- Prompt assembler (`[N]` marker injection, strict-grounding fallback,
  `include_citations` toggle)
- `Curator.ask` with optional streaming block
- `Curator::Answer` value object wrapping `RetrievalResults`
- RubyLLM Chat + Message persistence per query
- `curator_retrievals` + `curator_retrieval_steps` trace capture (respecting
  `config.trace_level`)
- Error hierarchy (`Curator::EmbeddingError`, `RetrievalError`, `LLMError`)

### M5 — Admin UI Core
- Vanilla namespaced CSS (`app/assets/stylesheets/curator/curator.css`,
  scoped under `.curator-ui`)
- Layout, navigation, top-bar KB switcher
- Landing page (empty-state aware stub; rich dashboard deferred to M9)
- Knowledge Base CRUD + per-KB configuration form
- Document management (drag-drop upload, list with status, delete, re-ingest
  trigger)
- Chunk Inspector
- Live document/KB list updates via ActionCable + Turbo Streams broadcasts
  (host must have a configured cable adapter — Solid Cable on Rails
  7.1+/8, Redis pre-7.1)

### M6 — Query Testing Console + Token Streaming
- Query Testing Console (admin Turbo UI; live token streaming via
  `ActionController::Live` + Turbo Streams; per-run parameter overrides;
  runs persist as `curator_retrievals` rows).
- Token-streaming module (`Curator::Streaming::TurboStream`) reusable by
  the M8 chat UI without changes.

### M7 — Evaluations
- `Curator::Evaluation` model + admin UI controllers
- Thumbs UI + feedback form + ideal answer capture
- Failure categories dropdown with tooltips
- `Curator::Evaluations::Exporter` service (CSV via streaming, JSON)
- Admin UI export button + `curator:evaluations:export` rake task
- In-app feedback submission (admin UI thumbs/feedback form writes
  `Curator::Evaluation` directly; host apps that want end-user feedback
  wrap `Curator::Evaluation.create!` in their own controller)

### M8 — Persistent Chat
- `Curator::Chat` wrapper class
- Retrieval wired as a RubyLLM Tool
- Tool-call trace capture into `curator_retrieval_steps`
- `curator:chat_ui` generator (unscoped) — both single-KB pin (`--kb=slug`) and
  multi-KB selector modes

### M9 — Polish & Release
- Scoped `curator:chat_ui` generator (`curator_scope` partitioning on chats)
- Rich dashboard (tiles, needs-attention panel, activity feed, per-KB nav
  cards)
- Remaining rake tasks (`curator:stats`, `curator:vacuum`)
- Documentation (README, configuration reference, upgrade guide, sample host
  app repository link)
- Release checklist (RubyGems metadata, changelog, version tagging)

---

## Deferred to v2+

### From the original spec's deferred list
- Analytics dashboard (query volume, slow query tracking, retrieval success rate)
- A/B comparison view in evals
- LLM-as-judge scoring
- Corpus page (public-facing document index)
- Reranking (second-pass reranking model)
- Multi-tenancy within Curator
- External vector databases (Pinecone, Weaviate, etc.)
- Multi-language support (beyond swappable tsvector config)
- Fine-tuning / model training

### Added during planning
- **REST API endpoints** (`/api/query`, `/api/retrieve`, `/api/stream`,
  `/api/evaluations`) — for non-Rails clients (mobile, separate-origin
  SPAs, server-to-server). Removed from v1 in the M6 amendment because
  the gem mounts in a Rails host that already has in-process access to
  `Curator.ask` / `Curator.retrieve` / `Curator.chat`. Easy to add later
  once shipped, hard to remove once shipped.
- **JSON success/error envelope** (`data` + `meta` shape; error code
  taxonomy spanning 400/401/404/422/500/502/503) — depends on REST API.
- **`authenticate_api_with` auth hook** + API tokens — depends on REST
  API. v1 retains only `authenticate_admin_with` for the Hotwire admin
  UI.
- **Non-Rails-client concerns** — CORS, OpenAPI/Swagger spec, rate
  limiting, API token issuance/rotation. All deferred with the REST API.
- **Tool-based retrieval for one-shot queries** — spec's "advanced usage" where
  the LLM decides when to retrieve. v1 ships this only for `Curator.chat`
  (persistent, where multi-turn demands it). One-shot `Curator.ask` uses
  explicit upfront retrieval.
- **RRF weight tuning** — v1 uses parameterless RRF. Per-KB weight config in v2.
- **Sampled query logging** — v1 `log_queries` is boolean; v2 adds `:sampled`
  with a rate.
- **Large eval export queue-and-email** — v1 streams directly; v2 queues when
  row count exceeds a threshold.
- **`curator:eval:run`** — golden dataset runner powered by LLM-as-judge.
- **`curator:tool` generator** — thin wrapper around `ruby_llm:tool` for
  KB-aware custom tools. Users can use `ruby_llm:tool` directly for now.
- **Anthropic-style prompt caching** — caches long system prompts across
  retrieval calls to reduce cost. Exposes RubyLLM's raw-content storage.
- **Multimodal image/audio embedding** — spec's original "image/audio ingestion"
  clarified: image *text* IS indexed in v1 via Kreuzberg OCR. What's deferred is
  treating images/audio as first-class retrievable entities with multimodal
  embeddings.
- **Structured table extraction** — Kreuzberg's `tables` data becomes first-class
  chunks with table-aware citation rendering. v1 indexes table text via content
  flattening only.
- **Section / heading hierarchy in chunks** — Kreuzberg's Ruby API does not
  currently expose document hierarchy. Original spec's "structure-aware chunking"
  was aspirational; v1 uses paragraph-aware chunking only. If/when Kreuzberg
  exposes hierarchy, v2 adds heading-boundary chunking.
- **Swap heuristic token counter for tiktoken** — v1 uses a char-based heuristic
  (no native deps). Behind a single `Curator::TokenCounter.count(text)` module
  so swap is a one-file change + token_count backfill.
- **BM25 keyword scoring (via ParadeDB `pg_search` or SQL-side computation)** —
  v1 uses Postgres `tsvector` + `ts_rank`, which is known to underperform BM25
  on RAG retrieval-quality benchmarks. Deferred because the swap is localized
  to `Curator::Retrievers::Keyword` (RRF fusion layer unchanged) and should be
  driven by eval data, not speculation. Trigger for v2 work: M7 evaluation
  exports show keyword recall as a recurring failure category, or operators
  request it. Implementation path: ParadeDB extension for native BM25, or a
  manual SQL-side BM25 computation against the existing `tsvector` index for
  zero-extension deployments.
- **SQLite support alongside Postgres** — v1 is Postgres-only (pgvector for
  vectors, tsvector for keyword, `text[]` for `failure_categories`). SQLite
  support requires an adapter layer over vector ops (sqlite-vec), keyword
  search (FTS5 with native BM25), array columns (JSON-encoded fallback), and
  parallel migration templates. Most Rails production apps run Postgres, so
  v1 keeps a single integration surface. Trigger for v2: developer-experience
  feedback that the Postgres requirement blocks adoption for small / hobbyist
  Rails apps.
- **External / embedded vector stores (LanceDB, Pinecone, Weaviate, etc.)** —
  separately listed under "From the original spec's deferred list," but the
  M4-planning concern is worth recording: a separate vector store breaks the
  single-transaction guarantee that lets Curator cascade-delete cleanly,
  back up atomically, and avoid dual-write inconsistency between chunk rows
  and vector rows. The pgvector-in-the-same-DB design is load-bearing for
  the engine's "drop-in" positioning. v2 work, if pursued, must include an
  ingestion-side reconciliation story (orphan-vector sweep, retry-with-idempotency
  on partial-write failures) before the architectural cost is justifiable.

---

## Decisions Considered and Rejected

Captured here so future contributors understand the "why not" behind current
shape.

- **Message-linked via RubyLLM schema mod** — rejected; Curator owns the link
  on its side (`curator_retrievals.message_id`) so RubyLLM's tables stay pristine.
- **Variable-dim embedding column or per-KB tables** — rejected; complexity
  without clear v1 benefit. Single fixed-dim column, dim chosen at install.
- **Soft delete** — rejected for v1; export-then-delete flow covers audit
  needs, cascade delete is simpler.
- **4-point or 5-point rating scale** — rejected; binary gives higher
  submission rates, cleaner analytics, matches industry norm. Nuance goes in
  `feedback` + `ideal_answer` + `failure_categories`.
- **JSON:API response spec** — rejected; `data` + `meta` envelope is simpler
  and sufficient.
- **Per-chunk embedding jobs** — rejected; batch API calls are the actual
  efficiency mechanism. Per-chunk jobs fragment batching, multiply HTTP
  overhead, and worsen rate-limit pressure.
- **Oversized padded vectors** (e.g. always vector(4096)) — rejected; cosine
  similarity is correct, but storage is 2.6× larger and queries scale with
  dimension, including padded zeros.
- **Ignoring the `curator_scope` column for simple apps** — rejected;
  nullable string column has negligible cost and keeps the generator simpler.
