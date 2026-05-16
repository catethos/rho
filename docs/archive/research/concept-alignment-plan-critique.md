# Concept Alignment Plan — Critique

Collected feedback on `docs/concept-alignment-plan.md` across two
review rounds.

---

## Current verdict

**Architecturally sound and implementation-ready for Phases 1–4.**
Phases 5+ have a few remaining spec gaps that should be clarified
before execution but do not block earlier work.

The revised plan addresses all eleven original critique points — some
by direct fix, some by reasoned pushback. The eight-concept framing
holds. Skill decomposes cleanly. Plugin opts are preserved.
Transformer stages are typed. Session and namespace migration are
correctly deferred.

---

## Round 1 — Original critique points

### Resolved in revision

| # | Issue | Resolution |
|---|-------|------------|
| 1 | **Missing concept: Skill** | Skill explicitly decomposed into data/loader (`Rho.Skill`, `Rho.Skill.Loader`) + Plugin (`Rho.Skill.Plugin`). Not a ninth concept. Three rows added to feature-preservation audit. Regression test required for next-turn (not same-turn) instruction injection. |
| 2 | **Plugin callbacks drop per-instance opts** | Callbacks now take `(keyword(), Context.t())`. `PluginInstance` preserves `module`, `opts`, `scope`, `priority`. Tuple config forms (`{:multi_agent, except: [...]}`) continue to work. |
| 3 | **Tape and Bus conflated** | Distinct section added. Tape = durable semantic log, Bus = transient event stream (superset). Tape appends emit bus signals; bus also carries operational and coordination signals. Three signal categories documented. |
| 4 | **Transformer API too generic** | Six named stages with typed input/output contracts. `:tool_args_out` gains `{:deny, reason}`. `:post_step` gains `{:inject, [message]}`. `:tape_write` disallows halt. Elixir `@type` aliases specified for Dialyzer enforcement. |
| 5 | **Reasoner prompt shaping is strategy-owned** | `TurnStrategy.prompt_sections/2` added as optional callback. Structured strategy uses it for JSON-format instructions. |
| 6 | **Keep `Rho.Session` as a façade** | Session collapse deferred with explicit prerequisites (Registry prefix-query, bus-only CLI/web, `ask/3` equivalent). Façade stays until proven replaceable. |
| 7 | **Context struct too small** | Phase renamed to "audit + rename." Explicit instruction: audit all callsites first, remove only zero-reader fields. No guessing the minimal set. |
| 8 | **Defer namespace migration** | Moved to "Deferred" section. Rationale: conflates semantic cleanup with structural boundary enforcement. Separate follow-up. |
| 9 | **`MountRegistry` → `Rho.Registry` name collision** | Renamed to `Rho.PluginRegistry`. Collision with `Elixir.Registry` and `Rho.Agent.Registry` avoided. |
| 10 | **Acceptance criteria shape-based** | Replaced with 10 behaviour-based criteria (e.g., "a tools-only plugin is one module with one callback," "a transformer can deny a tool call without halting the turn"). |
| 11 | **Compatibility aliases not enumerated** | Full legacy-alias table added (config keys, modules, delegated shims, atom shorthands, tuple forms). |

### Pushback accepted from author

- **#4's `post_step_effects` hook.** The critique suggested a separate
  Runner hook. The plan instead added `:post_step` as a Transformer
  stage with `{:inject, messages}`. This keeps one mechanism and avoids
  reopening the lifecycle-hook door. **Accepted** — one mechanism is
  cleaner.
- **#6's permanent Session retention.** The critique could be read as
  arguing for permanent façade. The plan keeps it only during migration
  with explicit collapse prerequisites. **Accepted** — deferred
  collapse with prerequisites is the right sequencing.

---

## Round 2 — Oracle review of revised plan

### Issues addressed in latest revision

| # | Finding | Resolution in plan |
|---|---------|-------------------|
| R1 | **`:tape_write` halt is dangerous** — side effects already happened but durable record may not exist | Halt disallowed at `:tape_write`. Transformers must return `{:cont, stub_entry}` for redaction. Rationale documented. |
| R2 | **Transformer stages not typed in Elixir terms** — still `transform(stage, data, ctx)` | Explicit `@type` aliases added per stage (`prompt_out_data`, `prompt_out_result`, `tool_args_result` with `:deny`, `post_step_result` with `:inject`, `tape_write_result` with no halt). Dialyzer-enforceable. |
| R3 | **Bus contract too narrow** — plan read as if bus only carries tape-derived signals | Bus section rewritten. Three signal categories: tape-derived, operational (`:sap_repairs`, `:streaming_delta`, `:turn_started`), agent-coordination. Bus is a superset of tape events. |
| R4 | **Prompt-section merge order wrong** — `system → strategy → plugin` puts format instructions too early | Reversed to `system → plugin (contextual) → strategy (format-enforcing) → tape messages`. Recency-bias rationale documented. `:position` hint (`:prelude`/`:postlude`) added for override cases. |
| R5 | **Replay acceptance criterion too strong** — "same output" unrealistic with nondeterministic LLMs | Weakened to: "byte-identical tape entries with a stubbed deterministic LLM adapter." Real-LLM nondeterminism explicitly scoped out. |
| R6 | **SAP plan vocabulary drift** — still uses `Reasoner`, `MountRegistry`, "mount hook" | SAP plan and other docs added to Phase 7 doc-update table with specific terms to sync. |
| R7 | **Skill dynamic loading timing** — verify it's next-turn, not same-turn | Regression test requirement added to plan. Test must fail if same-turn injection ever ships. |

### Remaining gaps (not yet addressed)

These are minor and do not block Phases 1–4, but should be resolved
before executing Phase 5+:

#### A. Phase 5 parity gate

Before deleting direct-pid fan-out, prove that CLI, LiveView,
`Session.EventLog`, and SAP/UI streaming signals all work correctly
over bus subscription alone. The plan says "audit current direct
subscribers" but doesn't frame this as a **gate** — it should be an
explicit prerequisite check, not just an audit step.

**Recommendation:** add a parity-test suite as a Phase 5 prerequisite.
Each current direct subscriber gets a test showing identical behaviour
over bus-only delivery before the old path is deleted.

#### B. Transformer `@type` aliases vs. single `transform/3` callback

The plan defines per-stage `@type` aliases but keeps a single
`transform(stage, data, Context.t()) :: stage_result` callback. This
means the stage-specific types are **documentation-level** — Dialyzer
can check the union type but cannot enforce that a `:prompt_out`
implementation returns `prompt_out_result` specifically (it only sees
the union of all stage results).

This is acceptable for now. If it becomes a source of bugs, the fix is
stage-specific callbacks (`transform_prompt_out/2`,
`transform_response_in/2`, etc.) with default no-op implementations.
Don't do this preemptively — the single-callback design is simpler and
covers the common case where a transformer handles 1–2 stages.

#### C. Namespace migration trigger

The "Deferred — Namespace migration" section says "after the semantic
split stabilises" but doesn't define a concrete trigger. Add one line:

> Trigger: no semantic-refactor PRs open, docs/examples stop using
> legacy aliases, xref boundary rules are written and testable.

#### D. Acceptance criterion #2 wording vs. `:tape_write` — **RESOLVED**

Criterion #2 now reads "any of its five haltable stages" with
`:tape_write` called out as mutation-only. Fixed in plan.

---

## Summary of plan evolution

| Version | Concepts | Phases | Key changes |
|---------|----------|--------|-------------|
| Draft 1 | 6 protocols + Mount split | 6 phases | Three protocols (Capability/Contributor/Observer), typed per-callback context structs |
| Draft 2 | 8 concepts (Occam pass) | 7 phases + docs | Collapsed to Plugin + Transformer, deleted Observer, added Runner |
| Revision 1 (post-critique) | 8 concepts | 7 phases + deferred | Skill decomposition, `(opts, ctx)`, Tape ≠ Bus, typed stages, strategy prompt hook, Session façade, alias table |
| Revision 2 (post-oracle) | 8 concepts | 7 phases + deferred | `:tape_write` no-halt, `@type` aliases, bus signal categories, prompt order reversed, replay scoped to stubs, SAP vocab sync |

The plan is now mature enough for implementation. Start with Phase 1
(tape rename) — it's the smallest change with the lowest risk and
unblocks everything downstream.
