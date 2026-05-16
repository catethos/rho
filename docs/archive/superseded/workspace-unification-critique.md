# Workspace Unification Plan — Critique

## Verdict

The core direction is right: unifying `SessionLive` and `SpreadsheetLive` into a single LiveView shell with a projection-based model over the signal stream is well-motivated and architecturally sound. The issues below are about tightening the abstractions before committing to them.

---

## 1. Chat Is Not a Workspace

The plan says "chat is a workspace" but the UI treats it as a collapsible side panel that coexists with any artifact tab. That makes chat **cross-cutting shell UI**, not a peer of spreadsheet/chatroom/canvas.

**Recommendation:** Rename `ChatProjection` → `SessionProjection`. Keep it as the always-on base reducer that handles agent status, token counters, streaming state, and per-agent message history. Reserve the workspace abstraction for artifact tabs only.

---

## 2. Projections Should Be Pure

The `Workspace` behaviour currently has projections return `Phoenix.LiveView.Socket.t()`. This couples projections to LiveView internals and makes them impossible to test or replay in isolation.

Additionally, `ChatroomProjection` generates IDs and timestamps inside the reducer:

```elixir
# ❌ Non-deterministic — breaks replay and multi-subscriber consistency
id: "cr_#{System.unique_integer([:positive])}",
timestamp: System.system_time(:millisecond)
```

**Recommendation:**

- Projections should be pure folds: `reduce(state :: map(), signal :: map()) :: map()`.
- `SessionLive` owns the socket; it calls the reducer and applies the returned state to assigns.
- All signals must carry stable metadata (`event_id`, `seq`, `emitted_at`, `source`) so projections derive rendered items from signal data, not runtime calls.

```elixir
defmodule RhoWeb.Projection do
  @callback handles?(signal_type :: String.t()) :: boolean()
  @callback reduce(state :: map(), signal :: map()) :: map()
end
```

---

## 3. Signal Matching Should Be Exact

The plan uses `String.contains?/2` for signal routing:

```elixir
# ❌ Brittle — "message_sent_v2" or "failed_message_sent" would match
String.contains?(type, "message_sent")
```

**Recommendation:** Use exact string matches or a static dispatch table.

```elixir
case signal.type do
  "events.message_sent" -> ...
  "events.broadcast" -> ...
  _ -> state
end
```

---

## 4. Defer the Workspace Behaviour

The proposed `Workspace` behaviour bundles metadata, signal filtering, state mutation, socket manipulation, and rendering into one contract. That's too much surface area to lock in before the second artifact workspace (chatroom) has validated the API.

**Recommendation:** Start with a plain registry map in `SessionLive`:

```elixir
@workspace_registry %{
  spreadsheet: %{label: "Skills Editor", icon: "📊", component: SpreadsheetComponent, projections: [SpreadsheetProjection]},
  chatroom: %{label: "Chatroom", icon: "💬", component: ChatroomComponent, projections: [ChatroomProjection]}
}
```

Formalize into a behaviour only after chatroom proves what the API actually needs.

---

## 5. Hydration Must Use the Same Reducer Path

The plan describes `subscribe_and_hydrate/2` as loading agents and common assigns, but doesn't specify how workspace state is rebuilt for late joiners or reconnects.

**Recommendation:** Hydration should replay the tape (or load a snapshot + tail) through the same `reduce/2` functions used for live updates. One code path for both:

```elixir
state = initial_state(session_ctx)
state = Enum.reduce(signals, state, &reduce/2)
```

Without this, reconnecting clients and new subscribers will drift from live state.

---

## 6. Fix Ambiguous Assign Names Now

`active_tab` (agent tab) vs `active_workspace_tab` (workspace tab) will cause confusion as complexity grows.

**Recommendation:** Standardize immediately:

| Current | Proposed |
|---------|----------|
| `active_tab` | `active_agent_id` |
| `tab_order` | `agent_tab_order` |
| `active_workspace_tab` | `active_workspace_id` |

For workspace-specific assigns, the `ws_` prefix convention is acceptable but enforce two rules:
1. Only shared session state stays unprefixed.
2. Workspace reducers may only touch their own namespace.

---

## 7. Event-Sourced Writes Need More Than Publish

The plan claims "undo/replay for free" from event sourcing. What you actually get:

- ✅ Shared visibility for edits
- ✅ Replayability (if tape is durable and reducers are pure)
- ✅ Auditability
- ❌ Undo (requires reverse operations or snapshots)
- ❌ Conflict resolution (requires explicit policy)
- ❌ Optimistic reconciliation (requires `client_op_id`)

**Recommendation:**

- Every user edit signal must include a `client_op_id`.
- On commit, apply optimistic local update, then publish.
- When the echoed event arrives, reconcile by `client_op_id` (skip if already applied).
- Adopt **last-write-wins at cell level** as the initial conflict policy.
- Ensure `Rho.Comms.publish/3` writes to durable tape, not just transient PubSub. Otherwise replay won't work.

---

## 8. Adjusted Implementation Order

The proposed order is mostly right but should be resequenced slightly:

| Step | What | Why |
|------|------|-----|
| 1 | Extract `SessionCore` | Low risk, easy to verify with existing tests |
| 2 | Extract projections as pure reducers | Rename chat → `SessionProjection`, extract `SpreadsheetProjection`, add replay-style tests |
| 3 | Unify into one `SessionLive` with simple workspace registry | No need for a formal behaviour yet |
| 4 | Add `ChatroomProjection` + chatroom workspace | Validates the abstraction |
| 5 | Finalize `Workspace` behaviour (if needed) | After chatroom proves the API |
| 6 | Event-sourced user edits | Last, with `client_op_id` and conflict policy |

Key change: **don't formalize the behaviour (old Step 3) until after chatroom (old Step 5) proves what's needed.**

---

## Risks

| Risk | Mitigation |
|------|------------|
| Replay drift from non-deterministic projectors | Require stable event metadata on every signal |
| Over-broad workspace contract | Keep workspace metadata thin; keep reducers separate |
| Assign name confusion | Rename ambiguous assigns before unification |
| Hydration gaps for late joiners | Replay tape through same reducers used for live updates |
| Double-apply on optimistic updates | `client_op_id` + reconciliation |
| Hidden render cost from inactive workspaces | Only render the active workspace component |

---

## When to Revisit

Move to a more complex design only if:

- 4+ workspace types exist
- Workspace definitions must be plugin/discoverable at runtime
- Signal volume makes naive routing measurable
- Full replay is too slow and snapshots are needed
- Workspaces need independent write-side authorization
