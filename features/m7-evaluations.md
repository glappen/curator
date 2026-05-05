# M7 — Evaluations

SME annotation surfaces, an end-user feedback path, list/filter UIs for past
queries and evaluations, and CSV/JSON exports. Closes the implementation.md
M7 bullet plus a few amendments captured in Phase 0.

The `Curator::Evaluation` model + migration template + failure-category
constants/tooltips + retrieval `has_many :evaluations` association already
exist (shipped with M1 + M3). M7 is everything *around* that schema:
write path, three admin surfaces, two exporters.

**Reference**: `features/implementation.md` → "Implementation Milestones" →
M7, plus the "Evaluation System" section. M7 follows the M5/M6 pattern of
amending implementation.md as a living document — Phase 0 ships those
edits.

## Completed

- **Phase 0 — Spec amendment + `origin` column.** ✓
  - `features/implementation.md` amended: `origin` column documented in
    `curator_retrievals` schema; Evaluation System section gained "Write
    path — `Curator.evaluate`" + "Admin surfaces" subsections; two
    evaluator hooks added to Configuration; Admin UI Response Evaluation
    expanded; `curator:retrievals:export` added to Rake Tasks; deferred
    `curator:feedback_widget` noted under Generators; `Curator.evaluate`
    example added to Service Object API.
  - `lib/generators/curator/install/templates/create_curator_retrievals.rb.tt`
    — added `origin` (null: false, default: "adhoc") column + index.
  - `app/models/curator/retrieval.rb` — `ORIGINS` constant + `enum :origin`.
  - `bin/reset-dummy` regenerated dummy schema cleanly.
  - Validate: 607 examples, 0 failures; rubocop no offenses.

- **Phase 1 — `Curator.evaluate` + identity hooks + admin endpoint.** ✓
  - `lib/curator/evaluator.rb` — `Curator::Evaluator.call(...)` with
    `EVALUATOR_ROLES = %i[reviewer end_user]`. Validates rating +
    evaluator_role (raises `ArgumentError`); accepts retrieval as
    instance or id; `evaluation_id:` triggers in-place update.
  - `lib/curator.rb` — `Curator.evaluate(...)` delegator.
  - `lib/curator/configuration.rb` — `current_admin_evaluator` and
    `current_end_user_evaluator` attrs, both default to
    `NULL_EVALUATOR = ->(_controller) { nil }`.
  - `app/models/curator/evaluation.rb` — pushed
    `failure_categories_only_on_negative` validation down into the
    model (per cross-phase regression note in this file).
  - `app/controllers/curator/application_controller.rb` —
    `current_admin_evaluator_id` helper method (also exposed via
    `helper_method`) calling the configured proc with `self`.
  - `app/controllers/curator/evaluations_controller.rb` — POST
    creates; the same action updates in place when an
    `evaluation_id` param is present. Returns
    `{ id:, rating: }` JSON. Drops blank entries from
    `failure_categories` array (Rails form quirk).
  - `config/routes.rb` — `resources :evaluations, only: %i[create]`.
  - `lib/generators/curator/install/templates/curator.rb.tt` —
    documented both hooks with commented-out examples.
  - Validate: 625 examples, 0 failures; rubocop no offenses.

## Current Work

_(empty — Phase 1 done; Phase 2 next)_

## Next Steps

- [x] **Phase 0 — Spec amendment + `origin` column.** Edit
   `features/implementation.md` (living-document update, per project
   convention):
   - "Evaluation System" section: add subsection describing the three
     admin surfaces (Console inline, Retrievals tab, Evaluations tab) and
     the `Curator.evaluate` service-object write path (with symmetric
     `current_admin_evaluator` / `current_end_user_evaluator` hooks).
   - "Configuration" section: add the two new evaluator hooks to the
     reference list.
   - "Database Schema → `curator_retrievals`": add `origin` column
     (string, default `"adhoc"`, indexed) — enum `:adhoc | :console |
     :console_review`. Note default UI filters hide `:console_review`.
   - "Rake Tasks": add `curator:retrievals:export` row alongside the
     existing `curator:evaluations:export` row.
   - "Admin UI → Surfaces": expand "Response Evaluation" entry to list
     the two new tabs + Console inline rating.
   - "Generators": add deferred-to-v2+ note for `curator:feedback_widget`
     (the end-user thumbs widget generator).
   - "Service Object API": add `Curator.evaluate(...)` example.
   Edit `lib/generators/curator/install/templates/create_curator_retrievals.rb.tt`
   to add the `origin` column with default `"adhoc"` and an index.
   `bin/reset-dummy` to regenerate `spec/dummy/db/schema.rb`. Update
   `Curator::Retrieval` model to add the enum + a default scope or
   per-controller filter helper (decide during implementation; default
   scope is risky given the model is also used by Console job).
   Add `Curator::Retrieval::ORIGINS` constant.
   - **Validate**: `bundle exec rspec` 0 failures (no behavior change yet
     — the new column has a default so existing rows + factories work);
     `bundle exec rubocop` no offenses; `features/implementation.md` diff
     reads cleanly.

- [x] **Phase 1 — `Curator.evaluate` service object + identity hooks +
   admin annotate-form path.** Build the canonical write path that
   admin and host code both go through.
   - `lib/curator/evaluator.rb` — service object with single class
     method `Curator::Evaluator.call(retrieval:, rating:, evaluator_role:,
     evaluator_id: nil, feedback: nil, ideal_answer: nil,
     failure_categories: [])` returning the persisted `Curator::Evaluation`.
     Validates rating against `Curator::Evaluation::RATINGS`, normalizes
     `failure_categories` (array, stripped of unknowns or raises —
     decide; matches existing model validation), enforces
     `failure_categories` empty unless `rating: :negative`.
   - `Curator.evaluate(...)` — thin module-level delegator (matches
     `Curator.ingest`/`.ask` shape).
   - `lib/curator/configuration.rb` — add two new attrs:
     `current_admin_evaluator` and `current_end_user_evaluator`. Both
     default to `->(_controller) { nil }`.
   - Wire admin-side resolution in `Curator::ApplicationController`:
     helper method `current_admin_evaluator_id` calls the configured
     block with `self`. Documented in the install template's
     `curator.rb.tt` initializer with a commented-out example.
   - `Curator::EvaluationsController#create` — admin-side endpoint that
     calls `Curator.evaluate(...)` with `evaluator_role: :reviewer`,
     `evaluator_id: current_admin_evaluator_id`. Returns the persisted
     row's id (used by Console's Q3-D edit-in-place flow). PATCH variant
     for the same endpoint updates the row when a hidden `evaluation_id`
     param is present.
   - Specs:
     - `spec/curator/evaluator_spec.rb` — happy paths for `:positive`
       and `:negative`, validation failures (unknown rating, unknown
       failure category, categories on `:positive`), `evaluator_id` /
       `feedback` / `ideal_answer` round-trip.
     - `spec/requests/curator/evaluations_spec.rb` — POST creates +
       returns id; PATCH updates same row; auth gating via the existing
       admin auth hook; configured `current_admin_evaluator` returns id
       on persisted row.
   - **Validate**: `bundle exec rspec` 0 failures; `bundle exec rubocop`
     no offenses.

- [ ] **Phase 2 — Console inline thumbs flow.** Wire Q2-D + Q3-D + Q8-D
   into the existing Console.
   - `Curator::ConsoleStreamJob` — on the final `done` broadcast, also
     broadcast an `update` to a new `console-evaluation` div containing
     the thumbs widget (rendered via a new `_evaluation.html.erb`
     partial). Failed runs (`:failed` status) skip this step.
   - `app/views/curator/console/_evaluation.html.erb` — initial state:
     two thumb buttons (👍 / 👎) + retrieval id (hidden field) + topic
     (hidden field). No textarea, no checkboxes. Submits to
     `evaluations#create` via Turbo form.
   - `app/views/curator/evaluations/_form.html.erb` — rating-aware
     expansion. When `rating == "positive"`: feedback textarea only.
     When `rating == "negative"`: feedback + ideal_answer + failure
     categories multi-select with hover tooltips from
     `FAILURE_CATEGORY_TOOLTIPS`. Submit button. Hidden
     `evaluation_id` round-tripped from the create response → PATCH
     instead of POST.
   - Stimulus controller `console-evaluation-controller.js` — handles
     thumbs-click → POST → render returned `_form` partial in place
     (Turbo Stream response from the controller); subsequent edits
     PATCH the same id.
   - `Curator::EvaluationsController#create` returns
     `turbo_stream.update("console-evaluation", partial: "evaluations/form",
      locals: { evaluation: persisted, rating: persisted.rating })`.
   - Update `app/views/curator/console/show.html.erb` to add the
     `<div id="console-evaluation"></div>` slot.
   - Specs:
     - `spec/jobs/curator/console_stream_job_spec.rb` — extend existing
       `:broadcasts` spec to assert the evaluation-form broadcast lands
       on `done`, and is *absent* on `:failed`.
     - `spec/requests/curator/evaluations_spec.rb` — Console POST flow
       returns the partial via Turbo Stream; PATCH updates same row.
   - **Validate**: `bundle exec rspec` 0 failures; manual smoke in
     dummy app — run a query, click 👎, see categories appear, submit,
     click 👎 again on a different category set, see same row updated.

- [ ] **Phase 3 — Retrievals tab.** `[parallelizable with Phase 4]`
   Index + filters + detail view (the unified detail view shared with
   Phase 4).
   - `Curator::RetrievalsController` — `index` paginated list of
     `Curator::Retrieval` (default scope hides `origin: :console_review`
     unless filter set); filters: KB, date range (created_at), status,
     chat_model, embedding_model, rating (joined to evaluations),
     unrated-only toggle, free-text query (ILIKE on `query`),
     show-exploratory toggle. Filter state in URL querystring.
     `show` action renders the unified detail view.
   - `app/views/curator/retrievals/index.html.erb` — filter form (top)
     + paginated table (rows: created_at, KB, query truncated, status
     badge, eval count badge, origin tag if not `:adhoc`). Each row
     links to `show`.
   - `app/views/curator/retrievals/show.html.erb` — unified detail view
     (Q7-D): query (heading), persisted answer text (from
     `retrieval.message&.content`), ranked sources via the existing
     `_source` partial reused from Console, collapsible snapshot config
     section, "Re-run in Console" link
     (`console_path(knowledge_base_slug:, query:, chunk_limit:, ...)`
     with origin marker — see below), "Show trace" toggle revealing
     the `curator_retrieval_steps` timeline, evaluation form (renders
     `evaluations/form` partial in append mode — `evaluation_id` blank,
     rating defaults to `:negative` since explicit annotation is
     usually corrective, but operator can switch).
   - **Re-run-in-Console origin plumbing**: Console's `show` action
     accepts an optional `origin=console_review` querystring param and
     stashes it in a hidden form field; `ConsoleStreamJob` accepts
     `origin:` and passes through to `Curator::Asker`; `Asker` writes
     `origin` onto the persisted retrieval. Default origin for direct
     Console usage stays `:console`.
   - Add primary-nav link to "Retrievals" via `admin_helper`.
   - Specs:
     - `spec/requests/curator/retrievals_spec.rb` — index renders +
       filter querystring round-trips correctly + `:console_review`
       hidden by default + show renders + Re-run link includes
       `origin=console_review`.
     - Extend `spec/jobs/curator/console_stream_job_spec.rb` to assert
       `origin:` param is plumbed through onto the persisted row.
   - **Validate**: `bundle exec rspec` 0 failures; manual smoke —
     filter by KB + date range, click into a retrieval, hit Re-run in
     Console, confirm the resulting retrieval has
     `origin: "console_review"` and is hidden from the default
     Retrievals index.

- [ ] **Phase 4 — Evaluations tab.** `[parallelizable with Phase 3 after
   the unified detail view stabilizes]` Index + filters; detail click
   reuses the Phase 3 `retrievals#show` view.
   - `Curator::EvaluationsController#index` — paginated list of
     `Curator::Evaluation` joined to `Curator::Retrieval`. Filters: KB
     (joined), date range (eval `created_at`), rating, evaluator_role,
     failure_categories (multi-select; matches "any of" semantics —
     `failure_categories && ARRAY[...]::text[]`), evaluator_id (text
     match), chat_model (joined), embedding_model (joined). Filter
     state in URL querystring.
   - `app/views/curator/evaluations/index.html.erb` — filter form +
     paginated table (rows: created_at, retrieval query truncated, KB,
     rating badge, failure_categories chips if `:negative`,
     evaluator_role tag, evaluator_id if present). Each row links to
     `retrievals#show?evaluation_id=...` so the detail view scrolls/
     anchors to the specific eval.
   - Update `retrievals#show` to support `?evaluation_id=...` —
     scrolls to the matching eval in the timeline (multiple evals per
     retrieval per Q3-D), shows it expanded by default.
   - Add primary-nav link to "Evaluations" via `admin_helper`.
   - Specs:
     - `spec/requests/curator/evaluations_spec.rb` (new index section)
       — index renders + filter querystring round-trips +
       failure_categories multi-select uses array overlap correctly +
       link to retrieval detail with `?evaluation_id=...`.
   - **Validate**: `bundle exec rspec` 0 failures; manual smoke —
     filter by `:negative` + `:hallucination`, see only matching evals,
     click through to detail.

- [ ] **Phase 5 — Exporters + rake tasks + buttons.** Two service
   objects, two rake tasks, two admin export buttons.
   - `lib/curator/retrievals/exporter.rb` — `.stream(io:, format:,
     filters:)` writes CSV via line-by-line `io.puts` (lazy) or single
     JSON document; columns include retrieval_id, query, answer
     (truncated to 500 chars), KB slug, chat_model, embedding_model,
     status, origin, retrieved_hit_count, eval_count, created_at.
   - `lib/curator/evaluations/exporter.rb` — `.stream(io:, format:,
     filters:)` columns from implementation.md: retrieval_id, query,
     answer (truncated), KB, chat_model, embedding_model, rating,
     feedback, ideal_answer, failure_categories (semicolon-joined CSV /
     array JSON), evaluator_id, evaluator_role, created_at.
   - Shared concern / module for streaming-CSV-with-headers + JSON
     array shape if it stays under 30 lines; otherwise keep them
     separate.
   - `app/controllers/curator/retrievals_controller.rb#export` and
     `evaluations_controller.rb#export` — accept current filter
     querystring, call exporter with `ActionController::Live` stream
     (CSV) or `render json:` (JSON). Same auth gating as the index
     actions.
   - "Export CSV" + "Export JSON" buttons on each tab — links that
     append `?format=csv` / `?format=json` to the current filter URL
     and route to the export action.
   - Rake tasks:
     `curator:retrievals:export KB=<slug> FORMAT=<csv|json> [SINCE=<iso>]`
     and
     `curator:evaluations:export KB=<slug> FORMAT=<csv|json> [SINCE=<iso>]`
     write to STDOUT. Filters limited to the CLI subset (KB + since).
   - Specs:
     - `spec/curator/retrievals/exporter_spec.rb` — CSV header + row
       shape, JSON shape, filter respect, streaming behavior (rows
       written incrementally, not buffered).
     - `spec/curator/evaluations/exporter_spec.rb` — same coverage,
       plus failure_categories serialization (semicolon CSV vs array
       JSON), rating filter, `failure_categories` ANY-of filter.
     - `spec/requests/curator/retrievals_spec.rb` + evaluations spec —
       export action returns CSV with `text/csv` content-type and
       `Content-Disposition: attachment`; JSON variant.
     - `spec/tasks/curator_export_spec.rb` (or extend existing rake
       spec) — both rake tasks invoke the right exporter with parsed
       filters.
   - **Validate**: `bundle exec rspec` 0 failures; manual smoke — load
     Retrievals tab with filters, click Export CSV, confirm download +
     row count matches filter; same for Evaluations.

- [ ] **Phase 6 — Manual visual QA in dummy app.** Exercise the full
   M7 surface in a browser against the dummy app:
   - Run a Console query, click 👎, see categories appear, submit, see
     row in Evaluations tab.
   - Click into a retrieval from Retrievals tab, confirm answer +
     sources + snapshot render, hit "Re-run in Console", confirm new
     run is `origin: :console_review` and hidden from default index.
   - Submit an SME annotation via the detail view, confirm a *second*
     eval row appears for the same retrieval.
   - Filter Evaluations by `:negative` + `:hallucination`, verify
     correct rows.
   - Export CSV from both tabs with filters applied; spot-check the
     downloaded files.

## Validation Strategy

### Per-phase

Each phase has a **Validate** sub-bullet above. Both `bundle exec rspec
--format progress` (0 failures) and `bundle exec rubocop` (no offenses)
are required to mark a phase complete (per CLAUDE.md "Verification —
required after every change").

### Cross-phase regressions to watch

- **Existing Console specs** (`spec/jobs/curator/console_stream_job_spec.rb`,
  `spec/requests/curator/console_spec.rb`) must keep passing through
  Phase 2 changes — the eval-form broadcast is additive, not a
  replacement.
- **Existing Retrieval factories / specs** — Phase 0 adds `origin`
  column with default `"adhoc"`, so existing factories don't need to
  set it. But spec assertions that count "all retrievals" might break
  once Phase 3 lands a default-hidden `:console_review` filter on the
  index — check before merging Phase 3.
- **`bin/reset-dummy`** must be re-run after Phase 0's migration
  template edit; CI / fresh clones depend on it (per CLAUDE.md).
- **Dashboard recent-activity feed** (M5 + M6 ConsoleStreamJob spec
  preserved a "no origin column" note — Phase 0 invalidates that
  comment; update it in the same edit to avoid future confusion).
- **`Curator::Evaluation` model validation** — Phase 1's `Evaluator`
  service object also enforces "categories empty unless `:negative`",
  which is a *stricter* contract than the model's existing
  `failure_categories_are_known` validator. Decide whether to push
  the new constraint down into the model (cleaner) or keep it in the
  service (defensive). Lean: push to model — host code calling
  `Curator::Evaluation.create!` directly should fail-loud here too.

## Files Under Development

```
lib/curator/
  evaluator.rb                    [P1 new]
  configuration.rb                [P1 modify — add 2 hooks]
  asker.rb                        [P3 modify — accept origin: kwarg]
  retrievals/
    exporter.rb                   [P5 new]
  evaluations/
    exporter.rb                   [P5 new]
lib/curator.rb                    [P1 modify — add Curator.evaluate delegator]
lib/generators/curator/install/templates/
  create_curator_retrievals.rb.tt [P0 modify — add origin column]
  curator.rb.tt                   [P1 modify — document evaluator hooks]
app/models/curator/
  retrieval.rb                    [P0 modify — origin enum, ORIGINS const]
  evaluation.rb                   [P1 modify — push categories-on-negative
                                   validation down]
app/controllers/curator/
  application_controller.rb       [P1 modify — current_admin_evaluator_id helper]
  console_controller.rb           [P3 modify — accept origin querystring]
  evaluations_controller.rb       [P1 new (create+update);
                                   P4 add (index); P5 add (export)]
  retrievals_controller.rb        [P3 new (index+show); P5 add (export)]
app/jobs/curator/
  console_stream_job.rb           [P2 modify — eval-form broadcast on done;
                                   P3 modify — accept origin: kwarg]
app/javascript/curator/
  console_evaluation_controller.js [P2 new — Stimulus]
app/views/curator/
  console/
    show.html.erb                 [P2 modify — add console-evaluation slot]
    _evaluation.html.erb          [P2 new — initial thumbs widget]
  evaluations/
    _form.html.erb                [P2 new — rating-aware expansion]
    index.html.erb                [P4 new]
  retrievals/
    index.html.erb                [P3 new]
    show.html.erb                 [P3 new — unified detail view]
    _trace.html.erb               [P3 new — collapsible step timeline]
  shared/
    _filter_form.html.erb         [P3 new — reused by P4]
app/helpers/curator/
  admin_helper.rb                 [P3+P4 modify — nav links]
config/routes.rb                  [P1, P3, P4, P5 modify — accreting routes]
lib/tasks/curator.rake            [P5 modify — add 2 export tasks]
features/implementation.md        [P0 modify — spec amendment]
spec/                             [parallel additions across phases]
```

## Parallelization

Per `~/.claude/projects/-home-greg-curator-rails/memory/milestone_parallelization.md`,
M7 is independent of the remaining milestones (M8, M9) — and M6 has
already shipped. The interesting parallelization is **internal**:

### Worktree split (Phase 3 ∥ Phase 4)

After Phases 0–2 land, **Phase 3 (Retrievals tab)** and **Phase 4
(Evaluations tab)** can run in parallel worktrees. They share the
unified detail view (`retrievals/show.html.erb`), but Phase 3 owns it
and Phase 4 only adds an `?evaluation_id=` query param consumer to it
— small surface to coordinate at merge.

```
                          ┌────────────────────────────────────┐
   Phase 0 ─► Phase 1 ─►  │  Phase 2 (Console inline)          │
   (P0 = spec +           │                                    │
   origin column)         │  Phase 3 (Retrievals)  ─┐          │
                          │           ∥             ├─► Phase 5 ─► Phase 6
                          │  Phase 4 (Evaluations) ─┘  (exporters)  (manual QA)
                          └────────────────────────────────────┘
```

Phase 2, 3, and 4 can technically all overlap once Phase 1 lands —
they touch disjoint controllers / views — but Phase 2 is small and
Phase 3 introduces the `_source`-partial reuse from Console, so
serializing Phase 2 → (3 ∥ 4) keeps merges simple.

### Conflict-prone files when merging

- `config/routes.rb` — Phases 1, 3, 4, 5 all add routes. Last merge
  rebases.
- `app/helpers/curator/admin_helper.rb` — Phases 3 and 4 both add a
  `nav_link_active?` entry. Trivial conflict.
- `app/views/layouts/curator/application.html.erb` — both add a nav
  link. Trivial conflict.
- `lib/curator.rb` — Phase 1 adds `Curator.evaluate`; no other phase
  touches it. No conflict expected.
- `app/jobs/curator/console_stream_job.rb` — Phase 2 (eval-form
  broadcast) and Phase 3 (origin kwarg) both modify. If running these
  in different worktrees, sequence the Phase 3 modification *after*
  Phase 2 lands.

## Implementation Notes

### `Curator.evaluate` shape

```ruby
# Canonical write path — used by admin Console / Retrievals / Evaluations
# UI and by host-app controllers exposing end-user feedback.
Curator.evaluate(
  retrieval:          Curator::Retrieval | id,
  rating:             :positive | :negative,
  evaluator_role:     :reviewer | :end_user,   # required
  evaluator_id:       String | nil,            # opaque host-app user id
  feedback:           String | nil,
  ideal_answer:       String | nil,            # only meaningful on :negative
  failure_categories: [String] # zero-or-more from Curator::Evaluation::FAILURE_CATEGORIES
)
# => Curator::Evaluation (persisted)
# Raises Curator::Evaluation::ValidationError on bad input.
```

### Identity hooks

```ruby
# config/initializers/curator.rb
Curator.configure do |c|
  # Existing
  c.authenticate_admin_with = ->(controller) { controller.authenticate_user! }

  # New in M7
  c.current_admin_evaluator    = ->(controller) { controller.current_user&.email }
  c.current_end_user_evaluator = ->(controller) { controller.current_user&.id&.to_s }
end
```

Both default to `->(_controller) { nil }` — zero-config hosts get
nil-evaluator evals everywhere, no breakage.

### Origin column rollout

Pre-v1, edit `create_curator_retrievals.rb.tt` directly (per CLAUDE.md
"Migration templates and the dummy app"). Post-v1 the same change
would have to ship as `add_origin_to_curator_retrievals.rb.tt`. Set
`default: "adhoc"` so existing rows in any host that's already mounted
the engine for testing pre-v1 don't break.

### Exporter streaming

Both exporters use the same shape: `stream(io:, format:, filters: {})`
where `io` is anything responding to `<<` / `puts`. Rake tasks pass
`$stdout`; controllers pass the response stream via
`ActionController::Live`. CSV writes header + rows lazily; JSON
buffers (acceptable for v1 sizes — large eval export queue-and-email
is explicitly deferred to v2 per implementation.md).

## Out of Scope (deferred to v2+)

- **`curator:feedback_widget` generator** — turnkey end-user thumbs
  widget that emits a controller + view + Stimulus into the host.
  v1 hosts wire 5 lines of controller themselves calling
  `Curator.evaluate`; the README ships the canonical example.
- **Large-export queue-and-email** — already deferred per
  implementation.md "Deferred to v2+ → Added during planning". v1
  streams synchronously.
- **Analytics dashboard** — the Evaluations tab is a list, not a
  dashboard. Aggregate views ("75% of `:wrong_retrieval` evals also
  carry `:hallucination`") deferred per implementation.md.
- **A/B comparison view** — already deferred.
- **LLM-as-judge `curator:eval:run`** — already deferred.

## Ideation Notes

This milestone was scoped via the `/ideate` skill on 2026-05-04. Q&A
summary captured during ideation:

- **Q1: Where does evaluation live in admin nav?** All three: Console
  inline + Retrievals tab + Evaluations tab. Phase 0 amends
  `features/implementation.md` to reflect this.
- **Q2: Console post-run rating UX?** Thumbs-only widget injected by
  the `done` broadcast; either thumb POSTs immediately and reveals an
  optional "Add details" expansion.
- **Q3: Multiple evals per retrieval — append vs edit?** Hybrid —
  same operator session edits one row in place (POST returns id, "Add
  details" PATCHes); a fresh page-load or different SME appends a new
  row. Schema's "many evals per retrieval" affordance is real and
  used.
- **Q4: How does `evaluator_id` get populated in admin?** New
  `config.current_admin_evaluator = ->(controller) { … }` hook,
  mirrors existing `authenticate_admin_with` shape. Default block
  returns nil.
- **Q4b: How do `:end_user` evals get submitted in v1?** Service
  object `Curator.evaluate(...)` + symmetric
  `config.current_end_user_evaluator` hook. Hosts write 5-line
  controller calling `Curator.evaluate`. Turnkey
  `curator:feedback_widget` generator deferred to M9/v2. Admin and
  host code share the same write path.
- **Q5: Retrievals tab vs Evaluations tab — separate or unified?**
  Distinct tabs. Retrievals = every `curator_retrievals` row;
  Evaluations = every eval joined to retrieval. Filters overlap on
  KB / date range / chat_model / embedding_model; tab-specific
  filters above.
- **Q6: One exporter or two?** Two — `Curator::Retrievals::Exporter`
  + `Curator::Evaluations::Exporter`, sharing a streaming-CSV /
  single-shot-JSON skeleton. Two rake tasks, two admin buttons.
- **Q7: SME detail-view scope?** Query, persisted answer, ranked
  sources (reuse `_source`), collapsible snapshot config, "Re-run in
  Console" deep-link, rating-aware annotation form. Trace timeline
  behind a "Show trace" toggle.
- **Q7b: Should the deep-link create noisy retrieval rows?** Add
  `origin` enum on `curator_retrievals` (`:adhoc | :console |
  :console_review`), plumbed through `Curator::Asker`. Deep-linked
  re-runs tagged `:console_review`; index tabs default-hide them.
  Pre-v1: edit existing migration template + `bin/reset-dummy`.
- **Q8: When do failure categories appear in the inline Console
  flow?** Console's "Add details" expansion is rating-aware (👎
  reveals categories + feedback + ideal answer; 👍 reveals just
  feedback). Detail view always shows the rating-aware annotation
  form regardless of current rating, since the SME explicitly came to
  annotate.
