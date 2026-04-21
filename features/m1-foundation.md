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

- [-] Phase 2 — Install generator
   - `Rails::Generators::Base` subclass at
     `lib/generators/curator/install/install_generator.rb`.
   - Class options:
     - `--embedding-dim` (integer, default 1536)
     - `--mount-at` (string, default `/curator`)
   - Steps in `#install` (Thor-style sequence):
     1. Verify Active Storage installed. Check via
        `defined?(ActiveStorage::Blob) && ActiveStorage::Blob.table_exists?`.
        If missing, `say_status :abort, "Active Storage required...", :red`
        and `exit 1`.
     2. `invoke "ruby_llm:install"` to chain RubyLLM's generator.
     3. Copy each migration template with
        `migration_template "templates/<name>.rb.tt", "db/migrate/<name>.rb"`
        so Rails assigns monotonic timestamps.
     4. `template "templates/curator.rb.tt", "config/initializers/curator.rb"`.
     5. `route "mount Curator::Engine, at: \"#{mount_at}\""`.
     6. `say_status :info, "Next: rails db:migrate && rails curator:seed_defaults"`.
   - Initializer template is exhaustive — one commented example per config
     field, grouped into "LLM + embedding", "Auth", "Ingestion",
     "Tracing/logging", "Reliability" sections.
   - **Validate**: Phase 2 checklist below.

## Next Steps

- [ ] Phase 3 — Auth plumbing
   - `Curator::NullAuthenticator` — single `.call(controller, hook_name)`
     entry point. In `Rails.env.test?`, return silently. Otherwise raise
     `Curator::AuthNotConfigured` with a message:
     `"Curator requires authenticate_#{hook_name}_with to be configured in config/initializers/curator.rb before first use."`
   - `Curator::ApplicationController` (inherits `ActionController::Base`):
     - `before_action :authenticate_curator_admin!`
     - `authenticate_curator_admin!` runs the configured
       `Curator.config.authenticate_admin_with` block via `instance_exec`,
       or falls through to `NullAuthenticator`.
   - `Curator::Api::BaseController` (inherits `ActionController::API`):
     - `before_action :authenticate_curator_api!`
     - Same pattern against `authenticate_api_with`.
   - **Validate**: Phase 3 checklist below.

- [ ] Phase 4 — Concrete model classes
   - `Curator::KnowledgeBase`
     - `has_many :documents, dependent: :destroy`
     - `has_many :searches, dependent: :destroy`
     - `validates :name, presence: true`
     - `validates :slug, presence: true, uniqueness: true, format: /\A[a-z0-9_-]+\z/`
     - `validates :chunk_size, numericality: { greater_than: 0 }`
     - `validates :is_default, uniqueness: true, if: :is_default?`
     - `before_save :unset_prior_default` when becoming default
   - `Curator::Document`
     - `belongs_to :knowledge_base`
     - `has_many :chunks, dependent: :destroy`
     - `has_one_attached :file`
     - `enum status: %i[pending extracting embedding complete failed]`
     - `validates :title, :content_hash, :mime_type, presence: true`
   - `Curator::Chunk`
     - `belongs_to :document`
     - `has_one :embedding, dependent: :destroy`
     - `enum status: %i[pending embedded failed]`
   - `Curator::Embedding`
     - `belongs_to :chunk`
     - neighbor setup: `has_neighbors :embedding`
   - `Curator::Search`
     - `belongs_to :knowledge_base`
     - `belongs_to :chat, class_name: "Chat", optional: true`
     - `belongs_to :message, class_name: "Message", optional: true`
     - `has_many :search_steps, dependent: :destroy`
     - `has_many :evaluations, dependent: :destroy`
     - `enum status: %i[success failed]`
   - `Curator::SearchStep`
     - `belongs_to :search`
   - `Curator::Evaluation`
     - `belongs_to :search`
     - `enum rating: %i[positive negative]`
     - `validate :failure_categories_are_known` —
       `FAILURE_CATEGORIES = %w[hallucination wrong_retrieval incomplete wrong_citation refused_incorrectly off_topic other]`
   - FactoryBot factories for all models.
   - **Validate**: Phase 4 checklist below.

- [ ] Phase 5 — Seed task
   - Add `curator:seed_defaults` to `lib/tasks/curator.rake`.
   - Behavior: if no KB has `is_default: true`, create one with
     `name: "Default"`, `slug: "default"`, `is_default: true`,
     `embedding_model: "text-embedding-3-small"`, `chat_model: "gpt-5-mini"`,
     and the default chunk/retrieval settings from the spec.
   - **Validate**: Phase 5 checklist below.

- [ ] Phase 6 — End-to-end smoke
   - System-level spec that, against a clean `spec/dummy` test DB, runs the
     generator, migrates, seeds, boots the engine, and hits
     `GET /curator` to confirm the mount responds (not a 500; 401 from the
     admin auth hook is acceptable when configured, or controller-specific
     response in test env via NullAuthenticator).
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
- [ ] `Rails.env = "test"` + no block: `NullAuthenticator.call(controller, :admin)` returns
      silently; request passes through
- [ ] `Rails.env = "development"` + no block: raises
      `Curator::AuthNotConfigured` with a pointer to the initializer
- [ ] Configured block is `instance_exec`d in controller context — block
      can call `current_user`, `redirect_to`, `main_app` helpers
- [ ] Symmetric behavior verified for `authenticate_api_with`

### Phase 4 — Models
- [ ] `kb1.update!(is_default: true); kb2.update!(is_default: true)` results
      in `kb1.reload.is_default == false`, `kb2.is_default == true`
- [ ] Creating two KBs with identical slug raises `ActiveRecord::RecordInvalid`
- [ ] Evaluation with `failure_categories: ["bogus"]` fails validation
- [ ] Deleting a KB cascades to documents, chunks, embeddings, searches,
      search_steps, evaluations (zero orphans)

### Phase 5 — Seed
- [ ] Fresh DB: `bundle exec rake curator:seed_defaults` creates exactly
      one KB with `is_default: true`, `slug: "default"`
- [ ] Running the task a second time results in no change and no error

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
| 4 | `NullAuthenticator` behavior? | **Lenient only in `Rails.env.test?`**. Dev + prod raise `Curator::AuthNotConfigured` with a pointer to the initializer. Symmetric for `authenticate_api_with`. |

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
