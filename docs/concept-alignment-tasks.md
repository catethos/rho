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

- [x] Grep audit: list every `Rho.Memory`, `Journal`, `memory_mod`, `memory_module` callsite
- [x] Rename `Rho.Memory` → `Rho.Tape.Context`
- [x] Rename `Rho.Mounts.JournalTools` → `Rho.Tools.TapeTools`
- [x] Replace `memory_mod.build_context(tape_name)` callsites with `Rho.Tape.Context.build/1`
- [x] Accept `memory_module` config key as alias for the new projection binding
- [x] Update `lib/rho/memory.ex` → delegated shim OR delete if alias handled elsewhere
- [x] `mix test` green
- [x] Grep confirms zero `Memory` / `Journal` references outside docs footnotes
- [ ] PR opened, reviewed, merged to `main`

---

## Phase 2 — Plugin behaviour  `refactor/phase-2-plugin-behaviour`

Mount split, part 1. Contribution role only.

- [x] Write same-turn skill-injection regression test (must fail if same-turn injection ever ships)
- [x] Define `Rho.Plugin` behaviour with `(opts, ctx)` signatures
- [x] Create `Rho.PluginInstance` struct (`module`, `opts`, `scope`, `priority`)
- [x] Rename `Rho.MountRegistry` → `Rho.PluginRegistry`
- [x] Rename `Rho.MountInstance` → `Rho.PluginInstance`
- [x] Dispatch: `collect_tools/1`, `collect_prompt_sections/1`, `collect_bindings/1`
- [x] Migrate tools-only plugins: Bash, FsRead, FsWrite, FsEdit, WebFetch, MultiAgent
- [x] Migrate tools+bindings: Python, Sandbox
- [x] Skill decomposition: extract `Rho.Skill` data + `Rho.Skill.Loader`
- [x] Migrate `Rho.Skills` → `Rho.Skill.Plugin` (tools/2 + prompt_sections/2)
- [x] Migrate Builtin, TapeTools (from Phase 1) whichever callbacks apply
- [x] Split StepBudget: capability side → Plugin (hook side deferred to Phase 3)
- [x] Split Subagent: capability side → Plugin (hook side deferred to Phase 3)
- [x] Delete `children/2` callback; move owners to `Supervisor.child_spec/1` + agent supervision tree
- [x] Verify atom shorthand resolution works (`:bash`, `:fs_read`, …)
- [x] Verify tuple form resolution works (`{:multi_agent, except: […]}`, `{:py_agent, …}`)
- [x] `Rho.Mount` behaviour becomes delegated alias to `Rho.Plugin`
- [x] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 3 — Transformer behaviour  `refactor/phase-3-transformer`

Mount split, part 2. Typed pipeline stages.

- [x] Define `Rho.Transformer` behaviour + `@type` aliases for all 6 stages
- [x] Implement stage dispatch in Runner/Strategy (see Phase 4 handoff)
- [x] `:prompt_out` stage wired (halt-capable)
- [x] `:response_in` stage wired (halt-capable)
- [x] `:tool_args_out` stage wired (`:cont` / `:deny` / `:halt`)
- [x] `:tool_result_in` stage wired (halt-capable)
- [x] `:post_step` stage wired (`:cont` / `:inject` / `:halt`)
- [x] `:tape_write` stage wired (no halt; mutation only)
- [x] Migrate StepBudget hook side → Transformer
- [x] Migrate Subagent hook side → Transformer
- [x] Migrate `before_tool` deny semantics → `:tool_args_out` with `{:deny, …}`
- [x] Migrate `after_tool` result replace → `:tool_result_in` with `{:cont, new}`
- [x] Migrate `after_step` injection → `:post_step` with `{:inject, …}`
- [x] Migrate `before_llm` prompt mutation → `:prompt_out`
- [ ] Dialyzer clean on transformer implementations (no dialyzer configured in project)
- [x] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 4 — Runner + TurnStrategy  `refactor/phase-4-runner-turnstrategy`

Collapse hook split. Strategy owns the turn, Runner drives the loop.

- [x] Define `Rho.TurnStrategy` behaviour (`run/2`, optional `prompt_sections/2`)
- [x] Define `Rho.Runner` module (`run/3`: model, messages, opts — strategy/tape/plugins wired internally)
- [x] Move step budget to Runner integer field
- [x] Move compaction to Runner predicate field
- [x] Runner applies Transformer stages at correct moments
- [x] Runner applies `:tape_write` before each tape append
- [x] Rename `Rho.Reasoner` → `Rho.TurnStrategy`
- [x] Rename `Rho.Reasoner.Direct` → `Rho.TurnStrategy.Direct`
- [x] Rename `Rho.Reasoner.Structured` → `Rho.TurnStrategy.Structured`
- [x] Accept `reasoner:` config as alias for `turn_strategy:`
- [x] Move Structured strategy's JSON-format injection to `prompt_sections/2`
- [x] Verify prompt merge order: system → plugin → strategy → tape
- [x] Support `:position` (`:prelude` / `:postlude`) hints on plugin sections
- [x] `AgentLoop` becomes thin Runner (thin delegate)
- [x] `Rho.Lifecycle` deleted; Runner calls `PluginRegistry.apply_stage/3` directly
- [x] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 5 — Single event path  `refactor/phase-5-single-event-path`

Bus-only delivery. Gated by parity suite.

### 5a — Parity migration (blocking)

- [x] Audit direct-pid subscribers; record signals each consumes (only `Rho.CLI` uses direct-pid; LiveViews + `Session.EventLog` were already bus-only)
- [x] Add operational signals to Worker for parity: `:turn_started`, `:turn_cancelled`, `:streaming_delta`, `:sap_repairs`, `:budget_warning` (as needed) — all events CLI consumes were already in `Worker.@signal_event_types`; nothing missing for parity
- [x] Tape appends emit `:entry_appended` bus signals (`rho.session.<sid>.tape.entry_appended`, wired in `Rho.AgentLoop.Recorder`)
- [x] Add bus subscription to CLI alongside existing direct-pid path (dual-run) — `Rho.CLI` now takes `source: :direct_pid | :bus | :both`
- [x] Add bus subscription to LiveView projections (session, observatory, spreadsheet) — already bus-only, no change needed
- [x] Add bus subscription to `Session.EventLog` — already bus-only, no change needed
- [x] Add bus subscription to SAP streaming — N/A: `StreamEnvelope` is a passive text analyzer, not an event subscriber
- [x] **Parity test:** CLI streams identical output over bus-only
- [x] **Parity test:** LiveView projections render identical event sequence over bus-only
- [x] **Parity test:** `Session.EventLog` captures identical entries over bus-only
- [x] **Parity test:** SAP streaming emits identical mid-stream events over bus-only
- [x] All 4 parity tests green (`test/rho/session/bus_parity_test.exs`)
- [x] Switch subscribers to bus-only (remove direct-pid on subscriber side)
- [x] Re-run parity suite
- [x] Delete `subscribers` field and `broadcast/2` on Worker
- [x] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 6 — Context struct audit + rename  `refactor/phase-6-context-audit`

Audit first, rename second. Do not guess the minimal set.

- [x] Grep every `context.*` and `context[:…]` read across `lib/` and `test/`
- [x] Produce `docs/context-field-audit.md`: field → readers, writers, keep/remove recommendation
- [x] Audit reviewed and approved
- [x] Rename `Rho.Mount.Context` → `Rho.Context`
- [x] Remove fields with zero readers
- [x] Document each surviving field on the struct
- [x] Zero behaviour change verified
- [x] `mix test` green
- [ ] PR opened, reviewed, merged

---

## Phase 7 — Documentation pass  `refactor/phase-7-docs`

- [x] README.md: replace "memory backend" / `Rho.Memory` / `memory_module` / "Memory System" / `mounts:` / "agent loop" vocabulary
- [x] README: add architecture blurb (Runner → TurnStrategy → Transformer → Tape → Bus)
- [x] README: Transformer example (PII scrubber or denial policy)
- [x] CLAUDE.md: "Mount Architecture" → "Plugin & Transformer Architecture"
- [x] CLAUDE.md: split module tables into Plugin / Transformer implementers
- [x] CLAUDE.md: Runner / TurnStrategy split explanation
- [x] CLAUDE.md: Transformer Pipeline section with 6 typed stages
- [x] CLAUDE.md: Config System — document legacy aliases
- [x] CLAUDE.md: Migration appendix enumerating every legacy alias
- [x] `.rho.exs` example: update `mounts:` / `reasoner:` comments with new + legacy
- [x] `docs/schema-aligned-parsing-plan.md`: sync vocabulary (Reasoner → TurnStrategy, MountRegistry → PluginRegistry, mount hook → Transformer stage / Plugin)
- [x] `docs/reasoner-baml-*.md`: update Reasoner → TurnStrategy
- [x] `docs/tagged-removal-and-lenient-streaming-plan.md`: update cross-refs
- [x] Every code snippet in README.md and CLAUDE.md compiles against current code
- [x] Grep discipline verified: no stray old vocabulary outside migration appendix
- [ ] PR opened, reviewed, merged

---

## Acceptance gate (post-Phase 7)

Verify all 10 acceptance criteria from the plan:

- [x] 1. Tools-only plugin = one module, one callback (`tools/2`)
- [x] 2. Transformer can halt at any of its 5 haltable stages; halt reason propagates
- [x] 3. Transformer at `:tool_args_out` can deny without halting; denial recorded on tape
- [x] 4. Transformer at `:post_step` can inject synthetic user message visible next turn
- [x] 5. Plugin reads per-instance opts from callback args (not global lookup)
- [x] 6. Adding a new TurnStrategy requires zero Runner changes
- [x] 7. Adding a new subscriber type requires zero agent-side changes
- [x] 8. Replay w/ stubbed LLM adapter = byte-identical tape entries
- [x] 9. Every README / CLAUDE.md snippet compiles
- [x] 10. Legacy config keys (`mounts:`, `reasoner:`, `memory_module`) resolve

Full verification: `docs/acceptance-gate-verification.md`.

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
