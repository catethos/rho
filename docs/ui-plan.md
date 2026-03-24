# Rho Web UI — Implementation Plan (Phoenix LiveView)

## Migration: Plug/Bandit → Phoenix LiveView

The current web layer is `Plug.Router` + `Bandit` + `WebSockAdapter` (no Phoenix deps).
Adding LiveView means adding Phoenix as a real dependency. The existing `Rho.Web.Socket`
stays for CLI/API clients; the LiveView UI is a separate surface.

### New deps in `mix.exs`

```elixir
{:phoenix, "~> 1.7"},
{:phoenix_live_view, "~> 1.0"},
{:phoenix_html, "~> 4.2"},
{:phoenix_live_reload, "~> 1.5", only: :dev},
{:heroicons, "~> 0.5"},   # optional, for icons
{:esbuild, "~> 0.8", only: :dev},
{:tailwind, "~> 0.2", only: :dev}
```

Bandit stays as the HTTP server (Phoenix supports it natively).

---

## Architecture

### Single LiveView state owner

One LiveView — `RhoWeb.SessionLive` — owns all session state and is the only
process that subscribes to the signal bus. All panels are projections of
a single event stream, not independent subscribers.

```
Browser ──LiveView socket──▶ RhoWeb.SessionLive
                                 │
                                 ├─ subscribes to Rho.Comms.SignalBus
                                 │   (rho.session.<sid>.events.*, rho.agent.*, rho.task.*)
                                 │
                                 ├─ handle_event/3  ← phx-submit / phx-click from browser
                                 │   └─ Rho.Session.submit/2, Rho.Session.ensure_started/2
                                 │
                                 └─ handle_info({:signal, ...})
                                     └─ update assigns/streams → LiveView diff → browser
```

No second browser WebSocket. LiveView's `/live` channel is the only browser transport.
The existing `Rho.Web.Socket` stays for non-browser API/CLI clients.

### Assigns structure

```elixir
%{
  session_id: nil | String.t(),
  agents: %{agent_id => %{role, status, depth, parent_id, capabilities, model, step, max_steps}},
  selected_agent_id: nil | String.t(),
  timeline_open: false,
  drawer_open: false,

  # Token/cost aggregates
  total_input_tokens: 0,
  total_output_tokens: 0,
  total_cost: 0.0,

  # Streaming state (NOT in streams — handled by JS hook)
  inflight: %{agent_id => %{turn_id, chunks: []}},

  # LiveView streams for append-only lists
  streams: [:messages, :signals, :agent_tapes]
}
```

### Reducer module: `RhoWeb.SessionProjection`

Translates raw signal bus events into assign updates. Templates never interpret
raw backend events. Single function: `project(socket, signal) :: socket`.

---

## Component Decomposition

### Function components (stateless, in `RhoWeb.Components`)

| Component | Purpose |
|---|---|
| `session_header/1` | Session ID, agent count badge, token/cost, stop button |
| `chat_feed/1` | Scrollable message list + input form |
| `message_row/1` | Single chat message (user or assistant) |
| `tool_call_row/1` | Collapsible tool invocation block |
| `delegation_card/1` | Inline "Delegated to agent_X" card |
| `agent_sidebar/1` | Tree of agent nodes |
| `agent_node/1` | Single agent: id, role badge, status dot, step count |
| `signal_chip/1` | Single signal dot on timeline |
| `signal_timeline/1` | Horizontal scrolling timeline |

### Stateful LiveComponents (only where needed)

| Component | Why stateful |
|---|---|
| `AgentDrawerComponent` | Owns lazy tape loading, has its own mini-chat input, manages its own stream of tape entries |

### JS Hooks (in `assets/js/hooks/`)

| Hook | Purpose |
|---|---|
| `StreamingText` | Receives `push_event` text deltas, appends to DOM directly. Container has `phx-update="ignore"`. Avoids re-rendering chat feed per token. |
| `AutoScroll` | Keeps chat feed and timeline scrolled to bottom unless user scrolled up. |
| `SignalTimeline` | Renders the horizontal dot timeline with hover tooltips. Pure CSS/JS — no D3. Receives signal items via `push_event`. |

---

## Streaming Text Strategy

The most performance-sensitive part. Approach:

1. On first `text_delta` for a `{agent_id, turn_id}`, insert a placeholder
   streaming message into the `:messages` stream.
2. Buffer chunks server-side for 50–100ms (use `Process.send_after`).
3. Flush batched chunks via `push_event(socket, "text-chunk", %{chunks: ...})`.
4. The `StreamingText` JS hook appends text to the DOM node marked
   `phx-update="ignore"` — LiveView never diffs this node.
5. On `turn_finished`, replace the placeholder with a finalized message,
   render full markdown/syntax highlighting, and remove `phx-update="ignore"`.

**Why not pure assigns?** A growing string in assigns at token rate produces
too many diffs. Streams are for finalized items. The hybrid approach gives
smooth streaming without chat feed re-renders.

---

## Agent Graph: Pure LiveView Tree (v1)

The data model is a rooted hierarchy (`parent_agent_id` + `depth`), so a
nested list/tree rendered server-side is sufficient. No D3, no SVG, no canvas.

```heex
<div class="agent-tree">
  <%= for agent <- root_agents(@agents) do %>
    <.agent_node agent={agent} selected={@selected_agent_id == agent.id}>
      <%= for child <- children(@agents, agent.id) do %>
        <.agent_node agent={child} selected={@selected_agent_id == child.id} />
      <% end %>
    </.agent_node>
  <% end %>
</div>
```

Status indicators via CSS classes:
- `idle` → green dot (CSS `background: #22c55e`)
- `busy` → amber dot with CSS pulse animation
- `error` → red dot

Agent spawn/stop: LiveView's built-in DOM diffing + CSS transitions
(`transition: opacity 300ms`) handle appear/fade naturally.

**Upgrade path:** If pan/zoom or animated relayout is needed later, add a
JS hook that renders SVG/Canvas. Not needed for v1.

---

## Signal Timeline

Collapsed by default (`@timeline_open = false`). Toggle with `phx-click`.

Implementation: `SignalTimeline` JS hook receives signal items via `push_event`.
Each signal is a color-coded dot. On hover, a tooltip shows signal details.
On click, `pushEvent` back to LiveView to highlight the related agents.

Rolling window: keep last 500 signals server-side. Older signals dropped
from the stream.

Color coding (CSS classes):
- `task.requested` → blue `#3b82f6`
- `task.completed` → green `#22c55e`
- `task.failed` → red `#ef4444`
- `message.sent` → yellow `#eab308`
- `turn.*` → gray `#6b7280`

Causality lines: connect signals sharing the same `correlation_id`
(already present in `SignalBus` events). Rendered as thin SVG lines
between dots in the JS hook.

---

## Data Flow: Signal Bus Subscriptions

On `mount/3` (only when `connected?(socket)`):

```elixir
def mount(%{"session_id" => sid}, _session, socket) do
  if connected?(socket) do
    # Subscribe to all session events
    {:ok, _} = Rho.Comms.SignalBus.subscribe("rho.session.#{sid}.events.*")
    # Subscribe to agent lifecycle
    {:ok, _} = Rho.Comms.SignalBus.subscribe("rho.agent.*")
    # Subscribe to task events
    {:ok, _} = Rho.Comms.SignalBus.subscribe("rho.task.*")
  end

  {:ok, assign(socket, session_id: sid, ...)}
end
```

Filter in `handle_info`: only process signals where
`signal.data.session_id == socket.assigns.session_id`.

### Targeted agent messaging

The plan's `message.agent` for mini-chat uses the existing inbox topic:
`rho.session.<sid>.agent.<agent_id>.inbox`. No new ad-hoc path needed.

```elixir
def handle_event("send_agent_message", %{"agent_id" => aid, "content" => msg}, socket) do
  Rho.Comms.publish(
    "rho.session.#{socket.assigns.session_id}.agent.#{aid}.inbox",
    %{type: "rho.message.sent", message: msg, from_agent: "user"},
    source: "/user"
  )
  {:noreply, socket}
end
```

---

## Responsive Layout

CSS Grid with `minmax()`, not fixed percentages.

```css
/* Default: two-panel */
.session-layout {
  display: grid;
  grid-template-columns: minmax(400px, 1fr) minmax(280px, 0.4fr);
  grid-template-rows: auto 1fr auto;
  height: 100vh;
}

/* Wide: three-panel (drawer pinnable) */
@media (min-width: 1440px) {
  .session-layout.drawer-pinned {
    grid-template-columns: minmax(400px, 1fr) minmax(280px, 0.35fr) 360px;
  }
}

/* Narrow: single column */
@media (max-width: 1023px) {
  .session-layout {
    grid-template-columns: 1fr;
  }
  .agent-sidebar { display: none; }
  .agent-pill-bar { display: flex; }
  .signal-timeline { display: none; }
}
```

The drawer is always a slide-over sheet by default. At >1440px it can be
*pinned* as a third column, but it's not forced.

At narrow widths, the agent sidebar collapses to a horizontal pill bar
showing `N agents` with status dots.

---

## Key States

| State | What's visible |
|---|---|
| **Empty session** | Chat panel only, centered prompt "Start a conversation", single idle node in graph |
| **Single agent chatting** | Chat streaming, one node in graph (green→amber→green) |
| **Delegation in progress** | Delegation card in chat, tree grows, child nodes pulse amber |
| **Multi-agent conversation** | Timeline shows signal flow, graph shows message edges |
| **Task completed** | Result card in chat, child nodes fade out, graph shrinks |
| **Error state** | Red node in graph, error signal in timeline, error card in chat |
| **Disconnected** | Banner: "Reconnecting...", all panels frozen, auto-rehydrate on reconnect |

---

## Reconnection / Rehydration

On LiveView reconnect (happens automatically):
1. Re-subscribe to signal bus
2. Fetch current agent list from `Rho.Agent.Registry.list(session_id)`
3. Replay recent signals from `Rho.Comms.SignalBus.replay/2` (already supported)
4. Show connection status indicator during reconnect

---

## Guardrails

- **Cap collections**: chat stream paginated (load older on scroll-up), signals
  rolling window of 500, tool output collapsed/truncated by default
- **Streaming markdown**: render as plain text during streaming, full
  markdown + syntax highlighting only on finalization (avoids flicker)
- **Event identity**: preserve `correlation_id` and `causation_id` from
  SignalBus for timeline causality lines
- **No D3 in v1**: agent graph is a CSS tree, signal timeline is a simple
  JS hook with dots — both upgradeable later

---

## File Structure

```
lib/rho_web/
├── endpoint.ex              # Phoenix.Endpoint (replaces Rho.Web.Endpoint for LiveView)
├── router.ex                # Phoenix.Router with live routes
├── live/
│   ├── session_live.ex      # Main LiveView — state owner
│   └── session_projection.ex # Signal → assign reducer
├── components/
│   ├── layouts.ex           # Root/app layout
│   ├── core_components.ex   # Shared primitives
│   ├── chat_components.ex   # chat_feed, message_row, tool_call_row, delegation_card
│   ├── agent_components.ex  # agent_sidebar, agent_node, agent_pill_bar
│   ├── signal_components.ex # signal_timeline, signal_chip
│   └── agent_drawer_component.ex  # Stateful LiveComponent
├── telemetry.ex
assets/
├── js/
│   ├── app.js
│   └── hooks/
│       ├── streaming_text.js
│       ├── auto_scroll.js
│       └── signal_timeline.js
├── css/
│   └── app.css              # Tailwind + custom dark theme
```

The existing `Rho.Web.*` modules stay untouched for API/CLI clients.

---

## Implementation Order

1. **Phoenix bootstrap** — add deps, create `RhoWeb.Endpoint`, router, root layout
2. **SessionLive shell** — mount, signal bus subscription, basic assigns
3. **Chat panel** — message stream, input form, `Rho.Session.submit/2` integration
4. **Streaming text** — JS hook, push_event, buffered delta flushing
5. **Agent sidebar** — tree rendering from `agents` assign, status dots
6. **Tool call blocks** — collapsible inline tool calls in chat
7. **Delegation cards** — inline task.requested/completed cards
8. **Agent drawer** — LiveComponent with tape loading, mini-chat
9. **Signal timeline** — JS hook, rolling window, color-coded dots
10. **Responsive** — CSS grid breakpoints, pill bar, drawer pinning
11. **Polish** — reconnection handling, error states, animations
