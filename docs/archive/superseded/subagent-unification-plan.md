# Subagent unification plan

**Status:** shipped (Phases 1–4 complete) • **Scope:** collapse `Rho.Plugins.Subagent.Worker` onto `Rho.Agent.Worker`

> Done. `Rho.Plugins.Subagent.Worker/.Supervisor/.UI` and `Rho.SubagentRegistry` are removed.
> `Rho.Plugins.Subagent` now spawns `Rho.Agent.Worker` via `Rho.Agent.Supervisor.start_worker/1`
> with hierarchical `agent_id`s (`<parent>/sub_<N>`). The `:tool_result_in` transformer reads
> completion from `Rho.Agent.Registry.children_of/1` (filtering `last_result != nil` and
> `reported_at == nil`) and dedupes via `mark_reported/1`. Collect flow:
> `Worker.collect/2` → `mark_reported` → `GenServer.stop(:normal)`. The `parent_emit` CLI chrome
> was deleted entirely (was already returning nil via the dropped `:opts` context field).

## Context

`Rho.Agent.Worker` is documented as "replaces both Session.Worker and Subagent.Worker", but
`Rho.Plugins.Subagent.Worker` is still a parallel process shape: own supervisor, own registry,
own ETS table, own depth/parent plumbing, own `collect/2` implementation. Two agent systems,
two lifecycles, two ways to query "who is running right now?".

Post-unification, `Rho.Plugins.Subagent` becomes a thin plugin that just wraps the same
`Rho.Agent.Worker` / `Rho.Agent.Supervisor` used by `Rho.Mounts.MultiAgent`.

## Divergences between the two worker shapes

| Dimension | `Plugins.Subagent.Worker` | `Agent.Worker` |
|---|---|---|
| Supervision | own `Subagent.Supervisor` (DynamicSupervisor) | `Agent.Supervisor` (DynamicSupervisor) |
| Registry | `Rho.SubagentRegistry` (keyed by `subagent_id`, value = `parent_tape`) | `Rho.AgentRegistry` (keyed by `agent_id`) + ETS `Rho.Agent.Registry` (rich metadata) |
| Identity | `subagent_id = "sub_<int>"` | hierarchical `agent_id` (encodes parent chain) |
| Parent link | `parent_tape` field + `parent_agent_id` (the dropped field) | derived from `agent_id` via `Primary.parent_of/1` |
| Depth | stored in state | derived from `agent_id` (post-task-1 refactor) |
| Execution | single `Task.async` running `Rho.AgentLoop.run/3` once, no mailbox | mailbox of signals, repeated turns, cancellable |
| `collect` | deferred GenServer reply, returns `{:ok, text} \| {:error, reason}` | `Worker.collect/2` exists — needs parity check |
| Status tracking | ETS table `:rho_subagent_status` keyed by `{subagent_id, parent_tape, :done, result}` | `Agent.Registry` ETS, live process info |
| UI (parent chrome) | `Plugins.Subagent.UI` renders "active children of parent X" (CLI) | n/a — chat UI driven by signal bus |
| Context | `subagent: true` in context → `PluginRegistry.apply_stage/3` skips all stages | regular context → stages apply |
| Fork/merge tapes | `memory_mod.fork/2` + `memory_mod.merge/2` if `inherit_context: true` | n/a (each agent has its own tape) |
| Tool resolution | inline `requested_tool_modules/2` that cherry-picks mounts by name | resolved via plugin registry during Runner build |
| Events emitted | `rho.agent.started`, `rho.agent.stopped`, `rho.session.*.events.*`, plus `parent_emit` callback into CLI | same signal set, owned by Worker |
| Concurrency cap | `@max_concurrent = 5` per parent_tape | n/a (session-level cap in MultiAgent) |
| Completion poll | `:tool_result_in` transformer checks ETS, appends notices | n/a |

## Consolidation strategy

**Goal:** the `spawn_subagent` / `collect_subagent` tools spawn `Rho.Agent.Worker` instances via
`Rho.Agent.Supervisor.start_worker/1` using hierarchical agent_ids, and reuse its existing
`collect/2`. Kill `Rho.Plugins.Subagent.Worker`, `.Supervisor`, `Rho.SubagentRegistry`, and the
`:rho_subagent_status` ETS table. Keep the `Rho.Plugins.Subagent` tool surface and the
`:tool_result_in` completion-notice transformer (re-pointed at `Agent.Registry`).

### Semantics we must preserve

1. **Same `collect`/deferred-reply contract** — callers of `collect_subagent` still block until
   the child finishes, then the worker is stopped (child exits, result returned).
2. **Completion notices** — when parent issues any tool call, the `:tool_result_in` transformer
   still appends `[subagent <id> finished: <preview>]` for children done since last check.
3. **Per-parent concurrency cap** — `@max_concurrent = 5` active children for one parent.
4. **CLI chrome** — `parent_emit` callback receives `subagent_progress`/`subagent_tool`/
   `subagent_error` and `Plugins.Subagent.UI` renders active children.
5. **`inherit_context` semantics** — fork parent tape if requested, else fresh tape.
6. **Subagent lifecycle passthrough** — subagent turns skip plugin stages (currently via
   `context.subagent = true`).

### Semantics we can drop

- **Own registry keyed by parent_tape.** Replaced: derive children from `agent_id` prefix.
  `Agent.Registry` already has `find_by_session/1`; we'd add a `children_of/1` that filters by
  `agent_id` prefix (`<parent>_sub_*` or similar).
- **ETS `:rho_subagent_status` table.** Replaced: `Agent.Registry.get/1` reports status, and
  `Agent.Worker.info/1` has `status` + `last_result`. Completion notices read from Registry
  (see "Completion notice re-wiring" below).
- **`parent_agent_id` / `parent_tape` fields in state.** Already derivable from agent_id / tape
  convention.

### Identity scheme

Choose one (recommend **A**):

- **A. Hierarchical agent_id.** `parent_agent_id <> "/sub_" <> int` (or similar separator).
  `Primary.parent_of/1` walks up the chain. `Agent.Registry` gains `children_of(parent_id)`
  that scans live entries and filters by `String.starts_with?/2` (admin-path, acceptable).
- **B. Keep opaque `sub_<int>` + explicit parent field in Registry metadata.** Less clean —
  contradicts the hierarchical-id direction task 1 already moved toward.

Going with **A** keeps the system coherent with `Rho.Agent.Primary.depth_of/1`,
`parent_of/1`, and `find_by_session_prefix/1`.

### Completion notice re-wiring

Today's `:tool_result_in` handler in `Rho.Plugins.Subagent`:

```elixir
def transform(:tool_result_in, %{result: result} = data, %{tape_name: tape_name}) ...
  case check_completed(tape_name) do ...
```

Post-unification:

1. Parent's `agent_id` is in context (not `tape_name`).
2. `check_completed/1` queries `Agent.Registry.children_of(parent_agent_id)` and filters for
   `status: :done`.
3. Notice-preview needs a way to get the result text; add `Agent.Registry.last_result/1` or
   embed it in the ETS row on turn finish (Worker already has the info).
4. After reporting, we either (a) auto-stop the child (preserves "collect = consume" semantics
   when parent notices without explicit collect) or (b) mark-as-reported to avoid dupes. Prefer
   (b) via a `reported_at` Registry field — `collect_subagent` still stops the worker.

### Module/file changes

**Delete:**
- `lib/rho/plugins/subagent/worker.ex`
- `lib/rho/plugins/subagent/supervisor.ex`
- `Rho.SubagentRegistry` registration in `application.ex`
- ETS `:rho_subagent_status` setup
- `test/rho/plugins/subagent*` worker-specific tests (keep plugin-level tests, rewritten)

**Modify:**
- `lib/rho/plugins/subagent.ex`
  - `do_spawn/6` → build child agent_id, call `Agent.Supervisor.start_worker/1` with
    `system_prompt`, `memory_ref: tape_name`, role: `:subagent`, depth derived by Worker.
  - `execute_collect/2` → `Worker.collect(pid, timeout)` then `GenServer.stop(pid, :normal, …)`.
  - `active_children_of/1` → `Agent.Registry.children_of(parent_agent_id)` filtered by alive +
    status != :done.
  - `:tool_result_in` → use parent `agent_id` from context, query Registry for done children.
  - `requested_tool_modules/2` — can it be replaced by routing tool-list through
    `PluginRegistry.collect_tools/1` scoped to the child context? Investigate; if yes, drop it.
- `lib/rho/agent/registry.ex`
  - Add `children_of(parent_agent_id) :: [info]` (prefix scan over ETS, same pattern as
    `find_by_session_prefix/1`).
  - Add `last_result` / `reported_at` optional fields.
- `lib/rho/agent/worker.ex`
  - Ensure `info/1` and/or terminate publishes final-result into Registry ETS so
    `:tool_result_in` can render notices without a GenServer call to a possibly-dead worker.
  - Confirm `collect/2` works for a worker whose status reaches `:done` — add deferred-reply
    path if absent.
- `lib/rho/application.ex`
  - Remove `Rho.SubagentRegistry` child and Subagent.Supervisor child.
- `lib/rho/cli.ex` — unchanged if `parent_emit` routing is preserved (see below).
- `lib/rho_web/*` — check LiveView subscribes to subagent events by `agent_id`; should Just
  Work once children publish under `rho.session.<sid>.events.*` with their own `agent_id`.

**Parent-emit bridging.** ~~The current `parent_emit` callback lives outside the bus~~
**Resolved:** dropped entirely. `ctx[:opts][:emit]` was already returning `nil` since
`Rho.Context` has no `:opts` field, so the callback was dead code. CLI subscribes to
`rho.session.<sid>.events.*` via the bus.

### `subagent: true` passthrough

`PluginRegistry.apply_stage/3` currently short-circuits when `context.subagent == true`.
Post-unification, `Rho.Agent.Worker` (which runs the child) builds its own context for
`Rho.Runner.run/3`. We must:

- Pass a flag from the spawning plugin telling the worker to mark its Runner-context as
  `subagent: true`. Simplest: `Agent.Worker.start_worker/1` takes `subagent: true` opt,
  threads it into its Runner invocation.
- Alternatively derive from `role: :subagent` — but `MultiAgent` also spawns non-primary
  workers and may or may not want stages applied. Leave `subagent:` as an explicit opt.

### Test impact

- `test/rho/plugins/subagent_test.exs`, `test/rho/plugins/subagent/*_test.exs` — rewrite to
  spawn via `Agent.Supervisor.start_worker/1` semantics.
- `test/rho/agent/*` — add tests for `Registry.children_of/1`, `last_result` propagation.
- Integration: verify CLI still prints subagent chrome; LiveView still shows child traces.

## Phasing

| Phase | Deliverable | Tests to keep green |
|---|---|---|
| 1 | ~~Add `Agent.Registry.children_of/1` + `last_result` field, with tests~~ ✅ | Existing suite |
| 2 | ~~`Agent.Worker` supports `subagent: true` opt threaded into Runner context; add `collect/2` parity if missing~~ ✅ | Existing suite |
| 3 | ~~Rewrite `Rho.Plugins.Subagent` to spawn `Agent.Worker`~~ ✅ (done without feature flag) | Full suite |
| 4 | ~~Remove `Plugins.Subagent.Worker`, `.Supervisor`, `Rho.SubagentRegistry`, ETS table~~ ✅ | Full suite |

## Open questions

1. Should nested subagent cleanup happen via `Agent.Supervisor` child-of traversal (new), or
   via `terminate/2` walking `agent_id` children explicitly?
2. Does `fork/merge` semantics want to live in the plugin or the Worker? Probably plugin — it's
   a subagent-specific concern, not a primary-agent concern.
3. Should the CLI chrome move to the bus in this PR, or stay as `parent_emit`? Recommend later.
4. Naming collision: `Rho.Agent.Worker` has a `role` field — `:subagent` is already used by
   `Plugins.Subagent.Worker` init. `MultiAgent` spawned workers use role atoms like
   `:researcher`. Ok to reuse `:subagent` for plugin-spawned children.

## Blast radius estimate

- **Process tree:** one DynamicSupervisor + one Registry removed.
- **Lines:** delete ~500 (Subagent.Worker + .Supervisor + tests); add ~150 across
  `Agent.Registry`, `Agent.Worker`, and slimmer `Plugins.Subagent`.
- **Caller changes:** only `Rho.Plugins.Subagent` directly — the public tool surface
  (`spawn_subagent`, `collect_subagent`) stays identical.
