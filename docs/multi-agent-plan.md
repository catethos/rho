# Rho Multi-Agent Rewrite Plan

## Executive Summary

Rho today is a single-agent LLM framework with a basic parent→child subagent bolt-on. This plan rewrites the orchestration layer to make every agent a first-class peer that communicates via signals, while preserving the proven execution core (AgentLoop, tape memory, mounts, reasoners).

We adopt `jido_signal` as the coordination backbone **without** the core `jido` agent framework. Rho keeps its own agent model — LLM reasoning loops with side effects — because Jido's pure-functional `cmd/2` abstraction is a poor fit for streaming tool-calling agents. But Jido's signal infrastructure (pub/sub bus, pattern-matched routing, causality journal, replay) is exactly what's missing for agent-to-agent coordination.

**Ecosystem cherry-pick:**

| Package | Status | Role |
|---------|--------|------|
| `req_llm` | Already used | LLM HTTP client |
| `jido_signal` | **Adopt** | Inter-agent communication, routing, causality tracking |
| `jido` (core) | Skip | Rho's AgentLoop + mounts is a better fit for LLM agents |
| `jido_action` | Skip | Rho tools aren't state transformers |
| `jido_ai` | Skip | Redundant — Rho already integrates req_llm directly |

---

## Architecture: Three Planes

The rewrite separates concerns into three planes. Each plane has a clear responsibility and a clear boundary.

```
┌─────────────────────────────────────────────────────┐
│                   EDGE PLANE                        │
│  CLI adapter, Web/WS adapter, future adapters       │
│  Subscribe to session event topics on the bus       │
└──────────────────────┬──────────────────────────────┘
                       │ signals
┌──────────────────────▼──────────────────────────────┐
│               COORDINATION PLANE                    │
│  Signal Bus (jido_signal)                           │
│  Agent Registry (role/capability discovery)         │
│  Orchestration (delegation, messaging, completion)  │
│  Causality Journal (debug/replay)                   │
└──────────────────────┬──────────────────────────────┘
                       │ function calls (not signals)
┌──────────────────────▼──────────────────────────────┐
│                EXECUTION PLANE                      │
│  AgentLoop (recursive LLM tool-calling)             │
│  Reasoner (Direct, future: FSM, Chain-of-Thought)   │
│  Tape Memory (per-agent, append-only JSONL)         │
│  Mount System (tools, prompt sections, hooks)       │
└─────────────────────────────────────────────────────┘
```

### Why this split

- **Execution plane** is the part that works well today. AgentLoop, tapes, mounts, and reasoners are Rho's core value. They should not know about signals, buses, or multi-agent coordination.
- **Coordination plane** is the part being rewritten. Today it's a hacky parent→child model with ETS polling. Tomorrow it's a proper signal-based communication layer.
- **Edge plane** is the part that connects to humans. CLI and web adapters should be thin subscribers to session event streams, not owners of session lifecycle.

---

## What Changes, What Stays

### Keep (execution plane)

| Module | Why |
|--------|-----|
| `Rho.AgentLoop` | Core reasoning loop. Works well. No signals needed inside it. |
| `Rho.AgentLoop.Runtime` | Immutable config per loop invocation. Clean design. |
| `Rho.AgentLoop.Recorder` | Tape writes during loop. Stays internal. |
| `Rho.TurnStrategy` behaviour + `TurnStrategy.Direct` | Strategy pattern for one reason+act iteration. (Was `Rho.Reasoner`.) |
| `Rho.PluginRegistry.apply_stage/3` | Transformer pipeline at 6 typed stages. (Was `Rho.Lifecycle`; deleted.) |
| `Rho.Plugin` behaviour | Plugin interface for tools, prompt sections, bindings. (Was `Rho.Mount`; alias kept.) |
| `Rho.PluginRegistry` | GenServer + ETS registration. (Was `Rho.MountRegistry`; delegate kept.) |
| `Rho.Context` | Typed struct for plugin/transformer callbacks. (Was `Rho.Mount.Context`.) |
| `Rho.Tape.Context` behaviour + `Rho.Tape.Context.Tape` | Pluggable tape-context backend. (Was `Rho.Memory`.) |
| `Rho.Tape.*` (Store, Service, Entry, View, Compact, Fork) | Append-only event log with JSONL persistence. Battle-tested. |
| `Rho.Config` | .rho.exs config with agent profiles. Extend with role definitions. |
| `Rho.Tools.*` (Bash, FsRead, FsWrite, FsEdit, etc.) | LLM-facing tools. No changes needed. |
| `Rho.Skills` | Skill discovery and prompt injection. Stays. |

### Rewrite (coordination plane)

| Current | Becomes | Why |
|---------|---------|-----|
| `Rho.Session.Worker` | `Rho.Agent.Worker` | Every agent is a peer worker, not just top-level sessions. Done. |
| `Rho.Plugins.Subagent` | `Rho.Mounts.MultiAgent` | Plugin providing `delegate_task`, `send_message`, `await_task`, `list_agents`, `find_capable`. Done. |
| `Rho.Plugins.Subagent.Worker` | Removed (absorbed into Agent.Worker) | No more "subagent" vs "real agent" distinction. Done. |
| `Rho.Plugins.Subagent.Supervisor` | `Rho.Agent.Supervisor` | One DynamicSupervisor for all agent workers. Done. |
| `Rho.Session` (facade) | `Rho.Agent.Primary` | Thin helper for session's primary agent convention. Done. |
| Subscriber maps in Worker | Signal bus via `Rho.Comms` | Events flow through bus, not hand-rolled broadcast. Done (Phase 5). |
| ETS status polling for subagent completion | Signal-based task completion | `rho.task.completed` signals replace polling. Done. |

### Adapt (edge plane)

| Current | Becomes | Why |
|---------|---------|-----|
| `Rho.CLI` | Subscribes to `rho.session.<sid>.events.**` on signal bus | Thin adapter, no direct GenServer coupling to session |
| `Rho.Web.Socket` | Same pattern — bus subscriber | Already close to this model |

---

## New Modules

### 1. `Rho.Comms` — Signal abstraction layer

**What:** A behaviour + default implementation wrapping `jido_signal`. All coordination-plane code talks to `Rho.Comms`, never to `jido_signal` directly.

**Why:** Prevents jido_signal APIs from bleeding into AgentLoop, mounts, and tools. Provides a rollback path if jido_signal proves awkward. Keeps the dependency contained.

**How:**

```elixir
defmodule Rho.Comms do
  @moduledoc """
  Signal-based communication layer for inter-agent messaging.
  Wraps jido_signal with Rho-specific conventions.
  """

  @type signal_type :: String.t()
  @type payload :: map()
  @type meta :: keyword()

  @callback publish(signal_type(), payload(), meta()) :: :ok | {:error, term()}
  @callback subscribe(pattern :: String.t(), opts :: keyword()) :: {:ok, reference()}
  @callback unsubscribe(reference()) :: :ok
  @callback replay(pattern :: String.t(), opts :: keyword()) :: {:ok, [map()]}
end
```

Default implementation: `Rho.Comms.JidoSignal` — starts a `Jido.Signal.Bus` named `:rho_bus` in the supervision tree, wraps publish/subscribe/replay calls.

### 2. `Rho.Agent.Worker` — Unified agent process

**What:** GenServer that replaces both `Session.Worker` and `Subagent.Worker`. Every agent — whether the primary chat agent, a delegated researcher, or a nested sub-task worker — is the same process shape.

**Why:** Today "subagents" are second-class: they run with `Lifecycle.noop()`, can't receive messages after spawn, can't be addressed by peers. Making every agent the same shape enables peer messaging, delegation, and dynamic orchestration.

**How:**

```elixir
defmodule Rho.Agent.Worker do
  use GenServer, restart: :transient

  defstruct [
    :agent_id,        # unique identifier (e.g., "agent_abc123")
    :session_id,      # session this agent belongs to
    :role,            # :primary | :researcher | :coder | :reviewer | custom atom
    :workspace,
    :memory_mod,
    :memory_ref,      # tape name
    :agent_name,      # config profile name from .rho.exs
    :task_ref,
    :task_pid,
    :current_turn_id,
    :bus_subscriptions,  # list of signal subscription refs
    capabilities: [],    # [:bash, :fs_read, :web_fetch, ...]
    status: :idle,       # :idle | :busy | :cancelling
    mailbox: :queue.new() # queued signals waiting to become turns
  ]
end
```

Key differences from current `Session.Worker`:
- Has an `agent_id` separate from `session_id` (multiple agents per session)
- Has a `role` and `capabilities` for discovery
- Has a `mailbox` queue of incoming signals (not just raw text content)
- Subscribes to its inbox topic on the signal bus at init
- Publishes events to the bus instead of broadcasting to subscriber pids
- Full mount/lifecycle support regardless of depth (no more `subagent: true` noop)

Lifecycle:
1. `init` → bootstrap tape, subscribe to `rho.session.<sid>.agent.<aid>.inbox`
2. Incoming signal → enqueue in mailbox
3. When idle → dequeue one signal → start an AgentLoop turn
4. AgentLoop emits events → publish as signals to `rho.session.<sid>.events`
5. Turn finishes → publish `rho.turn.finished` → dequeue next signal

### 3. `Rho.Agent.Registry` — Agent discovery

**What:** ETS-based registry for finding agents by role, capability, or session.

**Why:** Agents need to answer "who can do X?" for delegation. The signal bus routes messages; the registry answers queries about agent population.

**How:**

```elixir
defmodule Rho.Agent.Registry do
  @moduledoc """
  Tracks running agents and their capabilities for discovery.
  Separate from the signal bus — the bus routes, the registry queries.
  """

  def register(agent_id, attrs)    # attrs: session_id, role, capabilities, pid
  def unregister(agent_id)
  def find_by_role(session_id, role)
  def find_by_capability(session_id, capability)
  def list(session_id)
  def get(agent_id)
end
```

Backed by a named ETS table (`:rho_agent_registry`). Workers register themselves at init and unregister at terminate.

### 4. `Rho.Mounts.MultiAgent` — LLM-facing multi-agent tools

**What:** A mount that replaces `Rho.Plugins.Subagent`. Provides tools the LLM can call to interact with other agents.

**Why:** The current `spawn_subagent`/`collect_subagent` tools model a one-way fire-and-forget pattern. Multi-agent needs delegation, messaging, and discovery.

**How:** Provides these tools:

#### `delegate_task`
Spawn a new agent (or route to an existing one) to handle a subtask.

```
delegate_task(
  task: "Research the performance characteristics of ETS vs Redis for session storage",
  role: "researcher",         # optional: spawn with this role
  target: "agent_abc123",     # optional: send to existing agent instead of spawning
  context_summary: "We're evaluating storage backends for Rho's tape system",
  inherit_context: false,     # fork parent tape if true
  max_steps: 30
)
→ {:ok, "Delegated task_t1234 to agent_xyz789 (role: researcher)"}
```

Under the hood:
1. Spawn a new `Agent.Worker` (or find existing by role/target)
2. Publish `rho.task.requested` signal with task details
3. Return task_id + agent_id immediately

#### `send_message`
Send a direct message to another agent.

```
send_message(
  target: "agent_xyz789",     # agent_id or role
  message: "Can you also check Redis Cluster mode?",
  task_id: "task_t1234"       # optional: correlate with existing task
)
→ {:ok, "Message sent to agent_xyz789"}
```

Under the hood: publish signal to target's inbox topic.

#### `await_task`
Block until a delegated task completes.

```
await_task(
  task_id: "task_t1234",
  timeout: 300                # seconds, default 300
)
→ {:ok, "Research complete. ETS is faster for single-node..."}
```

Under the hood: subscribe to `rho.task.<task_id>.completed`, wait for signal.

#### `list_agents`
Discover what agents are available in this session.

```
list_agents()
→ {:ok, "Active agents:\n- agent_abc (primary, idle)\n- agent_xyz (researcher, busy: step 5/30)"}
```

Under the hood: query `Rho.Agent.Registry`.

### 5. `Rho.Agent.Primary` — Session management (completed)

> **Completed.** `Rho.Session` was collapsed into `Rho.Agent.Primary` +
> `Rho.Agent.Worker` + `Rho.Agent.Registry`. See CLAUDE.md.

A session is a `session_id` namespace. `Rho.Agent.Primary` centralises
the primary-agent convention:

- `ensure_started/2` — find or start the primary agent + EventLog
- `resume/2` — alias for `ensure_started` (tape context loads from disk)
- `list_resumable/1` — discover sessions with event logs but no live agent
- `stop/1` — stop all agents + EventLog in a session
- `inject/4` — deliver a message to a specific agent or the primary
- `list/1` — list live primary agents

---

## Signal Taxonomy

All signals follow a hierarchical naming convention for pattern-matched routing.

### Control signals (agent-to-agent)

| Signal type | Payload | When |
|-------------|---------|------|
| `rho.task.requested` | `%{task_id, session_id, agent_id, parent_agent_id, role, task, context_summary, max_steps}` | Agent delegates a task |
| `rho.task.accepted` | `%{task_id, agent_id, session_id}` | Worker begins processing a delegated task |
| `rho.task.completed` | `%{agent_id, session_id, result, task_id?}` | Delegated agent finishes (depth > 0). `result` is text or `"error: ..."` on failure. `task_id` present when correlated to a `rho.task.requested`. |
| `rho.session.*.events.message_sent` | `%{session_id, agent_id, from, to, message}` | Direct message between agents |
| `rho.session.*.events.broadcast` | `%{session_id, agent_id, from, message, target_count}` | Broadcast to all session agents |

### Runtime events (observability)

| Signal type | Payload | When |
|-------------|---------|------|
| `rho.turn.started` | `%{agent_id, turn_id}` | Agent begins processing a turn |
| `rho.turn.finished` | `%{agent_id, turn_id, result}` | Agent finishes a turn |
| `rho.turn.cancelled` | `%{agent_id, turn_id}` | Turn was cancelled |
| `rho.agent.step` | `%{agent_id, step, max_steps}` | AgentLoop step started |
| `rho.agent.tool.started` | `%{agent_id, tool_name, args}` | Tool execution started |
| `rho.agent.tool.finished` | `%{agent_id, tool_name, status, output, latency_ms}` | Tool execution finished |
| `rho.agent.llm_usage` | `%{agent_id, step, usage}` | Token usage stats |
| `rho.agent.error` | `%{agent_id, reason}` | Agent-level error |
| `rho.agent.compact` | `%{agent_id, tape_name}` | Tape compaction occurred |

### Lifecycle events

| Signal type | Payload | When |
|-------------|---------|------|
| `rho.agent.started` | `%{agent_id, session_id, role, capabilities}` | Agent worker started |
| `rho.agent.stopped` | `%{agent_id, session_id}` | Agent worker stopped |
| `rho.session.started` | `%{session_id}` | Session namespace created |
| `rho.session.stopped` | `%{session_id}` | Session ended |

### User-facing events

| Signal type | Payload | When |
|-------------|---------|------|
| `rho.user.input` | `%{session_id, content}` | Human sends a message |
| `rho.text.delta` | `%{agent_id, text}` | Streaming text chunk from LLM |

### Routing patterns

The signal bus uses trie-based pattern matching with wildcards:

```elixir
# Agent inbox — direct messages
"rho.session.<sid>.agent.<aid>.inbox"

# All events for a session — UI adapters subscribe here
"rho.session.<sid>.events.**"

# All task completions for a session — orchestrator subscribes here
"rho.session.<sid>.task.*.completed"

# Everything from a specific agent — debugging
"rho.session.<sid>.agent.<aid>.**"
```

### Causality tracking

Every signal carries `jido_signal` causality fields:

- `id` — unique signal ID (auto-generated)
- `source` — originating agent (`/session/<sid>/agent/<aid>`)
- `subject` — what this signal is about (`/task/<task_id>`)
- `causation_id` — the signal that directly caused this one
- `correlation_id` — shared across a causal chain (e.g., task_id)

This gives us a full cause-effect graph for debugging agent swarms. "Why did the coder agent edit the wrong file?" → trace back through the causality chain to see what instructions it received and from whom.

---

## What Happens to the `emit` Callback

Today, `AgentLoop` takes an `emit` callback that fires on events like `:text_delta`, `:tool_start`, `:tool_result`. This is Rho's internal event system.

**In the rewrite, the `emit` callback becomes a signal publisher.** The `Agent.Worker` wraps the bus publish call as the emit function passed to AgentLoop:

```elixir
# In Agent.Worker, when starting a turn:
emit = fn event ->
  # Write to tape (same as today)
  memory_mod.append_from_event(memory_ref, event)

  # Publish to bus (replaces subscriber broadcast)
  signal_type = "rho.#{event_to_signal_type(event)}"
  payload = Map.merge(event, %{agent_id: state.agent_id, session_id: state.session_id})
  Rho.Comms.publish(signal_type, payload,
    source: "/session/#{state.session_id}/agent/#{state.agent_id}",
    correlation_id: turn_id
  )
end
```

AgentLoop itself does not change. It still calls `emit.(event)` as before. The difference is what the closure does — publish to a bus instead of sending to subscriber pids.

---

## File Structure After Rewrite

```
lib/rho/
  application.ex           # Updated supervision tree
  config.ex                # Add role definitions, agent_id generation

  # --- Execution plane (mostly unchanged) ---
  agent_loop.ex            # No changes
  agent_loop/
    recorder.ex            # No changes
    runtime.ex             # No changes
    tape.ex                # No changes
  reasoner.ex              # No changes
  reasoner/
    direct.ex              # No changes
  lifecycle.ex             # No changes
  mount.ex                 # No changes
  mount_instance.ex        # No changes
  mount_registry.ex        # No changes
  mount/
    context.ex             # Add :agent_id field
  memory.ex                # No changes
  memory/
    tape.ex                # No changes
  tape/
    entry.ex               # No changes
    store.ex               # No changes
    service.ex             # No changes
    view.ex                # No changes
    compact.ex             # No changes
    fork.ex                # No changes
  tools/
    bash.ex                # No changes
    fs_read.ex             # No changes
    fs_write.ex            # No changes
    fs_edit.ex             # No changes
    web_fetch.ex           # No changes
    python.ex              # No changes
    anchor.ex              # No changes
    search_history.ex      # No changes
    recall_context.ex      # No changes
    clear_memory.ex        # No changes
    finish.ex              # No changes — used by agents to signal task completion
    path_utils.ex          # No changes
    sandbox.ex             # No changes
  skill.ex                 # No changes
  skills.ex                # No changes
  builtin.ex               # No changes

  # --- Coordination plane (new/rewritten) ---
  comms.ex                 # Behaviour: publish, subscribe, unsubscribe, replay
  comms/
    jido_signal.ex         # Default implementation wrapping jido_signal bus
  agent/
    worker.ex              # Unified agent process (replaces Session.Worker + Subagent.Worker)
    registry.ex            # ETS-based agent discovery by role/capability
    supervisor.ex          # DynamicSupervisor for all agent workers
  session.ex               # Rewritten: session = namespace for agent group
  mounts/
    journal_tools.ex       # No changes
    multi_agent.ex         # New: delegate_task, send_message, await_task, list_agents

  # --- Edge plane (adapted) ---
  cli.ex                   # Subscribe to bus instead of Session.subscribe
  web/
    socket.ex              # Subscribe to bus instead of Session.subscribe
    ...                    # Other web files unchanged

  # --- Removed ---
  # plugins/subagent.ex        → replaced by mounts/multi_agent.ex
  # plugins/subagent/worker.ex → replaced by agent/worker.ex
  # plugins/subagent/ui.ex     → absorbed into cli.ex event rendering
  # plugins/subagent/supervisor.ex → replaced by agent/supervisor.ex
  # session/worker.ex          → replaced by agent/worker.ex
  # session/supervisor.ex      → replaced by agent/supervisor.ex
```

---

## Supervision Tree After Rewrite

```
Rho.Supervisor (one_for_one)
├── Registry (Rho.AgentRegistry)          # agent_id → pid lookup
├── Registry (Rho.PythonRegistry)         # Python interpreter tracking
├── Task.Supervisor (Rho.TaskSupervisor)
├── DynamicSupervisor (Python.Supervisor)
├── Rho.PluginRegistry                    # plugin + transformer dispatch
├── Rho.Comms.SignalBus                   # jido_signal bus (:rho_bus)
├── [Tape children]                       # from memory_mod.children/1
├── Rho.Agent.Supervisor                  # DynamicSupervisor for all agents
├── Registry (Rho.EventLogRegistry)
├── DynamicSupervisor (EventLog.Supervisor)
├── Rho.CLI
└── [Web children]                        # conditional
```

One flat `Agent.Supervisor` for all agents across all sessions. Session scoping is logical (via session_id), not structural.

---

## Implementation Order

Each step produces a working system. The rule from the original build-plan still holds: **if you can't interact with it, it's not done.**

### Step 1: Add jido_signal dependency and Rho.Comms

**Goal:** Signal bus runs, can publish and subscribe from iex.

1. Add `{:jido_signal, "~> 2.0"}` to mix.exs
2. Create `lib/rho/comms.ex` — behaviour definition
3. Create `lib/rho/comms/jido_signal.ex` — implementation that starts a `Jido.Signal.Bus`
4. Add `Rho.Comms.JidoSignal` to supervision tree in `application.ex`
5. Test: `iex -S mix` → `Rho.Comms.publish("test.hello", %{msg: "hi"})` → subscriber receives it

**Feedback:** Open iex, publish a signal, see it arrive at a subscriber process.

### Step 2: Create Agent.Worker (single-agent, drop-in replacement)

**Goal:** Replace `Session.Worker` with `Agent.Worker` for the single-agent case. Everything still works exactly as before from the CLI.

1. Create `lib/rho/agent/worker.ex` — GenServer with agent_id, session_id, role, mailbox
2. Create `lib/rho/agent/supervisor.ex` — DynamicSupervisor
3. Create `lib/rho/agent/registry.ex` — ETS-based discovery
4. Rewrite `lib/rho/session.ex` — `ensure_started` now spawns an `Agent.Worker` with role `:primary`
5. Agent.Worker publishes events to bus via emit callback (alongside direct subscriber broadcast for backward compat during transition)
6. Remove `lib/rho/session/worker.ex` and `lib/rho/session/supervisor.ex`

**Feedback:** `mix rho.chat` works exactly as before. `Rho.Agent.Registry.list("cli:default")` shows the primary agent.

### Step 3: Migrate CLI and Web to bus subscribers

**Goal:** CLI and Web adapters subscribe to session events via the signal bus instead of direct `Session.subscribe`.

1. Update `Rho.CLI` to subscribe to `rho.session.<sid>.events.**` on the bus
2. Update `Rho.Web.Socket` similarly
3. Agent.Worker stops maintaining subscriber maps — all event delivery goes through the bus
4. Remove backward-compat direct broadcast from Step 2

**Feedback:** `mix rho.chat` works. Events flow through the signal bus. You can spy on them from iex.

### Step 4: Multi-agent tools (delegate_task, await_task)

**Goal:** The primary agent can delegate tasks to peer agents via LLM tool calls.

1. Create `lib/rho/mounts/multi_agent.ex` implementing `Rho.Mount`
2. Implement `delegate_task` tool:
   - Spawns a new `Agent.Worker` with its own tape, role, and agent_id
   - Publishes `rho.task.requested` signal to the new agent's inbox
   - New agent processes it as a normal turn
   - Returns task_id + agent_id immediately
3. Implement `await_task` tool:
   - Subscribes to `rho.task.<task_id>.completed`
   - Blocks until signal arrives or timeout
   - Returns the result text
4. New agent publishes `rho.task.completed` when its `finish` tool is called
5. Register mount in config: add `:multi_agent` to mount_modules map
6. Remove `lib/rho/plugins/subagent.ex` and `lib/rho/plugins/subagent/`

**Feedback:** In chat, ask "Research X and Y in parallel" → agent calls `delegate_task` twice → two peer agents spin up → primary calls `await_task` → results come back.

### Step 5: send_message and list_agents

**Goal:** Agents can send direct messages to each other and discover peers.

1. Add `send_message` tool to `Rho.Mounts.MultiAgent`:
   - Publishes to target agent's inbox topic
   - Target agent processes it as a queued turn
2. Add `list_agents` tool:
   - Queries `Rho.Agent.Registry` for the current session
   - Returns agent_id, role, status, capabilities
3. Agents can now have multi-turn conversations with each other

**Feedback:** In chat, delegate a task, then send a follow-up message to the delegated agent. The agent incorporates the new information.

### Step 6: Causality tracking and replay

**Goal:** Debug multi-agent conversations by tracing signal causality.

1. Enable `Jido.Signal.Journal` integration in `Rho.Comms.JidoSignal`
2. Set `causation_id` and `correlation_id` on every published signal
3. Create `mix rho.signals` mix task for inspecting signal history:
   - `mix rho.signals list --session <sid>` — show all signals
   - `mix rho.signals trace --task <task_id>` — show causal chain for a task
   - `mix rho.signals replay --session <sid> --since 5m` — replay recent signals
4. Wire into `mix rho.trace` for combined tape + signal analysis

**Feedback:** Run a multi-agent conversation, then `mix rho.signals trace --task <task_id>` shows the full delegation chain.

### Step 7 (future): Advanced orchestration patterns

Not part of the initial rewrite, but the signal infrastructure enables these:

- **Pipeline:** Agent A → Agent B → Agent C, each processing in sequence
- **Debate:** Two agents argue, a judge agent decides
- **Voting:** Multiple agents propose, session collects votes
- **Supervisor agent:** An LLM-powered orchestrator that dynamically spawns and manages workers
- **Human-in-the-loop:** Pause a task, route to human for approval via signal
- **Cross-session:** Agents in different sessions collaborate via shared bus topics

---

## Config Changes

### .rho.exs additions

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a helpful assistant.",
    mounts: [:bash, :fs_read, :fs_write, :fs_edit, :journal, :multi_agent],
    max_steps: 50,
    # New: default roles for delegated agents
    delegation: [
      default_role: :worker,
      max_agents_per_session: 10,
      max_depth: 3,
      default_max_steps: 30
    ]
  ],
  # New: role-specific agent profiles
  researcher: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a research agent. Focus on thorough investigation.",
    mounts: [:bash, :fs_read, :web_fetch],
    max_steps: 30
  ],
  coder: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a coding agent. Write clean, tested code.",
    mounts: [:bash, :fs_read, :fs_write, :fs_edit],
    max_steps: 40
  ]
}
```

When `delegate_task(role: "researcher")` is called, the worker spawns with the `:researcher` agent profile.

---

## Guardrails

Multi-agent systems can spiral. These limits prevent runaway behavior:

| Guardrail | Default | Where |
|-----------|---------|-------|
| Max agents per session | 10 | `Rho.Agent.Supervisor` checks count before spawn |
| Max depth (nested delegation) | 3 | `Rho.Mounts.MultiAgent` checks depth before providing delegate_task tool |
| Max steps per agent | 30 (delegated), 50 (primary) | Config per role profile |
| Task timeout | 5 minutes | `await_task` tool default |
| Message budget per session | 100 signals/minute | Signal bus rate limiting |
| Payload size limit | Summaries + refs only, no raw histories | `delegate_task` carries `context_summary`, not full tape |
| Idempotent task handling | Task IDs checked before processing | Agent.Worker deduplicates by task_id |

---

## Migration Path

The steps are ordered so that at every point, `mix rho.chat` works:

1. **Step 1** — Bus runs alongside existing system. No behavioral change.
2. **Step 2** — Agent.Worker replaces Session.Worker. CLI still works via direct subscribers (temporary).
3. **Step 3** — CLI moves to bus. Old subscriber code removed.
4. **Step 4** — Multi-agent tools replace subagent tools. Delegation works.
5. **Step 5** — Peer messaging. Agents talk to each other.
6. **Step 6** — Observability. Debug and replay multi-agent conversations.

At no point is the system broken. Each step is independently testable.

---

## Dependencies After Rewrite

```elixir
defp deps do
  [
    {:req_llm, "~> 1.6"},          # LLM HTTP client (already used)
    {:jido_signal, "~> 2.0"},      # NEW: signal bus, routing, causality
    {:jason, "~> 1.4"},            # JSON (already used)
    {:dotenvy, "~> 1.1"},          # .env loading (already used)
    {:yaml_elixir, "~> 2.11"},     # Skills YAML (already used)
    {:bandit, "~> 1.6"},           # HTTP server (already used)
    {:websock_adapter, "~> 0.5"},  # WebSocket (already used)
    {:plug, "~> 1.16"},            # HTTP (already used)
    {:floki, "~> 0.37"},           # HTML parsing (already used)
    {:pythonx, "~> 0.4"},          # Python interop (already used)
    {:mimic, "~> 1.10", only: :test}
  ]
end
```

Only one new dependency: `jido_signal`.
