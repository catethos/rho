# Kernel Minimisation Plan (v2)

**Date:** 2026-04-26 · **Branch:** `refactor`
**Supersedes:** the v1 plan (pre-Reasoner→TurnStrategy rename, pre-`Rho.Events` migration).

---

## What Changed Since v1

The v1 plan referenced an architecture that no longer exists. The combined
simplification plan (Phases 0–13) reshaped the kernel:

| v1 plan referenced | Current name |
|--------------------|--------------|
| `Rho.AgentLoop` | `Rho.Runner` |
| `Rho.Reasoner.Direct` | `Rho.TurnStrategy.Direct` |
| `Rho.Mount` / `Rho.MountRegistry` | `Rho.Plugin` / `Rho.PluginRegistry` + `Rho.Transformer` / `Rho.TransformerRegistry` |
| `Rho.Mount.Context` | `Rho.Context` |
| `Rho.Lifecycle` | (deleted — transformers replace it) |
| `Rho.Comms` (signal bus) | `Rho.Events` (Phoenix.PubSub-based) |

### What's already done (no longer in scope)

- ✅ **v1 Phase 5 — Single event path.** `Worker.build_emit/2` (`worker.ex:833`)
  publishes only to `Rho.Events.broadcast`. No `subscribers` map, no
  `@high_freq_event_types` filtering, no dual-broadcast plumbing. Done by
  combined-simplification Phase 10.
- ✅ **Reasoner/AgentLoop rename.** Pluggable strategy via `Rho.TurnStrategy`
  behaviour with `Direct` and `TypedStructured` implementations.
- ✅ **Lifecycle hooks.** Replaced by `Rho.Transformer` with six stages
  (`:prompt_out`, `:response_in`, `:tool_args_out`, `:tool_result_in`,
  `:post_step`, `:tape_write`). The `:post_step` stage already returns
  `{:cont, nil} | {:inject, [msg]} | {:halt, reason}` — exactly the shape
  v1 Phase 2 needed.

### What's still ugly (in scope)

| Smell | Location | Acceptance criterion |
|-------|----------|----------------------|
| Hardcoded terminal tool names | `runner.ex:131,501,782` | `grep '"finish"\|"end_turn"\|"create_anchor"\|"clear_memory"'` returns 0 hits in `apps/rho/lib/rho/runner.ex` and `tool_executor.ex` |
| `subagent` boolean flag threaded through kernel | 12 sites across `run_spec.ex`, `context.ex`, `runner.ex`, `worker.ex` | `grep -rn 'subagent'` in `apps/rho/lib` returns 0 hits |
| Signal type strings hardcoded in Worker | `worker.ex:763,782,795` | `grep '"rho.task.requested"\|"rho.message.sent"'` in `worker.ex` returns 0 hits |
| Direct-command (`,tool args`) syntax | `worker.ex:316,748,952` | `grep '"," <> '` in `worker.ex` returns 0 hits |
| String-matching tool error classification | `turn_strategy/shared.ex:99–120`, called from `tool_executor.ex:259` | `classify_tool_error` deleted |
| Vestigial `Rho.Stdlib.Builtin` | `apps/rho_stdlib/lib/rho/stdlib/builtin.ex` | Module deleted (or repurposed) |

---

## Why Bother

**Honest framing:** This is technical-debt cleanup. The kernel works. Tests
pass. Users see no direct improvement. Defer if heads-down on features.

**Real benefits, ordered by payoff:**

1. **Subagents currently bypass all transformer hooks.** A global rate
   limiter, budget enforcer, or observability transformer doesn't apply to
   subagent turns because Phase 2's `subagent` flag short-circuits the
   pipeline. This is a silent correctness gap, not just a code smell.
   Phase 2 below fixes it.
2. **Each new TurnStrategy must remember the `subagent` flag.** When
   `TypedStructured` was added, the conditional re-appeared. The next
   strategy will too unless we collapse the flag.
3. **`MultiAgent` is half-baked into the kernel.** Worker contains the
   *receive* side of inter-agent messaging; the plugin contains the
   *send* side. A non-multi-agent build of Rho is impossible.
4. **Adding a new terminal tool requires editing the kernel.**
   `@terminal_tools` is a static list; `{:final, _}` already works for
   any tool but coexists redundantly.
5. **Smaller kernel = faster onboarding** and easier to publish `apps/rho`
   as a standalone library.

**Non-benefits:**
- No latency improvement.
- No new user-facing features.
- No bug fixes (except the silent subagent-lifecycle gap).

---

## Target State

After all phases:

```
Rho.Runner
  ├── step counting + max-steps + compaction
  ├── system prompt assembly (via PluginRegistry, no strategy-specific branches)
  ├── transformer pipeline dispatch (:prompt_out → strategy → :post_step)
  ├── tape recording via Recorder
  └── event emission via Rho.Events

Rho.TurnStrategy.Direct
  ├── LLM call + stream retry
  ├── transformer dispatch :tool_args_out / :tool_result_in
  ├── tool execution via ToolExecutor
  └── return {:respond, text} | {:tools, calls} | {:halt, reason}
      (no subagent branching, no error string-matching)

Rho.Agent.Worker
  ├── GenServer shell (init, terminate, trap_exit)
  ├── turn management (start, queue, process)
  ├── signal receipt → PluginRegistry.dispatch_signal
  └── event emission via Rho.Events

Rho.PluginRegistry
  ├── tools / prompt_sections / bindings
  └── handle_signal (new)

Rho.TransformerRegistry
  └── 6 stages — unchanged
```

No tool names. No signal types. No subagent flags. No CLI syntax. A
kernel readable in one sitting.

---

## Phase Plan

**Progress key:** `[ ]` not started · `[~]` in progress · `[x]` done

Phases are ordered by value/effort ratio. 1, 4, 6, 7 are cheap and
independent. Phase 2 is the structural win; Phase 3 pairs with it.

### [x] Phase 1: Tool-driven termination (≤2h) — done in cf17f22

**Goal:** Tools self-declare end-of-loop via `{:final, value}`.
Drop `@terminal_tools`.

1. `Rho.Stdlib.Tools.Finish.execute/2` already returns `{:final, args["result"]}`
   (verify) — no changes needed if true.
2. Update `Rho.Stdlib.Tools.EndTurn`, `Anchor`, `ClearMemory` to return
   `{:final, value}` instead of `{:ok, value}`.
3. Delete `@terminal_tools` and the two `MapSet.intersection` calls in
   `runner.ex:501` + `runner.ex:782`. The existing `{:final, _}` handling
   in `ToolExecutor` already terminates the loop.

**Tests:** Characterisation tests first — for each terminal tool, assert
the loop terminates. Must pass before and after.

**Risk:** Low. Removes redundancy.

### [x] Phase 4: Delete direct-command syntax (≤1h) — done in cf17f22

**Goal:** `,tool args` syntax is dead code — `rho_cli` was the only consumer
and is gone. **Pure deletion**, not extraction (v1 plan called for CLI
extraction, no longer needed).

1. Delete `handle_call({:submit, "," <> command, _opts}, ...)` clause
   (`worker.ex:316`).
2. Delete the `{:value, {"," <> command, ...}}` branch in `process_queue/1`
   (`worker.ex:748`).
3. Delete `run_direct_command/3` (`worker.ex:952`) and
   `execute_direct_command/3`.
4. Delete `Rho.Config.parse_command/1` if no remaining callers.

**Tests:** Run full suite. No behavior change expected.

**Risk:** Negligible. ~70 lines, zero callers in the repo.

### [x] Phase 6: Typed tool errors (1d) — built-ins migrated; `classify_tool_error/1` deleted (no third-party consumers, skipped the release-cycle wait)

**Goal:** Drop `classify_tool_error` string-matching from `TurnStrategy.Shared`.

1. Define convention: tools return `{:error, reason}` where `reason` is an
   atom or `{atom, detail}`. Examples:
   `{:error, :timeout}`, `{:error, {:not_found, "/foo"}}`,
   `{:error, {:permission_denied, path}}`.
2. Migrate built-in tools in this order: `Bash` → `FsRead/Write/Edit` →
   `WebFetch` → `Python` → `Sandbox`. Each PR keeps tests green.
3. Add a `Logger.warning` in `TurnStrategy.Shared.classify_tool_error/1`
   when called with a bare string — visibility for third-party tools that
   haven't migrated. Keep this for one release cycle.
4. Once all built-ins are migrated and the warning has been quiet, delete
   `classify_tool_error/1` (`turn_strategy/shared.ex:99–120`). The
   `tool_executor.ex:259` call site passes the atom through directly as
   `error_type`.

**Tests:** Per-tool: assert errors are atoms. Reasoner test: assert atom
passthrough.

**Risk:** Low. Forcing function (the warning) prevents the
"both mechanisms forever" failure mode.

### [x] Phase 2: Subagent flag → `:post_step` transformer (1–1.5d) — done in cf17f22

**Goal:** Remove the `subagent` boolean from kernel. Subagents are agents
at `depth > 0`; the nudge becomes a transformer policy.

**Architecture choice:** Add `Rho.Stdlib.Transformers.SubagentNudge`
implementing `:post_step`. When `depth > 0` and the previous step result
was a text-only assistant response (no tool calls), the transformer
returns `{:inject, [nudge_msg]}` to continue the loop. Otherwise
`{:cont, nil}`.

This was chosen over alternatives because:
- The `:post_step` stage already exists and returns the right shape.
- Transformers are scoped — agents that don't include this transformer
  don't get the behavior, making it opt-in.
- No kernel changes to add the policy.

**Changes:**

1. Create `Rho.Stdlib.Transformers.SubagentNudge` with `:post_step` callback.
   Logic: if `context.depth > 0` and the step yielded a text response with
   no tool calls, inject the nudge message; otherwise pass through.
2. Register the transformer in any agent profile that spawns subagents
   (the existing `MultiAgent` plugin can register it as a side-effect of
   being included).
3. Delete the `if runtime.subagent` branch in `runner.ex:662–678`.
   `handle_strategy_result({:respond, text}, ...)` becomes a single path:
   record text, return `{:done, %{type: :response, text: text}}`.
4. Delete the `subagent` field from:
   - `Rho.RunSpec` struct (`run_spec.ex:96,120`)
   - `Rho.Context` struct (`context.ex:59`)
   - `Rho.Runner.Runtime` struct (`runner.ex:96`)
5. Delete `subagent` plumbing in `runner.ex:174,182,208,223,243,258` and
   `worker.ex:54,248,657,666,926`. Use `Rho.Agent.Primary.depth_of/1`
   wherever the distinction is needed.
6. Delete the `subagent` reference in the `LLM.Admission` docstring
   (`llm/admission.ex:14`) — no logic change, just a comment.

**Tests:**
- New: agent at `depth > 0` with `SubagentNudge` transformer registered
  → text response triggers nudge injection → loop continues.
- New: agent at `depth > 0` *without* the transformer → text response
  terminates normally (proves nudge is policy, not kernel).
- New: agent at `depth = 0` with the transformer → text response
  terminates normally (proves depth gating).
- Update existing subagent tests: assertion shifts from "kernel injects
  nudge" to "transformer injects nudge".

**Risk:** Medium. All ~12 sites must land in one PR — partial completion
leaves the kernel inconsistent. Subagent end-to-end tests in
`MultiAgent`-using flows are the regression guard.

### [x] Phase 3: Plugin signal-handler callback (1d) — done in 081009d

**Goal:** Drop hardcoded signal-type strings from Worker. Plugins handle
their own signals via the registry.

**Architecture choice:** Add an optional `handle_signal/3` callback to
`Rho.Plugin` behaviour with return shape:

```elixir
@callback handle_signal(signal :: map, opts :: keyword, context :: Rho.Context.t()) ::
            {:start_turn, content :: String.t(), opts :: keyword()}
          | {:update_state, (state -> state)}
          | {:emit, signal_type :: String.t(), payload :: map()}
          | :ignore
```

`Rho.PluginRegistry` adds `dispatch_signal(signal, context)` that iterates
registered plugins and returns the first non-`:ignore` result. The four
return variants keep the door open for future handlers without forcing
"start a turn" semantics.

**Changes:**

1. Add `handle_signal/3` to `Rho.Plugin` (optional callback).
2. Add `Rho.PluginRegistry.dispatch_signal/2`.
3. Implement `handle_signal/3` in `Rho.Stdlib.Plugins.MultiAgent` for
   `"rho.task.requested"` and `"rho.message.sent"`. The
   `format_incoming_message/2` helper in `worker.ex:797–830` moves to
   the plugin.
4. Replace the three `process_signal/2` clauses in `worker.ex:763–795`
   with a single dispatch:
   ```elixir
   defp process_signal(signal, state) do
     ctx = build_context(state, agent_depth(state))
     case Rho.PluginRegistry.dispatch_signal(signal, ctx) do
       {:start_turn, content, opts} -> start_turn(content, opts, state)
       {:update_state, fun}         -> fun.(state)
       {:emit, type, payload}       -> Rho.Events.broadcast(...); state
       :ignore                      -> state
     end
   end
   ```
5. Optional: extract a `Rho.Events.Topics` module with helpers like
   `inbox_topic(session_id, agent_id)`. ~6 inline string constructions
   today; centralising them prevents drift.

**Tests:**
- Worker with no signal-handling plugins → all signals ignored.
- Plugin returning `{:start_turn, ...}` → turn starts.
- Move existing signal-handling assertions from Worker tests to MultiAgent
  plugin tests.

**Risk:** Low-medium. The handler logic is straightforward to relocate.
Existing inter-agent end-to-end tests are the regression guard.

### [x] Phase 7: Cleanup sweep (≤1h)

**Goal:** Drop vestigial code exposed by other phases.

1. Delete `Rho.Stdlib.Builtin` (14 lines, zero callbacks, only `resolve_session/1`
   which isn't a behaviour callback). Verify no callers first.
2. Audit `apps/rho/test/support/turn_strategy_harness.ex` for `subagent`
   field references — update to drop the field.
3. Search for any `# subagent:` comments or docstrings referencing the
   deleted flag. Update or remove.

**Risk:** Negligible.

---

## Sequencing

```
Phase 1 (terminal tools)       — standalone
Phase 4 (delete direct cmds)   — standalone
Phase 6 (typed errors)         — standalone, can run in parallel
Phase 2 (subagent flag)        — depends on Phase 1 (Finish returns {:final, _})
Phase 3 (signal handlers)      — independent, but pairs naturally with Phase 2
Phase 7 (cleanup sweep)        — last
```

**Recommended cadence:**

- **Quick-win batch (½ day):** Phase 4 → Phase 1. ~150 lines deleted, no
  behavior change. Single PR.
- **Phase 6 (1 day):** Migrate built-in tools to typed errors. One PR
  per tool batch is fine.
- **Phase 2 (1–1.5 days):** Subagent flag removal. One PR, all sites.
  Bisect-friendly because every commit must keep tests green.
- **Phase 3 (1 day):** Plugin signal handlers. Independent PR.
- **Phase 7 (≤1h):** Sweep.

**Total:** ~3–4 days of work, ~1100 lines removed from kernel, biggest
behavior change is "subagents now run transformer hooks".

---

## Acceptance Criteria

The plan is complete when all of the following return zero hits in
`apps/rho/lib/`:

```
grep -rn 'subagent'
grep -rn '@terminal_tools\|"create_anchor"\|"clear_memory"\|"finish"\|"end_turn"' apps/rho/lib/rho/runner.ex apps/rho/lib/rho/tool_executor.ex
grep -rn '"rho.task.requested"\|"rho.message.sent"' apps/rho/lib/rho/agent/worker.ex
grep -rn '"," <> ' apps/rho/lib/rho/agent/worker.ex
grep -rn 'classify_tool_error'
```

And:
- `Rho.Stdlib.Builtin` deleted.
- All existing tests pass.
- New characterisation tests cover terminal tools, subagent nudge
  transformer, and plugin signal dispatch.
- File line counts: `worker.ex` ≤ 700 (down from 1005), `runner.ex`
  ≤ 750 (down from 884). Direct.ex unchanged (already 163, well under
  any target).

---

## Rollback Strategy

Each phase is a single PR. If a phase regresses after merge:

| Phase | Rollback |
|-------|----------|
| 1 | Revert. Restore `@terminal_tools` MapSet. |
| 4 | Revert. Code was dead anyway, but trivial restore. |
| 6 | Revert per-tool batch. The forcing-function `Logger.warning` makes regressions visible during the transition window. |
| 2 | Revert the entire PR. Subagent flag removal is atomic — partial revert leaves an inconsistent kernel. |
| 3 | Revert. Signal handlers return to Worker; `Rho.Events.Topics` module (if added) can stay (additive). |
| 7 | Revert. |

---

## What's Next: After Kernel Minimisation

Once the kernel is minimal, three directions open up that aren't
practical today:

### A. Carve `apps/rho` out as a standalone library

The kernel would be small enough (~3500 LOC down from ~6000) and clean
enough (no multi-agent baked in, no CLI vestiges) to publish on Hex as
a standalone agent runtime. `apps/rho_stdlib/` becomes a separate
`rho_stdlib` package depending on it. Consumers get a minimal Rho
without the BAML/structured-output/multi-agent surface area unless they
opt in.

**Prerequisite work:**
- Move `apps/rho/lib/mix/tasks/` mix tasks into a `rho_dev` package or
  the umbrella root (they reference `RhoFrameworks` indirectly via
  `Rho.AgentConfig`).
- Audit `apps/rho/` for any remaining `Rho.Stdlib.*` references in test
  setup.
- Decide on a versioning policy and write a CHANGELOG.

### B. Add a third TurnStrategy

With the `subagent` flag gone, adding a new strategy becomes a real
extension exercise rather than a copy-paste-and-remember-to-add-the-flag
exercise. Candidates:

- **`TurnStrategy.MultiModal`** — image/audio inputs, vision model calls.
- **`TurnStrategy.HumanInLoop`** — pause and wait for human approval on
  tool calls above a risk threshold; resumes via a signal handler
  (which Phase 3 makes pluggable).
- **`TurnStrategy.Plan`** — explicit plan-then-execute pattern with a
  separate planning model (cheaper) and execution model (smarter).

### C. Telemetry/observability layer

With Phase 6 done (typed errors) and Phase 3 done (single signal
dispatch path), `:telemetry.execute/3` calls fall naturally into:

- `[:rho, :turn, :start | :stop | :exception]`
- `[:rho, :tool, :start | :stop | :exception]` with `error_type` atom
- `[:rho, :signal, :dispatch]` with plugin name + signal kind

A `RhoTelemetry` package can subscribe and export OpenTelemetry traces,
StatsD metrics, or Phoenix LiveDashboard panels — all without touching
the kernel.

### D. Performance pass

Currently meaningless because the kernel still has dead branches and
duplicate event paths. After this plan: the hot path (Runner →
TurnStrategy → ToolExecutor → Recorder) is small enough to profile
honestly. Worth doing only if a real workload reports latency issues —
no premature optimization.

### Recommendation

Do this plan if any of A/B/C are on your roadmap. Skip it if you're
purely shipping product features and the kernel works.
