# Prompt XML Context

Wrap the retrieved-context block in XML tags (`<context>` plus per-hit
`<source>`) inside the assembled system prompt. Improves Claude's
adherence to the "answer only from context" instruction, hardens the
prompt against injection attempts buried in source text (a chunk that
says "ignore previous instructions" stops blurring into the
surrounding instructions when it lives inside `<source>...</source>`),
and tightens the citation grounding for OpenAI models too.

This is a one-shot prompt-format change. The context block format is
already Curator-owned (see the comment in `Curator::Prompt::Assembler`
— operator overrides only replace the *instructions* half), so blast
radius on host-app overrides is zero. Eval-baseline continuity across
the cutover is a non-concern in pre-v1 development.

**Reference**: `features/implementation.md` → "Service Object API →
Curator::Prompt::Assembler"; `lib/curator/prompt/{assembler,templates}.rb`.

## Completed

_(none yet — feature specced 2026-05-05.)_

## Current Work

_(empty — Phase 1 not yet promoted.)_

## Next Steps

- [ ] **Phase 1 — Switch context block to XML tags.**
   - `lib/curator/prompt/assembler.rb` — replace the `CONTEXT_HEADER`
     constant + `render_hit` method so `context_block(hits)` emits:
     ```
     <context>
       <source rank="1" doc="manual.md" page="3">
         <chunk text>
       </source>
       <source rank="2" doc="api.md">
         <chunk text>
       </source>
     </context>
     ```
     Page attribute omitted entirely when `hit.page_number` is nil
     (don't emit `page=""`). Document name + chunk text get the
     standard XML escape — a doc title like `Q&A Guide` becomes
     `doc="Q&amp;A Guide"`, a chunk that contains `</source>` inside
     its body becomes `&lt;/source&gt;` (otherwise an adversarial
     ingest could close the source tag early).
   - `lib/curator/prompt/templates.rb` — update both
     `DEFAULT_INSTRUCTIONS_WITH_CITATIONS` and
     `DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS` to reference the new
     structure. Keep the citation-marker shape (`[N]`) — the markers
     match `<source rank="N">` and the existing `_source` partial /
     answer rendering already keys off rank. The instructions should
     teach the model the convention explicitly so adherence doesn't
     depend on it inferring from XML alone:
     ```
     The retrieved context appears below inside <context> tags.
     Each <source> entry is a separate retrieved chunk identified
     by its `rank` attribute. Reference sources using `[N]`
     markers that match the rank...
     ```
   - `features/implementation.md` — amend the "Service Object API →
     Curator::Prompt::Assembler" section to document the XML
     wrapping (treat as a living-document update, not a new file).
   - Specs:
     - `spec/curator/prompt/assembler_spec.rb` — replace `[N] From`
       string assertions with the new `<source rank="N" doc="...">`
       shape. Add coverage: page attribute omitted when nil; `&` in
       doc name escapes; `</source>` in chunk text escapes; empty
       hits still emit no `<context>` block (instructions-only).
     - `spec/curator/asker_spec.rb` + `spec/jobs/curator/console_stream_job_spec.rb`
       — update the four existing `include("[1] From")` assertions
       to match `include('<source rank="1"')` instead. These assert
       *that* hits made it into the prompt, not the legacy format —
       the change is mechanical.
   - **Validate**: `bundle exec rspec --format progress` 0 failures;
     `bundle exec rubocop` no offenses.

- [ ] **Phase 2 — Manual visual QA in dummy app.**
   - Run a Console query against a real KB with at least 3 hits;
     view the persisted system prompt — confirm structure is
     well-formed XML (paste into an XML validator if uncertain).
   - Ingest a doc whose title contains `&` and `<` characters
     (e.g. a fixture named `Q&A Guide.md`), run a query that pulls
     it, confirm the rendered prompt escapes correctly and the
     model still cites it as `[N]`.
   - Run a query against an empty KB (no hits, strict_grounding
     off) — confirm the prompt has no `<context>` block at all
     (instructions-only path), so the model isn't confused by an
     empty `<context></context>` envelope.
   - Run the same query against the same KB twice in immediate
     succession — confirm `system_prompt_hash` is identical (the
     XML attribute order must be deterministic; Ruby `Hash` insertion
     order makes this trivial as long as we don't iterate a Set
     anywhere in `render_hit`).

## Validation Strategy

### Per-phase

Each phase has a **Validate** sub-bullet. Both `bundle exec rspec
--format progress` (0 failures) and `bundle exec rubocop` (no
offenses) are required to mark a phase complete (per CLAUDE.md
"Verification — required after every change").

### Cross-phase regressions to watch

- **`Curator::Asker` strict-grounding refusal** — refusal path skips
  `assemble_prompt` entirely (no LLM call, see `Asker#refuse?`). The
  existing `REFUSAL_MESSAGE` template stays as-is; XML wrapping is
  context-only, not refusal-message-related.
- **Token budget** — XML tags add a small per-hit overhead
  (~15 tokens for the `<source rank="N" doc="...">` open + close).
  At chunk_limit=10 that's ~150 extra tokens, well inside any modern
  context window but worth noting if a host has tight per-call
  spend caps. The heuristic `Curator::TokenCounter.count` already
  re-runs against the full assembled text, so estimates stay
  accurate.
- **Operator `kb.system_prompt` overrides** — the override only
  replaces the *instructions half* (per the assembler comment), so
  hosts that override see no behavioral break. They will *not*
  automatically pick up the new `<context>` reference text in their
  custom instructions, though, so a host with strict-grounding +
  an aggressive custom prompt may want to update theirs to mention
  the XML wrapper.

## Files Under Development

```
lib/curator/prompt/
  assembler.rb        [P1 modify — CONTEXT_HEADER + render_hit + escape]
  templates.rb        [P1 modify — instructions reference <context>/<source>]
spec/curator/prompt/
  assembler_spec.rb   [P1 modify — XML shape, escape coverage]
spec/curator/
  asker_spec.rb       [P1 modify — 3 assertions: `[1] From` -> `<source rank="1"`]
spec/jobs/curator/
  console_stream_job_spec.rb [P1 modify — 1 assertion likewise]
features/
  implementation.md   [P1 modify — Assembler API doc amendment]
```

## Implementation Notes

### XML escape — defense against adversarial ingest

The `render_hit` method must escape both attribute values (`doc=`)
and the chunk body. A document whose title is literally `Q&A` would
otherwise emit malformed attribute syntax; a chunk body that contains
`</source>` would otherwise close the source tag early and let
following chunks fall outside the `<context>` envelope (which is the
whole point of using the wrapper for injection resistance).

Use `CGI.escape_html` (or `ERB::Util.html_escape` — same thing) for
attribute values. For chunk text, escape `<`, `>`, and `&`; do NOT
escape quotes inside the text body (it's not in an attribute), and
do NOT pre-mangle whitespace (preserving the chunk's original
formatting matters for code blocks / tables).

### Why `<source rank="N">` over `[N]` interleaved

Tempting alternative: leave `[N]` as the per-source label inside the
context block and just wrap the whole thing in `<context>`. Rejected
because:
- Models cite more reliably when the rank is a *parseable attribute*
  on the wrapping tag than when it's free text inside.
- Per-hit `<source>` tags give the model a clean delimiter for "this
  chunk ends here" — important when chunks have inconsistent
  trailing whitespace or end mid-sentence.
- Negligible token cost (one tag pair per hit).

### Why this is its own feature file, not an M7 phase

The change is independent of M7's evaluations work — it ships in
`Curator::Prompt::Assembler`, which has been stable since M4. Done as
a standalone feature file so the small change can land independently
of however far M7 Phases 4–6 progress.

## Out of Scope (deferred)

- **Per-KB toggle for XML vs legacy format** — adds a config column
  and code-path branching for negligible win. If a host hates the
  XML format they can override `kb.system_prompt` and emit whatever
  they want in the instructions; the context block stays
  Curator-owned.
