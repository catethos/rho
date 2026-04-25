# Rho Redesign — Implementation Plan

## Guiding Principle

**Start from the outside (API surface), work inward (internals).** The development velocity problem and the architecture problem are the same problem: CLI, web, and tests use three different code paths. Unify them first, then fix internals with a fast feedback loop.

**Every phase must leave `mix rho.chat` working.** No "rebuild the plane mid-flight."

---

## What Rho Is (Current State)

An Elixir umbrella (5 apps, ~45k lines) containing two products:

1. **Agent Engine** (`rho` + `rho_stdlib` + `rho_cli`): LLM agent framework with tool execution, append-only tape memory, plugin/transformer pipeline, multi-agent coordination, signal bus, CLI and web interfaces.
2. **Competency Framework Manager** (`rho_frameworks` + `rho_web`): Multi-tenant SaaS for skill libraries, role profiles, lenses, gap analysis — uses the agent engine as its AI backend.

## What's Wrong (Root Causes)

### 1. Three different entry paths

| Frontend | Path | What it bypasses |
|----------|------|-----------------|
| CLI (`mix rho.chat`) | Repl → bus subscribe → Primary.ensure_started → Worker.submit → bus delivers events → Repl renders | Nothing (full stack) |
| Web (`SessionLive`) | SessionCore → bus subscribe → Primary.ensure_started → Worker.submit → bus delivers events → SignalRouter projects | Nothing (full stack, different code) |
| Tests / `mix rho.run` | `Runner.run(model, messages, opts)` directly | Worker, session, bus, tape bootstrap, plugins |

A coding agent cannot verify interactive features without booting a REPL and typing manually.

### 2. Hidden boot-time coupling

`Rho.CLI.Application.start/2` sets 5 `{mod, fun}` callback tuples in application env. `RhoFrameworks.Application` globally registers `IdentityPlugin`. Core runtime behavior depends on app start order — not on explicit configuration.

### 3. God Worker (1038 lines)

`Rho.Agent.Worker` does: GenServer lifecycle, state machine, turn execution, tool resolution, context assembly, emit construction, meta-update dispatch, signal processing, direct commands, sandbox lifecycle, agent registry management, queue management, waiter management.

### 4. Duplicated tool execution in strategies

Both `TurnStrategy.Direct` (412 lines) and `TurnStrategy.TypedStructured` (415 lines) independently implement ~200 lines of identical tool dispatch: transformer pipeline calls, result normalization, emit events, deny/halt, timeout handling. `TurnStrategy.Shared` only extracts retry logic.

### 5. Naming schizophrenia

Mount = Plugin = Hook. MountRegistry = PluginRegistry. Reasoner = TurnStrategy. Memory = Tape. `mounts:` in config = plugins. Legacy aliases and "backward compatibility" comments throughout.

### 6. Signal bus as mandatory default

Every event (even in single-user CLI) routes through `jido_signal`. The bus became event log, delivery path, and coordination mechanism simultaneously.

### 7. Config indirection hell

`Rho.Config` delegates everything through `Application.get_env` → `{mod, fun}` callbacks. You cannot grep for where anything is implemented.

---

## The Plan

### Phase 1: `Rho.Session` — The Single Shared Mechanism

**~2 days · Unlocks: everything**

Create a programmatic API that CLI, web, tests, and coding agents all use.

#### 1.1 Create `Rho.Session` module

File: `apps/rho/lib/rho/session.ex`

```elixir
defmodule Rho.Session do
  @moduledoc "Programmatic session API — the single entry point for all frontends."

  def start(opts \\ [])
  # opts: agent:, workspace:, session_id:, emit:, user_id:, organization_id:
  # Returns {:ok, %Handle{}}

  def send(session, content, opts \\ [])
  # Synchronous — blocks until turn completes
  # Returns {:ok, text} | {:error, reason}

  def send_async(session, content, opts \\ [])
  # Asynchronous — events delivered via emit callback
  # Returns {:ok, turn_id}

  def events(session)
  # Returns all events from this session

  def info(session)
  # Returns session info (agents, status, tape)

  def stop(session)
  # Stops the session and all its agents
end
```

Internally wraps `Rho.Agent.Primary.ensure_started` + `Worker.submit` + `Worker.ask` — the same code paths CLI and web already use, exposed as clean functions.

#### 1.2 Create `Rho.run/2` convenience

File: `apps/rho/lib/rho.ex`

```elixir
def run(message, opts \\ []) do
  {:ok, session} = Rho.Session.start(opts)
  result = Rho.Session.send(session, message)
  Rho.Session.stop(session)
  result
end
```

#### 1.3 Create `Rho.Session.Handle` struct

```elixir
defstruct [:session_id, :primary_pid, :emit, :bus_sub]
```

#### 1.4 Rewrite `mix rho.run` to use `Rho.run/2`

Current (bypasses Worker): `Rho.Runner.run(model, messages, run_opts)`
New: `Rho.run(message, agent: agent_name, model: opts[:model])`

#### 1.5 Rewrite `Rho.CLI.Repl` to use `Rho.Session`

Repl gets events via emit callback instead of bus subscription. Same rendering logic.

#### 1.6 Rewrite `SessionCore.ensure_session` to use `Rho.Session.start`

Web path uses `Rho.Session.start` with a bus-publishing emit callback.

#### Verification

```elixir
# In iex — one-liner feature verification
iex> {:ok, text} = Rho.run("read mix.exs and tell me the app name")

# In a test file
test "agent can read files" do
  Mimic.stub(ReqLLM, :stream_text, fn ... end)
  {:ok, text} = Rho.run("read mix.exs", agent: :coder)
  assert text =~ "rho"
end
```

---

### Phase 2: `RunSpec` — Explicit Config Through the Stack

**~2 days · Depends on: Phase 1**

Create a single struct that carries all agent configuration. `Rho.Session.start` builds it, Worker stores it, Runner reads it. No global registries, no `{mod, fun}` callbacks.

#### 2.1 Create `%Rho.RunSpec{}` struct

File: `apps/rho/lib/rho/run_spec.ex`

```elixir
defstruct [
  :model,              # "openrouter:anthropic/claude-sonnet-4.6"
  :system_prompt,      # base system prompt string
  :max_steps,          # loop budget (default 50)
  :plugins,            # [{module, opts}] — capability contributors
  :transformers,       # [{module, opts}] — pipeline interceptors
  :tools,              # [tool_def] | nil — pre-resolved, or nil = resolve from plugins
  :tape_name,          # tape reference, nil = no persistence
  :tape_module,        # e.g. Rho.Tape.Context.Tape
  :workspace,          # working directory
  :agent_name,         # :default, :coder, etc.
  :agent_id,           # unique agent process id
  :session_id,         # session namespace
  :depth,              # delegation depth (0 = primary)
  :subagent,           # boolean
  :prompt_format,      # :markdown | :xml
  :user_id,            # for multi-tenant scoping
  :organization_id,    # for multi-tenant scoping
  :emit,               # (map() -> :ok) event callback
  :provider,           # provider routing config
  :turn_strategy,      # strategy module
  :compact_threshold   # token threshold for auto-compaction
]
```

Add `RunSpec.build(opts)` with sensible defaults.

#### 2.2 Create `Rho.RunSpec.FromConfig` builder

File: `apps/rho_cli/lib/rho/run_spec/from_config.ex`

Reads `.rho.exs` via `CLI.Config.agent/1`, resolves plugin shorthand atoms via `Stdlib.resolve_plugin/1`, resolves turn_strategy, returns `%RunSpec{}`. Called by `Rho.Session.start` when no explicit RunSpec is provided.

This is the ONLY place that touches `.rho.exs` or application env.

#### 2.3 Refactor `Runner.run/3` → `Runner.run/2`

Accept `run(messages, %RunSpec{})`. Delete the `opts[:xxx]` fallback chains.

#### 2.4 Add `RunSpec.collect_tools/1` and `RunSpec.apply_stage/3`

Iterate the spec's plugin/transformer lists directly — no global ETS lookup.

#### 2.5 Worker stores RunSpec, passes it to Runner

Delete scattered `Rho.Config.agent_config(state.agent_name)` calls.

#### 2.6 Delete `Rho.Config` indirection callbacks

Remove `parse_command/1`, `capabilities_from_plugins/1`, `agent_names/0`, `sandbox_enabled?/0` — all the `{mod, fun}` delegation. Delete the 5 `Application.put_env` calls from `CLI.Application`.

#### Verification

```elixir
# Full control, no .rho.exs needed
spec = Rho.RunSpec.build(model: "mock:test", plugins: [:bash, :fs_read], max_steps: 5)
{:ok, session} = Rho.Session.start(run_spec: spec)
{:ok, text} = Rho.Session.send(session, "echo hello")
```

---

### Phase 3: Test Harness — Make Coding Agents Fast

**~1.5 days · Depends on: Phase 2**

Build test infrastructure so every subsequent phase can be verified in seconds.

#### 3.1 Create `Rho.Test` helper module

File: `apps/rho/test/support/rho_test.ex`

```elixir
defmodule Rho.Test do
  @doc "Run a one-shot agent turn with mocked LLM responses."
  def run_with_responses(message, responses, opts \\ [])

  @doc "Build a canned text response."
  def text_response(text)

  @doc "Build a canned tool-call response."
  def tool_call_response(text, tool_calls)

  @doc "Start a session with mocked LLM."
  def start_mock_session(opts \\ [])
end
```

Extracts and formalizes the helpers already in `runner_test.exs` (lines 18-79).

#### 3.2 Create `mix rho.smoke`

Quick smoke test — 5 seconds:
```bash
mix rho.smoke
# Boots app, creates session, sends "echo hello" through bash tool,
# verifies tool called and result returned. Mocked LLM. Exit 0/1.
```

#### 3.3 Create `mix rho.verify`

Full integration test — 15 seconds:
```bash
mix rho.verify
# Tests: session start/stop, multi-turn, tape persistence,
# multi-agent delegation, plugin loading, transformer pipeline.
# All mocked LLM.
```

#### 3.4 Write integration tests using `Rho.Session` API

```elixir
test "session starts, accepts message, returns response" do
  stub_llm(text_response("Hello!"))
  {:ok, s} = Rho.Session.start(agent: :default)
  assert {:ok, "Hello!"} = Rho.Session.send(s, "Hi")
  Rho.Session.stop(s)
end

test "tools execute through full stack" do
  stub_llm_sequence([
    tool_call_response("", [{"c1", "bash", %{"cmd" => "echo hi"}}]),
    text_response("Done")
  ])
  {:ok, text} = Rho.run("say hi", agent: :coder)
  assert text == "Done"
end

test "tape persists across session restart" do
  # Start session, send message, stop, restart, verify tape has entries
end
```

#### Development workflow after this phase

```
1. Make a change
2. mix rho.smoke        → 5 seconds
3. mix rho.verify       → 15 seconds
4. mix test             → unit tests
```

No more "boot the REPL and manually type things."

---

### Phase 4: ToolExecutor + Worker Decomposition + EventSink

**~3 days · Depends on: Phase 3**

Fix the core agent internals. Verified by `mix rho.smoke` + `mix rho.verify` after each sub-task.

#### 4.0 Extract `Rho.ToolExecutor`

The most important internal fix. Both strategies duplicate ~200 lines of tool execution. A strategy should decide **what to do**, not execute tools.

**Create `Rho.ToolExecutor`** — shared tool dispatch:

```elixir
defmodule Rho.ToolExecutor do
  @doc "Execute tool calls through the transformer pipeline."
  def run(tool_calls, tool_map, context, emit)
  # Handles: :tool_args_out transformer, dispatch, await with timeout,
  # :tool_result_in transformer, result normalization, emit events.
  # Returns [%{name, args, result, call_id, latency_ms, status, disposition}]

  @doc "Execute a single tool call."
  def execute_one(name, args, call_id, tool_def, context, emit)
end
```

**Simplify `TurnStrategy` behaviour** — strategies return intent:

```elixir
@type turn_result ::
  {:respond, text}
  | {:call_tools, [tool_call], response_text}
  | {:think, thought}
  | {:parse_error, reason, raw_text}
  | {:error, reason}

@callback turn(projection, runtime) :: turn_result()
```

**Refactor `Runner.do_loop`** — Runner handles tool execution:

```elixir
case runtime.turn_strategy.turn(projection, runtime) do
  {:respond, text} ->
    {:ok, text}

  {:call_tools, tool_calls, response_text} ->
    results = ToolExecutor.run(tool_calls, runtime.tool_map, runtime.context, runtime.emit)
    # build entries, run :post_step, advance context, loop

  {:think, thought} ->
    # inject thought, loop

  {:parse_error, reason, raw_text} ->
    # inject correction, loop
end
```

**Result:**

| Module | Before | After |
|--------|--------|-------|
| `TurnStrategy.Direct` | 412 lines (LLM + tool execution) | ~150 lines (LLM stream + response classification) |
| `TurnStrategy.TypedStructured` | 415 lines (LLM + JSON parse + tool execution) | ~200 lines (LLM stream + ActionSchema dispatch) |
| `ToolExecutor` | n/a | ~200 lines (shared, written once) |
| **Total** | **948 lines** (200 duplicated) | **~550 lines** (zero duplication) |

Adding a new strategy = implement `turn/2` only, ~100 lines. No tool dispatch copy-paste.

#### 4.1 Create `Rho.EventSink` behaviour + implementations

```elixir
defmodule Rho.EventSink do
  @callback emit(event :: map()) :: :ok
end
```

- `Rho.EventSink.Direct` — calls a provided function (for `Rho.run/2`, tests)
- `Rho.EventSink.Bus` — publishes to signal bus (for web/multi-agent)
- `Rho.EventSink.Callback` — sends to a pid (for CLI Repl)

Session API picks the right sink: `emit:` callback → Callback, no emit → Direct (collect internally).

#### 4.2 Extract `Rho.Agent.TurnExecutor`

Module (not GenServer). Functions:
- `start(messages, %RunSpec{})` — spawns a Task under TaskSupervisor, returns `%Task{}`
- `run(messages, %RunSpec{})` — synchronous turn execution (calls Runner.run)

Extracts `start_turn/3`, `run_turn/6`, `build_turn_opts/3` from Worker.

#### 4.3 Extract `Rho.Agent.RuntimeBuilder`

Pure-function module:
- `for_turn(base_spec, turn_opts)` — per-turn overrides (model, max_steps, tools)
- `for_delegation(parent_spec, child_opts)` — child RunSpec for delegated agents
- `for_simulation(parent_spec, agent_opts)` — RunSpec for spawn_agent

Replaces scattered context assembly in Worker and MultiAgent plugin.

#### 4.4 Simplify Worker to ~400 lines

After extraction, Worker contains only:
- State struct: `agent_id, session_id, run_spec, sandbox, task_ref, task_pid, status, queue, mailbox, waiters, turn_meta`
- `init/terminate`
- `handle_call` for submit/collect/info/status
- `handle_cast` for cancel/deliver_signal
- `handle_info` for task results, bus signals, watchdog, meta_update
- `process_queue`, `process_signal`
- Direct command handler (~30 lines)

---

### Phase 5: Naming + Frameworks Boundary + Flatten Umbrella

**~3 days (parallel) · Depends on: Phase 4**

Three independent cleanup tasks. Each verified by `mix rho.smoke && mix rho.verify`.

#### 5A: Delete naming baggage (~1 day)

Pick ONE name, kill the rest:

| Concept | Canonical | Kill |
|---------|-----------|------|
| Capability contributor | `Rho.Plugin` | Mount, Hook |
| Pipeline interceptor | `Rho.Transformer` | (keep separate) |
| Inner-turn strategy | `Rho.TurnStrategy` | Reasoner |
| Append-only log | `Rho.Tape` | Memory |
| Tape projection behaviour | `Rho.Tape.Projection` | Tape.Context |
| Default projection | `Rho.Tape.Projection.JSONL` | Tape.Context.Tape |
| Config key for plugins | `plugins:` | `mounts:` |
| Config key for strategy | `turn_strategy:` | `reasoner:` |
| Config key for tape module | `tape_module` | `memory_module` |

Actions:
- Delete `mount.ex`, `mount_registry.ex` delegate files
- Update all `@behaviour Rho.Mount` → `@behaviour Rho.Plugin`
- Rename `Tape.Context` → `Tape.Projection`, `Tape.Context.Tape` → `Tape.Projection.JSONL`
- Update `.rho.exs` to use `plugins:` and `turn_strategy:` keys
- Delete `memory_module/0` from `Rho.Config`
- Update README.md

#### 5B: Frameworks boundary (~1 day)

Define the seam in-place before any repo split.

- Remove `rho_cli` dependency from `rho_frameworks/mix.exs`
- Replace `Rho.Config.agent_config()` call in `Roles.rank_similar_via_llm/3` with direct `ReqLLM.generate_object` using app-env config
- Create `RhoFrameworks.LLM` — thin wrapper for the two direct LLM calls frameworks needs
- Make `IdentityPlugin` registration explicit in `.rho.exs` instead of boot-time side effect in `RhoFrameworks.Application`
- Document interface contract: which Rho modules frameworks depends on

#### 5C: Flatten engine umbrella (~1.5 days)

Merge `rho_stdlib` + `rho_cli` into `rho`. Result: 3 apps instead of 5.

- Move `apps/rho_stdlib/lib/rho/stdlib/` → `apps/rho/lib/rho/stdlib/`
- Move `apps/rho_cli/lib/rho/cli/` → `apps/rho/lib/rho/cli/`
- Move `apps/rho_cli/lib/mix/tasks/` → `apps/rho/lib/mix/tasks/`
- Merge deps from stdlib/cli mix.exs into rho/mix.exs
- Merge Application children
- Delete `apps/rho_stdlib/` and `apps/rho_cli/`
- Update `in_umbrella: true` deps
- Verify: `mix compile && mix rho.smoke && mix rho.verify && mix test`

---

### Phase 6: Dead Code Purge + File Consolidation + Docs

**~1.5 days · Depends on: Phase 5**

Final sweep.

- Run `mix xref unreachable`, delete dead modules and functions
- Delete legacy `Rho.Plugins.Subagent` module + worker + supervisor
- Delete `Rho.AgentLoop` delegate (if it still exists)
- Consolidate `fs_read.ex` + `fs_write.ex` + `fs_edit.ex` → `fs.ex`
- Consolidate tape tool files (`anchor.ex`, `search_history.ex`, `recall_context.ex`, `clear_memory.ex`) → `tape_tools.ex`
- Collapse `AgentLoop.Runtime` into RunSpec, `AgentLoop.Recorder` into Runner private functions
- Update AGENTS.md, CLAUDE.md, README.md
- Final `mix rho.smoke && mix rho.verify && mix test`

---

## Feature Preservation Matrix

Every feature, its files, and plan status:

| Feature | Plan Status | Risk |
|---------|-------------|------|
| **Tape** (Entry, Store, Service, View, Compact, Fork) | ✅ Untouched | None |
| **Skills** (SKILL.md discovery, Loader, Plugin) | ✅ Untouched (1 call site change: `PluginRegistry.collect_tools` → `RunSpec.collect_tools`) | None |
| **Tape Tools** (anchor, search, recall, clear) | ✅ Untouched | None |
| **Multi-Agent** (delegate, spawn, await, send, broadcast) | ⚠️ Internal spawning uses RuntimeBuilder for child RunSpecs | Medium |
| **Data Table** (Server, Schema, Plugin, tools) | ✅ Untouched | None |
| **Structured Output** (TypedStructured, ActionSchema) | 🔄 Strategy simplified (returns intent, not side-effects). ActionSchema/StructuredOutput untouched. | Low |
| **Python REPL** | ✅ Untouched | None |
| **Doc Ingest** | ✅ Untouched | None |
| **Step Budget** | ✅ Untouched (registered via RunSpec instead of global registry) | None |
| **Live Render** | ✅ Untouched | None |
| **Sandbox** | ✅ Untouched | None |
| **CLI Repl** | 🔄 Rewired to use Rho.Session, same rendering | Low |
| **mix rho.chat / rho.run** | 🔄 Rewired to use Rho.Session / Rho.run | Low |
| **mix rho.trace** | ✅ Untouched (reads JSONL directly) | None |
| **Web SessionLive** | 🔄 SessionCore uses Rho.Session.start | Low |
| **Web Workspaces** | ✅ Untouched | None |
| **Frameworks** (Library, Roles, Lenses, Accounts) | 🔄 Phase 5B boundary, domain logic untouched | Low |
| **Signal Bus** | 🔄 Kept but demoted to one EventSink option | Low |
| **Py Agent** | ✅ Untouched | None |
| **LLM Admission** | ✅ Untouched | None |
| **Event Log** | ✅ Untouched (already a bus subscriber) | None |
| **Telemetry** | ✅ Untouched | None |

---

## Timeline

```
Phase 1: Rho.Session API ............ 2 days
Phase 2: RunSpec .................... 2 days
Phase 3: Test harness ............... 1.5 days
Phase 4: ToolExecutor + internals ... 3 days
Phase 5: Naming + boundary + flatten  3 days (parallel)
Phase 6: Purge + docs ............... 1.5 days
                                      ─────────
                                      ~13 days
```

Critical path: Phase 1 → 2 → 3 → 4 → 5 → 6 (~13 days sequential, ~11 with Phase 5 parallelism).

## Estimated Line Count

| Area | Before | After | Delta |
|------|--------|-------|-------|
| Worker | 1038 | ~400 | -638 |
| TurnStrategy (Direct + Structured + Shared) | 948 | ~550 | -398 |
| Config + indirection | ~300 | ~100 (RunSpec.FromConfig) | -200 |
| Legacy aliases/delegates | ~200 | 0 | -200 |
| Dead code (old subagent, etc.) | ~400 | 0 | -400 |
| New modules (Session, RunSpec, ToolExecutor, EventSink, Test, RuntimeBuilder, TurnExecutor) | 0 | ~800 | +800 |
| **Net** | | | **~-1000** |

Total codebase: ~45k → ~44k lines, but the meaningful metric is: **the code you actually read and debug when adding features drops dramatically** because the hot path (Session → Worker → Runner → Strategy → ToolExecutor) is a straight line with explicit data flow.
