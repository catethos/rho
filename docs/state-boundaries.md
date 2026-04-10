# State Boundary Rules

Rules governing where state lives and how it flows after the architecture refactor. Read this before adding a new workspace or tool.

---

## The Three Boundaries

### 1. Projections own canonical workspace data

Projection modules are pure reducers: `(state, signal) → new_state`. They hold the source of truth for each workspace's domain data (rows, columns, schema keys, conversation threads, lens results, etc.).

- **Location:** `apps/rho_web/lib/rho_web/projections/`
- **Examples:** `DataTableProjection`, `SessionState`
- Projections declare `handles?(signal_type)` to opt into signals.
- Projection state is stored in `socket.assigns.ws_states[key]` and included in snapshots.
- Projections must not perform side effects — no PubSub, no IO, no process messaging.

### 2. LiveComponent owns ephemeral UI state

LiveComponents own transient, view-local state: selection, scroll position, hover state, expanded/collapsed sections, local search filters.

- **Location:** `apps/rho_web/lib/rho_web/components/`
- **Examples:** `DataTableComponent`, `ChatroomComponent`, `LensDashboardComponent`
- This state is **not** persisted in snapshots and is **not** part of signal routing.
- LiveComponents receive projection state via assigns and render it. They handle `phx-*` events scoped to `@myself`.
- When a user interaction requires a domain state change, the component publishes a signal or calls a context function — it does not mutate projection state directly.

### 3. LiveView (SessionLive) owns shell state

SessionLive owns two categories of state:

**Shell chrome** (`assigns.shell`, managed by `RhoWeb.Session.Shell`):
- Which workspace tabs are open and their surface (`:tab` or `:overlay`)
- Which overlay is currently visible
- Pulse animations and unseen-activity indicators
- Active workspace tracking

**Session-level state** (managed by `SessionState` projection):
- `agents`, `agent_tab_order`, `selected_agent_id`
- `agent_messages`
- `inflight`, `pending_response`
- Token/cost accumulators

SessionLive discovers workspaces via `RhoWeb.Workspace.Registry` at mount and renders them generically — it contains no workspace-specific rendering or event handling.

---

## Signal Flow

Every signal follows the same pipeline through `SignalRouter.route/3`:

```
Signal
  → enrich_signal/2           (add resolved labels, target IDs)
  → SessionState.reduce/2     (pure — session-level state)
  → projection.reduce/2       (pure — per-workspace, only if handles?(signal.type))
  → Shell.record_activity/3   (pure — unseen badges, pulse, auto-open)
  → SessionEffects.apply/2    (impure boundary — push_event, timers, dispatch)
```

Effects are collected as data during the pure stages (as `{:push_event, ...}`, `{:send_after, ...}`, etc.) and applied in a single impure pass at the end. This keeps all reducers testable without a socket.

**Key files:**
- `apps/rho_web/lib/rho_web/session/signal_router.ex` — pipeline orchestration
- `apps/rho_web/lib/rho_web/session/session_effects.ex` — impure boundary

---

## Workspace Registration

Workspaces are self-contained modules implementing the `RhoWeb.Workspace` behaviour. Registration is explicit — no runtime module scanning.

**Behaviour callbacks** (`apps/rho_web/lib/rho_web/workspace.ex`):

| Callback | Purpose |
|---|---|
| `key()` | Unique atom (`:data_table`, `:chatroom`, `:lens_dashboard`) |
| `label()` | Tab/header text |
| `icon()` | Icon identifier |
| `auto_open?()` | Whether signal activity auto-opens the workspace overlay |
| `default_surface()` | `:tab` or `:overlay` |
| `projection()` | Module implementing projection reducer |
| `component()` | LiveComponent module for rendering |
| `component_assigns(ws_state, shared)` | Build assigns for the component from projection state + shared session state |
| `handle_info(msg, ws_state, ctx)` | Handle domain-specific messages (optional) |

**Registry** (`apps/rho_web/lib/rho_web/workspace/registry.ex`):

```elixir
# Add your workspace to the list:
@workspaces [
  RhoWeb.Workspaces.DataTable,
  RhoWeb.Workspaces.Chatroom,
  RhoWeb.Workspaces.LensDashboard
]
```

To add a new workspace: create the workspace module + projection + component, then add one line to the registry. Zero changes to SessionLive.

---

## Effect Dispatch

Tools do not publish signals or interact with UI directly. Instead, they return effect structs:

```elixir
%Rho.ToolResponse{
  text: "Loaded 42 items",
  effects: [
    %Rho.Effect.OpenWorkspace{key: :data_table},
    %Rho.Effect.Table{columns: cols, rows: rows}
  ]
}
```

Effects flow through two layers:

1. **SessionEffects** (`session_effects.ex`) — handles socket-level effects (`push_event`, `send_after`) and delegates tool effects to the dispatcher.
2. **EffectDispatcher** (`effect_dispatcher.ex`) — translates `Rho.Effect.*` structs into signal bus publishes that workspace projections already handle.

Supported effect structs:

| Struct | What it does |
|---|---|
| `Rho.Effect.Table` | Publishes schema-change + row data to the DataTable signal topic |
| `Rho.Effect.OpenWorkspace` | Publishes a workspace-open signal |

Adding a new effect type: define the struct in `apps/rho`, add a `dispatch/2` clause in `EffectDispatcher`.

---

## Quick Reference: What Goes Where

| State kind | Owner | Persisted? | Signal-routed? |
|---|---|---|---|
| Domain data (rows, threads, lens results) | Projection | Yes (snapshot) | Yes |
| UI-local (selection, scroll, hover) | LiveComponent | No | No |
| Shell chrome (tabs, overlay, pulse) | SessionLive / Shell | Yes (snapshot) | Yes |
| Session-level (agents, messages, cost) | SessionState | Yes (snapshot) | Yes |

**Rule of thumb:** if losing the state on reconnect is acceptable, it belongs in the LiveComponent. If it must survive reconnect or is derived from signals, it belongs in a projection.
