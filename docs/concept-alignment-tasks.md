# Concept Alignment — Progress Tracker

Companion to `docs/concept-alignment-plan.md`. Check off deliverables
as they land. One branch per phase, merged into `main` sequentially.

**Legend:** `- [ ]` pending · `- [x]` done · `- [~]` in progress ·
`- [!]` blocked

---

## Pre-work

- [ ] Stash/commit unrelated WIP on `main` (working tree is clean before Phase 1 branch)
- [x] Commit plan + critique + `.gitignore` for `_rho/` & `priv/rho.db*`
- [x] Fix critique point D (acceptance criterion #2 wording)
- [x] Baseline `mix xref graph --format stats` → `docs/xref-baseline.txt`
- [ ] Resolve 3 cycles reported by xref (or document why they stay)
- [ ] Feature-preservation audit table cross-checked against current code
- [ ] Legacy-alias table finalised (see plan, "Legacy aliases" section)

---

## Phase 1 — Tape renaming  `refactor/phase-1-tape-rename`

Small, low-risk. Unblocks docs and downstream vocabulary.

- [ ] Grep audit: list every `Rho.Memory`, `Journal`, `memory_mod`, `memory_module` callsite
- [ ] Rename `Rho.Memory` → `Rho.Tape.Context`
- [ ] Rename `Rho.Mounts.JournalTools` → `Rho.Tools.TapeTools`
- [ ] Replace `memory_mod.build_context(tape_name)` callsites with `Rho.Tape.Context.build/1`
- [ ] Accept `memory_module` config key as alias for the new projection binding
- [ ] Update `lib/rho/memory.ex` → delegated shim OR delete if alias handled elsewhere
- [ ] `mix test` green
- [ ] Grep confirms zero `Memory` / `Journal` references outside docs footnotes
- [ ] PR opened, reviewed, merged to `main`

---

## Phase 2 — Plugin behaviour  `refactor/phase-2-plugin-behaviour`

Mount split, part 1. Contribution role only.

- [ ] Write same-turn skill-injection regression test (must fail if same-turn injection ever ships)
- [ ] Define `Rho.Plugin` behaviour with `(opts, ctx)` signatures
- [ ] Create `Rho.PluginInstance` struct (`module`, `opts`, `scope`, `priority`)
- [ ] Rename `Rho.MountRegistry` → `Rho.PluginRegistry`
- [ ] Rename `Rho.MountInstance` → `Rho.PluginInstance`
- [ ] Dispatch: `collect_tools/1`, `collect_prompt_sections/1`, `collect_bindings/1`
- [ ] Migrate tools-only plugins: Bash, FsRead, FsWrite, FsEdit, WebFetch, MultiAgent
- [ ] Migrate tools+bindings: Python, Sandbox
- [ ] Skill decomposition: extract `Rho.Skill` data + `Rho.Skill.Loader`
- [ ] Migrate `Rho.Skills` → `Rho.Skill.Plugin` (tools/2 + prompt_sections/2)
- [ ] Migrate Builtin, TapeTools (from Phase 1) whichever callbacks apply
- [ ] Split StepBudget: capability side → Plugin (hook side deferred to Phase 3)
- [ ] Split Subagent: capability side → Plugin (hook side deferred to Phase 3)
- [ ] Delete `children/2` callback; move owners to `Supervisor.child_spec/1` + agent supervision tree
- [ ] Verify atom shorthand resolution works (`:bash`, `:fs_read`, …)
- [ ] Verify tuple form resolution works (`{:multi_agent, except: […]}`, `{:py_agent, …}`)
- [ ] `Rho.Mount` behaviour becomes delegated alias to `Rho.Plugin`
- [ ] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 3 — Transformer behaviour  `refactor/phase-3-transformer`

Mount split, part 2. Typed pipeline stages.

- [ ] Define `Rho.Transformer` behaviour + `@type` aliases for all 6 stages
- [ ] Implement stage dispatch in Runner/Strategy (see Phase 4 handoff)
- [ ] `:prompt_out` stage wired (halt-capable)
- [ ] `:response_in` stage wired (halt-capable)
- [ ] `:tool_args_out` stage wired (`:cont` / `:deny` / `:halt`)
- [ ] `:tool_result_in` stage wired (halt-capable)
- [ ] `:post_step` stage wired (`:cont` / `:inject` / `:halt`)
- [ ] `:tape_write` stage wired (no halt; mutation only)
- [ ] Migrate StepBudget hook side → Transformer
- [ ] Migrate Subagent hook side → Transformer
- [ ] Migrate `before_tool` deny semantics → `:tool_args_out` with `{:deny, …}`
- [ ] Migrate `after_tool` result replace → `:tool_result_in` with `{:cont, new}`
- [ ] Migrate `after_step` injection → `:post_step` with `{:inject, …}`
- [ ] Migrate `before_llm` prompt mutation → `:prompt_out`
- [ ] Dialyzer clean on transformer implementations
- [ ] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 4 — Runner + TurnStrategy  `refactor/phase-4-runner-turnstrategy`

Collapse hook split. Strategy owns the turn, Runner drives the loop.

- [ ] Define `Rho.TurnStrategy` behaviour (`run_turn/2`, optional `prompt_sections/2`)
- [ ] Define `Rho.Runner` module (`run/5`: strategy, tape, plugins, transformers, opts)
- [ ] Move step budget to Runner integer field
- [ ] Move compaction to Runner predicate field
- [ ] Runner applies Transformer stages at correct moments
- [ ] Runner applies `:tape_write` before each tape append
- [ ] Rename `Rho.Reasoner` → `Rho.TurnStrategy`
- [ ] Rename `Rho.Reasoner.Direct` → `Rho.TurnStrategy.Direct`
- [ ] Rename `Rho.Reasoner.Structured` → `Rho.TurnStrategy.Structured`
- [ ] Accept `reasoner:` config as alias for `turn_strategy:`
- [ ] Move Structured strategy's JSON-format injection to `prompt_sections/2`
- [ ] Verify prompt merge order: system → plugin → strategy → tape
- [ ] Support `:position` (`:prelude` / `:postlude`) hints on plugin sections
- [ ] `AgentLoop` becomes thin Runner (or deleted, if fully absorbed)
- [ ] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 5 — Single event path  `refactor/phase-5-single-event-path`

Bus-only delivery. Gated by parity suite.

### 5a — Parity migration (blocking)

- [ ] Audit direct-pid subscribers; record signals each consumes
- [ ] Add operational signals to Worker for parity: `:turn_started`, `:turn_cancelled`, `:streaming_delta`, `:sap_repairs`, `:budget_warning` (as needed)
- [ ] Tape appends emit `:entry_appended` bus signals
- [ ] Add bus subscription to CLI alongside existing direct-pid path (dual-run)
- [ ] Add bus subscription to LiveView projections (session, observatory, spreadsheet)
- [ ] Add bus subscription to `Session.EventLog`
- [ ] Add bus subscription to SAP streaming
- [ ] **Parity test:** CLI streams identical output over bus-only
- [ ] **Parity test:** LiveView projections render identical event sequence over bus-only
- [ ] **Parity test:** `Session.EventLog` captures identical entries over bus-only
- [ ] **Parity test:** SAP streaming emits identical mid-stream events over bus-only
- [ ] All 4 parity tests green
- [ ] Switch subscribers to bus-only (remove direct-pid on subscriber side)
- [ ] Re-run parity suite
- [ ] Delete `subscribers` field and `broadcast/2` on Worker
- [ ] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 6 — Context struct audit + rename  `refactor/phase-6-context-audit`

Audit first, rename second. Do not guess the minimal set.

- [ ] Grep every `context.*` and `context[:…]` read across `lib/` and `test/`
- [ ] Produce `docs/context-field-audit.md`: field → readers, writers, keep/remove recommendation
- [ ] Audit reviewed and approved
- [ ] Rename `Rho.Mount.Context` → `Rho.Context`
- [ ] Remove fields with zero readers
- [ ] Document each surviving field on the struct
- [ ] Zero behaviour change verified
- [ ] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 7 — Documentation pass  `refactor/phase-7-docs`

- [ ] README.md: replace "memory backend" / `Rho.Memory` / `memory_module` / "Memory System" / `mounts:` / "agent loop" vocabulary
- [ ] README: add architecture blurb (Runner → TurnStrategy → Transformer → Tape → Bus)
- [ ] README: Transformer example (PII scrubber or denial policy)
- [ ] CLAUDE.md: "Mount Architecture" → "Plugin & Transformer Architecture"
- [ ] CLAUDE.md: split module tables into Plugin / Transformer implementers
- [ ] CLAUDE.md: Runner / TurnStrategy split explanation
- [ ] CLAUDE.md: Transformer Pipeline section with 6 typed stages
- [ ] CLAUDE.md: Config System — document legacy aliases
- [ ] CLAUDE.md: Migration appendix enumerating every legacy alias
- [ ] `.rho.exs` example: update `mounts:` / `reasoner:` comments with new + legacy
- [ ] `docs/schema-aligned-parsing-plan.md`: sync vocabulary (Reasoner → TurnStrategy, MountRegistry → PluginRegistry, mount hook → Transformer stage / Plugin)
- [ ] `docs/reasoner-baml-*.md`: update Reasoner → TurnStrategy
- [ ] `docs/tagged-removal-and-lenient-streaming-plan.md`: update cross-refs
- [ ] Every code snippet in README.md and CLAUDE.md compiles against current code
- [ ] Grep discipline verified: no stray old vocabulary outside migration appendix
- [ ] PR opened, reviewed, merged

---

## Acceptance gate (post-Phase 7)

Verify all 10 acceptance criteria from the plan:

- [ ] 1. Tools-only plugin = one module, one callback (`tools/2`)
- [ ] 2. Transformer can halt at any of its 5 haltable stages; halt reason propagates
- [ ] 3. Transformer at `:tool_args_out` can deny without halting; denial recorded on tape
- [ ] 4. Transformer at `:post_step` can inject synthetic user message visible next turn
- [ ] 5. Plugin reads per-instance opts from callback args (not global lookup)
- [ ] 6. Adding a new TurnStrategy requires zero Runner changes
- [ ] 7. Adding a new subscriber type requires zero agent-side changes
- [ ] 8. Replay w/ stubbed LLM adapter = byte-identical tape entries
- [ ] 9. Every README / CLAUDE.md snippet compiles
- [ ] 10. Legacy config keys (`mounts:`, `reasoner:`, `memory_module`) resolve

---

## Deferred (separate follow-ups, not in this plan)

### Session collapse
- [ ] Registry prefix-query API
- [ ] Hierarchical agent IDs (`s123/primary`, `s123/primary/coder_1`)
- [ ] `Worker.ask/2` equivalent of `Session.ask/3`
- [ ] Rewrite Session callers → Registry prefix-query
- [ ] Deprecation cycle on `Rho.Session`
- [ ] Delete `Rho.Session` module

### Namespace migration (`Rho.Exec.*` / `Rho.Coord.*` / `Rho.Edge.*`)
Triggers (all must hold):
- [ ] No semantic-refactor PRs open
- [ ] Docs use new vocabulary (grep-verified)
- [ ] xref boundary rules written and reviewed
- [ ] Plane assignment documented per module
