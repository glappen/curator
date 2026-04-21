# Curator (curator-rails)

Rails engine that adds production-ready RAG to any Rails 7+ app: knowledge
bases, semantic search, Q&A over documents, a Hotwire admin UI, and a JSON
API. Built on RubyLLM + pgvector.

**Full design**: `specs/implementation.md` is the source of truth for schema,
service objects, API shapes, generators, milestones, and v2 deferrals.
`specs/initial.md` captures product vision.

---

## Conventions

- **Namespace**: flat `Curator::*`. Gem name is `curator-rails` but modules are
  `Curator::KnowledgeBase`, `Curator.ingest`, etc. — no nested `Rails` module.
- **Tests**: RSpec under `spec/`. No Minitest. Host app for integration specs
  lives at `spec/dummy` (Postgres + pgvector).
- **Style**: Rails Omakase RuboCop. Run `bundle exec rubocop` after changes.
- **Table prefix**: All Curator-owned tables are prefixed `curator_`. RubyLLM
  owns `chats`, `messages`, `tool_calls`, `models` — do not modify beyond the
  one additive `curator_scope` column on `chats`.
- **File layout** (abridged — full tree in `specs/implementation.md`):
  ```
  lib/curator/            # top-level code
    extractors/           # pluggable Kreuzberg + basic
    chunkers/
    retrieval/            # vector, keyword, hybrid, rrf
    prompt/               # assembler + templates
    evaluations/          # exporter
  app/controllers/curator/
  app/controllers/curator/api/
  app/models/curator/
  app/jobs/curator/       # ingest + embed jobs
  app/views/curator/
  ```
- **Value objects**: `Curator::Answer`, `Curator::SearchResults`,
  `Curator::Chat`, `Curator::Extractors::ExtractionResult`. These are the
  stable public-facing return types.
- **Errors**: `Curator::EmbeddingError`, `Curator::RetrievalError`,
  `Curator::LLMError` all inherit from a base `Curator::Error`. Fail loud;
  every failure creates a `curator_searches` row with `status: :failed`.

## Key design decisions (so you don't relitigate them)

- **Hard delete with cascade** (KB → documents → chunks → embeddings →
  searches → evaluations). No soft delete.
- **Single fixed-dim embedding column** (dimension chosen at install time via
  `--embedding-dim`, default 1536). Switching models = migration + re-embed.
- **Heuristic token counter** (char-based, no native deps). Behind
  `Curator::TokenCounter.count(text)` so it's swappable.
- **Citation rank `hit.rank` == marker `[N]`** in the prompt. No separate
  marker concept.
- **Binary rating** on evaluations (`:positive | :negative`). Multi-select
  failure categories (Postgres `text[]`) for negative evals.
- **Hybrid retrieval is default** (vector + keyword via
  `Neighbor::Reranking.rrf`). Per-KB toggle to vector-only or keyword-only.
- **Snapshot config on every search** (model, prompt, threshold, chunk_limit
  captured on `curator_searches` at query time). Do not lose this — v2
  analytics depend on it.
- **Scoped chat UIs** share RubyLLM models but partition via `curator_scope`
  string on `chats`.

## Testing notes

- Real Postgres with pgvector for retrieval specs — do **not** mock vector
  search. Stub LLM HTTP with WebMock.
- Factories under `spec/factories/`. Fixtures under `spec/fixtures/`.
- Both extractor adapters (Kreuzberg + basic) must pass the same adapter
  contract suite.

## Development flow

- After code changes, run `bundle exec rspec` and `bundle exec rubocop`.
- If touching migrations, update `spec/dummy/db/schema.rb` via
  `cd spec/dummy && bin/rails db:prepare`.
- Specs docs in `specs/` are living documents — update them when decisions
  change, don't just add new files.

## Out of scope for v1

See the "Deferred to v2+" section in `specs/implementation.md`. Key items:
tool-based retrieval for one-shot queries, reranking, multi-tenancy,
multimodal image/audio embedding, structured table extraction, analytics
dashboard, LLM-as-judge, A/B comparison view.
