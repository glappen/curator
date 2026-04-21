# Curator — Implementation Plan (v1)

Companion to `specs/initial.md`. The initial spec captures product vision; this
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
| Admin UI stack | Hotwire (Turbo + Stimulus), Tailwind + daisyUI (pre-compiled) |
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
│   │       ├── queries_controller.rb        # query testing console
│   │       ├── evaluations_controller.rb
│   │       └── api/
│   │           ├── base_controller.rb       # applies API auth hook
│   │           ├── queries_controller.rb
│   │           ├── searches_controller.rb
│   │           └── streams_controller.rb
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
│   │       ├── search.rb
│   │       ├── search_step.rb
│   │       └── evaluation.rb
│   ├── views/
│   │   └── curator/                         # Hotwire + Tailwind views
│   └── assets/
│       └── curator/
│           └── curator.css                   # pre-compiled Tailwind+daisyUI
├── lib/
│   ├── curator.rb                            # top-level API
│   ├── curator/
│   │   ├── version.rb
│   │   ├── engine.rb
│   │   ├── configuration.rb
│   │   ├── answer.rb                         # Curator::Answer value object
│   │   ├── search_results.rb                 # Curator::SearchResults value object
│   │   ├── chat.rb                           # Curator::Chat wrapper
│   │   ├── token_counter.rb                  # heuristic (swappable)
│   │   ├── extractors/
│   │   │   ├── base.rb
│   │   │   ├── kreuzberg.rb
│   │   │   ├── basic.rb
│   │   │   └── extraction_result.rb          # value object
│   │   ├── chunkers/
│   │   │   └── paragraph_aware.rb
│   │   ├── retrieval/
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
chunks → embeddings → searches → evaluations).

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
similarity_threshold   decimal default 0.7
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

#### `curator_searches`

Captures a full config snapshot per query so v2 analytics can A/B by
prompt/model without schema changes.

```
id, knowledge_base_id (FK)
chat_id                bigint           # FK to RubyLLM chats
message_id             bigint           # FK to RubyLLM messages
                                        # (assistant message this search
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
created_at
```

#### `curator_search_steps`

Structured per-step trace for observability. Gated by
`config.trace_level` (`:full` | `:summary` | `:off`).

```
id, search_id (FK)
sequence               integer          # ordinal within search
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

Multiple evaluations per search allowed (end-user thumbs + SME review both
create rows).

```
id, search_id (FK)
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
results = Curator.search("refund policy",
                         knowledge_base: :legal,
                         limit: 10,
                         threshold: 0.7)
# => Curator::SearchResults

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
```

### Value objects

```ruby
class Curator::Answer
  attr_reader :answer, :search_results, :search_id
  def sources; search_results.hits; end
end

class Curator::SearchResults
  attr_reader :hits, :query, :duration_ms, :knowledge_base
end

# Hit shape (shared between Answer#sources and SearchResults#hits)
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
and assistant `Message` rows. `curator_searches` FKs to the assistant message
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
- `curator_searches` still captures the no-hit state.
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
   row and its historical `curator_searches` links valid).
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

One `curator_searches` row can have many evaluations (end-user thumb + SME
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

### Export

Rake task and admin UI "Export" button share `Curator::Evaluations::Exporter`
service object. CSV streams via `ActionController::Streaming`; JSON is a single
response. Exports respect current admin UI filters (KB, date range, rating,
evaluator_role, failure_categories — filter matches rows where any selected
category is present).

Columns: `search_id, query, answer (truncated), knowledge_base, chat_model,
embedding_model, rating, feedback, ideal_answer, failure_categories (semicolon-
joined in CSV; JSON array in JSON), evaluator_id, evaluator_role, created_at`.

---

## REST API

Mounted at `<mount-path>/api/`. Default: `/curator/api/`.

### Endpoints

```
POST /curator/api/query              # Q&A, non-streaming
POST /curator/api/stream             # Q&A, Turbo Streams
GET  /curator/api/search             # Semantic search
POST /curator/api/evaluations        # Submit user feedback
                                     # (links to a prior search via query_id)
```

All endpoints accept `?knowledge_base=<slug>`. Omitting uses the default KB.

### Success envelope

```json
{
  "data": {
    "answer": "...",
    "sources": [...],
    "context_count": 3
  },
  "meta": {
    "knowledge_base": "support",
    "query_id": "uuid-or-id",
    "duration_ms": 847
  }
}
```

### Error format

```json
{
  "error": {
    "code": "unknown_knowledge_base",
    "message": "Knowledge base 'foobar' does not exist",
    "details": { "available": ["default", "support"] }
  }
}
```

HTTP status codes: 400 validation, 401 auth, 404 KB not found, 422 input
semantically invalid, 500 LLM/embedding failure, 502 upstream provider error,
503 rate limit / temporary.

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
- **Response Evaluation** — review queries, submit SME annotations, export

### Asset strategy

- **CSS**: pre-compiled `curator.css` (Tailwind + daisyUI) shipped in
  `app/assets/curator/`. Host app just mounts the engine; no pipeline
  participation required. Rebuilt by engine maintainers via
  `rake curator:build_assets`.
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
  - `curator_searches`
  - `curator_search_steps`
  - `curator_evaluations`
  - Adds `curator_scope string nullable` to `chats`
- `app/controllers/knowledge_controller.rb` (sample — unless `--skip-sample-controller`)
- Seeds a default KB via `curator:seed_defaults` rake task (not inline in a
  migration)

Modifies:
- `config/routes.rb` — adds mount line

Does NOT:
- Configure auth (ships with a `NullAuthenticator` raising in non-test envs)
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

---

## Rake Tasks

```
curator:reembed KB=<slug>               # re-embed all chunks in a KB
                                        # (after embedding model change)
curator:reingest DOCUMENT=<id>          # re-run full pipeline on one doc
curator:evaluations:export KB=<slug> FORMAT=<csv|json>
curator:stats                           # print KB/doc/chunk/search counts
curator:ingest PATH=<dir> KB=<slug>     # CLI equivalent of Curator.ingest_directory
curator:vacuum KB=<slug>                # remove orphaned chunks/embeddings
curator:build_assets                    # (engine maintainers) rebuild curator.css
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

  # Auth hooks (separate for admin UI and API; option B from design)
  config.authenticate_admin_with do
    redirect_to main_app.login_path unless current_user&.admin?
  end
  config.authenticate_api_with do
    render json: { error: { code: "unauthorized" } }, status: 401 unless api_token_valid?
  end

  # Document handling
  config.max_document_size = 50.megabytes

  # Tracing / logging
  config.trace_level = :full     # :full | :summary | :off
  config.log_queries = true      # create curator_searches rows (can be false
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

Fail loud, not silent. Every failure creates a `curator_searches` row with
`status: :failed` and an `error_message`, so the admin UI surfaces what went
wrong.

| Failure mode | Behavior |
|---|---|
| Query embedding fails | Raise `Curator::EmbeddingError`; search row marked `:failed` |
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
  dispatching to configured blocks; `NullAuthenticator` for unconfigured envs)

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
- `Curator.search` returning `Curator::SearchResults`
- `curator:reembed` rake task

### M4 — Q&A
- Prompt assembler (`[N]` marker injection, strict-grounding fallback,
  `include_citations` toggle)
- `Curator.ask` with optional streaming block
- `Curator::Answer` value object wrapping `SearchResults`
- RubyLLM Chat + Message persistence per query
- `curator_searches` + `curator_search_steps` trace capture (respecting
  `config.trace_level`)
- Error hierarchy (`Curator::EmbeddingError`, `RetrievalError`, `LLMError`)

### M5 — Admin UI Core
- Pre-compiled Tailwind + daisyUI asset pipeline (engine ships `curator.css`)
- Layout, navigation, top-bar KB switcher
- Landing page (empty-state aware stub; rich dashboard deferred to M9)
- Knowledge Base CRUD + per-KB configuration form
- Document management (drag-drop upload, list with status, delete, re-ingest
  trigger)
- Chunk Inspector

### M6 — Interactive Features + Public API
- Streaming infrastructure (Turbo Streams in admin UI, `/api/stream` endpoint)
- Query Testing Console (live streaming answer + retrieved chunks side-by-side;
  tweak params and re-run)
- REST API controllers: `/api/query`, `/api/search`, `/api/stream`
- Envelope + error format implementation
- API auth hook integration

### M7 — Evaluations
- `Curator::Evaluation` model + admin UI controllers
- Thumbs UI + feedback form + ideal answer capture
- Failure categories dropdown with tooltips
- `Curator::Evaluations::Exporter` service (CSV via streaming, JSON)
- Admin UI export button + `curator:evaluations:export` rake task
- `/api/evaluations` endpoint for end-user thumb submission from host-app
  frontends

### M8 — Persistent Chat
- `Curator::Chat` wrapper class
- Retrieval wired as a RubyLLM Tool
- Tool-call trace capture into `curator_search_steps`
- `curator:chat_ui` generator (unscoped) — both single-KB pin (`--kb=slug`) and
  multi-KB selector modes

### M9 — Polish & Release
- Scoped `curator:chat_ui` generator (`curator_scope` partitioning on chats)
- Rich dashboard (tiles, needs-attention panel, activity feed, per-KB nav
  cards)
- Remaining rake tasks (`curator:stats`, `curator:vacuum`,
  `curator:build_assets`)
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

---

## Decisions Considered and Rejected

Captured here so future contributors understand the "why not" behind current
shape.

- **Message-linked via RubyLLM schema mod** — rejected; Curator owns the link
  on its side (`curator_searches.message_id`) so RubyLLM's tables stay pristine.
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
