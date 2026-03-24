# Rho — Developer Context

## Project Overview

Rho is an Elixir-based AI agent framework with a CLI and optional web transport. Agents have configurable mounts, memory (journal/tape), skills, sandbox support, and signal-based multi-agent coordination.

## Three-Plane Architecture

Rho separates concerns into three planes:

- **Execution plane** — AgentLoop, tapes, mounts, reasoners. The core LLM reasoning loop. Does not know about signals or multi-agent coordination.
- **Coordination plane** — Signal bus (`Rho.Comms`), agent registry, multi-agent mount, session namespace. Manages agent-to-agent communication.
- **Edge plane** — CLI and web adapters. Thin subscribers to session event streams.

## Mount Architecture

All optional behavior arrives through **mounts** — modules implementing `@behaviour Rho.Mount`. See `docs/mount-architecture-refactor.md` for the full refactor plan and history.

### Mount System

- `Rho.Mount` (`lib/rho/mount.ex`) — behaviour with optional callbacks:
  - Affordances: `tools/2`, `prompt_sections/2`, `bindings/2`
  - Hooks: `before_llm/3`, `before_tool/3`, `after_tool/4`, `after_step/4`
  - Lifecycle: `children/2`
  - All callbacks receive `(mount_opts, context)` or `(data, mount_opts, context)`
- `Rho.MountInstance` (`lib/rho/mount_instance.ex`) — struct: `module`, `opts`, `scope`, `priority`
- `Rho.MountRegistry` (`lib/rho/mount_registry.ex`) — GenServer + ETS
  - Registration: `register/2`, `clear/0`
  - Collection: `collect_tools/1`, `collect_prompt_sections/1`, `collect_bindings/1`, `render_binding_metadata/1`
  - Dispatch: `dispatch_before_llm/2`, `dispatch_before_tool/2`, `dispatch_after_tool/3`, `dispatch_after_step/3`
- Tests: `test/rho/mount_registry_test.exs`

### Modules Implementing `@behaviour Rho.Mount`

| Module | File | Affordances | Hooks |
|--------|------|-------------|-------|
| `Rho.Tools.Bash` | `lib/rho/tools/bash.ex` | `tools/2` | — |
| `Rho.Tools.FsRead` | `lib/rho/tools/fs_read.ex` | `tools/2` | — |
| `Rho.Tools.FsWrite` | `lib/rho/tools/fs_write.ex` | `tools/2` | — |
| `Rho.Tools.FsEdit` | `lib/rho/tools/fs_edit.ex` | `tools/2` | — |
| `Rho.Tools.WebFetch` | `lib/rho/tools/web_fetch.ex` | `tools/2` | — |
| `Rho.Tools.Python` | `lib/rho/tools/python.ex` | `tools/2` + `bindings/2` | — |
| `Rho.Tools.Sandbox` | `lib/rho/tools/sandbox.ex` | `tools/2` + `bindings/2` | — |
| `Rho.Mounts.JournalTools` | `lib/rho/mounts/journal_tools.ex` | `tools/2` + `bindings/2` | — |
| `Rho.Mounts.MultiAgent` | `lib/rho/mounts/multi_agent.ex` | `tools/2` | — |
| `Rho.Skills` | `lib/rho/skills.ex` | `tools/2` + `prompt_sections/2` | — |
| `Rho.Plugins.StepBudget` | `lib/rho/plugins/step_budget.ex` | `tools/2` | `after_step/4` |
| `Rho.Plugins.Subagent` | `lib/rho/plugins/subagent.ex` | `tools/2` | `after_tool/4` |
| `Rho.Builtin` | `lib/rho/builtin.ex` | — | — |

## Agent System

### Agent.Worker (`lib/rho/agent/worker.ex`)

Unified GenServer that replaces both `Session.Worker` and `Subagent.Worker`. Every agent — primary, delegated, or nested — is the same process shape.

Key fields: `agent_id`, `session_id`, `role`, `depth`, `capabilities`, `mailbox`, `bus_subscriptions`, `subscribers`.

- Publishes events to signal bus via `Rho.Comms` AND direct broadcast to subscriber pids (dual-path)
- Registers in `Rho.Agent.Registry` at init, unregisters at terminate
- Subscribes to inbox topic on signal bus at init
- Processes signals from mailbox when idle
- Supports `collect/2` for delegated agents (deferred reply pattern)

### Agent.Registry (`lib/rho/agent/registry.ex`)

ETS-backed discovery: `register/2`, `unregister/1`, `find_by_role/2`, `find_by_capability/2`, `list/1`, `get/1`, `count/1`.

### Agent.Supervisor (`lib/rho/agent/supervisor.ex`)

Single `DynamicSupervisor` for all agents across all sessions.

### Session (`lib/rho/session.ex`)

Session = namespace for a group of cooperating agents. The primary agent has id `"primary_#{session_id}"`.

- `ensure_started/2` — starts primary agent worker
- `whereis/1` — looks up primary agent via `Rho.AgentRegistry`
- `submit/3`, `subscribe/2`, `cancel/1` — delegate to primary `Agent.Worker`
- `agents/1` — list all agents in a session via `Agent.Registry`
- `stop/1` — stop all agents in a session

### Comms (`lib/rho/comms.ex`, `lib/rho/comms/signal_bus.ex`)

Signal bus abstraction wrapping `jido_signal`. All coordination-plane code talks to `Rho.Comms`, never to jido_signal directly.

- `publish/3` — create and publish a `Jido.Signal` to `:rho_bus`
- `subscribe/2` — subscribe to pattern, receive `{:signal, %Jido.Signal{}}` messages
- `unsubscribe/1`, `replay/2`

### MultiAgent Mount (`lib/rho/mounts/multi_agent.ex`)

Provides tools: `delegate_task`, `await_task`, `send_message`, `list_agents`. Depth-gated (tools hidden at max depth). Guardrails: max 10 agents/session, max depth 3.

## Reasoner Architecture

The reason+act phase of the agent loop is delegated to a pluggable **Reasoner** strategy.

- `Rho.Reasoner` (`lib/rho/reasoner.ex`) — behaviour with `run/4` callback
  - Returns `{:continue, entries}`, `{:done, entries}`, or `{:final, value, entries}`
- `Rho.Reasoner.Direct` (`lib/rho/reasoner/direct.ex`) — standard tool-use loop: send tools+prompt to LLM, execute tool calls, return results
- Config: `reasoner: :direct` (default) or a module implementing `Rho.Reasoner`
- `Rho.Config.resolve_reasoner/1` resolves atom shorthands to modules

### Tool Resolution (single path)

In `Agent.Worker.resolve_all_tools/2`: calls `Rho.MountRegistry.collect_tools(context)` which collects tools from all active mounts for the given context.

### Context Map Shape

The context map passed to mount callbacks (`Rho.Mount.Context`):
```elixir
%{
  tape_name: String.t(),        # memory reference (agent-scoped)
  workspace: String.t(),        # working directory (may be sandbox mount path)
  agent_name: atom(),           # :default, :coder, :researcher, etc.
  agent_id: String.t(),         # unique agent identifier
  session_id: String.t(),       # session this agent belongs to
  depth: integer(),             # 0 for primary agent, +1 per delegation level
  sandbox: nil | Rho.Sandbox.t()
}
```

### Tool Definition Shape

```elixir
%{
  tool: ReqLLM.Tool.t(),       # schema: name, description, parameter_schema
  execute: (map() -> {:ok, String.t()} | {:error, term()})
}
```

## Key Integration Points in Agent Loop

### Prompt Assembly (`lib/rho/agent_loop.ex`)
- System prompt + prompt sections: `Rho.MountRegistry.collect_prompt_sections(context)`
- Bindings + metadata: `Rho.MountRegistry.collect_bindings(context)` + `render_binding_metadata/1`
- Memory context: `memory_mod.build_context(tape_name)` builds message history

### Reason+Act (`Rho.Reasoner.Direct`)
- AgentLoop delegates reason+act to the active Reasoner strategy
- `Rho.Reasoner.Direct` handles: LLM call, tool execution, before_tool/after_tool dispatch
- AgentLoop retains: outer loop, step counting, compaction, before_llm, after_step dispatch
- Before LLM: `Rho.MountRegistry.dispatch_before_llm(projection, context)` (in AgentLoop)
- Before tool: `Rho.MountRegistry.dispatch_before_tool(call, context)` (in Reasoner)
- Execution: `tool_def.execute.(args)` (in Reasoner)
- After tool: `Rho.MountRegistry.dispatch_after_tool(call, result, context)` (in Reasoner)
- After step: `Rho.MountRegistry.dispatch_after_step(step, max_steps, context)` (in AgentLoop)

## Config System

- `.rho.exs` — per-agent config: `model`, `system_prompt`, `mounts` (atom list or module list), `max_steps`, `reasoner` (`:direct` or module)
- `Rho.Config` (`lib/rho/config.ex`) — `@mount_modules` maps shorthand atoms → modules: `bash`, `fs_read`, `fs_write`, `fs_edit`, `web_fetch`, `python`, `skills`, `subagent`, `multi_agent`, `sandbox`, `journal`, `step_budget`
- `Config.resolve_mount/1` resolves atoms/tuples to `{module, opts}` pairs
- Role-specific agent profiles (`:researcher`, `:coder`, etc.) are defined in `.rho.exs` and used by `delegate_task`

## Supervision Tree (`lib/rho/application.ex`)

```
Rho.Supervisor (one_for_one)
├── Registry (Rho.AgentRegistry)         # agent_id → pid lookup
├── Registry (Rho.PythonRegistry)        # Python interpreter tracking
├── Task.Supervisor (Rho.TaskSupervisor)
├── DynamicSupervisor (Python.Supervisor)
├── MountRegistry
├── Rho.Comms.SignalBus                  # jido_signal bus (:rho_bus)
├── [Memory children]
├── Rho.Agent.Supervisor                 # DynamicSupervisor for all agent workers
├── CLI
└── [Web children]                       # conditional
```

## Running Tests

```bash
mix test                                    # full suite
mix test test/rho/mount_registry_test.exs   # mount registry
```
