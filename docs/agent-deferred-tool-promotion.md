# Self-promoting deferred tools

> Status: design proposal — not yet implemented.
> Supersedes the static `deferred:` plugin opt as the primary mechanism.

## The problem

Every tool we surface to the agent costs ~30–80 tokens in the BAML
action union (class definition + literal discriminant + parameter
fields). For a 20-tool plugin set, that's a flat ~1k tokens on every
turn — paid even when the agent uses two tools all day.

The current escape hatch is `deferred:` in `.rho.exs`:

```elixir
{:data_table, deferred: [:describe_table, :replace_all, :list_tables]}
```

`RhoBaml.SchemaWriter.to_baml/2` (line 76) drops these from the action
union. The token win is real, but the design has two failure modes
the recent `query_table` regression made obvious:

1. **The agent doesn't know they exist.** Nothing in the prompt lists
   deferred tools. The LLM sometimes guesses a name it remembers from
   training data, BAML coercion fails, and the user sees a stack trace
   instead of an answer.
2. **Promotion requires a human.** When a tool turns out to be needed
   (read-before-rewrite for proficiency edits), someone edits
   `.rho.exs` and reloads. The agent itself can't say "I need this
   one for what I'm about to do."

What we want: **the agent sees what's available, decides what it
needs, and pulls a tool into scope before calling it.** The cost
shifts from "every turn pays for every tool" to "the first turn that
needs a tool pays a one-step round-trip; subsequent turns pay nothing."

## What's already there

The mechanism is closer than it looks:

- `mark_deferred/2` in `rho_stdlib/lib/rho/stdlib/plugins/data_table.ex:248`
  stamps `deferred: true` on tool defs by name.
- `RhoBaml.SchemaWriter.to_baml/2` is the *single* consumer that
  filters them out of the BAML action union.
- `TurnStrategy.TypedStructured.run/3` regenerates the BAML schema
  **every turn** (`apps/rho/lib/rho/turn_strategy/typed_structured.ex:49`).
  So promotion doesn't require any new "rebuild" plumbing — it just
  needs an "enabled" set the schema writer can union with the
  always-on tools.
- `Rho.Runner.Runtime.tool_defs` is the static list built once per
  `run/2`. Promotion needs a mutable companion that evolves through
  the loop.

The work is mostly: where does the enabled set live, and what action
mutates it.

## Design options considered

### Option A — Tape-derived enabled set

Each turn, scan the tape for past `enable_tool` calls and rebuild the
enabled `MapSet`. No new state container.

- **Pro:** replays reproduce the enabled set automatically — no extra
  serialization concerns.
- **Pro:** zero new fields on Runtime/Context.
- **Con:** O(N) per turn over a growing tape. Probably fine in
  practice (tapes are short relative to LLM cost) but feels wasteful.
- **Con:** couples the mechanism to the tape format.

### Option B — Field on `Rho.Runner.Runtime`

Add `enabled_deferred_tools: MapSet.t()` to `Runtime`. The loop
threads an evolving runtime forward. The `enable_tool` action
returns instructions the loop applies before the next turn.

- **Pro:** localized to the runner; no changes to context plumbing.
- **Con:** Runtime is currently treated as immutable across the loop
  — `do_loop` re-uses the same runtime each step. Adding a mutable
  field means either threading a new runtime through the recursion
  or adding a per-step transform. Either way, a small ergonomic
  break.

### Option C — Field on `Rho.Context`

Context is already the ambient struct passed through every step and
every plugin/transformer callback (`apps/rho/lib/rho/context.ex`).
Add `enabled_deferred_tools: MapSet.t()`. The `enable_tool` action
returns a context update; the loop merges it.

- **Pro:** Context is *already* the place for cross-step ambient
  state; this is exactly its job.
- **Pro:** plugins/transformers that care can inspect it (e.g.
  prompt sections that list "currently enabled extras").
- **Con:** small Context surface growth. Acceptable.

### Option D — Agent worker GenServer state

The `Rho.Agent.Worker` holds the enabled set; passes it in on each
`run` call. Survives across multi-turn sessions naturally.

- **Pro:** matches OTP boundaries cleanly.
- **Con:** requires re-plumbing the agent boot path; more invasive
  than C.
- **Con:** tape replay needs explicit reconstruction of worker state.

## Recommendation: **Option C, plus a tape echo for replay**

Track `enabled_deferred_tools` on `Rho.Context`. The `enable_tool`
meta-action records the change to the tape (via a normal tool result
event) AND mutates the context for the next turn. Tape replay
reconstructs the set by replaying the same actions in order, so we
get Option A's replay safety without paying the per-turn scan.

This keeps:

- **The wire format clean**: enable_tool is just a tool. Its result
  is a confirmation message. Nothing magical at the BAML or LLM
  layer.
- **The mechanism centralized**: one chokepoint in `SchemaWriter`
  already filters; we change one line ("treat enabled deferred as
  visible") and the rest follows.
- **The state model honest**: enabled tools are part of the
  conversation context, not hidden in OTP state.

## The mechanism

### Three states for a tool

1. **Always-on** — included in every turn's action union from the
   start. Default for everything not in `deferred:`.
2. **Deferred** — listed by name + description in a prompt section;
   not in the action union; can be promoted.
3. **Enabled** — promoted by the agent via `enable_tool`. Behaves
   like always-on for the rest of the conversation.

### The `enable_tool` meta-action

```
enable_tool(name: "query_table", reason: "user asked me to convert
existing descriptions; I need to read them first.")
```

- `name` — string, must match a deferred tool's exact name.
- `reason` — short string for the tape (and for review). Optional
  but encouraged; the tape becomes self-documenting.

Returns either:

- `{:ok, "Tool query_table enabled. It will be available next turn."}`
- `{:error, {:unknown_tool, name, available_deferred: [...]}}`
- `{:error, {:not_deferred, name}}` (already always-on)

### The new prompt section

A new built-in prompt section, emitted by the `:typed_structured`
turn strategy (or a small helper plugin) when any tool is deferred:

```
## Deferred tools (call enable_tool to load before use)

  - query_table — Read data table rows by id list or filter.
  - describe_table — Data table shape: row count, columns, samples.
  - list_tables — List data tables with row counts.

Each costs ~50 prompt tokens per turn once enabled. Enable only what
you need; they remain enabled for the rest of the conversation.
```

The agent now has both **discovery** ("here's what I can pull in")
and **economics** ("each costs N tokens per turn") — so promotion is
a deliberate choice, not a guess.

### Where `enable_tool` lives

It's a runtime-provided tool (similar to `respond` and `think` in
the typed-structured BAML schema). Not a user-defined plugin tool.
The runner injects it into `tool_defs` whenever any plugin declares
deferred tools. If no plugin uses `deferred:`, `enable_tool` doesn't
appear at all.

## Implementation phases

Each phase compiles and ships independently.

### Phase 1 — Track enabled set + filter in writer

- Add `enabled_deferred_tools :: MapSet.t(String.t())` to
  `Rho.Context` (default `MapSet.new()`).
- Update `RhoBaml.SchemaWriter.to_baml/2` to take the enabled set as
  an option:

  ```elixir
  visible_defs =
    Enum.reject(tool_defs, fn td ->
      td[:deferred] && not MapSet.member?(enabled, td.tool.name)
    end)
  ```

- `TurnStrategy.TypedStructured.run/3` passes
  `runtime.context.enabled_deferred_tools` through the
  `write!`/`to_baml` opts.

At this phase the new field is plumbed but no action mutates it —
nothing changes behaviorally yet. Tests: a unit test that passes a
non-empty enabled set and asserts the corresponding tool variant
appears in the generated BAML.

### Phase 2 — `enable_tool` action + context update

- Add `enable_tool` as a runtime tool (alongside the existing
  internal `respond`/`think`/`finish`/`end_turn`). Lives in
  `apps/rho/lib/rho/stdlib/...` or directly in the runner injection
  path.
- Its execute fn validates `name` against the deferred tool list
  (collected from `runtime.tool_defs`), returns the appropriate
  ok/err, and emits a `{:context_update, %{add_enabled: name}}`
  signal that the runner applies before the next turn.
- Loop change: `do_loop` merges context updates between steps.

Tests:

1. `enable_tool(name: "query_table")` → next turn's BAML includes
   `QueryTableAction`. Idempotent (calling twice returns ok both
   times, no double-add).
2. `enable_tool(name: "edit_row")` (always-on) →
   `{:not_deferred, "edit_row"}`.
3. `enable_tool(name: "made_up_name")` →
   `{:unknown_tool, "made_up_name", available_deferred: [...]}`
   with the exact list.

### Phase 3 — Discovery prompt section

- A new prompt section that lists deferred tools by name + first
  line of description. Hides itself when no tools are deferred.
- Marks already-enabled deferred tools with a tag (e.g. `(enabled)`)
  so the agent doesn't re-enable redundantly.
- Hooks into the existing prompt-section pipeline — same surface as
  `data_table_index`.

Tests:

1. Section omitted when no tool is deferred.
2. Each deferred tool appears with its first-line description.
3. Already-enabled deferred tools are marked.

### Phase 4 — Migrate existing config

- Move `:spreadsheet`'s `deferred:` decisions to "agent gets to
  decide", except where the human still wants them hidden.
- Re-add `:query_table` to the deferred list in `.rho.exs` now that
  the agent can self-promote — the recent fix that made it
  always-on becomes unnecessary.

Tests: end-to-end smoke that the spreadsheet agent, given the
proficiency rewrite task, calls `enable_tool(name: "query_table")`
then `query_table(...)` then `edit_row(...)`.

### Phase 5 — System-prompt nudges

Update the `:spreadsheet` system prompt:

- "If you need a deferred tool, call `enable_tool(name: ...)` first
  — it will be available on the next step."
- Drop the explicit `query_table` guidance from the editing-rules
  block; replace with "if you need to read existing data, enable
  `query_table` first."

## Edge cases

- **Mid-conversation plugin set changes.** Not currently supported
  anyway; out of scope. If it becomes a thing, the writer's filter
  already handles missing names by simply not finding them in
  `tool_defs`.
- **Multi-agent delegation.** Child agents start with their own
  fresh `enabled_deferred_tools` (default empty). Parents' decisions
  don't leak. This is the right default — children are independent
  conversations.
- **Replay determinism.** As long as `enable_tool` calls are
  recorded as ordinary tool events on the tape, replay reproduces
  the same enabled set at each step. ✓
- **Concurrent promotion.** TypedStructured produces one action per
  step. Two `enable_tool` calls are sequential turns. Not a race.
- **`enable_tool` for `enable_tool`.** It must always be visible
  whenever any deferred tool exists; never deferred itself.
- **Direct turn strategy.** `TurnStrategy.Direct` doesn't use BAML
  unions — it relies on tool-call message format. Deferred filtering
  there happens at `req_tools` build time. Phase 1's filter change
  needs to land in both paths; the direct path is simpler (just one
  `Enum.reject` in runtime construction or per-turn assembly).

## Open questions

- **Auto-demote?** Tools enabled but unused for N turns get pruned
  from the active set. Saves tokens for "I needed it once" cases.
  My take: skip in v1. Adds complexity and the win is small unless
  conversations get very long. Reconsider if telemetry shows lots
  of one-shot enables.
- **Per-plugin promote?** `enable_plugin(name: "data_table")` to
  enable all deferred tools in one plugin. Cleaner ergonomics for
  "I'm about to do a bunch of table work" cases. Defer until we
  see whether agents actually want this — single-tool granularity
  matches the explicit-intent design philosophy.
- **Prompt section per turn vs. once?** The deferred-tools listing
  is volatile-ish (its "enabled" markers change), but the underlying
  list is stable. Mark it `volatile: false` to let prompt-cache hits
  carry over; flip the marker via a small per-turn appendix instead.
  Optimization, not blocking.

## Test plan (overall)

End-to-end through the public agent surface:

1. **Cold start.** Agent boots, BAML schema does NOT include any
   deferred tool's action variant. Token-counted: schema is N tokens
   smaller than the un-deferred baseline.
2. **Discovery.** First system prompt includes the "Deferred tools"
   section listing every deferred tool by name + description.
3. **Promotion.** Agent calls `enable_tool(name: "query_table")` →
   ok. Next turn's BAML includes `QueryTableAction`. Agent calls
   `query_table(...)`, gets rows.
4. **Persistence.** A turn later, `query_table` is still in the
   schema (sticky, until end of run).
5. **Bad input.** `enable_tool(name: "describe-table")` (typo with
   dash) → error with the available list.
6. **Replay.** Run a tape that includes `enable_tool` →
   `query_table`. Replayed agent's BAML schema at the
   `query_table`-step turn includes `QueryTableAction` deterministically.
7. **No-deferred plugin set.** With a plugin config that has nothing
   deferred, `enable_tool` does NOT appear in the action union; the
   discovery prompt section is empty/omitted. Zero overhead.

## What's NOT in scope

- **Disabling.** No `disable_tool`. If conversations grow stale
  enough that this matters, revisit alongside auto-demote.
- **Tool versioning.** A tool's parameter schema can't change
  mid-conversation. Out of scope for this design; would be its own
  lifecycle problem.
- **Cross-agent tool sharing.** Each agent is independent.
- **Per-user enabled sets.** State is per-conversation. If we ever
  want "agent X always has Y enabled for user Z", that's a config
  layer above this mechanism.

## Effort estimate

- Phase 1: ~50 lines (Context field + writer plumbing + one test).
- Phase 2: ~100 lines (action def + execute fn + loop merge + 3 tests).
- Phase 3: ~60 lines (prompt section + 3 tests).
- Phase 4: ~10 lines + manual verification.
- Phase 5: prompt edits only.

Total: a half-day of focused work, plus the e2e smoke test.

## When to NOT build this

If we never push past ~10 always-on tools and prompt-cache hit rate
is high, the static `deferred:` mechanism is fine. The cost-benefit
flips when:

- The plugin set grows past ~20 tools per agent, OR
- Specific tools need to "appear and disappear" by user intent
  rather than agent config, OR
- The agent class hallucinating tool calls becomes a recurring
  reliability issue.

The recent proficiency-edit incident is the third case. That alone
makes the case to build it.
