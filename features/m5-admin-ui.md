# M5 — Admin UI Core

First end-user-facing surface for curator-rails: a Hotwire admin
mounted at `/curator` (or wherever the host app mounted the engine).
Ships vanilla CSS (no Tailwind), Knowledge Base CRUD, document
upload + management, the chunk inspector, and live status updates
via ActionCable + Turbo Streams broadcasts so operators watch
ingestion progress without F5. Query Testing Console, REST API, LLM
token streaming, evaluations, and chat are deferred to M6–M8.

**Reference**: `features/implementation.md` → "Implementation
Milestones" → M5, plus the "Admin UI" and "Generators" sections. M5
amends two earlier decisions: drops Tailwind+daisyUI from
"Technology & Dependencies" / "Asset strategy" in favor of
vanilla namespaced CSS, and pulls the admin-side Turbo Streams
infrastructure forward from M6 (M6 retains its `/api/stream`
LLM-token streaming + Query Console scope).

## Next Steps

- [x] **Phase 1 — Plan amendment + asset/layout scaffolding +
   `:deleting` status + ActionCable check.**
   - Edit `features/implementation.md` (living-document update, per
     project convention):
     - "Technology & Dependencies" table: swap
       `Hotwire (Turbo + Stimulus), Tailwind + daisyUI (pre-compiled)`
       for `Hotwire (Turbo + Stimulus), vanilla CSS namespaced
       under .curator-ui`.
     - "Gem Structure" tree: drop `app/assets/curator/curator.css`
       comment about Tailwind+daisyUI; replace with
       `app/assets/stylesheets/curator/curator.css`.
     - "Admin UI → Asset strategy": rewrite to describe vanilla
       `curator.css`, drop the `rake curator:build_assets` reference
       and the `app/assets/curator/` path. Note `.curator-ui`
       body-class scoping.
     - "Rake Tasks": delete the `curator:build_assets` row.
     - "Implementation Milestones → M5": replace the
       Tailwind+daisyUI bullet with "vanilla namespaced CSS",
       and add a bullet "Live document/KB list updates via
       ActionCable + Turbo Streams broadcasts (host must have a
       configured cable adapter)".
     - "Implementation Milestones → M6": narrow the
       `Streaming infrastructure (Turbo Streams in admin UI,
       /api/stream endpoint)` line to `Streaming infrastructure
       (/api/stream LLM-token endpoint)` — admin-UI Streams now
       land in M5.
   - Vanilla stylesheet at
     `app/assets/stylesheets/curator/curator.css`. Every rule scoped
     under `.curator-ui` (the `<body>` class on every engine view).
     Provides utility primitives — layout (`.app-shell`,
     `.app-header`, `.app-main`), table, form, fieldset, button,
     badge (`embedded` / `missing` / status colors), card, modal —
     just enough for the views Phases 2–7 build. No per-feature
     classes beyond what's used. Visual targets per the "Visual
     Design" section below (Mission Control-style, light theme,
     system fonts, comfortable density).
   - `app/views/layouts/curator/application.html.erb`: `<body
     class="curator-ui">` wrapping `<header>` (engine title + slot
     for Phase 7's KB switcher), `<main>` (yields), `<footer>` w/
     engine version. Stylesheet linked via `stylesheet_link_tag
     "curator/curator"`. Turbo + Stimulus pinned via importmap
     entries; `<%= turbo_include_tags %>`.
   - Migration template edit:
     `lib/generators/curator/install/templates/create_curator_documents.rb.tt`
     adds `:deleting` as a valid status value (current schema:
     string column with model-level enum mapping). `bin/reset-dummy`
     to regenerate `spec/dummy/db/schema.rb`. Update
     `Curator::Document` enum hash to include `:deleting`.
   - `Curator::Generators::InstallGenerator` gains an ActionCable
     check mirroring its existing Active Storage check: verify
     `Rails.root.join("config/cable.yml").exist?`. On miss, print a
     non-aborting warning pointing at the default Rails scaffolding
     and recommending Solid Cable for production. Update the
     generator's post-install message to flag that production needs
     a real cable adapter (Solid Cable on Rails 7.1+/8, Redis
     pre-7.1).
   - Test infra: `spec/support/turbo_helpers.rb` exposes
     `suppress_turbo_broadcasts` (wraps
     `Turbo::Broadcastable.suppressing_turbo_broadcasts`) so existing
     M2–M4 specs that exercise document/embedding writes stay
     deterministic. Default in `rails_helper.rb` to suppress
     broadcasts in non-broadcast specs; opt-in for the spec files
     that assert them.
   - **Validate**: full M1–M4 spec suite stays green (no regressions
     from layout introduction or broadcast plumbing — suppression
     covers it). New specs: `GET /curator` renders the layout
     (asserts `body.curator-ui`, stylesheet link tag, header
     skeleton). Generator spec asserts the ActionCable warning fires
     when `cable.yml` is absent and stays silent when present.
     `Curator::Document` enum spec covers `:deleting` round-trip.
     `bundle exec rubocop` clean.

- [x] **Phase 2 — Knowledge Base CRUD + tiered form.**
   - `Curator::KnowledgeBasesController` (`new` / `create` / `show`
     / `edit` / `update` / `destroy`); index covered in Phase 3.
     Routes: `resources :knowledge_bases, path: "kbs",
     param: :slug, except: [:index]`. `destroy` is sync — KB
     deletion cascades to documents/chunks/embeddings/retrievals;
     v1 accepts the latency for a rarely-exercised operator action.
     Document the caveat in the generated initializer.
   - `app/views/curator/knowledge_bases/_form.html.erb` is a tiered
     form with three `<fieldset>` sections:
     - **Display** — `name`, `description`, `is_default` (checkbox;
       single-default invariant handled by existing `before_save`
       callback).
     - **Retrieval** — `retrieval_strategy` (select: hybrid / vector
       / keyword), `chunk_limit`, `similarity_threshold`,
       `tsvector_config`, `include_citations`, `strict_grounding`.
     - **Advanced** — `chunk_size`, `chunk_overlap`, `chunk_model`,
       `system_prompt` (textarea).
     - **Locked-after-create** — `embedding_model`, `slug`. On
       `new` rendered as normal inputs; on `edit` rendered as
       `<input disabled readonly>` with an inline note: "Cannot be
       changed after creation. Recreate the KB to switch
       embedding model, or run `curator:reembed` to migrate."
   - `KnowledgeBase` model gains a strong-params permit list as a
     class method (`KnowledgeBase.permitted_params(action:)`)
     returning the appropriate column subset for `:new` vs
     `:edit` so the controller can't accidentally let a user post
     a new `embedding_model` to `update`. Server-side enforcement,
     not just frontend `disabled`.
   - Flash + error rendering via shared partial
     `app/views/curator/shared/_form_errors.html.erb`.
   - **Validate**: controller specs for full CRUD; form-rendering
     spec asserts each fieldset present, locked fields read-only on
     `edit`, editable on `new`. Strong-params spec asserts a POST
     to `update` with `embedding_model: "<other>"` does not change
     the value. Single-default invariant spec (carried over from
     M1) still green.
   - 🧵 **Round 1 begins after this phase lands.** Phases 3 ∥ 4 ∥ 7
     run in parallel — spawn one git worktree per phase, branched
     from this commit. See "Parallelization" section below for
     per-phase file lists and merge-conflict watch points.

- [ ] **Phase 3 — Landing page (KB list cards) + empty state +
   KB-list broadcasts.**
   - `Curator::KnowledgeBasesController#index` mounted at
     `root "knowledge_bases#index"`. View renders one card per KB:
     name (linked to `kbs/:slug/documents`), description,
     document count, last-ingested-at (computed from
     `documents.maximum(:created_at)`), and a small "Edit" link to
     `kbs/:slug/edit`. "New knowledge base" CTA in the header.
   - Empty state: zero-KB case renders a full-page onboarding panel
     ("Create your first knowledge base" + brief explanation +
     primary CTA → `kbs/new`) instead of the cards grid.
   - Broadcasts: each card wrapped in
     `<turbo-frame id="curator_kb_<id>">`. The index page subscribes
     via `<%= turbo_stream_from "curator_knowledge_bases_index" %>`.
     `Curator::Document` gains
     `after_create_commit` /
     `after_update_commit` /
     `after_destroy_commit` callbacks that
     `broadcast_replace_to "curator_knowledge_bases_index", target:
     dom_id(document.knowledge_base, :card), partial: ...` so the
     KB card re-renders with updated counts whenever its documents
     change. KB itself broadcasts append/replace/remove against the
     same stream on its own create/update/destroy.
   - **Validate**: index spec renders cards w/ counts, links to KB
     scope. Empty-state spec asserts onboarding panel + absence of
     cards grid. Broadcast spec uses
     `assert_broadcasts("curator_knowledge_bases_index", N)` around
     a doc create + KB create to confirm the wiring.

- [ ] **Phase 4 — Document index + multipart multi-file upload +
   drag-drop + doc-list broadcasts.**
   - `Curator::DocumentsController#index` and `#create` under
     `kbs/:slug`. Index renders a table: filename, mime, byte size,
     status badge, chunk count, ingested-at, row actions (re-ingest
     + delete — Phase 5). Hides rows where `status: :deleting`.
   - `#create` accepts `params[:files]` as an array, iterates,
     calls `Curator.ingest(file, knowledge_base: kb)` per file
     inside a single request. Aggregates results into a summary
     flash: `"3 ingested, 1 duplicate, 0 failed"`. Per-file
     failures (e.g. `FileTooLargeError`) caught and counted; do not
     abort the batch.
   - Upload form: `<input type="file" multiple>` inside a Stimulus
     `drag-drop` controller (`app/javascript/controllers/curator/
     drag_drop_controller.js`). Drop zone overlay highlights on
     `dragenter`; `drop` mirrors `event.dataTransfer.files` into
     the file input and submits the form. Form also works without
     JS — `<input>` is functional on its own.
   - Broadcasts: each row wrapped in `<turbo-frame
     id="curator_document_<id>">`. Index subscribes via
     `turbo_stream_from kb, "documents"`. `Curator::Document`'s
     `after_*_commit` callbacks (added in Phase 3 for KB-card
     refresh) extended to also broadcast row replace/append/remove
     against the per-KB stream. Status flips inside
     `IngestDocumentJob` and `EmbedChunksJob` already write to the
     model — broadcasts piggyback on those updates.
   - No "Refresh" link — broadcasts make it unnecessary.
   - **Validate**: controller specs for `#index` + `#create`
     including multi-file batch (3 valid + 1 oversize), summary
     flash assertion. Drag-drop controller's markup rendered
     (asserts `data-controller="curator--drag-drop"` + targets).
     Broadcast spec: enqueue `IngestDocumentJob`,
     `perform_enqueued_jobs`, assert
     `assert_turbo_stream(action: :replace, target:
     "curator_document_<id>")` fires on the per-KB stream.
   - 🧵 **Round 2 begins after this phase lands** (and Round 1's
     other phases are merged). Phases 5 ∥ 6 run in parallel —
     spawn one git worktree per phase, branched from the merged
     Round 1 tip. See "Parallelization" section below.

- [ ] **Phase 5 — Async destroy (`DestroyDocumentJob`) + sync
   re-ingest + status broadcasts.**
   - `app/jobs/curator/destroy_document_job.rb`: takes a document
     id, calls `document.destroy!` inside a transaction. Cascade
     handled by existing `dependent: :destroy` chain
     (chunks/embeddings/retrievals).
   - `DocumentsController#destroy` flips
     `document.update!(status: :deleting)`, enqueues
     `DestroyDocumentJob.perform_later(id)`, redirects to index
     with `flash[:notice] = "Document queued for deletion"`. Index
     scope already filters out `:deleting` rows, so the row
     disappears immediately on next render. After the job runs,
     `after_destroy_commit` broadcasts a `remove` against the
     per-KB stream so any other connected client sees the row
     vanish.
   - `documents#reingest` member POST route. Controller calls
     `Curator.reingest(document)`, redirects to index with a flash.
     Existing `Curator.reingest` (M2 Phase 7) handles
     chunk teardown + status reset; broadcasts ride on the
     subsequent `Document#update!` calls during the rerun.
   - Confirmation: both delete and re-ingest use
     `data-turbo-confirm="..."` on the `<button>` /
     `link_to method: :post`. No custom modal.
   - **Validate**: destroy controller spec asserts status flip +
     job enqueue + redirect; integration with `perform_enqueued_jobs`
     confirms the row is gone post-job. Re-ingest controller spec
     asserts `Curator.reingest` is called with the right doc and
     status flips back to `:pending`. Broadcast assertions on both
     paths.

- [ ] **Phase 6 — Chunk inspector at `documents#show` + per-chunk
   embedding badges + live "X of Y embedded" header.**
   - `Curator::DocumentsController#show` route already implicit in
     `resources :documents`; controller `@document` + `@chunks =
     @document.chunks.order(:position).offset(...).limit(...)`.
   - View structure:
     - Metadata header: filename, mime, byte size, status badge,
       chunk count, **`X of Y chunks embedded`** (counts
       `Curator::Embedding` rows where `embedding_model =
       kb.embedding_model`), ingested-at. Wrapped in
       `<turbo-frame id="curator_document_<id>_header">`.
     - Per-chunk cards: each rendered with metadata strip
       (`#<rank> · page N · M tokens · chars X–Y · embedding:
       <model> (<dim>d) · embedded <date>` or the missing-state
       fallback) and the chunk's full text inside a `<pre>` with
       preserved whitespace. `embedded` / `missing` badge driven by
       presence of an Embedding row matching the KB's current
       `embedding_model`.
     - Pagination: `?page=N&per=25` (max 100). Hand-rolled
       `Curator::PaginationHelper` (`#paginate(scope, page:, per:)`
       returning `{records:, page:, per:, total:, pages:}`) +
       `_pagination.html.erb` partial with prev/next/page-N
       links. No `kaminari` dependency.
   - Live header: `Curator::Embedding`
     `after_create_commit` /
     `after_destroy_commit` callbacks
     `broadcast_replace_to chunk.document, target:
     dom_id(chunk.document, :header), partial:
     "curator/documents/header"`. Recomputes the X-of-Y line on
     every embedding change. Suppressed in non-broadcast specs via
     the helper from Phase 1.
   - **Validate**: show spec renders header + paginated chunks +
     correct badges (mix of embedded + missing chunks via
     factories). Pagination spec covers page boundaries
     (page 0, page > pages, per > max). Broadcast spec asserts
     header re-renders on Embedding create.

- [ ] **Phase 7 — KB switcher Stimulus controller.**
   - Topbar slot in the layout populated only when
     `params[:knowledge_base_slug]` is set (i.e. inside any
     `kbs/:slug/*` request). Renders a `<select>` listing all KBs
     with the current KB pre-selected, wrapped in a Stimulus
     `kb-switcher` controller
     (`app/javascript/controllers/curator/kb_switcher_controller.js`).
   - On `change`: controller reads the new slug and the current
     URL, replaces the segment immediately following `/kbs/` with
     the new slug, and navigates via
     `Turbo.visit(new_url)`. Falls back to plain
     `window.location.assign` if Turbo isn't available.
   - Helper `current_kb_for_switcher` in
     `app/helpers/curator/admin_helper.rb` resolves
     `Curator::KnowledgeBase.find_by!(slug:
     params[:knowledge_base_slug])` and exposes the list. Layout
     calls it; nil-safe when no slug param.
   - **Validate**: layout spec asserts switcher renders inside a
     KB-scoped path (e.g. `/curator/kbs/default/documents`) with
     the right `<option>` selected, and is absent on `/curator` /
     `/curator/kbs/new`. Stimulus markup assertions only —
     navigation behavior covered by manual QA / M9 Capybara.

- [ ] **Phase 8 — End-to-end smoke + plan close.**
   - `spec/requests/curator/admin_smoke_spec.rb` drives the full
     M5 surface against the dummy app: GET `/curator` (empty
     state) → POST `/curator/kbs` (create KB) → GET landing (card
     present) → POST `/curator/kbs/<slug>/documents` with a
     multi-file payload → `perform_enqueued_jobs` (real ingest +
     stubbed embed via existing M3 helpers) → GET
     `/curator/kbs/<slug>/documents` (rows present, statuses
     terminal) → GET `/curator/kbs/<slug>/documents/<id>` (chunks
     visible w/ embedded badges + correct X-of-Y) → POST reingest
     → POST destroy → assert row gone after job runs.
   - Broadcast assertions interleaved using `assert_turbo_stream`
     at key transitions (doc create, status flip, embed complete,
     destroy).
   - Update CLAUDE.md if any new conventions emerged (likely a
     line about the broadcast-suppression helper). Tick the
     remaining boxes on this file. Add a "Completed" header above
     the phase list (mirroring m1-foundation.md / m2-ingestion.md
     close-out style) once all phases land.
   - **Validate**: `bundle exec rspec --format progress` ends 0
     failures. `bundle exec rubocop` ends "no offenses detected".
     **M5 milestone complete.**

## Implementation Notes

**Why vanilla CSS over Tailwind+daisyUI**: the engine surface is
small (one layout, ~6 view templates, a card/table/form vocabulary),
the host app inherits whatever the engine ships, and Tailwind's main
value (utility ergonomics across many editors) doesn't apply to a
small maintainer team. Vanilla CSS scoped under `.curator-ui`
gives us deterministic CSS isolation from the host's stylesheets,
zero Node toolchain, and no daisyUI version churn. Tradeoff
accepted: ~300–500 lines of CSS to write upfront and no "looks
decent for free" baseline.

**ActionCable as a hard dependency**: pulling Streams forward from
M6 means the install generator must surface this clearly. Rails
7.1+/8 ships Solid Cable in the new-app default; pre-7.1 hosts need
Redis. The generator warns rather than aborts so a host can install
the engine and configure cable later — but the post-install message
must be unambiguous.

**Locked fields as defense-in-depth**: `embedding_model` and `slug`
are `disabled` in the form *and* excluded server-side via
`KnowledgeBase.permitted_params(action: :edit)`. Frontend-only
locking (no `disabled` attribute on the input) would let a curl POST
through and silently corrupt embeddings.

**Async delete vs. sync KB delete**: documents are async-deleted
because a single doc with thousands of chunks/embeddings can take
seconds. KBs are sync-deleted in v1 because (a) operators rarely do
it, (b) cascading async would require a `:deleting` status on
`KnowledgeBase` too, which is more schema for a marginal win.
Revisit if a real user complains.

**Hand-rolled pagination over kaminari**: 30 LOC of helper + partial
vs. a runtime dependency. Kaminari's value is its rich UI helpers
(window-of-pages, Bootstrap themes); we don't need them. Easy to
swap in later if the chunk inspector grows tabular filters.

**`turbo_stream_from` scoping**: the per-KB documents stream uses
`[kb, "documents"]` as the channel name, which means a connected
client viewing KB A doesn't receive broadcasts for KB B. Free
isolation, falls out of `turbo_stream_from`'s `dom_id` semantics.

## Parallelization

Phases 1, 2, and 8 are sequential. The middle five phases collapse into
two parallel rounds, taking the milestone from 8 sequential phases to 5
sequential rounds.

```
Phase 1 (foundation)
   ↓
Phase 2 (KB CRUD — anchors routes/controllers for everything else)
   ↓
[ Phase 3 ∥ Phase 4 ∥ Phase 7 ]   ← 3-way parallel
                 ↓
       [ Phase 5 ∥ Phase 6 ]      ← 2-way parallel
                 ↓
Phase 8 (smoke — needs everything)
```

### Round 1: Phases 3 ∥ 4 ∥ 7 (after Phase 2 lands)

| Phase | Touches |
|---|---|
| 3 — Landing page + KB-list broadcasts | `KnowledgeBasesController#index`, KB views (index/card/empty_state), `Curator::Document` model (KB-card broadcast callbacks), `Curator::KnowledgeBase` model (broadcasts), `config/routes.rb` (`root` directive, drop `except: [:index]` from `resources :knowledge_bases`) |
| 4 — Document index + upload + per-KB broadcasts | `DocumentsController` (NEW: index + create), doc views (index/row/upload_form), `app/javascript/controllers/curator/drag_drop_controller.js` (NEW), `Curator::Document` model (per-KB stream broadcast callbacks), `config/routes.rb` (nested `resources :documents`) |
| 7 — KB switcher | `app/views/layouts/curator/application.html.erb` (switcher slot), `app/helpers/curator/admin_helper.rb` (NEW), `app/javascript/controllers/curator/kb_switcher_controller.js` (NEW). No conflicts with 3/4. |

### Round 2: Phases 5 ∥ 6 (after Phase 4 lands)

| Phase | Touches |
|---|---|
| 5 — Async destroy + sync reingest | `app/jobs/curator/destroy_document_job.rb` (NEW), `DocumentsController` (`#destroy` + `#reingest` methods), `config/routes.rb` (`member do; post :reingest; end`) |
| 6 — Chunk inspector + live header | `DocumentsController#show`, doc show view + `_header` / `_chunk` partials, `app/views/curator/shared/_pagination.html.erb` (NEW), `app/helpers/curator/pagination_helper.rb` (NEW), `Curator::Embedding` model (header-refresh broadcast callbacks) |

### Merge-conflict watch list

These are the files where parallel branches will overlap. Prep where
noted to make merges trivial:

1. **`app/models/curator/document.rb`** — Round 1's Phases 3 and 4 both
   append `after_*_commit` broadcast callbacks to different streams
   (`"curator_knowledge_bases_index"` vs `[kb, "documents"]`).
   **Phase 1 prep**: scaffold an empty
   ```ruby
   # ---- Broadcasts (M5) ----
   # ---- /Broadcasts ----
   ```
   region in the model so both phases append cleanly between the
   markers rather than racing on insertion point.

2. **`config/routes.rb`** — Phase 3 modifies the
   `resources :knowledge_bases, ..., except: [:index]` block (removes
   `except`, adds `root "knowledge_bases#index"` above it). Phase 4
   nests `resources :documents` inside the same block. Phase 5 adds a
   `member` declaration inside `resources :documents`.
   **Phase 2 prep**: write the resources block on multiple lines from
   the start (each option on its own line, opening `do…end` block ready
   even if empty). Three-way merge of small line-level edits is then
   straightforward.

3. **`app/controllers/curator/documents_controller.rb`** — Round 2's
   Phases 5 and 6 add disjoint actions (`#destroy` + `#reingest` vs
   `#show`). Append-only; trivial merge.

4. **`app/views/layouts/curator/application.html.erb`** — Phase 7
   populates the KB switcher slot. Phase 1 must establish the slot as
   a clearly-marked empty placeholder
   (`<%# KB switcher slot — populated in Phase 7 %>`) so Phase 7's edit
   is a single-region replace.

### Worktree handoff notes

- Each round's worktrees branch from the same parent commit (the tip
  of the previous round). Round 1 worktrees branch from Phase 2's tip;
  Round 2 worktrees branch from the merged Round 1 tip.
- Specs for each phase are independent — no spec-file conflicts across
  parallel phases (different paths under `spec/`).
- After a parallel round, run the full suite (`bundle exec rspec`)
  against the merged result before kicking off the next round; a
  broadcast callback collision in `Curator::Document` will surface
  there even if the textual merge succeeded.
- Phase 8 (smoke spec) must run after all merges land, on the
  consolidated branch. It exercises the full M5 surface and is the
  load-bearing assertion that the parallel work composed correctly.

## Visual Design

**Reference**: Rails 8 Mission Control / Solid Queue dashboard — modern
Rails Hotwire admin, comfortable density, light theme, polished but
utilitarian.

**Design targets** (Phase 1 implementer fills in concrete CSS values
within these constraints):

- **Theme**: light-only in v1. Stylesheet structured to make
  `prefers-color-scheme: dark` a future addition (custom properties
  for color tokens, no hard-coded hex outside the `:root` block).
- **Typography**: system font stack
  (`-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, ...`).
  No web fonts. Monospace stack for chunk text + code (`ui-monospace,
  "SF Mono", Menlo, monospace`). Base size 14–15px; small / medium /
  large scale via custom properties.
- **Density**: comfortable (Mission Control-ish), not compact.
  Generous-but-not-airy table row height; cards have real internal
  padding. Avoid Sidekiq's data-cram density.
- **Color palette**: neutral grays + one accent (saturated blue or
  teal — implementer's call within that range; document the chosen
  hex in `:root` comments). Status colors picked from a small fixed
  set: green (complete/embedded), yellow/amber (pending/processing),
  red (failed), gray (deleting/missing).
- **Shape**: small border radius (4–6px), minimal shadows used only
  for modals + elevated cards. No neumorphism, no heavy gradients.
- **Layout**: max content width ~1200px centered; sticky top
  `<header>` with engine title + KB switcher slot.

These are *targets*, not pixel-perfect specs — the goal is that a
reviewer comparing the rendered admin to a Mission Control screenshot
recognizes the same family. Visual polish iteration can happen in M9.

## Ideation Notes

Captured from `/ideate` session on 2026-04-29.

| # | Question | Conclusion |
|---|---|---|
| 1 | Asset pipeline: Tailwind+daisyUI vs vanilla CSS? | **Vanilla CSS** scoped under `.curator-ui`. Surface is small; CSS isolation from the host's styles matters more than utility ergonomics. Amend `implementation.md` to drop Tailwind+daisyUI, drop the `rake curator:build_assets` task and the `app/assets/curator/` path. |
| 2 | Route shape: URL-scoped or session-scoped KB selection? | **URL-scoped.** Selected KB lives in the URL itself (bookmarkable, multi-tab safe). |
| 3 | Slug segment under `/curator`: bare `:slug`, `kbs/:slug`, or scope block? | **`resources :knowledge_bases, path: "kbs", param: :slug, except: [:index]`** + nested document/chunk resources. Standard Rails idiom; sidesteps slug-vs-reserved-path collisions entirely (no `:slug` directly under `/curator`). |
| 4 | Landing page (`/curator`) shape in M5? | **KB list as the landing page.** `root "knowledge_bases#index"`. Cards w/ doc count + last-ingested-at; empty-state = full-page onboarding CTA. M9 grafts tiles + activity feed above. |
| 5 | KB configuration form: edit-anything, lock-dangerous, or tiered? | **Tiered form** (Display / Retrieval / Advanced fieldsets). `embedding_model` + `slug` editable on `new` only, read-only on `edit`. Strong-params enforces the lock server-side too. |
| 6 | Document upload mechanism? | **Multipart multi-file** w/ Stimulus drag-drop overlay. Server iterates `params[:files]`, returns summary flash. Active Storage direct upload deferred to M9. |
| 7 | Live document/KB updates in M5 or wait for M6? | **Live in M5** via ActionCable + Turbo Streams broadcasts. Pulls admin-UI streaming infra forward from M6; M6 retains `/api/stream` LLM-token streaming + Query Console. ActionCable becomes a host requirement; install generator gains a `cable.yml` check. (Initial answer was "defer to M6"; reconsidered.) |
| 8 | Row actions — confirm style, delete sync/async, re-ingest? | **Native `data-turbo-confirm`** + **async** delete via new `DestroyDocumentJob` + `:deleting` status (migration template edit; index hides + broadcasts removal post-job) + **sync** re-ingest POST member route. |
| 9 | Chunk inspector layout? | **`documents#show` doubles as inspector.** Doc metadata header (incl. *X of Y chunks embedded*, live), full chunk text inline w/ per-chunk metadata strip + `embedded`/`missing` badge. Hand-rolled `?page=N&per=25` pagination. Embedding details (model, dim, embedded-at) shown per chunk. |
| 10 | Testing approach + phase ordering? | **Request specs only in M5**; Capybara/Selenium deferred to M9 polish. 8-phase plan: scaffolding → KB CRUD → landing → docs upload → destroy/reingest → inspector → KB switcher → smoke. Doc detail header gets "X of Y chunks embedded" line for partial-failure visibility. |
| 11 | What is the UI styling based on? | **Mission Control / Solid Queue dashboard** as the visual reference. Light-only in v1 (dark-mode-ready via custom-property color tokens), system font stack, comfortable density, neutral grays + one accent, small radius + minimal shadows. See "Visual Design" section above. |
| 12 | Can phases run in parallel via worktrees? | **Yes — 8 phases collapse into 5 sequential rounds.** After Phase 1 (foundation) and Phase 2 (KB CRUD) land sequentially, Phases 3 ∥ 4 ∥ 7 run in parallel, then Phases 5 ∥ 6 run in parallel, then Phase 8 (smoke) closes. See "Parallelization" section above for per-phase file lists, merge-conflict watch points, and Phase 1/2 prep work needed to make merges trivial. |
