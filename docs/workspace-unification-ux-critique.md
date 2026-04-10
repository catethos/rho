# Workspace Unification — UX Critique

## User Journeys Analyzed

1. Creating a new skill (spreadsheet workspace + chat with agent)
2. Talking with multiple agents (chat side panel, agent tabs)
3. Watching agents talk to each other (chatroom workspace)
4. Doing all of the above within the same session

---

## Friction Point 1: Route Changes Kill State

Navigating from `/editor/session-123` to `/chatroom/session-123` triggers a new `mount/3` because `live_action` changes. The LiveView process is replaced. This means:

- Spreadsheet state (rows, scroll position, editing state) is lost
- Chat scroll position and streaming context reset
- Pending agent responses may be missed during the transition
- It feels like switching apps, not switching tabs

**Expected user experience:** "I click the Chatroom tab to see what agents are saying, then click back to the spreadsheet — everything is still there."

**Actual experience:** Full remount. State rebuilt from hydration replay. Scroll positions lost. Any in-progress inline edit gone.

---

## Friction Point 2: Can't Have Spreadsheet + Chatroom Simultaneously

The plan maps `live_action` to a single workspace set:

```elixir
defp determine_workspaces(:spreadsheet), do: [:spreadsheet]
defp determine_workspaces(:chatroom), do: [:chatroom]
```

But the most natural flow is: *"I'm editing skills in the spreadsheet while watching agents coordinate in the chatroom."* The tab bar UI implies switching between views, but the data behind the inactive tab is destroyed.

This matters most for multi-agent sessions where:
- The user wants to see the spreadsheet artifact being built
- While also monitoring agent-to-agent communication in the chatroom
- While also chatting with a specific agent via the side panel

All three are projections over the same signal stream — there's no architectural reason they can't coexist.

---

## Friction Point 3: No In-Session Workspace Discovery

There's no UI path to discover or open other workspace views from within a session. A user on `/editor/session-123` has no way to know that a chatroom view of the same session exists unless they manually construct the URL `/chatroom/session-123`.

Workspace views feel like separate applications rather than perspectives on the same session.

---

## Friction Point 4: Chat Side Panel vs. Chatroom Confusion

The chat side panel shows per-agent DM-style messages (one agent at a time, tab to switch). The chatroom workspace shows all agent messages interleaved in a single timeline. Both are projections over the same signals, but present them differently.

A user watching agents collaborate would need to understand:
- Why the side panel shows different content than the chatroom tab
- When to look at the side panel vs. the chatroom
- That the side panel is for 1:1 interaction while the chatroom is for observation

This distinction is clear to the architect but not to the user.

---

## Root Cause

The plan ties workspace selection to **routes and `live_action`**, which means:
- Switching workspaces = navigation = new mount = new process
- Only one workspace set is alive at a time
- The URL is the source of truth for what's visible

But workspaces are just **projections over the same signal stream**. They should be addable/removable without changing the LiveView process.

---

## Recommended Fixes

### Fix 1: Workspace Selection as Socket Assign, Not Route

Routes should suggest the *initial* workspace set, but switching tabs should be a client-side assign change within the same LiveView process:

```elixir
# Route sets initial workspaces
def mount(params, _session, socket) do
  initial_workspaces = determine_initial_workspaces(socket.assigns.live_action)
  socket = assign(socket, :active_workspace_keys, initial_workspaces)
  # ...
end

# handle_params keeps the process alive on URL changes
def handle_params(%{"session_id" => sid}, _uri, socket) do
  # Reuse existing process, just update session if needed
end

# Tab switching is just an assign change — no navigation
def handle_event("switch_workspace", %{"workspace" => ws}, socket) do
  {:noreply, assign(socket, :active_workspace_id, String.to_existing_atom(ws))}
end
```

All workspace projections run continuously regardless of which tab is visible. Switching tabs is instant — no remount, no replay, no lost state.

### Fix 2: Allow Multiple Workspace Tabs

Let `determine_initial_workspaces/1` return multiple keys, and let users add/remove tabs dynamically:

```elixir
defp determine_initial_workspaces(:spreadsheet), do: [:spreadsheet]
defp determine_initial_workspaces(:chatroom), do: [:chatroom]
defp determine_initial_workspaces(:full), do: [:spreadsheet, :chatroom]
defp determine_initial_workspaces(_), do: []

# User can add a workspace tab at runtime
def handle_event("add_workspace", %{"workspace" => ws}, socket) do
  key = String.to_existing_atom(ws)
  ws_def = Map.get(@workspace_registry, key)

  socket =
    socket
    |> update(:active_workspace_keys, &(&1 ++ [key]))
    |> update(:workspaces, &Map.put(&1, key, ws_def))
    |> update(:ws_states, &Map.put_new(&1, key, ws_def.projection.init()))

  {:noreply, socket}
end
```

### Fix 3: Workspace Picker in Tab Bar

Add a "+" button to the tab bar that shows available workspaces for the current session:

```
+--[Skills Editor]--[Chatroom]--[+]------------------[Chat >]--+
|                                                                |
|  Active workspace                          Chat side panel     |
|                                                                |
+----------------------------------------------------------------+
```

Clicking "+" shows a dropdown of workspace types from `@workspace_registry` that aren't already open. This lets users discover and compose workspace views without knowing URLs.

### Fix 4: Smart Chat Panel Behavior

Reduce confusion between chat side panel and chatroom:

| Active workspace | Chat side panel behavior |
|-----------------|--------------------------|
| Spreadsheet (no chatroom tab) | Show side panel with agent DM tabs (current behavior) |
| Chatroom | Auto-hide side panel (redundant — all messages are in the chatroom) |
| Spreadsheet + Chatroom | Side panel available for 1:1 agent DMs; chatroom tab shows group view |
| No workspaces (`:chat` route) | Chat takes full width as main content |

When the user opens the chatroom tab, the chat toggle button could show a brief hint: "Agent messages are now in the Chatroom tab."

---

## Architectural Implications

These UX fixes have one main architectural consequence: **all active workspace projections must run continuously**, not just the visible one.

This is already almost true in the plan — `SignalRouter.route/2` iterates over `socket.assigns.workspaces` and runs all projections. The change is:

1. Don't gate workspace activation on `live_action` alone
2. Keep projection state in `ws_states` even when a tab is hidden
3. Only control *rendering* with `active_workspace_id`, not *projection*

The signal routing cost is negligible (2–4 reducer calls per signal). The rendering cost is zero for hidden workspaces (`:if` or `hidden` class already in the plan).

---

## Updated Tab Bar UX

```
+--[Skills Editor]--[Chatroom]--[+]------------------[Chat >]--+
|                                     ↑                          |
|  ┌─────────────────────────┐  workspace picker                 |
|  │ Skills Editor  (active) │  adds tabs dynamically            |
|  │ showing spreadsheet     │                                   |
|  │ with inline editing     │          ┌──────────────────┐     |
|  │                         │          │ Chat side panel   │     |
|  │                         │          │ Agent: researcher │     |
|  │                         │          │ [agent tabs here] │     |
|  │                         │          │                   │     |
|  │                         │          │ > message input   │     |
|  └─────────────────────────┘          └──────────────────┘     |
+----------------------------------------------------------------+

Clicking [Chatroom] tab:
- Switches workspace-panel content instantly (no remount)
- Spreadsheet state preserved in ws_states
- Chat side panel auto-hides (chatroom already shows messages)

Clicking [+]:
- Dropdown: "Canvas", "Document Viewer", ...
- Adds new tab + initializes projection
- No navigation, no remount
```

---

## Summary

| Issue | Severity | Fix |
|-------|----------|-----|
| Route change kills state | High | Use `handle_params`, not remount. Workspace selection is an assign. |
| Single workspace at a time | Medium | Run all active projections continuously. Multiple tabs allowed. |
| No workspace discovery | Medium | Add "+" workspace picker button to tab bar. |
| Chat panel vs. chatroom confusion | Low | Smart auto-hide when chatroom is active. |
