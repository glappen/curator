# Curator (curator-rails)

Rails engine that adds production-ready RAG to any Rails 7+ app: knowledge
bases, semantic search, Q&A over documents, a Hotwire admin UI, and a JSON
API. Built on RubyLLM + pgvector.

**Full design**: `features/implementation.md` is the source of truth for
schema, service objects, API shapes, generators, milestones, and v2
deferrals. `features/initial.md` captures product vision.

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
- **File layout** (abridged — full tree in `features/implementation.md`):
  ```
  lib/curator/            # top-level code
    extractors/           # pluggable Kreuzberg + basic
    chunkers/
    retrievers/           # vector, keyword, hybrid, rrf
    prompt/               # assembler + templates
    evaluations/          # exporter
  app/controllers/curator/
  app/controllers/curator/api/
  app/models/curator/
  app/jobs/curator/       # ingest + embed jobs
  app/views/curator/
  ```
- **Value objects**: `Curator::Answer`, `Curator::RetrievalResults`,
  `Curator::Chat`, `Curator::Extractors::ExtractionResult`. These are the
  stable public-facing return types.
- **Errors**: `Curator::EmbeddingError`, `Curator::RetrievalError`,
  `Curator::LLMError` all inherit from a base `Curator::Error`. Fail loud;
  every failure creates a `curator_retrievals` row with `status: :failed`.

## Key design decisions (so you don't relitigate them)

- **Hard delete with cascade** (KB → documents → chunks → embeddings →
  retrievals → evaluations). No soft delete.
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
- **Snapshot config on every retrieval** (model, prompt, threshold, chunk_limit
  captured on `curator_retrievals` at query time). Do not lose this — v2
  analytics depend on it.
- **Scoped chat UIs** share RubyLLM models but partition via `curator_scope`
  string on `chats`.
- **Process-global inflection rule** registered at engine boot
  (`lib/curator/engine.rb`): `irregular("knowledge_base", "knowledge_bases")`.
  Without it, Rails' default inflector singularizes `bases → basis` and the
  resource's URL helpers become `knowledge_basis_path`. The rule only affects
  those two exact strings, so practical blast radius on host apps is nil — but
  it does mutate global `ActiveSupport::Inflector` state, so don't be surprised
  if you see it show up in an inflector dump.

## Testing notes

- Real Postgres with pgvector for retrieval specs — do **not** mock vector
  retrieval. Stub LLM HTTP with WebMock.
- Factories under `spec/factories/`. Fixtures under `spec/fixtures/`.
- Both extractor adapters (Kreuzberg + basic) must pass the same adapter
  contract suite.
- **Turbo broadcasts are suppressed by default** (see
  `spec/support/turbo_helpers.rb`). Tag an example or describe block
  `:broadcasts` to opt back in when asserting `have_broadcasted_to`.

## Verification — required after every change

Run both, in order. Do not mark work complete until both pass.

1. `bundle exec rspec --format progress` — progress formatter (single
   character per example) keeps output short enough to scan in one tool
   result. Use `--format documentation` only when focusing on a single
   spec file during debugging.
2. `bundle exec rubocop` — must end with "no offenses detected".

If specs fail or rubocop reports offenses, fix the underlying issue — do
not suppress warnings or skip tests.

## Migration templates and the dummy app

Source of truth for schema is `lib/generators/curator/install/templates/*.rb.tt`.
The generated dummy output — `spec/dummy/db/**`, ruby_llm model files,
curator + ruby_llm initializers — is **gitignored pre-v1**. Contributors
regenerate the dummy locally via `bin/reset-dummy` (required on first
clone before `rspec` can run, and again after editing any template).

**If you edit a migration template**, re-running `rails g curator:install`
against the already-installed dummy is a no-op — `migration_template`
dedupes by class name. `bin/reset-dummy` handles the wipe + regenerate.

**Post-v1** this shortcut stops working for host apps: once the gem ships,
a migration in a user's `db/migrate/` is frozen (standard Rails
immutability). Schema changes after v1 must ship as *additional* migration
templates (`add_foo_to_curator_...rb.tt`), not edits to existing ones.
At that point we'll also start committing the dummy output — templates
will have stabilized, diff churn goes away, and having a golden
"freshly installed host app" in-repo has real review value.

## Manually exercising the dummy host app

`bin/rails s` (from `spec/dummy`) boots the dummy with the engine
mounted at `/curator`. `spec/dummy/config/initializers/curator_dev.rb`
ships a development-only override that wires `authenticate_admin_with`
+ `authenticate_api_with` to a permissive block and switches the
extractor to `:basic`, so `/curator/*` is reachable without
configuring real auth and `.md`/`.txt`/`.csv`/`.html` ingest works
out of the box. The override is `Rails.env.development?`-guarded —
test env is unaffected.

`curator_dev.rb` is hand-written and committed; it survives
`bin/reset-dummy` because reset-dummy only deletes the
generator-owned files (`curator.rb`, `ruby_llm.rb`).

## Other development notes

- Design docs in `features/` are living documents — update them when
  decisions change, don't just add new files.

## Out of scope for v1

See the "Deferred to v2+" section in `features/implementation.md`. Key items:
tool-based retrieval for one-shot queries, reranking, multi-tenancy,
multimodal image/audio embedding, structured table extraction, analytics
dashboard, LLM-as-judge, A/B comparison view.
