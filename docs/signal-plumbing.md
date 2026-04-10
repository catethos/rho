# Signal Plumbing Architecture

Detailed reference for Rho's signal-based event system. Covers the
three-plane signal flow, task delegation lifecycle, capability routing,
edge rendering in the Observatory, EventLog persistence, and session
resume.

## Table of Contents

1. [Bus Abstraction](#bus-abstraction)
2. [Signal Taxonomy](#signal-taxonomy)
3. [Task Delegation Lifecycle](#task-delegation-lifecycle)
4. [Capability System](#capability-system)
5. [Signal Producers](#signal-producers)
6. [Signal Consumers](#signal-consumers)
7. [EventLog Persistence](#eventlog-persistence)
8. [Observatory Edge Rendering](#observatory-edge-rendering)
9. [Session Resume](#session-resume)
10. [Dual Delivery: Bus vs Mailbox](#dual-delivery-bus-vs-mailbox)

---

## Bus Abstraction

All inter-process event delivery flows through a single signal bus
(`:rho_bus`) backed by `Jido.Signal.Bus`. The Rho-specific wrapper
lives in two modules:

- **`Rho.Comms`** (`lib/rho/comms.ex`) — public API facade
- **`Rho.Comms.SignalBus`** (`lib/rho/comms/signal_bus.ex`) — GenServer
  process started in the supervision tree

### publish/3

```elixir
Comms.publish(type, payload, opts \\ [])
```

Creates a `Jido.Signal` and dispatches it to `:rho_bus`.

| Option | Default | Purpose |
|--------|---------|---------|
| `source` | `"/rho"` | URI identifying the publisher |
| `subject` | `nil` | URI identifying the target entity |
| `correlation_id` | `nil` | Stored in `signal.extensions` — used to group events into turns |
| `causation_id` | `nil` | Stored in `signal.extensions` — causal chain tracking |

### subscribe/2

```elixir
{:ok, sub_id} = Comms.subscribe(pattern, opts \\ [])
```

Subscribes `self()` (or `opts[:target]`) to signals matching `pattern`.
Patterns support wildcards: `"rho.session.abc.events.*"` matches all
session-scoped events for session `abc`.

Subscribers receive `{:signal, %Jido.Signal{type, data, source, ...}}`
messages asynchronously.

### replay/2

```elixir
{:ok, signals} = Comms.replay(pattern, since: 0)
```

Reads historical signals from the bus journal (when configured).

---

## Signal Taxonomy

Signals follow a hierarchical dotted naming convention. There are
four families:

### Agent lifecycle (`rho.agent.*`)

| Signal | Payload | When |
|--------|---------|------|
| `rho.agent.started` | `%{agent_id, session_id, role, capabilities}` | Worker `init/1` completes |
| `rho.agent.stopped` | `%{agent_id, session_id}` | Worker `terminate/2` |
| `rho.agent.spawned` | `%{session_id, agent_id, role}` | `spawn_agent` tool creates an idle agent |

### Task lifecycle (`rho.task.*`)

| Signal | Payload | When |
|--------|---------|------|
| `rho.task.requested` | `%{task_id, session_id, agent_id, parent_agent_id, role, task, context_summary?, max_steps}` | `delegate_task` spawns or routes a child task |
| `rho.task.accepted` | `%{task_id, agent_id, session_id}` | Worker begins processing a delegated task (in `start_turn`) |
| `rho.task.completed` | `%{agent_id, session_id, result, task_id?}` | Worker finishes a delegated task (depth > 0). `result` is text or `"error: ..."` |

### Session events (`rho.session.<sid>.events.*`)

Per-turn events emitted by the Runner/TurnStrategy during execution.
The `<sid>` segment is the session_id, enabling targeted subscriptions.

| Suffix | Payload | Notes |
|--------|---------|-------|
| `text_delta` | `text, turn_id, agent_id, session_id` | Streaming LLM output token |
| `llm_text` | `text, turn_id, agent_id, session_id` | Complete LLM text chunk |
| `tool_start` | `name, args, call_id, step, turn_id, agent_id, session_id` | Tool execution begins |
| `tool_result` | `name, output, status, call_id, turn_id, agent_id, session_id` | Tool execution result |
| `step_start` | `step, max_steps, turn_id, agent_id, session_id` | Runner step counter |
| `llm_usage` | `usage: %{input_tokens, output_tokens, ...}, turn_id, agent_id, session_id` | Token consumption |
| `turn_started` | `turn_id, agent_id, session_id` | Turn begins |
| `turn_finished` | `result, turn_id, agent_id, session_id` | Turn completes |
| `before_llm` | `agent_id, projection: %{context, tools, step}` | Debug info before LLM call |
| `structured_partial` | `partial, turn_id, agent_id, session_id` | Streaming structured output |
| `message_sent` | `session_id, agent_id, from, to, message` | Inter-agent direct message |
| `broadcast` | `session_id, agent_id, from, message, target_count` | Broadcast to all agents |
| `ui_spec` / `ui_spec_delta` | `spec, title, message_id` | UI rendering specs |
| `compact` | `agent_id, tape_name` | Tape compaction occurred |
| `error` | `agent_id, reason` | Agent-level error |

### Turn-level events (`rho.turn.*`)

Top-level turn events (not session-scoped). Published by Worker's
`publish_event` helper.

| Signal | Payload | When |
|--------|---------|------|
| `rho.turn.started` | `turn_id, agent_id, session_id` | Turn begins |
| `rho.turn.finished` | `turn_id, result, agent_id, session_id` | Turn completes |
| `rho.turn.cancelled` | `turn_id, agent_id, session_id` | Turn cancelled |

### Tape events (`rho.session.<sid>.tape.*`)

| Signal | Payload | When |
|--------|---------|------|
| `rho.session.<sid>.tape.entry_appended` | `tape_name, kind, data, agent_id, session_id` | Recorder appends to tape |

---

## Task Delegation Lifecycle

A task flows through four states, each marked by a signal:

```
delegate_task called
       │
       ▼
┌───────��──────┐     rho.task.requested
│   PENDING    │──── (parent publishes)
└──────┬───────┘
       │
       ▼
┌──────────────┐     rho.task.accepted
│   ACCEPTED   │──── (child publishes in start_turn)
└──────┬───────┘
       │  agent runs...
       ▼
┌──────────────┐     rho.task.completed
│  OK / ERROR  │──── (child publishes in maybe_publish_task_completed)
└──────────────┘
```

### Correlation

All three signals carry `task_id` (a string like `"task_12345"`),
enabling consumers to correlate the lifecycle. The observatory
projection uses `task_id` to update edge metadata from `:pending`
through `:accepted` to `:ok` or `:error`.

### Two delegation paths

1. **Spawn path** (`do_delegate`): MultiAgent spawns a new Worker via
   `Agent.Supervisor.start_worker/1` with `initial_task` and `task_id`
   in opts. Worker publishes `rho.task.requested` to the bus. On
   `handle_continue({:initial_task, ...})`, it calls `start_turn` which
   publishes `rho.task.accepted`.

2. **Capability-route path** (`route_by_capability`): MultiAgent finds
   an idle agent with the requested capability via
   `Registry.find_by_capability/2` and delivers
   `rho.task.requested` directly to its mailbox via
   `Worker.deliver_signal/2`. Also publishes to the bus for
   observability. When the worker processes the signal in
   `process_signal/2`, it calls `start_turn` which publishes
   `rho.task.accepted`.

Both paths converge: `start_turn` stores `task_id` on `state.current_task_id`,
and `maybe_publish_task_completed` includes it in the completed signal.

---

## Capability System

Capabilities are atoms derived from an agent's configured mounts.

### Derivation

At Worker init, `Rho.Config.capabilities_from_mounts(config.mounts)`
maps each mount entry to its shorthand atom (e.g., `Rho.Tools.Bash` →
`:bash`). The result is stored on worker state, registered in
`Rho.Agent.Registry`, and published in `rho.agent.started`.

```elixir
# Config
mounts: [:bash, :fs_read, {:python, max_iterations: 20}]

# Derived capabilities
[:bash, :fs_read, :python]
```

### Discovery

- **`find_capable` tool** — LLM-callable tool in MultiAgent. Takes a
  capability string, returns matching agents.
- **`Registry.find_by_capability/2`** — Programmatic lookup. Filters
  the session's registry entries by capability membership.
- **`delegate_task` with `capability:` param** — Routes to an idle
  agent with the capability instead of spawning. Falls back to spawn
  if no match found.

---

## Signal Producers

### Worker (`lib/rho/agent/worker.ex`)

The primary signal producer. Publishes via two mechanisms:

1. **Direct `Comms.publish/3` calls** — for lifecycle events
   (`agent.started`, `agent.stopped`, `task.accepted`,
   `task.completed`, `turn.cancelled`)

2. **`emit` callback** — built in `start_turn`, wraps events as
   `rho.session.<sid>.events.<type>` signals. The Runner/TurnStrategy
   call `emit.(event_map)` during execution, and the Worker's closure
   publishes to the bus and optionally to the tape.

### MultiAgent (`lib/rho/mounts/multi_agent.ex`)

Publishes coordination signals:
- `rho.task.requested` — on delegation
- `rho.agent.spawned` — on idle agent spawn
- `rho.session.<sid>.events.message_sent` — on send_message
- `rho.session.<sid>.events.broadcast` — on broadcast_message

### Recorder (`lib/rho/agent_loop/recorder.ex`)

Publishes `rho.session.<sid>.tape.entry_appended` after each tape
write. Only fires when `session_id` is non-nil.

---

## Signal Consumers

### CLI (`lib/rho/cli.ex`)

Subscribes to: `rho.session.<sid>.events.*`

Renders streaming text, tool progress, and turn completion to the
terminal. Releases the REPL prompt on `turn_finished`.

### SessionProjection (`lib/rho_web/live/session_projection.ex`)

Subscribes to: `rho.session.<sid>.events.*`, `rho.agent.*`,
`rho.task.*`

Maintains LiveView assigns for the chat UI:
- `messages` — per-agent message lists with tool calls, text, errors
- `agents` — agent metadata (status, step, capabilities)
- `signals` — generic signal timeline (catch-all)

Handles: `text_delta`, `llm_text`, `tool_start`, `tool_result`,
`turn_started`, `turn_finished`, `llm_usage`, `step_start`,
`before_llm`, `message_sent`, `ui_spec*`, `agent.started`,
`agent.stopped`, `task.requested`, `task.completed`.

### ObservatoryProjection (`lib/rho_web/live/observatory_projection.ex`)

Subscribes to: `rho.agent.*`, `rho.session.<sid>.events.*`,
`rho.task.*`, `rho.turn.*`, `rho.hiring.*`

Maintains a chronological discussion timeline and interaction graph:
- `discussion` — ordered list of timeline entries (messages, tool
  calls, agent events, markers)
- `agents` — agent nodes for the graph
- `edges` — directed edges with count and status metadata
- `recent_edges` — animation state for live particles

### EventLog (`lib/rho/agent/event_log.ex`)

Subscribes to: `rho.session.<sid>.events.*`, `rho.agent.*`,
`rho.task.*`, `rho.turn.*`

Persists events to JSONL on disk. See [EventLog Persistence](#eventlog-persistence).

---

## EventLog Persistence

### File format

One JSON object per line in `{workspace}/_rho/sessions/{session_id}/events.jsonl`:

```json
{
  "seq": 42,
  "ts": "2025-04-06T12:30:45.123Z",
  "type": "rho.session.abc.events.tool_result",
  "agent_id": "abc/primary",
  "session_id": "abc",
  "turn_id": "turn_789",
  "data": {"name": "bash", "output": "...", "status": "ok"}
}
```

### Filtering

- **Excluded (high-frequency):** `text_delta`, `structured_partial`
- **Truncated:** `output` fields capped at 4096 bytes, `args` at 2048
  bytes per field

### Correlation

The `turn_id` field is extracted from `signal.extensions["correlation_id"]`,
allowing events to be grouped by turn during replay.

### Replay

The Observatory uses `hydrate_from_event_log/2` on mount to replay
historical events through the projection, with configurable speed
(`:normal`, `:fast`, `:instant`) via batched `:replay_tick` messages.

---

## Observatory Edge Rendering

The interaction graph (`observatory_components.ex`) renders agents as
SVG nodes in a circle with directed edges between them.

### Edge data model

Edges are stored as `%{edges: %{{from, to} => edge_value}}` where
`edge_value` is either:

- **Integer** — simple message count (from `record_edge/3`)
- **Map** — `%{count: int, status: atom, task_id: string}` (from
  `record_edge/4` with metadata)

### Edge lifecycle states

| Status | CSS class | Visual | Trigger |
|--------|-----------|--------|---------|
| `:pending` | `igraph-edge-pending` | Dashed stroke, dim | `rho.task.requested` |
| `:accepted` | `igraph-edge-accepted` | Solid, pulsing animation | `rho.task.accepted` |
| `:ok` | `igraph-edge-ok` | Green (#4ade80) | `rho.task.completed` (success) |
| `:error` | `igraph-edge-error` | Red (#f87171) | `rho.task.completed` (error) |
| `nil` | (default) | Role-colored, solid | `message_sent`, `broadcast` |

Each status also has a matching arrowhead marker (`arrow-pending`,
`arrow-ok`, etc.) defined in the SVG `<defs>`.

### Animation

- **Ambient particles** — looping `<animateMotion>` on all edges when
  no live activity
- **Burst particles** — one-shot particles on `recent_edges` (last 3s)
  for live message flow

---

## Session Resume

Rho supports resuming stopped sessions because tape data persists to
disk independently of agent processes.

### How it works

1. **Tape persistence** — `Rho.Tape.Store` writes every entry to
   `~/.rho/tapes/{tape_name}.jsonl` and reloads all tapes on process
   start (`load_all_tapes/0`).

2. **Deterministic tape names** — `Rho.Tape.Context.Tape.memory_ref/2`
   generates the tape name from `(session_id, workspace)`, so the same
   session always maps to the same tape file.

3. **Context reconstruction** — When `Runner.run/3` builds the initial
   LLM context, it calls `Rho.Tape.Context.build/1` which reads the
   persisted tape entries and converts them to LLM messages. The agent
   sees its full prior conversation.

### API

```elixir
# List sessions that have event logs but no live agent
Rho.Agent.Primary.list_resumable()
# => [%{session_id: "cli:default", events_path: "...", modified_at: ~N[...]}]

# Resume a session — starts a fresh worker that picks up the tape
{:ok, pid} = Rho.Agent.Primary.resume("cli:default")
```

### What survives vs what doesn't

| Survives restart | Lost on restart |
|------------------|-----------------|
| Tape entries (full conversation) | In-flight turn state |
| EventLog on disk | Worker process state (mailbox, waiters) |
| Agent registry entries (status: :stopped) | Live bus subscriptions |
| Tape index/search | Current task_id, turn_id |

---

## Dual Delivery: Bus vs Mailbox

Rho uses two signal delivery mechanisms:

### Bus delivery (observability)

All signals published via `Comms.publish/3` go through the bus. Any
process can subscribe to any pattern. Used for UI rendering, logging,
and debugging.

### Mailbox delivery (agent targeting)

For inter-agent communication that must be processed by a specific
agent, signals are delivered directly to the worker's mailbox via
`Worker.deliver_signal/2`. This bypasses the bus for the delivery
itself, but the same event is **also** published to the bus separately
for observability.

| Use case | Mailbox? | Bus? |
|----------|----------|------|
| `send_message` | Yes (to target) | Yes (as `message_sent`) |
| `broadcast_message` | Yes (to each) | Yes (as `broadcast`) |
| `delegate_task` (capability-routed) | Yes (to target) | Yes (as `task.requested`) |
| `delegate_task` (spawn) | No (uses `initial_task` opt) | Yes (as `task.requested`) |
| Agent lifecycle | No | Yes |
| Turn execution events | No | Yes |

Mailbox signals are queued when the agent is busy and processed in
FIFO order when the current turn completes (`process_queue/1`).
