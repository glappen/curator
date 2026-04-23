# Contributing

curator-rails is pre-alpha. Design docs (`features/initial.md`,
`features/implementation.md`) are the source of truth; please read the
relevant milestone doc under `features/` before proposing changes.

## Development setup

Requires Ruby 3.1+, Postgres 14+, and the [pgvector](https://github.com/pgvector/pgvector)
extension installed on your Postgres instance.

```bash
bundle install
bin/reset-dummy    # create + migrate the spec/dummy host app
bundle exec rspec  # should print "129 examples, 0 failures"
```

Postgres credentials are read from the env (`CURATOR_PG_HOST`,
`CURATOR_PG_USER`, `CURATOR_PG_PASSWORD`). Defaults assume local Postgres
with a `postgres` superuser and no password.

## Verification — required on every PR

```bash
bundle exec rspec --format progress
bundle exec rubocop
```

Both must be green. Don't mark work complete otherwise — fix the underlying
issue rather than suppressing warnings or skipping tests.

## The dummy host app

`spec/dummy` is a living host-app fixture. Its generated files — migrations,
`schema.rb`, ruby_llm models, curator + ruby_llm initializers — are
**gitignored pre-v1** because the install generator templates are still
evolving and committing the output produces noisy diffs on every edit.

Source of truth for schema lives in
`lib/generators/curator/install/templates/*.rb.tt`. `bin/reset-dummy`
regenerates the dummy from those templates — run it on first clone, and
again any time you edit a template.

```bash
bin/reset-dummy
```

Wipes dummy DBs, reruns `active_storage:install` + `curator:install`,
migrates, preps the test DB. Idempotent and safe to run repeatedly.

**Post-v1**, shipped migrations become immutable (standard Rails rule).
Schema changes after v1 ship as *additional* migration templates, not
edits to existing ones — and at that point the dummy output will start
being committed again for review value.

## Code style

Rails Omakase RuboCop. Factories under `spec/factories/`, model specs under
`spec/models/curator/`, controller specs under `spec/controllers/curator/`.
Flat `Curator::*` namespace — no nested `Curator::Rails` module.

## Questions

Open an issue on GitHub. For broader context, `CLAUDE.md` in the repo root
has architectural conventions and key design decisions.
