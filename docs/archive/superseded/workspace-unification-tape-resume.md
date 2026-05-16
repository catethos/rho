# Workspace Unification — Tape, History, and Session Resumption

## The Question

When a user returns to a session (closes browser, comes back later), should they be able to resume the conversation? If so, should we compact the tape before loading if there's no recent compaction?

---

## Two Distinct Resumption Problems

There are two separate state reconstruction problems that look similar but have different sources, different consumers, and different solutions:

| | **LLM Context** (what the agent remembers) | **UI State** (what the user sees) |
|---|---|---|
| **Source** | `Rho.Tape.Store` (JSONL per agent tape) | `Rho.Agent.EventLog` (JSONL per session) + `Rho.Comms.SignalBus` (in-memory) |
| **Consumer** | `Rho.Tape.View` → `ReqLLM` messages | `SessionLive` → socket assigns |
| **Already works?** | ✅ Yes — tape persists to disk, View rebuilds from anchor | ❌ Partially — EventLog persists, but UI doesn't replay from it |
| **Compaction** | ✅ `Rho.Tape.Compact` exists (LLM summarization → anchor) | ❌ No UI state snapshots exist |
| **Token pressure** | Real — LLM context windows are finite | Not applicable — UI state is just data |
| **Size pressure** | Real — 100k+ token threshold | Real — replaying 10k signals through reducers is slow |

The plan's `hydrate_workspaces/2` replays signals through projection reducers. But it calls `load_session_tape(session_id)` — a function that doesn't exist yet. The question is: what does it actually load from, and how fast is it?

---

## Current State of Persistence

### What survives a browser close today

1. **Agent tape** (`~/.rho/tapes/*.jsonl`): Full conversation history per agent. Loaded into ETS on app startup by `Rho.Tape.Store.load_all_tapes/0`. The agent can resume — `Rho.Tape.View.default/1` rebuilds context from the latest anchor forward.

2. **Event log** (`_rho/sessions/{id}/events.jsonl`): Session-wide signal log, filtered (no `text_delta` or `structured_partial`). Written by `Rho.Agent.EventLog` GenServer. Survives on disk but is **not used for UI reconstruction** — it's used by `ObservatoryLive` for diagnostics.

3. **Signal bus** (`Jido.Signal.Bus` in-memory): Has `replay/3` with a `since` timestamp. But it's in-memory — dies on app restart. Only useful for reconnects within the same BEAM instance, not across restarts.

### What does NOT survive

- Socket assigns (LiveView process dies)
- Workspace projection state (in-memory only)
- Chat scroll position, editing state, collapsed groups
- The mapping of which workspaces were active

---

## The Resumption Flow

When a user navigates to `/editor/session-123` and the session existed before:

```
User opens /editor/session-123
        │
        ▼
   SessionLive.mount/3
        │
        ├─ Agent still running?
        │     YES → subscribe to live signals, hydrate from current state
        │     NO  → restart agent (tape on disk), subscribe, hydrate
        │
        ├─ Rebuild UI state
        │     Need to replay signals through workspace projections
        │     Source: EventLog on disk? Signal bus replay? Tape entries?
        │
        └─ Rebuild LLM context
              Already handled by Tape.View (reads from latest anchor)
              Compact if needed (Tape.Compact.run_if_needed/2)
```

### The gap: UI state reconstruction source

The plan says `load_session_tape(session_id)` feeds signals into workspace projections. But:

- **Signal bus replay** only works within the same BEAM instance (in-memory)
- **EventLog** persists to disk but filters out `text_delta` and `structured_partial` — spreadsheet streaming signals are lost
- **Agent tape** stores conversation entries (messages, tool calls, tool results), not UI signals (spreadsheet_rows_delta, update_cells, etc.)

**None of the existing persistence layers store the full signal stream needed for workspace projection replay.**

---

## Proposed Solution: Layered Resumption

### Layer 1: Agent Context Resumption (already works)

The agent tape persists. `Tape.View.default/1` rebuilds LLM context from the latest anchor. `Tape.Compact.run_if_needed/2` summarizes if context is too long.

**No changes needed.** The agent can always resume.

### Layer 2: UI State — Snapshot-Based (new)

Instead of replaying potentially thousands of signals, persist a snapshot of workspace projection state. This is the "compact before loading" analog for UI state.

```elixir
# Snapshot structure — one per session, stored alongside EventLog
%{
  session_id: "session-123",
  timestamp: 1717000000000,
  ws_states: %{
    spreadsheet: %{rows_map: %{...}, next_id: 42, partial_streamed: %{}},
    chatroom: %{messages: [...], streaming: %{}}
  },
  session_state: %{
    agents: %{...},
    agent_messages: %{...},
    agent_tab_order: [...],
    active_agent_id: "agent-1",
    total_cost: 0.0042,
    # ... other session projection state
  },
  active_workspace_keys: [:spreadsheet],
  active_workspace_id: :spreadsheet,
  chat_visible: true
}
```

**When to snapshot:**
- On `terminate/2` (browser close, navigation away)
- Periodically (every N signals or every M seconds)
- On explicit "save" if we add that

**When to load:**
- On `mount/3`, before subscribing to live signals
- If snapshot exists and agent is still running: load snapshot, subscribe, apply any signals received since snapshot timestamp
- If snapshot exists and agent is NOT running: load snapshot, restart agent, subscribe
- If no snapshot: start fresh (current behavior)

```elixir
def mount(params, _session, socket) do
  session_id = SessionCore.validate_session_id(params["session_id"])
  workspace_keys = determine_initial_workspaces(socket.assigns.live_action)

  socket = SessionCore.init(socket)

  socket =
    if connected?(socket) && session_id do
      case load_snapshot(session_id) do
        {:ok, snapshot} ->
          socket
          |> apply_snapshot(snapshot)
          |> SessionCore.subscribe_and_hydrate(session_id, ...)
          |> apply_signals_since(session_id, snapshot.timestamp)

        :none ->
          socket
          |> init_fresh_workspaces(workspace_keys)
          |> SessionCore.subscribe_and_hydrate(session_id, ...)
      end
    else
      init_fresh_workspaces(socket, workspace_keys)
    end

  {:ok, socket}
end
```

### Layer 3: Signal Tail Replay (catch-up after snapshot)

Between the snapshot timestamp and "now", signals may have been emitted (agent kept running while browser was closed). These need to be replayed through projections to bring UI state up to date.

Sources for tail replay (in preference order):
1. **Signal bus replay** (`Rho.Comms.replay/2` with `since: snapshot.timestamp`) — if same BEAM instance
2. **EventLog replay** (`EventLog.read/2` with `after: snapshot_seq`) — if bus is gone but EventLog is alive
3. **Nothing** — if both are gone, snapshot is the best we have (may be slightly stale)

```elixir
defp apply_signals_since(socket, session_id, since_timestamp) do
  case Rho.Comms.replay("rho.session.#{session_id}.events.*", since: since_timestamp) do
    {:ok, signals} ->
      Enum.reduce(signals, socket, fn signal, sock ->
        normalized = normalize_signal(signal)
        SignalRouter.route(sock, normalized)
      end)

    {:error, _} ->
      # Bus unavailable, try EventLog
      replay_from_event_log(socket, session_id, since_timestamp)
  end
end
```

### Layer 4: LLM Context Compaction on Resume (conditional)

When a session is resumed after a long gap, the agent tape may have grown large. Compact before the first LLM call, not on UI load (compaction requires an LLM call and is slow).

```elixir
# In SessionCore.subscribe_and_hydrate or agent startup
def maybe_compact_on_resume(tape_name, opts) do
  if Rho.Tape.Compact.needed?(tape_name, opts) do
    # Don't block mount — compact in background
    Task.start(fn ->
      Rho.Tape.Compact.run(tape_name, opts)
    end)
  end
end
```

**Important:** Compaction should NOT block the UI. The user should see their session immediately (from snapshot). Compaction happens in the background before the agent's next LLM call.

---

## What "Resume" Looks Like to the User

### Ideal flow

1. User opens `/editor/session-123`
2. **Instant** (< 100ms): Snapshot loads. Spreadsheet shows rows, chat shows messages, token counter shows cost. Everything looks exactly as they left it.
3. **Fast** (< 500ms): Tail replay applies any signals that arrived since the snapshot. New rows appear, streaming state updates.
4. **Background**: If the agent tape is huge, compaction runs silently. The agent is ready for the next message.
5. User types a message → agent responds with full context of the prior conversation.

### Degraded flow (no snapshot, first visit or snapshot lost)

1. User opens `/editor/session-123`
2. Workspace starts empty (no spreadsheet rows, no chat messages)
3. Agent has full context (tape is durable) — it can respond meaningfully
4. Any new agent actions rebuild UI state from live signals

This is the current behavior and is acceptable as a fallback.

---

## EventLog Gaps for UI Replay

`EventLog` filters out `text_delta` and `structured_partial` (high-frequency streaming signals). This means:

- Spreadsheet progressive row streaming cannot be replayed from EventLog alone
- Final state (after `spreadsheet_rows_delta` completes) IS captured
- Chat streaming state is lost (but final messages are captured)

This is acceptable because:
- Snapshots capture the final projected state (rows already folded in)
- Tail replay only needs to cover the gap between snapshot and now
- If that gap is small, missing streaming signals don't matter (final state signals suffice)

If full replay from EventLog becomes needed (no snapshot available), consider removing the `text_delta`/`structured_partial` filter or adding a separate UI signal log that captures everything.

---

## Snapshot Storage

### Location

Store alongside the EventLog, in the session directory:

```
_rho/sessions/{session_id}/
  events.jsonl          # existing EventLog
  ui_snapshot.json      # new: latest UI state snapshot
```

### Implementation

```elixir
defmodule RhoWeb.Session.Snapshot do
  @filename "ui_snapshot.json"

  def save(session_id, workspace, state) do
    dir = Path.join([workspace, "_rho", "sessions", session_id])
    File.mkdir_p!(dir)
    path = Path.join(dir, @filename)
    File.write!(path, Jason.encode!(state))
  end

  def load(session_id, workspace) do
    path = Path.join([workspace, "_rho", "sessions", session_id, @filename])

    case File.read(path) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, :enoent} -> :none
    end
  end

  def delete(session_id, workspace) do
    path = Path.join([workspace, "_rho", "sessions", session_id, @filename])
    File.rm(path)
  end
end
```

### What to snapshot

| Include | Exclude |
|---------|---------|
| `ws_states` (all workspace projection state) | Streaming state (ephemeral, will be stale) |
| `session_state` (agents, messages, tokens, cost) | `pending_response` (ephemeral) |
| `active_workspace_keys`, `active_workspace_id` | `inflight` (process-specific) |
| `chat_visible` | PID references, process state |
| `agent_tab_order`, `active_agent_id` | Upload state |
| Snapshot timestamp | |

### Serialization concerns

- `MapSet` → convert to list for JSON, reconstruct on load
- Atom keys → string keys in JSON, reconstruct with `String.to_existing_atom/1`
- Ensure all workspace projection state is JSON-serializable (no PIDs, refs, functions)

---

## Compaction Strategy Summary

| Layer | What | When | Blocks UI? |
|-------|------|------|------------|
| **UI Snapshot** | Workspace + session projection state | On terminate, periodically | No (write is async) |
| **UI Tail Replay** | Signals since snapshot | On mount, after snapshot load | Brief (~100ms for small gap) |
| **LLM Compact** | Agent conversation summary → anchor | Before next LLM call if over threshold | No (background task) |

---

## Integration with Workspace Unification Plan

### New prerequisite: Step 0.5

Add snapshot infrastructure before Step 3 (unification), so the unified `SessionLive` has resumption from day one:

| Step | What |
|------|------|
| 0 | Signal metadata enrichment |
| **0.5** | **Snapshot save/load infrastructure** |
| 1 | Extract SessionCore |
| 2 | Extract projections as pure reducers |
| 3 | Unify into single SessionLive (with snapshot save on terminate, load on mount) |
| ... | ... |

### Changes to SessionLive

```elixir
# In mount — load snapshot if available
socket =
  case Snapshot.load(session_id, workspace) do
    {:ok, snap} -> apply_snapshot(socket, snap)
    :none -> init_fresh_workspaces(socket, workspace_keys)
  end

# In terminate — save snapshot
@impl true
def terminate(_reason, socket) do
  if socket.assigns[:session_id] do
    state = build_snapshot(socket)
    Snapshot.save(socket.assigns.session_id, workspace, state)
  end
  SessionCore.unsubscribe(socket)
end
```

### Changes to SessionCore

```elixir
# In subscribe_and_hydrate — trigger background compaction if needed
def subscribe_and_hydrate(socket, session_id, opts) do
  # ... existing logic ...

  # Background compact if tape is large
  tape_name = Rho.Tape.Service.session_tape(session_id, workspace)
  if Rho.Tape.Compact.needed?(tape_name) do
    Task.start(fn -> Rho.Tape.Compact.run(tape_name, model: default_model()) end)
  end

  socket
end
```

---

## Edge Cases

### Agent finished while browser was closed

The agent may have completed its task (spreadsheet fully populated, all rows generated) while the user was away. The snapshot captures the last state the user saw. Tail replay fills in the rest. The user sees the completed result on return.

### Multiple browser tabs

Each tab is a separate LiveView process. Each saves its own snapshot on terminate. Last-write-wins is fine — all tabs subscribe to the same signals and converge to the same state.

### Session doesn't exist anymore

If the session ID is invalid or the session was cleaned up, `mount/3` already handles this (falls through to nil session_id, fresh state). Snapshot load fails gracefully.

### Snapshot is stale (hours/days old)

This is the most common resume case. Snapshot gives instant visual state, tail replay catches up. If tail replay source is unavailable (BEAM restarted, bus cleared), the snapshot is the best we have. The user sees slightly stale UI but the agent has full context from tape.

### Very long sessions (10k+ signals in tail)

If the gap between snapshot and now is huge, tail replay could be slow. Mitigations:
- Save snapshots more frequently (every 100 signals)
- Skip tail replay if gap is too large and just show snapshot state with a "some updates may be missing" indicator
- Or: rebuild from fresh + full EventLog replay (slower but complete)
