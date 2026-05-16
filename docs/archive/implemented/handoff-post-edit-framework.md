## Handoff — post `:edit-framework` flow

This session landed the first new flow built on the Phase 10.5 sub-flow
extraction, plus three real bug fixes surfaced by smoke testing.

### What landed (uncommitted — user commits manually)

1. **CSS for conflict-resolution UI** — `flow-conflict-*` classes had
   ZERO styles, so resolved rows looked identical to unresolved. Added
   in `apps/rho_web/lib/rho_web/inline_css.ex` after `.flow-submit`:
   green left-border + checkmark on resolved rows, teal border on
   unresolved, filled green for the chosen action button. Also
   `.flow-submit:disabled` opacity.

2. **`:scratch_intent` guard** — bug: picking "Start from scratch" on
   the intake form routed to `:similar_roles` because the existing
   `:scratch` guard only fires when domain+target_roles are blank. Now
   `:scratch_intent` mirrors `:from_template_intent` / `:merge_intent` /
   `:extend_existing_intent` (string-equals on form value); the implicit
   `:scratch` guard remains for chat-router no-signal fallback. Edge
   added BEFORE `:scratch` on `:choose_starting_point.next`.

3. **Nil-reasoning defensive fix** in
   `apps/rho_web/lib/rho_web/live/app_live.ex:1871` — `Map.get(struct,
   :reasoning, default)` returns `nil` (not the default) when the
   struct has `reasoning: nil`, then `nil <> binary` would crash. Only
   on the low-confidence/unknown-flow fallback path; smoke tests passed
   because they hit the high-confidence success branch.

4. **`:edit-framework` flow** — new flow for in-place library edits.
   See "Read first" below.

### Read first (for `:edit-framework`)

- `apps/rho_frameworks/lib/rho_frameworks/flows/edit_framework.ex` —
  the new module. Steps: `:pick_existing_library →
  :load_existing_library` ++ `FinalizeSkeleton.steps()`. **Crucial:**
  `build_input(:save, ...)` overrides FinalizeSkeleton's chain to pin
  `library_id` to `:load_existing_library`'s summary — without this,
  save would lookup-by-intake-name (no name in intake) and create a
  duplicate row. Extend_existing's fork-on-save semantic stays intact
  because it doesn't call this override.
- `apps/rho_web/lib/rho_web/live/flow_live.ex` — three changes:
  - `boot_flow` now calls `maybe_auto_run` on mount (latent bug: select
    as first step would have rendered empty).
  - `load_select_options` calls `maybe_auto_advance_picker` for
    `:pick_existing_library` singleton pre-pick — but ONLY when
    `flow_module == RhoFrameworks.Flows.EditFramework`. Scoping was
    deliberate: extending it to create_framework would cascade into
    `identify_gaps → generate` (LLM call) and break existing pre-pick
    tests at `flow_live_test.exs:758-858` which assert "stays at
    picker, pre-picked".
  - Action steps don't auto-advance after success — user clicks
    Continue. So edit-framework UX is: click Edit on row → mount →
    auto-pick → run load_existing_library → "Loaded N skills, click
    Continue" → review.
- `apps/rho_frameworks/lib/rho_frameworks/llm/match_flow_intent.ex` —
  prompt updated: `starting_point` scoped to create-framework only;
  3 edit examples added; library_hints docs decoupled from
  starting_point. The LV's `library_hints` resolver in `app_live.ex:1921`
  is unchanged — it already turns singleton hints into `library_id`
  regardless of flow_id.
- `apps/rho_web/lib/rho_web/live/app_live.ex:577-690` — Edit affordance
  per library row (hidden for `visibility == "public"` AND `immutable`).
  `known_flows_string/0` describes both flows.

### State of play

- All five apps green:
  - rho: 304 tests
  - rho_baml: 26 tests
  - rho_stdlib: 142 tests
  - rho_frameworks: 354 tests (+17 new in this session)
  - rho_web: 253 tests (+10 new — 3 flow_live edit, 3 smart_entry edit, 1 nil-reasoning, 3 unaccounted? actually was 246+7 after task 6 finished)
  - **1079 total, 0 failures.**
- `mix compile --warnings-as-errors` clean. `mix format --check-formatted`
  clean.
- Nothing committed.

### Outstanding browser smokes (do these BEFORE new work)

1. **Edit affordance smoke** — on the libraries landing page, click
   "Edit" on a non-public, non-immutable library row. Expected:
   navigate to `/orgs/:slug/flows/edit-framework?library_id=<id>`,
   wizard auto-advances through `:pick_existing_library`, runs
   `:load_existing_library`, lands at "Loaded N skills, Continue".
   Click Continue → see review screen with the library's existing
   skills.
2. **Edit chat smoke** — type "edit our SFIA framework" (or whatever
   library name exists) in the chat overlay's smart-entry box.
   Expected: BAML returns `flow_id="edit-framework"` +
   `library_hints=["SFIA"]`, LV resolves to `library_id`, navigates as
   in #1. If hint doesn't resolve uniquely, navigates without
   library_id → manual picker.
3. **Edit save smoke** — walk to :review, edit a cell value (e.g.
   rename a skill), click through confirm → proficiency → save.
   Expected: skill saved back to the SAME library row. Verify by
   navigating to the library detail page and seeing the renamed skill.
   No duplicate "untitled" library row appears.
4. **CSS conflict smoke (regression)** — re-run the merge smoke from
   last session to verify the Phase 10.5 conflict UI is still visually
   distinguishable (green left-border on resolved, teal on unresolved,
   ✓ checkmark, filled action button).
5. **Verify clone is NOT yet wired** — `Flows.Registry.list/0` should
   return `["create-framework", "edit-framework"]`, no clone yet.

### Don't break

- **Iron Law #10:** sub-flow ids and starting_point values are atoms
  declared in code. Never `String.to_atom` on user input.
- **Auto-advance scoping:** `maybe_auto_advance_picker` checks
  `flow_module == EditFramework` deliberately. Removing that guard
  would break `flow_live_test.exs:758-858` (the existing
  pick_existing_library pre-pick tests for create-framework's
  extend_existing path) and could cascade into LLM calls during tests.
- **`:save` override in EditFramework:** the explicit clause that pins
  `library_id` to load_existing_library is load-bearing. FinalizeSkeleton's
  default chain falls through to lookup-by-intake-name, which would
  create a duplicate row for edit-framework (intake has no name).
- **17-node id-list assertion in `flow_test.exs:14-36`** — for
  CreateFramework only. EditFramework has its own structural test in
  `apps/rho_frameworks/test/rho_frameworks/flows/edit_framework_test.exs`.
- **`:edit-framework` registration in `Flows.Registry`** — flow_id
  validation in `dispatch_smart_entry_result` depends on it.

### Process (unchanged)

- User commits manually. **Never run `git commit`.**
- `mix format` enforced by a pre-edit hook — Edit/Write fail with
  "NEEDS FORMAT" if not formatted. Run `mix format <path>` then retry.
- Per-app tests: `(cd apps/<app> && mix test)`. There's no
  umbrella-wide aggregator — `mix test` from root only runs the cwd's
  app.
- Pause on non-trivial design calls — surface the option set with a
  recommendation, don't pre-commit.

### Likely next directions

1. **`:clone_framework` flow** — same shape as edit, except `:save`
   creates a new library row (clone semantics). Probably:
   - Reuse most of `EditFramework.build_input` but the `:save` clause
     omits library_id (forcing SaveFramework's lookup-or-create-by-name
     path) and includes a name from intake.
   - Add a `:intake` step at the head to capture the new name (clone-
     destination), or seed from URL like edit does.
   - "Clone" affordance per library row alongside Edit.
   - MatchFlowIntent: add clone examples ("clone our SFIA framework",
     "duplicate the backend skills as a new framework").
2. **Action auto-advance polish** — currently the "Loaded N skills,
   Continue" intermediate screen for edit-framework is one extra click.
   Could be eliminated by auto-advancing past `:load_existing_library`
   when it succeeds, but that's a wider change to action-step UX (would
   affect every action in every flow). Probably not worth it for one
   click.
3. **Update `docs/swappable-decision-policy-plan.md`** to reflect:
   - Phase 10.5 completion (sub-flow extraction)
   - `:scratch_intent` guard added
   - `:edit-framework` flow added (and `:clone-framework` planned)
   - Note the CSS bug + nil-reasoning bug as smoke-surfaced findings.
4. **Defensive verification of FinalizeSkeleton's reuse claim** —
   FinalizeSkeleton's docstring says "if a future flow reuses this
   sub-flow with a different state shape, the build_input clauses move
   to a namespaced input map at that point". EditFramework's `:save`
   override is the first signal that this point has been reached for
   one clause. When clone arrives, evaluate whether to refactor
   FinalizeSkeleton.build_input(:save, ...) into a namespaced input
   contract instead of accumulating overrides per consumer.
