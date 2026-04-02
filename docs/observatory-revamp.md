# Observatory Revamp — What Was Done & What's Next

## What Was Built

### Unified Session Event Stream (backend)

The core infrastructure that makes the observatory possible:

- **`Rho.Session.EventLog`** — GenServer per session that subscribes to the signal bus and writes filtered events to `{workspace}/_rho/sessions/{session_id}/events.jsonl`. Filters out `text_delta` and `structured_partial` (high-frequency, reconstructable). Truncates tool results at 4KB and tool args at 2KB.
- **`Rho.Session.inject/4`** — Inject messages into any agent from external tools. Routes to primary agent or delivers signals to specific agents by ID. External messages are formatted differently from inter-agent messages.
- **`Rho.Session.event_log_path/1`** — Returns the JSONL file path for direct reading.
- **3 new HTTP endpoints** on the Observatory API:
  - `POST /sessions` — Create session with optional initial message
  - `POST /sessions/{id}/inject` — Inject messages to any agent
  - `GET /sessions/{id}/log` — Cursor-based event log pagination
- **Supervision tree** — `Rho.EventLogRegistry` (unique Registry) and `Rho.Session.EventLog.Supervisor` (DynamicSupervisor) added to `application.ex`.

### Discussion-Centric Observatory (frontend)

Complete rewrite of the Phoenix LiveView observatory, replacing the old grid-of-cards + signal-flow + convergence-chart layout with a chat-thread UI.

**Layout**: Two-column — scrollable discussion timeline (main) + sidebar (agents, scores, tokens).

**Discussion Timeline** renders these entry types:
| Entry Type | Visual | Source Signal |
|---|---|---|
| `:message` | Color-coded chat bubble with avatar, author, target | `message_sent`, `broadcast` |
| `:thinking` | Muted, dashed border, 55% opacity, expands on hover | `llm_text` |
| `:tool_use` | Compact inline row: gear icon + tool name + args | `tool_start` |
| `:tool_result` | Indented monospace with checkmark/cross | `tool_result` |
| `:turn_end` | Chat bubble labeled "final response", markdown rendered | `rho.turn.finished` |
| `:agent_event` | Inline text with colored dot | `rho.agent.started/stopped` |
| `:marker` | Horizontal rule with centered label | `rho.hiring.round.started`, `simulation.completed` |

**Role color palette**:
- Coordinator (default/primary) — teal `#5BB5A2`
- Technical — blue `#5B8ABA`
- Culture — purple `#B55BA0`
- Compensation — gold `#D4A855`

**Sidebar**:
- Agent pills — avatar, name, current tool/step, animated status dot
- Score table — compact, only shown when scores exist
- Token summary — input/output/total, updating live

**Landing page** (`/observatory`):
- Lists existing sessions (live + on-disk JSONL logs)
- Shows agent count and event count per session
- Click to open any past or live session

**JSONL Replay**: When opening a past session, the event log is replayed through the projection to rebuild the full discussion state. Filters skip `llm_usage`, `step_start`, `llm_text`, `text_delta`, `ui_spec`, `ui_spec_delta` for performance. Infrastructure tools (`stop_agent`, `present_ui`, `list_agents`) are hidden. Cross-session agent events are filtered by `session_id`.

**Markdown rendering**: Message bodies and turn results use `data-md` attribute with the `Markdown` JS hook (marked.js). Tables, headers, bold, lists, code blocks all render.

### Files Changed

| File | Action |
|---|---|
| `lib/rho/session/event_log.ex` | **Created** — JSONL event log GenServer |
| `lib/rho/session.ex` | Modified — `inject/4`, `event_log_path/1`, EventLog lifecycle |
| `lib/rho/agent/worker.ex` | Modified — external message formatting |
| `lib/rho/application.ex` | Modified — EventLog registry + supervisor |
| `lib/rho_web/observatory_api.ex` | Modified — 3 new HTTP routes |
| `lib/rho_web/live/observatory_live.ex` | **Rewritten** — discussion layout, session list, JSONL replay |
| `lib/rho_web/live/observatory_projection.ex` | **Rewritten** — chronological discussion entries |
| `lib/rho_web/components/observatory_components.ex` | **Rewritten** — chat bubbles, agent pills, score table |
| `lib/rho_web/inline_css.ex` | Modified — replaced observatory CSS section |

---

## What's Next — Making It Interactive

### P0: Core Interactivity

**1. Message injection from the UI**
Add a text input at the bottom of the discussion timeline. The user types a message, selects a target agent (or "all"), and sends it via `Session.inject/4`. The message appears in the timeline immediately. This turns the observatory from read-only into a control panel — the human becomes a participant in the multi-agent discussion.

- Input bar fixed at bottom of timeline pane
- Dropdown to pick target: "All agents", or specific agent by name
- Send button + Enter to submit
- Calls `Session.inject(session_id, target, message, from: "human")`
- New `:human_message` entry type with distinct styling (right-aligned or different color)

**2. Collapsible tool calls**
Tool use/result pairs are noisy. Group them into collapsible sections: show just the tool name inline, click to expand args + result. Reduces visual clutter by ~40% while keeping the data accessible.

- JS hook or `<details>` element
- Collapsed: `⚙ send_message → ✓` (one line)
- Expanded: full args + result

**3. Agent detail panel**
Clicking an agent pill in the sidebar opens a slide-out or modal with:
- Full agent info (role, depth, capabilities, description)
- Token usage breakdown
- Tool call history (filtered to that agent)
- Current tape/memory state (via `GET /agents/{id}/tape`)
- "Send message" shortcut pre-filled with that agent as target

### P1: Navigation & Search

**4. Jump to agent's messages**
Click an agent avatar in a message → scroll to / filter to only that agent's messages. Toggle between "all" and "agent X" view. Useful when the timeline is 700+ entries.

**5. Search within discussion**
Text search bar that filters the timeline to entries matching the query. Highlight matching text. Essential for long simulations.

**6. Timeline scrubber**
A thin horizontal bar above the timeline showing the density of messages over time. Click to jump to a point. Color-coded segments by active phase/round. Shows where the "hot" discussion periods were.

### P2: Live Simulation Controls

**7. Pause / resume agent**
Per-agent pause button that holds the agent's mailbox without processing. Useful for slowing down a fast simulation to observe behavior, or to let one agent finish before another starts.

**8. Adjust agent parameters mid-run**
- Change `max_steps` for an agent
- Inject a system prompt amendment ("from now on, also consider X")
- Swap model (e.g., switch an evaluator from haiku to sonnet mid-discussion)

**9. Fork simulation**
Snapshot current session state → create a new session with the same event history up to this point → run with different parameters. Compare outcomes side-by-side.

### P3: Visualization & Analysis

**10. Interaction graph**
SVG/canvas visualization showing agents as nodes, messages as directed edges. Edge thickness = message count. Node size = token usage. Animated during live simulation. Shows who talks to whom and how much.

**11. Cost ticker**
Running total of estimated cost in the header bar, broken down by agent. Updates live. Shows cost-per-message so the user can see which agents are expensive.

**12. Diff view for replays**
Compare two session event logs side-by-side. Highlight where they diverge. Useful for A/B testing different agent configurations on the same task.

### Implementation Priority

| Priority | Item | Effort | Impact |
|---|---|---|---|
| P0 | Message injection UI | Small | High — transforms observatory into control panel |
| P0 | Collapsible tool calls | Small | Medium — reduces clutter |
| P0 | Agent detail panel | Medium | Medium — better debugging |
| P1 | Filter by agent | Small | High — essential for long discussions |
| P1 | Search | Small | High — essential for long discussions |
| P1 | Timeline scrubber | Medium | Medium — nice navigation aid |
| P2 | Pause/resume | Medium | High — real-time control |
| P2 | Parameter adjustment | Medium | Medium — experimentation |
| P2 | Fork simulation | Large | High — A/B testing |
| P3 | Interaction graph | Medium | Medium — visualization |
| P3 | Cost ticker | Small | Medium — budget awareness |
| P3 | Diff view | Large | Medium — comparison |
