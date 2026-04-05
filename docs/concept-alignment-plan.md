# Concept Alignment Plan

Goal: collapse Rho's agent-loop architecture down to its **eight
first-principles concepts**, matching the code's names and shapes to the
architecture diagram in `CLAUDE.md` one-to-one. No new subsystems. No
feature loss. This is a vocabulary and factoring refactor that removes
mismatches forcing readers to hold extra context.

> **Progress tracking.** Per-phase deliverables live in
> [`docs/concept-alignment-tasks.md`](./concept-alignment-tasks.md).
> **After completing any phase (or any deliverable within a phase),
> update that file:** check off the completed items, mark
> in-progress items with `- [~]`, flag blocked items with `- [!]`.
> When branching, use the branch name listed in the tasks file for
> that phase (e.g. `refactor/phase-1-tape-rename`). The plan
> describes *what and why*; the tasks file tracks *what's done*.

> **Revision note.** Revised in response to
> `docs/concept-alignment-plan-critique.md`. Key changes: Skill's
> placement made explicit; Plugin callbacks keep per-instance opts;
> Tape and Bus are distinct but linked (tape appends *emit* signals);
> Transformer stages carry typed contracts including a `:post_step`
> stage for message injection; TurnStrategy owns its own
> prompt-shaping hook; namespace migration deferred to a separate
> follow-up; `Rho.Session` kept as a compatibility façade during
> migration; acceptance criteria rewritten in behaviour terms; legacy
> aliases enumerated explicitly.

---

## Why

The current code has the right concepts *latent* but spread across
misnamed modules and conflated behaviours:

- `Mount` bundles four unrelated roles (tools, prompt content, lifecycle
  hooks, process ownership) under one name.
- Lifecycle hooks split arbitrarily between `AgentLoop` and `Reasoner`.
- Worker output ships via two parallel delivery paths (bus + direct pid).
- One event log has three names: `memory`, `tape`, `journal`.
- An ambient context map passes many fields to every callback whether
  they're used or not.
- `Session` is a thin forwarding layer over `Registry`.

These mismatches make reading the code harder than it should be and make
refactors leak across unrelated modules. Fix them and the architecture
diagram *is* the architecture in the code.

---

## The target: eight concepts

The entire agent loop reduces to eight concepts, each answering one
question no other concept answers:

| # | Concept | Answers |
|---|---|---|
| 1 | **Turn** | What's one iteration of the loop? |
| 2 | **TurnStrategy** | How does the agent decide what to do? |
| 3 | **Tape** | How does the agent remember? |
| 4 | **Plugin** | How do you add tools or context? |
| 5 | **Transformer** | How do you gate or mutate data in flight? |
| 6 | **Runner** | What drives the loop? |
| 7 | **Worker** | How does an agent exist as a process? |
| 8 | **Bus** | How do observers and other agents see what happens? |

Everything currently in the codebase maps to one of these, decomposes
into a combination of them, or gets deleted.

### Where Skills fit

`Rho.Skill` and `Rho.Skills` are **not** a ninth concept. They
decompose cleanly:

- **Skill (data)** — the `%Rho.Skill{}` struct, YAML-frontmatter
  parser, and multi-path discovery logic (`.agents/skills/`, global,
  builtin). This is data + a loader utility. Lives as plain modules
  under `Rho.Skill` / `Rho.Skill.Loader`.
- **Skills Plugin** — the thing that surfaces skills to the agent. A
  `Plugin` implementation that (a) injects the "Available Skills"
  section via `prompt_sections/2`, and (b) exposes the `skill` tool
  via `tools/2` for on-demand dynamic loading. This is the current
  `Rho.Skills` module, migrated to the `Plugin` behaviour.

The dynamic-loading semantic (the `skill` tool injects instructions
mid-conversation) is just a regular tool invocation that appends to
the tape. No new mechanism needed — skill instructions become tool
output that the next turn reads as part of normal context building.

**Feature-preservation entries** (added to audit):
- Skill discovery → `Rho.Skill.Loader` (data + loader)
- `skill` tool → `Rho.Skill.Plugin` (Plugin.tools/2)
- "Available Skills" prompt section → `Rho.Skill.Plugin` (prompt_sections/2)

**Regression test required.** Dynamic skill loading must be verified
to inject instructions into the **next** turn's context, not the
current one — the `skill` tool's output becomes a tape entry, and the
following turn's prompt-assembly reads it. A regression test that
fails if a single-turn same-call injection ever ships is part of
Phase 2's acceptance.

---

## Tape and Bus: linked, not identical

Tape and Bus are **distinct** concepts with different contracts:

| Aspect | Tape | Bus |
|---|---|---|
| Purpose | Semantic context log (LLM history) | Operational event stream |
| Consumers | LLM context builder, replay, handoff | CLI, LiveView, telemetry, observers |
| Retention | Durable, on-disk (JSONL) | Transient |
| Fidelity | Full message content | Signals with optional payload |
| Schema | Entry types (`:message`, `:tool_call`, …) | Signal types (superset of tape-derived signals plus operational signals) |

The relationship between them: **tape appends emit bus signals, but
the bus also carries operational signals that are not tape-derived.**

### Bus signal categories

1. **Tape-derived signals.** Every tape append emits a corresponding
   signal (`:entry_appended` with entry type and id). Subscribers that
   need durable history read the tape; subscribers that need live
   updates listen for these signals.
2. **Operational signals.** Runtime-only events that don't belong on
   the tape: `:sap_repairs` (structured-parse repair logs),
   `:streaming_delta` (mid-stream tokens and list-item events from
   schema-aware streaming), `:turn_started`, `:turn_cancelled`,
   `:budget_warning`, etc. These are transient telemetry.
3. **Agent-coordination signals.** Inter-agent messages routed through
   the bus (delegation requests, replies, broadcasts).

Subscribers never read the tape directly for live updates — they
subscribe to the bus. The bus is a **superset** of the tape's event
stream, not a 1:1 mirror.

This preserves single-writer correctness for the tape while giving
streaming parsers, telemetry sinks, and coordination paths a
first-class operational-signal channel.

---

## What gets deleted (and why it's safe)

| Deleted | Replaced by | Reason |
|---|---|---|
| `Mount` behaviour | `Plugin` + `Transformer` + `TurnStrategy` prompt hook | Four concerns split by role |
| Observer callbacks (`before_llm`, `before_tool`, `after_tool`, `after_step`) | Transformer stages + Runner fields + Bus subscribers | Each old hook use-case has a better home |
| `children/2` callback | Plain `Supervisor.child_spec/1` | Supervision ≠ plug-point |
| `Rho.Memory` | `Rho.Tape.Context` | One log, one name |
| `Rho.Mounts.JournalTools` | `Rho.Tools.TapeTools` | Same |
| Direct-pid subscriber path on Worker | Bus subscription only (tape appends emit signals) | One delivery path |

Not deleted yet (kept as façade/compat during migration):
- `Rho.Session` — kept as a thin compatibility façade. Collapsing it
  to pure naming convention is a separate follow-up once Registry
  prefix-query, CLI subscription, and `Session.EventLog` have proven
  equivalent coverage.
- `memory_module` config key — accepted as alias for the
  `Rho.Tape.Context` projection binding.

Feature-preservation audit at the end verifies no features are lost.

---

## Plugin behaviour: exact shape

```elixir
defmodule Rho.Plugin do
  @callback tools(keyword(), Context.t()) :: [tool_def]
  @callback prompt_sections(keyword(), Context.t()) :: [section]
  @callback bindings(keyword(), Context.t()) :: [binding]
  @optional_callbacks tools: 2, prompt_sections: 2, bindings: 2
end
```

Each callback takes `(opts, context)` — per-instance opts are
preserved. `.rho.exs` entries like `{:multi_agent, except: [...]}`
and `{:py_agent, module: ..., name: ...}` continue to work.

Instance wrapping: `Rho.MountInstance` → `Rho.PluginInstance` with
the same fields (`module`, `opts`, `scope`, `priority`). Scoping and
priority rules are unchanged.

---

## Transformer behaviour: typed stages

```elixir
defmodule Rho.Transformer do
  @callback transform(stage, data, Context.t()) :: stage_result
end
```

Each stage has a **typed contract** for both input data shape and
allowed return shapes:

### `:prompt_out`
- **Input:** `%{messages: [message], system: String.t() | nil}`
- **Returns:** `{:cont, prompt} | {:halt, reason}`
- **Use:** PII scrub, policy gate, rate limit, token budget.

### `:response_in`
- **Input:** LLM response map (text, tool_calls, usage)
- **Returns:** `{:cont, response} | {:halt, reason}`
- **Use:** toxicity filter, PII scrub on assistant output.

### `:tool_args_out`
- **Input:** `%{tool_name: atom, args: map}`
- **Returns:** `{:cont, %{tool_name: atom, args: map}} | {:deny, reason} | {:halt, reason}`
- **Use:** arg validation, secret redaction, **deny tool execution**.
  (Absorbs the old `before_tool` deny semantics.)

### `:tool_result_in`
- **Input:** `%{tool_name: atom, result: term}`
- **Returns:** `{:cont, %{tool_name: atom, result: term}} | {:halt, reason}`
- **Use:** output scrub, size cap, **result replacement**.
  (Absorbs the old `after_tool` replace semantics.)

### `:post_step`
- **Input:** `%{step: integer, entries_appended: [entry]}`
- **Returns:** `{:cont, nil} | {:inject, [message]} | {:halt, reason}`
- **Use:** synthetic message injection, post-step annotations,
  observation with ability to nudge the next turn.
  (Absorbs the old `after_step` inject semantics.)

### `:tape_write`
- **Input:** `entry` (a tape entry about to be appended)
- **Returns:** `{:cont, entry}` — **halt is disallowed at this stage**
- **Use:** field encryption, retention tagging, PII redaction at rest.
- **Rationale:** side effects for the turn (LLM call, tool execution)
  have already happened by the time `:tape_write` fires. Halting here
  would leave the system in a state where an action occurred but is
  not durably recorded. If a transformer must prevent recording, it
  should return a redacted/stub entry via `{:cont, stub_entry}` rather
  than halt. This keeps the tape's recorded-reality invariant intact.

### Ordering and effects

- Transformers registered with explicit priorities; applied in
  priority order at each stage.
- `{:cont, data}` passes (possibly mutated) data to the next
  transformer at the same stage.
- `{:halt, reason}` stops the *turn* (not just the transformer
  chain). The halt reason propagates to the caller.
- `{:deny, reason}` at `:tool_args_out` skips the tool call, appends
  a synthetic denial entry to the tape, and continues the turn.
- `{:inject, messages}` at `:post_step` appends the injected messages
  to the tape as user messages before the next turn.

Stage-specific return shapes mean each stage's contract is documented
at the type level, not scattered in prose.

### Elixir `@type` aliases (in `Rho.Transformer`)

```elixir
@type stage :: :prompt_out | :response_in | :tool_args_out
              | :tool_result_in | :post_step | :tape_write

@type prompt_out_data   :: %{messages: [message()], system: String.t() | nil}
@type prompt_out_result :: {:cont, prompt_out_data} | {:halt, term()}

@type response_in_data   :: %{text: String.t(), tool_calls: [tool_call()], usage: map()}
@type response_in_result :: {:cont, response_in_data} | {:halt, term()}

@type tool_args_data   :: %{tool_name: atom(), args: map()}
@type tool_args_result :: {:cont, tool_args_data} | {:deny, term()} | {:halt, term()}

@type tool_result_data   :: %{tool_name: atom(), result: term()}
@type tool_result_result :: {:cont, tool_result_data} | {:halt, term()}

@type post_step_data   :: %{step: non_neg_integer(), entries_appended: [entry()]}
@type post_step_result :: {:cont, nil} | {:inject, [message()]} | {:halt, term()}

@type tape_write_data   :: entry()
@type tape_write_result :: {:cont, entry()}   # no halt allowed
```

Each stage has a typed input and a typed return. Dialyzer will catch
mis-typed transformer implementations at compile time.

---

## TurnStrategy shape

```elixir
defmodule Rho.TurnStrategy do
  @callback run_turn(state, env) :: {:continue, entries, state}
                                  | {:done, entries}
                                  | {:final, value, entries}

  @callback prompt_sections([tool_def], Context.t()) :: [section]
  # Strategy-owned prompt shaping. Structured strategy uses this to
  # inject JSON-format instructions based on the active tool set.

  @optional_callbacks prompt_sections: 2
end
```

Strategies own the full turn, plus their own prompt shaping.

### Prompt section merge order

```
[ system prompt ]
[ plugin prompt_sections — contextual content (skills, bindings docs, tool hints) ]
[ strategy prompt_sections — format enforcement (JSON schema, XML tags) ]
[ tape-derived messages (user/assistant history) ]
```

**Rationale:** format-enforcement instructions are most effective
when they're the last thing the model reads before the user turn.
LLMs exhibit recency bias — a "respond as JSON with this schema"
instruction buried above 40 tool descriptions is regularly ignored,
but the same instruction placed immediately before the user message
holds. This ordering puts contextual plugin content earlier (where
it provides reference material) and strategy format rules later
(where they directly shape the next completion).

Plugin sections can override this default by returning a section with
an explicit `:position` hint (`:prelude` or `:postlude`), for the rare
case where a plugin needs its content nearest the model's response
(e.g., a critical safety directive). Default position is `:prelude`.

---

## Phase sequencing (revised)

Each phase is self-contained and leaves tests green. No flag gates — git
is the rollback. Order chosen so earlier phases unblock later ones and
deferred phases stay deferred until prerequisites are stable.

**Phase 1 — Tape renaming** (small, low risk, unblocks docs)
**Phase 2 — Plugin behaviour** (contribution role, `(opts, ctx)` signatures)
**Phase 3 — Transformer behaviour** (typed stages including `:post_step`)
**Phase 4 — Runner + TurnStrategy refactor** (collapse hook split, add strategy prompt hook)
**Phase 5 — Single event path** (tape appends emit bus signals; delete direct-pid broadcast)
**Phase 6 — Context struct audit + rename** (audit fields before minimising)
**Phase 7 — Documentation pass** (README, CLAUDE.md, example configs)

**Deferred (separate follow-ups):**
- **Session collapse** — remove `Rho.Session` module, use agent-ID
  prefix convention. Prerequisite: Registry prefix-query API,
  CLI/web/event-log bus-only consumption, equivalent `ask/3`
  coverage.
- **Namespace migration** (`Rho.Exec.*` / `Rho.Coord.*` / `Rho.Edge.*`)
  + xref boundary check. Separate structural concern from semantic
  concept cleanup.

### Branching strategy

Each phase lands as its own branch off `main`, merged sequentially:

```
main → refactor/phase-1-tape-rename → merge →
       refactor/phase-2-plugin-behaviour → merge →
       refactor/phase-3-transformer → merge → …
```

Rules:

- **One branch per phase.** Each phase is self-contained and leaves
  tests green, so one PR per phase keeps diffs reviewable and `main`
  always green.
- **Merge before starting the next phase.** Phases unblock each other
  (e.g. Phase 2's `Plugin` behaviour is a prerequisite for Phase 3's
  Transformer migration). Stacking unmerged branches creates rebase
  pain.
- **No long-lived integration branch.** `main` is the integration
  point. Sequential merges keep history linear.
- **Pre-phase hygiene.** Before branching for a phase, stash or land
  any unrelated WIP on `main`. Mixing refactor diffs with unrelated
  changes destroys reviewability.
- **Rollback = `git revert`** of the phase's merge commit. No flag
  gates, no parallel module paths — git history is the rollback
  mechanism.

Parity-gated phases (Phase 5, Phase 6) get extra scrutiny: the parity
test suite / field audit lands in the same PR as the phase deliverable,
not in a follow-up.

---

## Phase 1 — Tape renaming

**Problem.** `Rho.Memory`, `Rho.Tape`, `Rho.Mounts.JournalTools` all
name aspects of the same append-only event log.

**Fix.** Pick "tape." Rename:
- `Rho.Memory` → `Rho.Tape.Context` (builds LLM context from a tape)
- `Rho.Mounts.JournalTools` → `Rho.Tools.TapeTools`
- `memory_mod.build_context(tape_name)` call sites →
  `Rho.Tape.Context.build(tape_name)`
- `Rho.Tape.Store`, `Rho.Tape.Service`, `Rho.Tape.View` already fine

**Keep.** Config key `tape_name` and on-disk tape format unchanged.
`memory_module` config key accepted as alias.

**Deliverable.** Grep confirms zero `Memory` / `Journal` references
outside documentation footnotes.

---

## Phase 2 — `Plugin` behaviour (Mount split, part 1)

**Problem.** `Mount` mixes tools, prompt sections, bindings, lifecycle
hooks, and process ownership under one behaviour.

**Fix.** One narrow behaviour that owns *contribution* only:

```elixir
defmodule Rho.Plugin do
  @callback tools(keyword(), Context.t()) :: [tool_def]
  @callback prompt_sections(keyword(), Context.t()) :: [section]
  @callback bindings(keyword(), Context.t()) :: [binding]
  @optional_callbacks tools: 2, prompt_sections: 2, bindings: 2
end
```

`(opts, context)` signatures preserve per-instance opts. A plugin
implements whichever callbacks apply.

**Migration.**
- `Bash`, `FsRead`, `FsWrite`, `FsEdit`, `WebFetch`, `MultiAgent` → `tools/2` only
- `Python`, `Sandbox` → `tools/2` + `bindings/2`
- `Skills` (via `Rho.Skill.Plugin`) → `tools/2` + `prompt_sections/2`
- `Builtin`, `JournalTools` → whichever callbacks apply
- `StepBudget`, `Subagent` → migrate their capability side to
  `Plugin`; hook side moves to Phase 3 Transformer or Runner option

**Delete.** `children/2` from the old `Mount` behaviour. Modules owning
child processes expose a `Supervisor.child_spec/1` and get added to the
agent's supervision tree directly.

**Rename.** `Rho.MountRegistry` → `Rho.PluginRegistry` (explicitly
*not* `Rho.Registry`, which collides with `Elixir.Registry` and
`Rho.Agent.Registry`). `Rho.MountInstance` → `Rho.PluginInstance`.
Dispatch functions become `collect_tools/1`, `collect_prompt_sections/1`,
`collect_bindings/1`.

**Keep.** Atom shorthands in `.rho.exs` (`:bash`, `:fs_read`, …) resolve
to the same module list. Tuple syntax (`{:multi_agent, except: [...]}`)
continues to work.

**Deliverable.** `Plugin` behaviour defined; all contribution-only
modules migrated; `PluginRegistry` collects; per-instance opts flow
through to callbacks; atom + tuple config forms both resolve.

---

## Phase 3 — `Transformer` behaviour (Mount split, part 2)

**Problem.** PII scrubbing, content filtering, cost gating, audit
redaction, field encryption, tool-call denial, result replacement, and
post-step message injection — none of these fit `Plugin` (they don't
contribute input) and none fit async subscribers (they mutate data or
control flow in-flight).

**Fix.** Typed transformer stages with per-stage contracts (see
"Transformer behaviour: typed stages" above for full contracts).

**Migration of old hooks:**
- `before_tool` deny semantics → `:tool_args_out` with `{:deny, reason}`
- `after_tool` result replace → `:tool_result_in` with `{:cont, new_result}`
- `after_step` synthetic-message injection → `:post_step` with `{:inject, messages}`
- `before_llm` prompt modification → `:prompt_out`
- Purely passive observation → Bus subscriber

**Deliverable.** `Transformer` behaviour + Runner pipeline applying it
at all six stages + typed contract docs + migration of existing
hook-style plugins (StepBudget hook side, Subagent hook side).

---

## Phase 4 — `Runner` + `TurnStrategy`

**Problem.** `AgentLoop` and `Reasoner` split hooks and loop concerns
arbitrarily.

**Fix.** Strategy owns the turn. Runner drives the loop.

```elixir
defmodule Rho.TurnStrategy do
  @callback run_turn(state, env) :: {:continue, entries, state}
                                  | {:done, entries}
                                  | {:final, value, entries}

  @callback prompt_sections([tool_def], Context.t()) :: [section]
  @optional_callbacks prompt_sections: 2
end

defmodule Rho.Runner do
  def run(strategy, tape, plugins, transformers, opts)
  # opts: budget, compact_when, etc.
end
```

Runner responsibilities:
- Step budget as integer field
- Compaction as predicate field
- Apply Transformer stages at the right moments
- Apply `:tape_write` transformers before each append
- Loop until strategy returns `:done` / `:final` or budget exhausted

Strategy responsibilities:
- Build prompt (plugins' prompt sections + strategy's own sections + bindings)
- Call the LLM
- Dispatch tools (through `:tool_args_out` / `:tool_result_in` stages)
- Return entries

**Rename.** `Rho.Reasoner` → `Rho.TurnStrategy`. `Rho.Reasoner.Direct`
→ `Rho.TurnStrategy.Direct`. `Rho.Reasoner.Structured` →
`Rho.TurnStrategy.Structured`. Config key `reasoner:` aliased to
`turn_strategy:` (both accepted).

The Structured strategy uses `prompt_sections/2` to inject JSON-format
instructions based on the active tool set.

**Deliverable.** `AgentLoop` becomes a thin runner; strategies own
turns and their own prompt shaping; hooks fire from one place.

---

## Phase 5 — Single event path

**Problem.** `Agent.Worker` publishes to the signal bus *and*
broadcasts directly to subscriber pids.

**Fix.** Tape appends emit bus signals. Subscribers use the bus only.
Direct-pid fan-out deleted. Tape remains its own durable log with its
own schema — the bus is not the tape, but it is *driven by* tape
appends.

### Scope split

Phase 5 does two things:

**5a — Parity migration (blocking).** Move every current direct-pid
subscriber onto bus subscription. Delete the direct-pid path only
after parity is proven. This is the Phase 5 acceptance bar.

**5b — Operational signals (in scope for this phase).** The bus
section names operational signals (`:sap_repairs`, `:streaming_delta`,
`:turn_started`, `:turn_cancelled`, `:budget_warning`) that nothing
currently emits. Phase 5 wires up the minimum set needed to replace
direct-pid callers' current events — specifically whichever
operational signals the CLI / LiveView / SAP streaming already rely
on today. Additional operational signals (telemetry,
budget warnings) can land in follow-ups, but Phase 5 must not leave
the bus missing signals that subscribers need for parity.

### Parity gate (blocking prerequisite)

Before deleting any direct-pid code, a **parity test suite** must
prove each existing subscriber works identically over bus-only:

1. **CLI parity test.** `mix rho.chat` streams the same output with
   direct-pid path disabled as it does today.
2. **LiveView parity test.** Session projection, observatory, and
   spreadsheet live all render the same event sequence under
   bus-only.
3. **`Session.EventLog` parity test.** Event log captures the same
   entries from bus subscription as from the current dual path.
4. **SAP streaming parity test.** Structured-reasoner streaming (and
   Phase 7 of the SAP plan when it lands) emits the same mid-stream
   events to subscribers over the bus.

All four tests must be green *before* the `subscribers` field and
`broadcast/2` are removed. Failing any one blocks the delete.

**Migration order (strict):**
1. Audit current direct-pid subscribers and record the signals each
   one consumes.
2. Ensure each consumed signal is emitted via the bus (adds
   operational signals to the Worker where needed).
3. Add bus subscription to each subscriber alongside the existing
   direct-pid subscription (dual-running period — bus is the source
   of truth, direct-pid is verification).
4. Land the parity test suite. Run it.
5. Switch subscribers to bus-only (remove direct-pid subscription on
   the subscriber side).
6. Run parity suite again.
7. Only now: delete `subscribers` field and `broadcast/2` on the
   Worker.

**Deliverable.** Parity test suite (4 tests) green; operational
signals emitted for subscriber parity; `subscribers` field and
`broadcast/2` removed; no worker-held pid set; tape schema unchanged.

---

## Phase 6 — Context struct audit + rename

**Problem.** The ambient `Rho.Mount.Context` struct passes many fields;
some callbacks read only 2–3. Minimising without audit risks breaking
callers that read less-obvious fields.

**Fix.**
1. **Audit (blocking prerequisite).** Grep every `context.*` and
   `context[:…]` read across `lib/rho/` and `test/`. Record every
   field name with its readers. This audit has **not been done yet**
   and must happen before the struct can be finalised.
2. Rename `Rho.Mount.Context` → `Rho.Context`.
3. Keep fields that are read. Remove fields with zero readers.
4. Document each surviving field with a short purpose comment on the
   struct.

**Do not** guess the minimal field set. The critique correctly noted
candidates beyond the originally-proposed seven (`memory_mod`,
`user_id`, `opts[:emit]`, `prompt_format`) — the audit must find
these.

**Audit deliverable** (produced before the rename): a markdown file
`docs/context-field-audit.md` listing every field name, the modules
that read it, the modules that write it, and a keep/remove
recommendation. Reviewed before Phase 6 implementation begins.

**Phase deliverable.** `Rho.Context` struct with documented fields;
zero behaviour change; audit report noting removed fields.

---

## Phase 7 — Documentation pass

**Problem.** The refactor changes nearly every public-facing term.
Documentation using old vocabulary actively misleads.

**Documents to update:**

| File | Outdated terms to replace |
|---|---|
| `README.md` | "memory backend", `Rho.Memory` behaviour, `memory_module` config key, "Memory System" section header, `mounts:` language, `Rho.Mounts.MultiAgent`, "agent loop" narrative |
| `CLAUDE.md` | Mount architecture section, `MountRegistry` table, hook callback list, `AgentLoop` / `Reasoner` split explanation, memory module references, context-map spec |
| `.rho.exs` example | Comments for `mounts:`, `reasoner:` (show new + legacy aliases) |
| `docs/*.md` | Cross-references to renamed modules |
| `docs/schema-aligned-parsing-plan.md` | Uses `Reasoner`, `MountRegistry`, "mount hook" throughout. Sync with new vocabulary: `TurnStrategy`, `PluginRegistry`, "Transformer stage" or "Plugin". SAP emits `:sap_repairs` operational signals on the bus. |
| `docs/reasoner-baml-*.md`, `docs/tagged-removal-and-lenient-streaming-plan.md` | Update `Reasoner` → `TurnStrategy` cross-references |

### README rewrite targets

1. Opening paragraph: replace "pluggable memory backends" with
   "pluggable turn strategies over an append-only tape."
2. "Memory System" section → "Tape" section.
3. "Mounts" language → "Plugins" + "Transformers," with a short
   Transformer example (PII scrubber or denial policy).
4. "Multi-Agent Delegation": keep content; update module names.
5. Add a short architecture blurb near the top: Runner drives a
   TurnStrategy through a Transformer pipeline, appending to a Tape
   that emits Bus signals.

### CLAUDE.md rewrite targets

1. "Mount Architecture" section → "Plugin & Transformer Architecture."
2. Module tables split: Plugin implementers, Transformer
   implementers.
3. "Agent Loop" section split: Runner (loop, budget, compaction,
   Transformer dispatch) + TurnStrategy (turn-internal decision).
4. New "Transformer Pipeline" section: the six named stages and
   their typed contracts.
5. "Config System" section: update keys and document legacy aliases.
6. Add a "Migration from Mount/Memory/Reasoner" appendix enumerating
   all aliases (see alias table below).

### Rules for the doc pass

- Grep discipline after each code phase, not batched at the end.
- One name per concept in prose. Aliases appear only in the
  migration appendix.
- Every code snippet verified to compile.

**Deliverable.** README.md and CLAUDE.md use only the eight target
concepts in vocabulary. Every example snippet compiles. Migration
appendix enumerates every legacy alias.

---

## Deferred — Session collapse

**Not in this plan.** Separate follow-up.

### Prerequisites

- `Rho.Agent.Registry` gains a prefix-query API.
- CLI, web, and `Session.EventLog` all consume bus-only (Phase 5
  lands).
- `Session.ask/3` has an equivalent on the Worker or Bus.
- Agent-ID hierarchy convention (`s123/primary`,
  `s123/primary/coder_1`) rolled out and tested.

### Order of operations (when the follow-up kicks off)

1. **Extend Registry.** Add `prefix_query/1` to `Rho.Agent.Registry`
   that returns `[{agent_id, pid}]` for all entries whose id starts
   with a given prefix. ETS `:match` with a prefix pattern. Add
   property tests.
2. **Introduce hierarchical agent IDs.** Change primary agent id from
   `"primary_#{session_id}"` to `"#{session_id}/primary"`. Accept old
   form as alias during migration.
3. **Migrate delegated agent IDs.** Subagents currently registered
   with flat ids get hierarchical parents:
   `"#{session_id}/primary/coder_1"`.
4. **Add `Worker.ask/2`** (or equivalent) covering `Session.ask/3`.
5. **Rewrite Session callers.** `Session.submit/3`,
   `Session.subscribe/2`, `Session.agents/1`, `Session.stop/1` all
   become: look up primary by `"#{session_id}/primary"`, delegate
   to Worker; or prefix-query the Registry.
6. **Deprecate `Rho.Session`.** Add deprecation warnings. Keep
   module as a thin forwarding façade for one release cycle.
7. **Delete.** Remove the module after deprecation cycle.

Until these land, `Rho.Session` stays as a thin compatibility façade.

---

## Deferred — Namespace migration

**Not in this plan.** Separate follow-up.

`Rho.Exec.*` / `Rho.Coord.*` / `Rho.Edge.*` namespaces + xref boundary
check are a structural change independent of the semantic concept
cleanup. Doing them together risks conflating "what does this module
do?" with "which plane does this module belong to?" — they are
different questions.

### Trigger conditions (when the follow-up kicks off)

Start the namespace migration only when **all** of the following
hold:

- **No semantic-refactor PRs open.** Phases 1–7 have all merged and
  no concept-alignment work is in flight. Namespace migration moves
  every file; running it while semantic refactors are open
  guarantees merge conflicts.
- **Docs use new vocabulary.** README.md, CLAUDE.md, and every plan
  doc under `docs/` use the eight target concepts (verified by
  grep — zero `Memory`, `Mount`, `Reasoner`, `AgentLoop` references
  outside the migration appendix).
- **xref rules written and reviewed.** Before moving modules, write
  the `mix xref` boundary check (`Rho.Edge.*` cannot depend on
  `Rho.Exec.*`, etc.) and get sign-off on the rules. Moving files
  without a target rule set produces an unprincipled result.
- **Plane assignment documented.** Every existing module has been
  mapped to a target plane in a design note. No "we'll figure it out
  when we move it" modules.

After the semantic split stabilises and the triggers are met, a
separate plan introduces the planes and the xref check.

---

## Legacy aliases (explicit table)

Every alias accepted during and after the refactor:

| Domain | New | Legacy alias accepted |
|---|---|---|
| Config key | `plugins:` | `mounts:` |
| Config key | `transformers:` | (new — no legacy) |
| Config key | `turn_strategy:` | `reasoner:` |
| Module | `Rho.Tape.Context` | `Rho.Memory` (delegated) |
| Module | `Rho.Plugin` behaviour | `Rho.Mount` (delegated) |
| Module | `Rho.PluginRegistry` | `Rho.MountRegistry` (delegated) |
| Module | `Rho.PluginInstance` | `Rho.MountInstance` (delegated) |
| Config | `Rho.Tape.Context` projection binding | `:memory_module` |
| Atom shorthand | `:bash`, `:fs_read`, `:fs_write`, `:fs_edit`, `:web_fetch`, `:python`, `:skills`, `:subagent`, `:multi_agent`, `:sandbox`, `:journal`, `:step_budget` | Unchanged — continue to resolve to their respective modules |
| Tuple form | `{:multi_agent, except: [...]}`, `{:py_agent, module: ..., name: ...}`, etc. | Unchanged |

Aliases are documented in a single Migration Notes appendix, not
sprinkled through prose.

---

## Feature-preservation audit

Every current feature maps to a target concept or combination:

| Feature | Target |
|---|---|
| Tool use | `Plugin.tools/2` |
| Prompt injection (plugin) | `Plugin.prompt_sections/2` |
| Prompt injection (strategy, e.g. JSON-format) | `TurnStrategy.prompt_sections/2` |
| Variable bindings | `Plugin.bindings/2` |
| Per-instance plugin opts | `(opts, ctx)` callback signature + `PluginInstance` |
| Step budget | `Runner` option |
| Compaction | `Runner` option |
| Subagent lifecycle | Subagent capability's `execute` + `Transformer` if needed |
| PII scrubbing | `Transformer` at `:prompt_out` / `:response_in` / `:tool_args_out` / `:tool_result_in` |
| Content filtering | `Transformer` at `:response_in` or `:tool_result_in` |
| Tool-call denial | `Transformer` at `:tool_args_out` returning `{:deny, reason}` |
| Tool-result replacement | `Transformer` at `:tool_result_in` returning `{:cont, new_result}` |
| Synthetic message injection | `Transformer` at `:post_step` returning `{:inject, [message]}` |
| Audit redaction | `Transformer` at `:tape_write` |
| Cost / rate limiting | `Transformer` at `:prompt_out` returning `:halt` |
| Field encryption | `Transformer` at `:tape_write` |
| Multi-agent delegation | Worker-to-Worker via Bus |
| Session namespace | `Rho.Session` façade (collapse deferred) |
| Agent discovery | Registry (prefix-query API deferred with Session collapse) |
| Replay | Replay tape through Runner |
| UI streaming | Bus subscription |
| Telemetry | Bus subscription |
| Sandbox workspace | `Plugin` + `Supervisor.child_spec` |
| Cancellation | Runner-owned cancel ref |
| Structured parsing | `TurnStrategy.Structured` + SAP |
| Skill discovery | `Rho.Skill.Loader` (data + loader) |
| `skill` tool (dynamic loading) | `Rho.Skill.Plugin.tools/2` |
| "Available Skills" prompt section | `Rho.Skill.Plugin.prompt_sections/2` |

Nothing dropped. Nothing requires reinvention by callers.

---

## Acceptance criteria (behaviour-based)

After the refactor completes, these statements must hold:

1. **A plugin that only provides tools can be implemented in one
   module with one callback (`tools/2`).**
2. **A transformer can halt a turn at any of its five haltable stages
   (`:prompt_out`, `:response_in`, `:tool_args_out`,
   `:tool_result_in`, `:post_step`), and the halt reason propagates
   to the caller.** `:tape_write` disallows halt by contract.
3. **A transformer at `:tool_args_out` can deny a specific tool call
   without halting the turn; the denial is recorded in the tape.**
4. **A transformer at `:post_step` can inject a synthetic user
   message that the next turn sees.**
5. **A plugin implementation can read its per-instance opts from its
   callback arguments** (not from a global registry lookup).
6. **Adding a new turn strategy does not require modifying the
   Runner.**
7. **Adding a new subscriber type (new UI, new telemetry sink) does
   not require modifying any agent-side code** — only bus
   subscription.
8. **Replaying a tape through the same strategy + plugins with a
   stubbed (deterministic) LLM adapter produces a byte-identical
   sequence of tape entries.** (Real LLMs are nondeterministic; replay
   determinism is contractually scoped to the stubbed-adapter case.)
9. **Every example snippet in README.md and CLAUDE.md compiles
   against the current code.**
10. **Legacy config keys (`mounts:`, `reasoner:`, `memory_module`)
    continue to resolve correctly.**

---

## Non-negotiables

- No behaviour change for end users. All existing integration tests
  pass unchanged.
- `.rho.exs` surface stays compatible (atom shorthands, tuple forms,
  legacy keys).
- Tape on-disk format unchanged.
- `Rho.Session` callers continue to work (façade kept).

---

## Out of scope

- Umbrella-app split.
- Plane namespace migration (`Rho.Exec.*` / `Rho.Coord.*` / `Rho.Edge.*`).
- Session module collapse.
- `Rho.Context` minimisation beyond removing zero-reader fields.
- Restructuring the signal schema (`jido_signal` is load-bearing).
- Adding a ninth concept. If a future need doesn't fit one of the
  eight, re-examine the factoring before adding.
