# Kernel Minimisation Plan

## Motivation

Rho's three-plane architecture (execution, coordination, edge) is clean in principle, but the boundaries have eroded. The execution plane — AgentLoop, Reasoner, Worker — has accumulated coordination and edge concerns: hardcoded tool names, subagent special-casing, signal-type knowledge, CLI syntax parsing, and dual-broadcast plumbing.

This makes the kernel harder to reason about, harder to test in isolation, and harder to extend. Every new multi-agent pattern or edge adapter requires touching core files.

The goal is a kernel small enough to hold in your head: **loop, reason, execute, record, emit**. Everything else arrives through mounts or adapter boundaries.

### Acceptance Criteria

The plan is complete when:

1. `grep -rn` for tool name strings (`"finish"`, `"end_turn"`, `"create_anchor"`, `"clear_memory"`) in `agent_loop.ex`, `direct.ex`, and `worker.ex` returns zero hits.
2. `grep -rn` for signal type strings (`"rho.task.requested"`, `"rho.message.sent"`) in `worker.ex` returns zero hits.
3. `grep -rn` for `subagent` as a boolean flag in `agent_loop.ex` and `direct.ex` returns zero hits. (Depth is used instead where needed.)
4. `worker.ex` contains no `,` prefix pattern-matching, no `subscribers` map, and no `process_signal` clauses with hardcoded types.
5. `direct.ex` contains no `classify_tool_error` function.
6. Kernel file sizes: AgentLoop ≤ 260 lines, Reasoner.Direct ≤ 200 lines, Worker ≤ 530 lines (down from 340, 239, 777 respectively).
7. All existing tests pass. New characterisation tests cover each extracted behaviour.

---

## Current State: What Doesn't Belong

### 1. Terminal tool names in the Reasoner

**Where**: `Rho.Reasoner.Direct`, line 12

```elixir
@terminal_tools MapSet.new(["create_anchor", "clear_memory", "finish", "end_turn"])
```

**Problem**: The reasoner — a pure execution concern — encodes knowledge of specific coordination-plane tools. Adding a new terminal tool requires editing the reasoner. The kernel and the tool set are coupled by a string list.

**Why it happened**: Originally the simplest way to stop the loop. But tools already support `{:final, value}` as a return convention. The two mechanisms coexist redundantly.

### 2. Subagent special-casing (five sites)

The `:subagent` boolean flag creates a parallel code path through the kernel. It appears in five distinct locations:

**2a. Runtime flag** — `Rho.AgentLoop`, line 93–105

```elixir
subagent = opts[:subagent] || false
```

Stored in `mount_context` and threaded through the entire runtime. Should be replaced by depth (already available).

**2b. Lifecycle bypass** — `Rho.AgentLoop`, lines 115–118

```elixir
lifecycle =
  if subagent, do: Lifecycle.noop(), else: Lifecycle.from_mount_registry(mount_context)
```

A binary flag disables *all* mount hooks for subagents. This prevents subagents from having their own mount-driven behaviour (guardrails, budgets, logging) and forces subagent-specific logic into the kernel.

**2c. System prompt bypass** — `Rho.AgentLoop`, line 173

```elixir
defp build_system_prompt(base, true = _subagent, _ctx), do: base
```

Subagents skip prompt section collection entirely. This means mounts cannot contribute prompt sections to subagents — a blunt exclusion that should be controlled by mount registration scope instead.

**2d. Nudge logic in AgentLoop** — `Rho.AgentLoop`, lines 275–289

```elixir
defp handle_reasoner_result({:continue, %{type: :subagent_nudge, text: text}}, ...) do
  nudge_msg = "[System] Continue working on your task. Call `finish` with your result when done."
  ...
end
```

The loop has a dedicated code path for a single orchestration policy. The nudge message text is hardcoded.

**2e. Nudge return type in Reasoner** — `Rho.Reasoner.Direct`, lines 60–68

```elixir
if runtime.subagent do
  {:continue, %{type: :subagent_nudge, text: text}}
else
  {:done, %{type: :response, text: text}}
end
```

The reasoner's return type vocabulary changes based on a coordination-plane flag. The reasoner should not distinguish between subagent and primary.

**Why it happened**: Early subagent implementation needed to avoid parent mount side-effects. The right fix is scoped mount registration (subagents get a different set of mounts), not a global bypass.

### 3. Signal handlers hardcoded in Worker

**Where**: `Rho.Agent.Worker`, lines 531–588

```elixir
defp process_signal(%{type: "rho.task.requested", data: data}, state) do ...
defp process_signal(%{type: "rho.message.sent", data: data}, state) do ...
```

**Problem**: The worker — an execution-plane process — contains coordination-plane logic: it knows how to format inter-agent messages, how to extract task parameters from signal payloads, and the exact signal types the system uses. Adding a new signal type means editing the worker.

**Why it happened**: No abstraction existed for pluggable signal handling. The worker was the process receiving signals, so the dispatch went there.

### 4. Direct command execution in Worker

**Where**: `Rho.Agent.Worker`, lines 217–223, 748–776

```elixir
def handle_call({:submit, "," <> command, _opts}, _from, %{status: :idle} = state) do
  ...
  run_direct_command(command, state, turn_id)
  ...
end
```

**Problem**: The `,tool_name args` syntax is a CLI UX convention. The worker pattern-matches on a comma prefix, parses the command, resolves tools, and executes — an entirely separate code path from the normal agent loop. This is edge-plane logic in the execution plane.

**Why it happened**: Convenient shortcut during development. The worker had access to the tool registry, so it was the path of least resistance.

### 5. Dual-path event broadcasting

**Where**: `Rho.Agent.Worker`, lines 597–661

```elixir
# Direct broadcast to subscribers (for CLI/Web backward compat)
for pid <- subscriber_pids do
  send(pid, {:session_event, session_id, turn_id, tagged})
end

# Publish to signal bus
if signal_type do
  Comms.publish(...)
end
```

**Problem**: Every event is sent twice: once via direct `send` to subscriber pids, once via the signal bus. The worker maintains a `subscribers` map, monitors subscriber processes, and has filtering logic for high-frequency events. This is transitional compatibility infrastructure that doubles the surface area of event delivery.

**Why it happened**: The signal bus was added after direct broadcasting already existed. Both paths were kept to avoid breaking CLI/web adapters.

### 6. Tool error classification in Reasoner

**Where**: `Rho.Reasoner.Direct`, lines 226–238

```elixir
defp classify_tool_error(reason) when is_binary(reason) do
  reason_down = String.downcase(reason)
  cond do
    String.contains?(reason_down, "timeout") -> :timeout
    String.contains?(reason_down, "permission") -> :permission_denied
    ...
  end
end
```

**Problem**: The reasoner guesses error categories by string-matching on error messages. This is fragile, locale-dependent, and lossy. It exists because tools return unstructured `{:error, "some string"}`.

### 7. Signal topic naming scattered across codebase

**Where**: `Rho.Agent.Worker` line 720, `Rho.Mounts.MultiAgent` lines 361/388, `Rho.Plugins.Subagent.Worker` line 326, `RhoWeb.Live.SessionLive` line 563, `RhoWeb.Live.ObservatoryLive` line 52

```elixir
pattern = "rho.session.#{session_id}.agent.#{agent_id}.inbox"
```

**Problem**: Signal topic strings are constructed inline in at least six files. This is not a kernel violation per se, but extracting signal handlers (Phase 3) without centralising topic naming will leave scattered string conventions that drift independently.

### 8. Reasoner ↔ system prompt coupling

**Where**: `Rho.AgentLoop`, lines 125–131

```elixir
system_prompt =
  if reasoner == Rho.Reasoner.Structured do
    system_prompt <> "\n\n" <> Rho.Reasoner.Structured.tool_prompt_section(tool_defs)
  else
    system_prompt
  end
```

**Problem**: Prompt assembly — an execution-plane concern — knows about a specific reasoner implementation. Adding a new reasoner that needs prompt modifications would require editing AgentLoop.

### 9. Vestigial `Rho.Builtin` mount

**Where**: `lib/rho/builtin.ex` (14 lines)

The module implements `@behaviour Rho.Mount` but defines no affordances and no hooks. Its only function (`resolve_session/1`) is not a mount callback. It is registered in mount integration tests but contributes nothing through the mount interface.

---

## Target State: The Minimal Kernel

After extraction, the kernel has five components with no coordination or edge knowledge:

### AgentLoop

Recursive step loop. Responsibilities:

- Step counting and max-steps enforcement
- Compaction trigger (delegate to memory module)
- Lifecycle hook dispatch: `before_llm`, `after_step`
- Reasoner dispatch: delegate reason+act to pluggable strategy
- Tape recording via Recorder
- Event emission via callback

Does NOT know about: subagents, tool names, signal types, CLI syntax, specific reasoner implementations.

### Reasoner (Direct)

One reason+act iteration. Responsibilities:

- Call LLM with tools and messages
- Execute tool calls (parallel, via Task)
- Lifecycle hook dispatch: `before_tool`, `after_tool`
- Honour `{:final, value}` from any tool as loop termination
- Stream retry with backoff

Does NOT know about: terminal tool names, subagent nudging, error classification heuristics.

### Worker

Generic agent process. Responsibilities:

- GenServer lifecycle: init, terminate, trap exits
- Turn management: start turn, queue submissions, process queue
- Registry registration/unregistration
- Event emission to a single channel (bus)
- Signal receipt and dispatch to pluggable handlers

Does NOT know about: specific signal types, `,command` syntax, inter-agent message formatting, subscriber pid management.

### Tape / Recorder

Persistent conversation log. Responsibilities:

- Record user messages, assistant text, tool steps, injected messages
- Rebuild LLM context from tape history
- Trigger compaction when threshold exceeded

No changes needed — already minimal. Recorder has no coordination or edge coupling.

### MountRegistry

Affordance collection and hook dispatch. Responsibilities:

- Collect tools, prompt sections, bindings from registered mounts
- Dispatch lifecycle hooks in priority order
- Dispatch signal handlers (new, Phase 3)
- Scoped to context (agent, session, depth)

---

## Extraction Plan

### Phase 1: Tool-Driven Termination

**Goal**: Remove `@terminal_tools` from the Reasoner. Tools self-declare termination.

**Changes**:

1. Each tool that should terminate the loop (`end_turn`, `finish`, `create_anchor`, `clear_memory`) returns `{:final, value}` instead of `{:ok, value}`.
2. Remove `@terminal_tools` MapSet and the `cond` branch that checks it in `handle_tool_calls/4`.
3. The existing `{:final, _}` code path in the reasoner already works — it produces `{:done, %{type: :response, text: final_output}}`. This becomes the only termination mechanism.
4. Special-case for `finish` extracting `args["result"]` moves into the `finish` tool's execute function — the tool itself returns `{:final, args["result"]}`.

**Testing**:

- Write characterisation tests *before* changes: for each terminal tool, assert that the agent loop terminates when the tool is called. These tests must pass both before and after the change.
- Test that a tool returning `{:ok, value}` does NOT terminate the loop (regression guard against accidental termination).
- Test that a non-terminal tool returning `{:final, value}` DOES terminate (proves the mechanism is general).

**Risk**: Low. `{:final, _}` already works. This is removing a redundant mechanism.

### Phase 2: Subagent Lifecycle via Mounts

**Goal**: Remove all five subagent special-casing sites from the kernel. Subagents participate in lifecycle like any other agent, distinguished only by depth.

**Design decision**: The `Rho.Plugins.Subagent` mount (which already exists and has `after_tool/4`) gains an `after_step/4` hook. When the reasoner returns `{:done, %{type: :response, ...}}` at `depth > 0`, the mount's `after_step` injects the nudge message. The reasoner always returns `{:done, ...}` for text-only responses regardless of depth — it has no concept of "subagent."

This was chosen over two alternatives:
- **Separate `SubagentNudge` mount**: Rejected — adds a new module for a single hook. The existing `Subagent` mount is the natural owner of subagent policy.
- **Reasoner emits `:no_tool_calls` signal**: Rejected — introduces a new signal type into the kernel to remove a subagent concept from the kernel. Lateral move.

**Changes**:

1. Remove `subagent` field from `mount_context` / `Context`. Use `depth > 0` where the distinction is needed.
2. Remove `if subagent, do: Lifecycle.noop()` from `build_runtime`. Subagents always get `Lifecycle.from_mount_registry(mount_context)`.
3. Subagent agent profiles (in `.rho.exs`) specify their own mount list. Mounts that shouldn't run for subagents are simply not included in that profile.
4. Remove `build_system_prompt(base, true = _subagent, _ctx), do: base` clause. Subagents get prompt sections from their own (scoped) mounts — if none are registered, the result is the same as today.
5. Add `after_step/4` to `Rho.Plugins.Subagent`. When `depth > 0` and the step result is `{:done, %{type: :response}}`, return `{:inject, [nudge_message]}` to continue the loop.
6. Remove the `handle_reasoner_result({:continue, %{type: :subagent_nudge, ...}}, ...)` clause from AgentLoop.
7. Remove the `:subagent_nudge` return type from `Reasoner.Direct.handle_no_tool_calls/2`. The function becomes: always return `{:done, %{type: :response, text: text}}`.
8. Remove the `runtime.subagent` check from Reasoner.Direct entirely.
9. Remove the reasoner-type conditional in AgentLoop (lines 125–131). If the Structured reasoner needs prompt modifications, it should provide them via a mount's `prompt_sections/2` callback.

**Testing**:

- The existing test at `agent_loop_test.exs:385` ("subagent mode does not run before_llm or after_step hooks") must be updated — subagents *will* run hooks after this change; the test should verify that the *correct* hooks run.
- New test: subagent at depth > 0 with `Subagent` mount registered receives nudge injection on text-only response.
- New test: subagent at depth > 0 *without* `Subagent` mount terminates normally on text-only response (proves the nudge is policy, not kernel).
- New test: primary agent (depth 0) with `Subagent` mount does NOT receive nudge (proves depth gating).
- End-to-end: `delegate_task` → subagent runs → receives nudge → calls `finish` → result collected.

**Risk**: Medium. This is the most invasive phase. The five removal sites interact — partial completion leaves the kernel in an inconsistent state. All five changes should land in a single PR.

### Phase 3: Pluggable Signal Handlers

**Goal**: Remove signal-type knowledge from Worker. Signal dispatch becomes a mount concern.

**Changes**:

1. Add a new mount callback: `handle_signal(signal, mount_opts, context)` with return type:
   ```elixir
   {:start_turn, content, opts}   # start an agent turn with the given content
   | {:update_state, fun}          # apply a state transformation (no turn)
   | {:emit, signal_type, payload} # publish a derived signal
   | :ignore                       # this mount doesn't handle this signal
   ```
   The return type is intentionally broader than the two current handlers need. `{:start_turn, ...}` covers both existing cases. `{:update_state, fun}` and `{:emit, ...}` prevent future signal handlers from being forced to start turns when they need different behaviour.
2. Add `MountRegistry.dispatch_signal(signal, context)` that iterates registered mounts and returns the first non-`:ignore` result.
3. In Worker, replace `process_signal/2` pattern-match clauses with a single dispatch:

   ```elixir
   defp process_signal(signal, state) do
     context = build_context(state, state.depth)
     case MountRegistry.dispatch_signal(signal, context) do
       {:start_turn, content, opts} -> start_turn(content, opts, state)
       {:update_state, fun} -> fun.(state)
       {:emit, type, payload} -> Comms.publish(type, payload); state
       :ignore -> state
     end
   end
   ```

4. Move the `rho.task.requested` handler into `Rho.Mounts.MultiAgent` (it already provides the delegation tools).
5. Move the `rho.message.sent` handler and inter-agent message formatting into `Rho.Mounts.MultiAgent`.
6. Centralise signal topic naming: add `Rho.Comms.Topics` module with functions like `inbox_topic(session_id, agent_id)`, `events_topic(session_id)`, `events_topic(session_id, signal_type)`. Update all six call sites.

**Testing**:

- New test: Worker with no signal-handling mounts ignores all signals.
- New test: Mount returning `{:start_turn, ...}` triggers a turn.
- Move existing signal-handling assertions from any Worker tests into MultiAgent mount tests.

**Risk**: Low-medium. The handler logic is straightforward to relocate. The `Rho.Comms.Topics` extraction is mechanical.

### Phase 4: Extract Direct Commands to Edge

**Goal**: Remove `,tool_name args` parsing from Worker.

**Prerequisite**: The CLI does not currently have access to mount context or tool resolution. This must be solved first.

**Changes**:

1. Add a `Worker.resolve_tools/1` public API that returns the current tool list for the agent's context. This is a read-only query — the CLI calls it to get tool definitions without starting a turn.
2. In CLI adapter, intercept input starting with `,`. Parse the command, resolve the tool (via `Worker.resolve_tools/1`), execute it locally, and display the result — without submitting to the worker.
3. Remove the `handle_call({:submit, "," <> command, ...})` clause from Worker.
4. Remove `run_direct_command/3` and `execute_direct_command/3` from Worker.
5. Remove the direct-command branch from `process_queue/1`.

**Testing**:

- `command_parser_test.exs` already exists — keep it, as the parser itself doesn't move.
- New test: CLI intercepts `,` prefix and does not call `Worker.submit/3`.
- New test: `Worker.resolve_tools/1` returns expected tools for context.

**Risk**: Low. The main subtlety is giving the CLI tool access without creating new coupling. The `resolve_tools` API keeps the Worker as the authority for tool resolution while the CLI handles the UX.

### Phase 5: Single Event Path

**Goal**: Remove dual-path broadcasting. Events flow through the bus only.

**Prerequisite**: Latency benchmark. Before starting this phase, measure:
- Baseline: time from `send(pid, {:session_event, ...})` to receipt in CLI, for `text_delta` events during streaming.
- Bus path: time from `Comms.publish(...)` to receipt in a bus subscriber, for the same events.
- **Abort threshold**: If bus path adds > 5ms p99 latency per token, do not proceed. Instead, keep a single direct-send path for the active turn's subscriber only and remove the general subscriber registry.

**Changes**:

1. CLI and web adapters subscribe to the signal bus instead of calling `Worker.subscribe/2`.
   - CLI: replace `Rho.Session.subscribe(session_id)` with `Comms.subscribe(Topics.events_topic(session_id))` (uses Phase 3's `Topics` module).
   - Web (`session_live.ex`): same pattern.
2. Remove `subscribers` map, `subscribe/unsubscribe` API, and process monitoring from Worker.
3. Remove direct `send(pid, {:session_event, ...})` from the emit function.
4. The emit function becomes: tag event → publish to bus. One path.
5. Remove `@high_freq_event_types` filtering — subscribers choose their own filter on the bus pattern.

**Fallback plan**: If the benchmark fails the abort threshold, implement a hybrid: remove the subscriber registry and monitoring, but keep a single `active_subscriber` pid field set at turn start. Direct-send `text_delta` events to that pid; publish everything else through the bus. This still removes ~80% of the dual-path complexity.

**Testing**:

- Benchmark script (not a test — a Mix task): stream 1000 tokens, measure p50/p95/p99 delivery latency through the bus vs direct send. Run before and after.
- New test: CLI receives events via bus subscription.
- New test: Worker emits events without maintaining subscriber state.

**Risk**: Medium. This is the highest-risk phase because it affects the hot path (token streaming). The benchmark prerequisite and fallback plan mitigate this.

### Phase 6: Typed Tool Errors

**Goal**: Remove string-matching error classification from the Reasoner.

**Changes**:

1. Define an error convention for tools:
   ```elixir
   {:error, reason}           # reason is atom or {atom, detail}
   # e.g. {:error, :timeout}, {:error, {:not_found, "/foo/bar"}}
   ```
2. Update tool mounts to return typed errors. Migration order: `Bash` → `FsRead` → `FsWrite` → `FsEdit` → `WebFetch` → `Python` → `Sandbox`.
3. Remove `classify_tool_error/1` from `Reasoner.Direct`.
4. The reasoner passes the error atom through to the event as `:error_type` directly.

**Forcing function**: After all built-in tool mounts are migrated, add a `Logger.warning` in the reasoner for any `{:error, reason}` where `reason` is a bare string. This creates visibility for third-party mounts that haven't migrated, without breaking them. Remove `classify_tool_error/1` once the warning has been in place for one release cycle.

**Testing**:

- For each migrated tool: test that error returns use atoms, not strings.
- Test that the reasoner passes atom error types through without classification.
- Test that the fallback logger fires for string errors during the transition period.

**Risk**: Low. The forcing function prevents the "both mechanisms forever" problem.

### Phase 7: Cleanup

**Goal**: Remove vestigial code exposed by the other phases.

**Changes**:

1. Remove `Rho.Builtin` if it has no remaining callers after Phase 2 (it currently contributes nothing through the mount interface; `resolve_session/1` is not a mount callback).
2. Remove `subagent` field from `Rho.Mount.Context` struct.
3. Audit `Rho.Lifecycle.noop/0` — if no longer called after Phase 2, remove it or keep it only for tests.

**Risk**: Negligible.

---

## Sequencing

```
Phase 1 (tool termination)     — standalone, no dependencies
Phase 6 (typed errors)         — standalone, no dependencies
Phase 4 (direct commands)      — standalone, no dependencies
Phase 2 (subagent lifecycle)   — depends on Phase 1 (finish tool returns {:final, _})
Phase 3 (signal handlers)      — standalone, but pairs well with Phase 2
Phase 5 (single event path)    — do last, highest risk, benchmark gate
Phase 7 (cleanup)              — after all others
```

Phases 1, 4, and 6 can be done in parallel. Phase 2 should follow Phase 1. Phase 5 should be last (before cleanup). Phase 7 is a sweep after everything else lands.

### Rollback strategy

Each phase is a single PR. If a phase causes regressions after merge:

- **Phases 1, 4, 6, 7**: Revert the PR. These are isolated extractions with no cross-phase state.
- **Phase 2**: Revert the entire PR (all five subagent sites must move together). Do not attempt partial revert.
- **Phase 3**: Revert the PR. Signal handlers return to Worker; `Rho.Comms.Topics` can remain (it's additive).
- **Phase 5**: If latency regresses post-merge, switch to the hybrid fallback (direct-send for `text_delta` only) without reverting the subscriber registry removal.

---

## Existing Test Coverage

Current test coverage for affected behaviour:

| Area | Test file | Coverage |
|------|-----------|----------|
| Subagent lifecycle bypass | `agent_loop_test.exs:385` | Tests that hooks are skipped — **must be rewritten in Phase 2** |
| Mount tool collection | `mount_integration_test.exs` | Good coverage of tool resolution |
| Command parser | `command_parser_test.exs` | Parser logic — survives Phase 4 |
| Signal handling in Worker | *None found* | **Gap — write characterisation tests before Phase 3** |
| Dual-path broadcasting | *None found* | **Gap — write characterisation tests before Phase 5** |
| Terminal tool termination | *None found* | **Gap — write characterisation tests before Phase 1** |
| Typed tool errors | *None found* | **Gap — write tests as part of Phase 6 migration** |

**Pre-work**: Before starting any phase, write characterisation tests for the behaviour being extracted. These tests assert current behaviour and must pass both before and after the extraction. This is non-negotiable — "low risk" extractions that change termination semantics or event delivery can fail silently.

---

## What Remains in the Kernel After All Phases

```
AgentLoop.run/3
  ├── step counting
  ├── compaction trigger
  ├── system prompt assembly (via MountRegistry, no special-casing)
  ├── before_llm dispatch → Reasoner.run → after_step dispatch
  └── tape recording

Reasoner.Direct.run/2
  ├── LLM call + stream retry
  ├── before_tool / execute / after_tool
  └── {:continue, entries} | {:done, result} based on {:final, _} only

Worker
  ├── GenServer shell (init, terminate, trap_exit)
  ├── turn management (start, queue, process)
  ├── signal receipt → mount dispatch
  └── event emission → bus

Recorder
  ├── record input, assistant text, tool steps, injected messages
  └── rebuild context

MountRegistry
  ├── collect tools, prompt sections, bindings
  ├── dispatch lifecycle hooks
  └── dispatch signal handlers (new)
```

No tool names. No signal types. No subagent flags. No CLI syntax. No dual broadcasting. No string-matching classifiers. No reasoner-specific prompt logic. A kernel you can read in ten minutes.
