# Web + Frameworks Unified Redesign

**Date:** 2026-04-25 · **Branch:** `refactor`  
**Scope:** How the frameworks simplification affects rho_web LiveViews, and what to redesign in the web layer.

---

## Current Event Flow

```
                    ┌──────────────────────────────────────────────┐
                    │              Rho.Comms (Signal Bus)           │
                    └──────────┬───────────────┬──────────────────┘
                               │               │
                    ┌──────────▼───┐    ┌──────▼────────┐
                    │  SessionLive │    │   FlowLive    │
                    │  subscribes: │    │  subscribes:  │
                    │  session.*   │    │  task.*       │
                    │  agent.*     │    │  session.*    │
                    │  task.*      │    └──────┬────────┘
                    └──────┬──────┘           │
                           │                  │
                    ┌──────▼──────┐           │
                    │ SignalRouter │           │
                    │   ↓         │           │
                    │ SessionState│  (bespoke signal handling)
                    │ (pure       │
                    │  reducer)   │
                    │   ↓         │
                    │ Workspace   │
                    │ Projections │
                    │   ↓         │
                    │ SessionEffects│
                    └─────────────┘
```

**The entanglement:** Frameworks domain code publishes specific Comms topics that the web layer subscribes to. Removing those publishes breaks the UI. But keeping them means domain code is coupled to a transport protocol.

---

## What's Good (Keep)

| Pattern | Why it's good |
|---------|---------------|
| `SessionState.reduce/2` pure reducer | Testable, deterministic, easy to reason about |
| Workspace projection modules | Clean separation of concerns |
| `{state, effects}` return from reducers | Impure boundary is explicit |
| `EffectDispatcher` for tool effects | Correct seam between runtime and UI |
| Shell auto-open/pulse tracking | Good UX pattern |

**Don't redesign the state model. Redesign the event boundary.**

---

## What's Wrong (Fix)

### 1. Topic-string coupling

SessionState parses topic strings to dispatch:
```elixir
defp do_reduce(state, %{type: "rho.session." <> _ = type, data: data} = signal) do
  suffix = type |> String.split(".") |> List.last()
  dispatch_session_event(suffix, state, type, data, signal)
end
```

Every new feature requires a new topic string, a new suffix, and a new dispatcher clause.

### 2. Three wildcard subscriptions per session

```elixir
{:ok, sub1} = Rho.Comms.subscribe("rho.session.#{session_id}.events.*")
{:ok, sub2} = Rho.Comms.subscribe("rho.agent.*")
{:ok, sub3} = Rho.Comms.subscribe("rho.task.*")
```

Global topics (`rho.agent.*`, `rho.task.*`) mean **every SessionLive receives events for all sessions** and must filter with `signal_for_session?/2`. This is O(sessions) per event.

### 3. Frameworks publishes UI transport topics

`lenses.ex` publishes `lens_score_update` and `lens_dashboard_init` directly on `Rho.Comms`. The domain code knows about the web layer's topic conventions.

### 4. FlowLive duplicates signal handling

FlowLive subscribes to the same Comms topics, then does bespoke matching:
```elixir
def handle_info({:signal, %{type: "rho.task.completed", data: data}}, socket) do
  ...
  handle_worker_completed(socket, data)
end
```

And `handle_worker_completed` uses fragile heuristics:
```elixir
generate_id != nil and is_binary(agent_id) and
    String.contains?(agent_id, socket.assigns.runtime.execution_id)
```

### 5. LiteWorker streaming is a separate code path

LiteWorker publishes its own events through Comms. After replacing LiteWorker with RunSpec+Runner, the Runner already has an `emit` callback. But the web layer doesn't consume `emit` — it listens to Comms topics.

---

## Proposed Architecture

### New Event Flow

```
  RunSpec.emit callback ──→ RhoWeb.LiveEvents.broadcast(session_id, event)
                                       │
  EffectDispatcher ──→ apply durable effect, then broadcast invalidation
                                       │
                                       ▼
                              Phoenix PubSub
                           (topic: "rho_lv:session:<sid>")
                                       │
                          ┌────────────┴────────────┐
                          ▼                          ▼
                    SessionLive                  FlowLive
                    handle_info                  handle_info
                    {:live_event, event}         {:live_event, event}
                          │                          │
                    SignalRouter.route           (same reducer?)
                          │
                    SessionState.reduce
                    Workspace projections
                    SessionEffects
```

### Step 1: Create `RhoWeb.LiveEvents`

Single-topic PubSub adapter per session:

```elixir
defmodule RhoWeb.LiveEvents do
  @prefix "rho_lv:session:"

  def topic(session_id), do: @prefix <> session_id

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Rho.PubSub, topic(session_id))
  end

  def broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Rho.PubSub, topic(session_id), {:live_event, event})
  end
end
```

### Step 2: Canonical event shape

Replace topic-string parsing with typed event maps:

```elixir
%{
  kind: :text_delta | :tool_start | :tool_result | :step_start |
        :turn_started | :turn_finished | :error | :llm_usage |
        :run_started | :run_progress | :run_finished |
        :agent_started | :agent_stopped |
        :workspace_invalidated | :workspace_opened,
  session_id: String.t(),
  run_id: String.t() | nil,
  parent_run_id: String.t() | nil,
  agent_id: String.t() | nil,
  data: map(),
  ts: integer()
}
```

SessionState.reduce pattern-matches on `kind` atoms instead of string suffixes:

```elixir
# Before:
defp dispatch_session_event("text_delta", state, _t, data, _s), do: ...
defp dispatch_session_event("tool_start", state, _t, data, _s), do: ...

# After:
def reduce(state, %{kind: :text_delta, data: data}), do: ...
def reduce(state, %{kind: :tool_start, data: data}), do: ...
```

### Step 3: Wire emit → LiveEvents

When `SessionCore.ensure_session` or `subscribe_and_hydrate` starts a session, the `RunSpec.emit` callback broadcasts to PubSub:

```elixir
emit = fn runner_event ->
  RhoWeb.LiveEvents.broadcast(session_id, normalize_event(runner_event, session_id, agent_id))
end

Rho.Session.start(session_id: sid, emit: emit, ...)
```

This covers all Runner/ToolExecutor streaming events: text_delta, tool_start, tool_result, step_start, turn_started, turn_finished, llm_usage, error.

### Step 4: Wire effects → LiveEvents

EffectDispatcher applies the durable effect, then broadcasts an invalidation:

```elixir
def dispatch(%Rho.Effect.Table{} = effect, ctx) do
  # 1. Write to DataTable (durable)
  DataTable.replace_all(ctx.session_id, effect.rows, table: table_name)

  # 2. Broadcast UI invalidation (ephemeral)
  RhoWeb.LiveEvents.broadcast(ctx.session_id, %{
    kind: :workspace_invalidated,
    data: %{workspace: :data_table, table_name: table_name, view_key: effect.schema_key}
  })
end
```

### Step 5: Wire delegation lifecycle → LiveEvents

When `RhoFrameworks.AgentJobs.start/2` spawns a child run:

```elixir
RhoWeb.LiveEvents.broadcast(session_id, %{
  kind: :run_started,
  run_id: run_id,
  parent_run_id: parent_run_id,
  data: %{role: :skeleton_generator, task: "Generating framework"}
})
```

On completion (via Task monitor or emit callback):

```elixir
RhoWeb.LiveEvents.broadcast(session_id, %{
  kind: :run_finished,
  run_id: run_id,
  data: %{status: :ok, result: text}
})
```

SessionState.reduce handles these as delegation cards — same UI, cleaner plumbing.

### Step 6: Collapse subscriptions

**Before (3 wildcard subscriptions + global filtering):**
```elixir
{:ok, sub1} = Rho.Comms.subscribe("rho.session.#{session_id}.events.*")
{:ok, sub2} = Rho.Comms.subscribe("rho.agent.*")
{:ok, sub3} = Rho.Comms.subscribe("rho.task.*")
```

**After (1 scoped subscription):**
```elixir
:ok = RhoWeb.LiveEvents.subscribe(session_id)
```

No more global event filtering. No more `signal_for_session?/2`.

### Step 7: FlowLive uses same stream

FlowLive currently has bespoke signal handling with fragile agent_id matching. After:

```elixir
def mount(%{"flow_id" => flow_id}, _session, socket) do
  ...
  :ok = RhoWeb.LiveEvents.subscribe(session_id)
  ...
end

def handle_info({:live_event, %{kind: :run_finished, run_id: run_id}}, socket) do
  if run_id == socket.assigns.active_run_id do
    complete_current_step(socket)
  else
    maybe_mark_fanout_worker(socket, run_id)
  end
end
```

Track `run_id`, not `generate_agent_id`. No substring matching. Deterministic.

---

## Impact on Frameworks Simplification

| Frameworks change | Web impact | Migration |
|------------------|------------|-----------|
| Remove `Rho.Comms.publish` from lenses.ex | Lens tools return effects; EffectDispatcher broadcasts invalidation | Replace 2 Comms.publish → return `ToolResponse.effects` |
| Remove `Rho.Comms.publish` from skeleton_generator/proficiency | AgentJobs wrapper broadcasts run lifecycle events | Replace 2 Comms.publish → emit callback + LiveEvents |
| Replace `Runtime` with `Scope` | FlowLive stores `Scope` instead of `Runtime` | Rename assign |
| Replace LiteWorker with RunSpec+Runner | Runner.emit already produces all needed streaming events | Wire emit → LiveEvents.broadcast |
| `RhoFrameworks.LLM` for single-shot calls | FlowLive select steps call LLM directly, no streaming needed | Simpler — no PubSub for those steps |

---

## What About `Rho.Comms`?

**Comms stays for agent-to-agent coordination** (multi-agent messaging, signal bus for internal coordination). It does NOT need to be the web delivery transport.

| Use case | Transport |
|----------|-----------|
| Agent-to-agent messaging | `Rho.Comms` (internal) |
| Web streaming (text, tools, progress) | `LiveEvents` → Phoenix PubSub |
| Durable state updates | Write to store, broadcast `:workspace_invalidated` |
| Delegation lifecycle | `emit` callback → `LiveEvents` |

---

## Migration Order

### Phase W1: Create LiveEvents + canonical events (~1d)

1. Create `RhoWeb.LiveEvents` module
2. Define canonical event struct/map
3. Create `normalize_event/3` to convert Runner emit events → canonical events
4. In `SessionCore.subscribe_and_hydrate`, ALSO subscribe via LiveEvents (dual-path)
5. Wire `RunSpec.emit` → `LiveEvents.broadcast` in session startup
6. Add `handle_info({:live_event, event}, socket)` alongside existing signal handlers

### Phase W2: Migrate SessionState reducers to canonical events (~1d)

1. Add new `reduce/2` clauses matching on `kind` atoms
2. Keep old string-based clauses as fallbacks
3. Test that both paths produce identical state

### Phase W3: Migrate EffectDispatcher to LiveEvents (~0.5d)

1. EffectDispatcher broadcasts via LiveEvents after durable writes
2. Remove `Comms.publish` from EffectDispatcher
3. Remove lens dashboard/score events from frameworks domain code
4. LensTools returns effects instead of publishing

### Phase W4: Collapse subscriptions (~0.5d)

1. Remove 3 Comms subscriptions from SessionCore
2. Keep only LiveEvents subscription
3. Remove `signal_for_session?/2` filtering
4. Delete Comms unsubscribe logic

### Phase W5: Simplify FlowLive (~0.5d)

1. Replace `Runtime` with `Scope`
2. Subscribe via LiveEvents
3. Track `run_id` instead of `generate_agent_id`
4. Remove substring agent_id matching
5. Use `RhoFrameworks.LLM` for select step loading

---

## Estimated Total

| Phase | Effort | What |
|-------|--------|------|
| Frameworks simplification (from previous doc) | 2.5d | LLM, Scope, AgentJobs, remove Config/LiteWorker/Comms |
| W1: LiveEvents + dual path | 1d | New event transport |
| W2: Migrate reducers | 1d | String → atom dispatch |
| W3: EffectDispatcher migration | 0.5d | Comms → LiveEvents |
| W4: Collapse subscriptions | 0.5d | Remove old plumbing |
| W5: FlowLive simplification | 0.5d | Scope + run_id |
| **Total** | **~6d** | — |

---

## Summary

**Keep:** SessionState pure reducers, workspace projections, effect-as-data pattern, shell/pulse tracking.

**Replace:** Comms-as-web-transport → Phoenix PubSub via `LiveEvents`. Topic-string parsing → `kind` atom dispatch. 3 wildcard subscriptions → 1 scoped subscription. FlowLive bespoke signal handling → same canonical event stream as SessionLive.

**Delete:** Direct `Comms.publish` from frameworks. Global event subscriptions. `signal_for_session?` filtering. Agent-ID substring matching in FlowLive. `Runtime` assign in FlowLive.

**Result:** Domain code never publishes transport topics. The web layer has one clean event stream. Both SessionLive and FlowLive consume the same canonical events. Streaming "just works" because `RunSpec.emit` → `LiveEvents.broadcast` is the single path.
