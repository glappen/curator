# M1 — Foundation

Shippable foundation for curator-rails: a developer installs the gem, runs
`rails g curator:install`, runs migrations + `curator:seed_defaults`, and
ends up with a booted engine mounted in their host app. No real features
(no ingestion, retrieval, Q&A) — just the skeleton, schema, models,
configuration, and auth plumbing that every later milestone builds on.

**Reference**: `features/implementation.md` → "Implementation Milestones" → M1.

## Completed

- [x] Scaffold cleanup: flat `Curator` namespace (not `Curator::Rails`),
      RSpec setup, Postgres `spec/dummy` host app, populated gemspec,
      CLAUDE.md, rewritten README, `.rspec`, `spec/spec_helper.rb`,
      `spec/rails_helper.rb` (commit `0a531a2`).
- [x] Phase 0 — error hierarchy + `Curator::Configuration` + `Curator.configure`
      entry points. 22 specs green, rubocop clean.
- [x] Phase 1 — `Curator::ApplicationRecord` abstract base + 9 migration
      templates under `lib/generators/curator/install/templates/`. Template
      rendering spec (43 examples) asserts each template produces valid Ruby
      with required schema fragments. Actual `db:migrate` against `spec/dummy`
      deferred until the install generator lands in Phase 2.
- [x] Phase 2 — `Curator::Generators::InstallGenerator` at
      `lib/generators/curator/install/install_generator.rb`. Class options
      `--embedding-dim` (default 1536) and `--mount-at` (default `/curator`).
      Steps: verify Active Storage, chain `ruby_llm:install`
      (passing `skip_active_storage: true`), copy the 9 migration templates
      via `migration_template`, render an exhaustive section-grouped
      `config/initializers/curator.rb`, append `mount Curator::Engine` to
      host routes, print next-step instructions. `install_generator_spec`
      covers embedding-dim substitution, mount path, idempotency on re-run,
      Active Storage abort, RubyLLM migration appearance, and the full
      9-migration set with monotonic timestamps. 83 specs green, rubocop
      clean.
- [x] Phase 3 — Auth plumbing. A shared `Curator::Authentication` concern
      exposes `curator_authenticate :admin|:api`, which installs a
      `before_action` that looks up `Curator.config.authenticate_<hook>_with`
      and runs it via `instance_exec`. Unconfigured: silent in
      `Rails.env.test?`, raises `Curator::AuthNotConfigured` pointing at
      the initializer in dev/prod. Exceptions from the host's block
      propagate. `Curator::ApplicationController` (ActionController::Base)
      and `Curator::Api::BaseController` (ActionController::API) each
      include the concern and declare their hook.
      `post_install_message` added to the gemspec telling the installer to
      configure both hooks. Also fixed a load-order bug:
      `lib/curator-rails.rb` now requires `curator/engine` after
      `require "curator"`, so the engine registers even when curator.rb has
      been preloaded by a test helper. 94 specs green, rubocop clean.
- [x] Phase 4 — Concrete model classes. Eight AR models under
      `app/models/curator/`: `KnowledgeBase`, `Document`, `Chunk`,
      `Embedding`, `Search`, `SearchStep`, `Evaluation` (plus the existing
      `ApplicationRecord` base). `KnowledgeBase` enforces single-default
      via a `before_save` callback (no uniqueness validator — the partial
      DB index is the hard backstop, and a validator would conflict with
      the callback's swap semantics). `Embedding` uses `has_neighbors
      :embedding` via the neighbor gem. `Evaluation` exposes
      `FAILURE_CATEGORIES` and `FAILURE_CATEGORY_TOOLTIPS` constants and
      validates `failure_categories` is a subset of the taxonomy.
      `Search.chat` / `Search.message` are `optional: true` belongs_to
      into RubyLLM-owned `Chat` / `Message`. FactoryBot factories for all
      seven models under `spec/factories/`. 128 specs green, rubocop clean.
- [x] Phase 5 — Seed task. `curator:seed_defaults` rake task in
      `lib/tasks/curator.rake` delegates to `Curator::KnowledgeBase.seed_default!`,
      which returns the existing default KB if one exists or creates
      `Default` (`slug: "default"`, `is_default: true`,
      `text-embedding-3-small` / `gpt-5-mini`; chunk/retrieval columns
      inherit their DB defaults). Idempotent: a second invocation is a
      no-op. Covered by model specs on `.seed_default!` and a rake-level
      integration spec under `spec/tasks/`. 134 specs green.

      Also fixed a second RubyLLM load-order bug: `require "ruby_llm"`
      moved from `lib/curator.rb` to `lib/curator-rails.rb`. In the spec
      flow, `spec_helper` preloads `curator` before Rails boots; requiring
      `ruby_llm` at that point hits the `if defined?(Rails::Railtie)` guard
      in `ruby_llm/railtie.rb` before Rails is loaded, so the Railtie class
      is never defined and the `on_load(:active_record)` callback that
      installs `acts_as_chat` never registers. Moving the require into
      `curator-rails.rb` defers it until Bundler.require loads the gem
      (which happens after Rails is up).

      Generated `spec/dummy/db/schema.rb` and `spec/dummy/db/migrate/**`
      are now excluded from rubocop — regenerated on every `db:migrate`
      and offenses are outside our control.

      Also added `FactoryBot.definition_file_paths` to `rails_helper.rb`
      pointing at the engine's `spec/factories` (factory_bot_rails only
      auto-discovers factories relative to the host app).

**Phase reorder note**: originally sequenced 0→1→models→seed→auth→generator→e2e.
Reordered to 0→1→generator→auth→models→seed→e2e so the install generator
(which has no model deps) can land early, unblocking host-app install
testing and giving Phase 4's model specs a real DB schema to run against.

## Files Under Development

```
lib/
├── curator.rb                              # existing — augment with eager requires
├── curator/
│   ├── configuration.rb                    # NEW
│   ├── errors.rb                           # NEW
│   ├── null_authenticator.rb               # NEW
│   ├── version.rb                          # existing
│   └── engine.rb                           # existing
├── generators/
│   └── curator/
│       └── install/
│           ├── install_generator.rb        # NEW
│           └── templates/
│               ├── curator.rb.tt           # initializer template
│               ├── enable_vector.rb.tt
│               ├── create_curator_knowledge_bases.rb.tt
│               ├── create_curator_documents.rb.tt
│               ├── create_curator_chunks.rb.tt
│               ├── create_curator_embeddings.rb.tt
│               ├── create_curator_searches.rb.tt
│               ├── create_curator_search_steps.rb.tt
│               ├── create_curator_evaluations.rb.tt
│               └── add_curator_scope_to_chats.rb.tt
└── tasks/
    └── curator.rake                        # existing placeholder — add seed task
app/
├── controllers/curator/
│   ├── application_controller.rb           # NEW — admin base
│   └── api/
│       └── base_controller.rb              # NEW — API base
└── models/curator/
    ├── application_record.rb               # NEW — abstract base
    ├── knowledge_base.rb                   # NEW
    ├── document.rb                         # NEW
    ├── chunk.rb                            # NEW
    ├── embedding.rb                        # NEW
    ├── search.rb                           # NEW
    ├── search_step.rb                      # NEW
    └── evaluation.rb                       # NEW
spec/
├── curator/
│   ├── configuration_spec.rb               # NEW
│   ├── null_authenticator_spec.rb          # NEW
│   └── models/*_spec.rb                    # NEW — per model
├── controllers/curator/                    # NEW — auth plumbing specs
├── generators/curator/
│   └── install_generator_spec.rb           # NEW
├── tasks/
│   └── seed_defaults_spec.rb               # NEW
├── factories/                              # NEW
│   └── *.rb
└── system/
    └── install_end_to_end_spec.rb          # NEW
```

## Current Work

- [-] Phase 6 — End-to-end smoke
   - System-level spec that, against a clean `spec/dummy` test DB, runs the
     generator, migrates, seeds, boots the engine, and hits
     `GET /curator` to confirm the mount responds (not a 500; 401 from the
     admin auth hook is acceptable when configured, or controller-specific
     response in test env where the auth hook no-ops).
   - **Validate**: Phase 6 checklist below.

## Validation Strategy

### Phase 0 — Configuration + errors
- [ ] `Curator.configure { |c| c.max_document_size = 10.megabytes }` updates
      the config; `Curator.config.max_document_size == 10.megabytes`
- [ ] All defaults from spec match on a fresh `Curator.config` read
- [ ] `Curator::Error` subclasses are distinct constants and inherit
      `StandardError`

### Phase 1 — Migrations
- [ ] `bin/rails db:migrate RAILS_ENV=test` in `spec/dummy` succeeds on
      an empty DB
- [ ] `pg_indexes` query confirms GIN index on `curator_chunks.content_tsvector`
- [ ] `pg_indexes` confirms partial unique on
      `curator_knowledge_bases(is_default) where is_default = true`
- [ ] `pg_indexes` confirms GIN on `curator_evaluations.failure_categories`
- [ ] `curator_embeddings.embedding` column type is `vector(1536)` by default
- [ ] `chats.curator_scope` column exists and is nullable

### Phase 2 — Install generator
- [ ] `rails g curator:install --embedding-dim=3072` writes a migration
      containing `vector(3072)`
- [ ] `rails g curator:install --mount-at=/kb` writes
      `mount Curator::Engine, at: "/kb"` in host routes
- [ ] Running the generator twice doesn't duplicate migration files
      (existing timestamped migrations detected)
- [ ] No Active Storage: generator prints `:abort` status and exits non-zero
- [ ] Generator invokes `ruby_llm:install` — RubyLLM migrations appear

### Phase 3 — Auth plumbing
- [x] `Rails.env = "test"` + no block: request passes through silently
- [x] `Rails.env = "development"` + no block: raises
      `Curator::AuthNotConfigured` with a pointer to the initializer
- [x] Configured block is `instance_exec`d in controller context — block
      can call `current_user`, `redirect_to`, `main_app` helpers
- [x] Symmetric behavior verified for `authenticate_api_with`
- [x] Exceptions raised in the host's block propagate

### Phase 4 — Models
- [x] `kb1.update!(is_default: true); kb2.update!(is_default: true)` results
      in `kb1.reload.is_default == false`, `kb2.is_default == true`
- [x] Creating two KBs with identical slug raises `ActiveRecord::RecordInvalid`
- [x] Evaluation with `failure_categories: ["bogus"]` fails validation
- [x] Deleting a KB cascades to documents, chunks, embeddings, searches,
      search_steps, evaluations (zero orphans)

### Phase 5 — Seed
- [x] Fresh DB: `bundle exec rake curator:seed_defaults` creates exactly
      one KB with `is_default: true`, `slug: "default"`
- [x] Running the task a second time results in no change and no error

### Phase 6 — End-to-end
- [ ] Fresh DB + install + migrate + seed + GET `/curator` returns non-500
- [ ] `bundle exec rspec` exits 0
- [ ] `bundle exec rubocop` exits 0
- [ ] Rerun of generator + migrate is a no-op (no duplicate migrations, no
      errors)

## Implementation Notes

**Generated tsvector column**: Rails 7.1+ has `t.virtual ..., stored: true` for
generated columns, but only for simple expressions. For `to_tsvector('english'::regconfig, content)` we may need a raw
`execute` in the migration. Document whichever path works.

**HNSW index**: Rails doesn't have native DSL for HNSW. Migrations use
`execute "CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)"`.

**neighbor gem**: `has_neighbors :embedding` on `Curator::Embedding` model is
declared in Phase 2. Actual similarity search calls are deferred to M3.

**Generator idempotency**: Rails' `migration_template` detects existing
migrations by class name and skips duplicates. Good default; no manual
handling needed.

## Ideation Notes

Captured from `/ideate` session on 2026-04-21.

| # | Question | Conclusion |
|---|---|---|
| 1 | Ship sample controller from install generator in M1? | **No** — `spec/dummy/app/controllers/knowledge_controller.rb` becomes a living, integration-tested example that evolves per milestone (M3 adds `#search`, M4 adds `#ask` + streaming, M8 adds chat). Install generator never writes a sample controller. |
| 2 | Install generator auto-runs the seed task? | **No**. Generator writes files only; prints next-step instructions. Standard Rails generator hygiene — generators shouldn't do DB ops that can fail for unrelated reasons. |
| 3 | Enforce one default KB? | **Partial unique index (DB) + model validation (readable errors) + `before_save` auto-flip callback** so flipping the default is a single save. Belt-and-suspenders. |
| 4 | Unconfigured-auth behavior? | **Lenient only in `Rails.env.test?`**. Dev + prod raise `Curator::AuthNotConfigured` with a pointer to the initializer. Symmetric for `authenticate_api_with`. Inlined into the `Curator::Authentication` concern — no separate `NullAuthenticator` module (three-line logic with one call site). |

Inline decisions (made without asking):

- **Config initializer template**: exhaustive and section-grouped so a first-install
  dev sees every knob with its default and a short comment.
- **RubyLLM generator chaining**: `invoke "ruby_llm:install"` (standard Rails
  generator chaining).
- **Active Storage check**: `defined?(ActiveStorage::Blob) && ActiveStorage::Blob.table_exists?`;
  warn + exit non-zero if missing.
- **`failure_categories` default**: Rails DSL `default: []` (translates to
  Postgres `'{}'` for `text[]`, not `'[]'` which would be jsonb syntax).
- **`tsvector_config` handling**: v1 uses a hardcoded `english` config at the
  generated column level; per-KB `tsvector_config` is applied at query time.
  Revisit in M3 if per-KB GIN indexes prove necessary for performance.
