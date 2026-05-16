# Live Patch Navigation + Memory Management Plan

## Goal

Persist chat state across page navigation by converting to `live_patch`, and add UI for users to manually manage memory/state.

---

## Phase 1: Unified Root LiveView with `live_patch`

### 1.1 Router Changes

Convert org-scoped routes to use a single `RhoWeb.AppLive` that handles all pages:

```elixir
# router.ex
live_session :org_authenticated, layout: {RhoWeb.Layouts, :app} do
  # All routes point to AppLive with different live_actions
  live "/orgs/:org_slug/chat", AppLive, :chat_new
  live "/orgs/:org_slug/chat/:session_id", AppLive, :chat_show
  live "/orgs/:org_slug/libraries", AppLive, :libraries
  live "/orgs/:org_slug/libraries/:id", AppLive, :library_show
  live "/orgs/:org_slug/roles", AppLive, :roles
  live "/orgs/:org_slug/roles/:id", AppLive, :role_show
  live "/orgs/:org_slug/observatory", AppLive, :observatory_new
  live "/orgs/:org_slug/observatory/:session_id", AppLive, :observatory_show
  live "/orgs/:org_slug/settings", AppLive, :settings
  live "/orgs/:org_slug/members", AppLive, :members
end
```

### 1.2 AppLive Module

Thin orchestrator that:
- Owns session state (agents, messages, shell, ws_states, signal subscriptions)
- Delegates rendering to page modules based on `@live_action`
- Handles `handle_params` to switch pages without losing state

```elixir
defmodule RhoWeb.AppLive do
  use RhoWeb, :live_view

  def mount(params, session, socket) do
    # Initialize session core (agents, signals, shell) — same as current SessionLive.mount
    # But DON'T load page-specific data yet — that happens in handle_params
  end

  def handle_params(params, uri, socket) do
    live_action = socket.assigns.live_action

    socket
    |> cleanup_previous_page()          # Drop page-scoped assigns
    |> apply_page(live_action, params)   # Load new page data
    |> noreply()
  end

  def render(assigns) do
    ~H"""
    <%!-- Global nav always rendered --%>
    <%!-- Chat state always alive in background --%>

    <%= case @live_action do %>
      <% action when action in [:chat_new, :chat_show] -> %>
        <.live_component module={ChatPage} id="chat" {chat_assigns(@socket)} />
      <% :libraries -> %>
        <.live_component module={LibrariesPage} id="libraries" {library_assigns(@socket)} />
      <% :library_show -> %>
        <.live_component module={LibraryShowPage} id="library-show" {library_show_assigns(@socket)} />
      <% action when action in [:roles, :role_show] -> %>
        <.live_component module={RolesPage} id="roles" {role_assigns(@socket)} />
      <% _ -> %>
        <.live_component module={SettingsPage} id="settings" {settings_assigns(@socket)} />
    <% end %>
    """
  end
end
```

### 1.3 Navigation Links

Change app layout nav from `href` to `patch`:

```html
<!-- Before -->
<a href={~p"/orgs/#{@org.slug}/chat"}>Chat</a>
<a href={~p"/orgs/#{@org.slug}/libraries"}>Libraries</a>

<!-- After -->
<.link patch={~p"/orgs/#{@org.slug}/chat"}>Chat</.link>
<.link patch={~p"/orgs/#{@org.slug}/libraries"}>Libraries</.link>
```

### 1.4 Page-scoped Cleanup in `handle_params`

```elixir
defp cleanup_previous_page(socket) do
  case socket.assigns[:active_page] do
    :libraries ->
      assign(socket, libraries: nil, library_detail: nil)
    :roles ->
      assign(socket, role_profiles: nil, role_families: nil)
    :observatory ->
      assign(socket, observatory_state: nil)
    _ ->
      socket
  end
end
```

### 1.5 Extract Page Modules from Existing LiveViews

Refactor each existing LiveView into a `live_component` or helper module:

| Current LiveView | New Module | Type |
|---|---|---|
| `SessionLive` | `RhoWeb.Pages.Chat` | live_component |
| `SkillLibraryLive` | `RhoWeb.Pages.Libraries` | live_component |
| `SkillLibraryShowLive` | `RhoWeb.Pages.LibraryShow` | live_component |
| `RoleProfileListLive` | `RhoWeb.Pages.Roles` | live_component |
| `RoleProfileShowLive` | `RhoWeb.Pages.RoleShow` | live_component |
| `ObservatoryLive` | `RhoWeb.Pages.Observatory` | live_component |
| `OrgSettingsLive` | `RhoWeb.Pages.Settings` | live_component |
| `OrgMembersLive` | `RhoWeb.Pages.Members` | live_component |

Each page module handles its own events and rendering, but AppLive owns the session state.

---

## Phase 2: Memory Management UI

### 2.1 Session Manager Panel

A slide-out drawer (similar to existing agent drawer) accessible from the session header. Contains tabs for managing different state types.

**Trigger:** Button in session header bar (gear/broom icon), or Cmd+K command "Manage Session".

**Layout:**

```
+------------------------------------------+
|  Session Manager                    [X]  |
|------------------------------------------|
|  [Chat] [Data] [Agents] [Memory]        |
|------------------------------------------|
|                                          |
|  (content based on active tab)           |
|                                          |
+------------------------------------------+
```

### 2.2 Chat Tab — Conversation Management

Controls for the chat/message state.

```
Chat History
─────────────────────────────────
Messages: 847 across 3 agents     [Clear All]

  primary (423 msgs, 12.4k tokens)  [Clear]
  researcher (298 msgs, 8.1k tokens) [Clear]
  writer (126 msgs, 3.2k tokens)    [Clear]

Token Usage
─────────────────────────────────
Input:  245,302 tokens ($1.23)
Output:  89,441 tokens ($0.67)
Cached:  34,100 tokens
                          [Reset Counters]

Threads
─────────────────────────────────
  main (active)
  fork-2024-04-13-a              [Delete]
  fork-2024-04-13-b              [Delete]
```

**Actions:**
- **Clear agent messages** — Resets `agent_messages[agent_id]` to `[]`
- **Clear all messages** — Resets all agent message lists
- **Reset counters** — Zeros token/cost counters
- **Delete thread** — Removes thread snapshot + tape

### 2.3 Data Tab — Table Management

Controls for the DataTable GenServer state.

```
Data Tables
─────────────────────────────────
  main (dynamic, 1,204 rows, ~48KB)   [Clear] [Drop]
  library (strict, 89 rows, ~3KB)     [Clear] [Drop]
  role_profile (strict, 12 rows, ~1KB) [Clear] [Drop]

                    [Clear All Tables] [Stop Server]
```

**Actions:**
- **Clear table** — Calls `DataTable.replace_all(sid, [], table: name)`, keeps schema
- **Drop table** — New API: removes named table entirely from server
- **Clear all** — Clears all tables
- **Stop server** — Stops DataTable GenServer entirely (restart on next write)

### 2.4 Agents Tab — Agent Lifecycle

```
Active Agents
─────────────────────────────────
  primary         idle    step 0/10      [Restart]
  researcher      running step 3/10     [Stop] [Remove]
  writer          idle    step 5/10     [Stop] [Remove]

Stopped Agents
─────────────────────────────────
  analyst         stopped               [Remove]

                              [Remove All Stopped]
```

**Actions:**
- **Stop agent** — `GenServer.stop(pid, :normal)`
- **Remove agent** — Stop + unregister + drop from assigns + clear messages
- **Restart agent** — Stop and re-start with same config
- **Remove all stopped** — Batch remove all stopped non-primary agents

### 2.5 Memory Tab — Process Memory Info

Read-only diagnostic view showing what's consuming memory in the LiveView process.

```
LiveView Process Memory
─────────────────────────────────
Total:           2.3 MB
  agent_messages:  1.1 MB  (47%)
  ws_states:       0.4 MB  (17%)
  signals:         0.3 MB  (13%)
  agents:          0.1 MB  (4%)
  other:           0.4 MB  (19%)

                              [Compact All]
```

**Actions:**
- **Compact all** — Trims messages to 50 (from 200 cap), clears signals, resets workspace projection caches, drops debug_projections

### 2.6 Quick Actions (Always Visible)

In the session header, small icon buttons for the most common cleanup actions:

```
[Session: abc123]  [Tokens: 245k/89k ($1.90)]  [3 agents]  [🧹] [⚙️]
                                                              ^     ^
                                                         Quick   Session
                                                         Clean   Manager
```

**Quick Clean (broom icon)** — One-click action that:
1. Removes all stopped agents + their messages
2. Clears signals list
3. Resets workspace projection caches for inactive workspaces
4. Shows brief flash: "Cleaned up 2 agents, freed ~0.8MB"

---

## Phase 3: Automatic Cleanup Hooks

### 3.1 On Page Navigation (handle_params)

When leaving a page, automatically clean up page-scoped state:

```elixir
defp cleanup_previous_page(socket) do
  prev = socket.assigns[:active_page]
  next = socket.assigns.live_action

  socket
  |> drop_page_assigns(prev)
  |> reset_inactive_workspace_caches(next)
end
```

### 3.2 Idle Timer

After N minutes of no user interaction on a page, compact that page's state:

```elixir
# In handle_info
{:idle_cleanup, page} ->
  if socket.assigns.active_page != page do
    # Page is no longer active — safe to compact
    compact_page_state(socket, page)
  end
```

### 3.3 Message Cap with Snapshot Offload

When agent_messages hits 200 (current cap), save older messages to snapshot before trimming. Users can "Load earlier messages" to pull from snapshot.

---

## Implementation Order

1. **Phase 1.1-1.3** — Router + AppLive + patch links (core migration)
2. **Phase 1.4-1.5** — Extract page modules (refactor)
3. **Phase 2.6** — Quick Clean button (highest value, lowest effort)
4. **Phase 2.1-2.2** — Session Manager panel + Chat tab
5. **Phase 2.3** — Data tab
6. **Phase 2.4** — Agents tab
7. **Phase 2.5** — Memory tab (diagnostic)
8. **Phase 3** — Automatic cleanup hooks

---

## Key Design Decisions

1. **AppLive owns all session state** — Pages are live_components that receive assigns from AppLive. This keeps one source of truth.

2. **Pages declare their own assigns** — Each page module exports `required_assigns/0` so AppLive knows what to fetch in `handle_params`.

3. **Chat state is never cleaned on navigation** — Only explicit user action (Clear, Remove) or thread switch clears chat. Navigation between pages preserves everything.

4. **DataTable state stays in GenServer** — LiveView only holds cached snapshots. Cleanup actions talk to the GenServer directly.

5. **Session Manager is a live_component** — Rendered conditionally when open. Gets assigns from AppLive. Sends events back to AppLive for state mutations.

6. **No `temporary_assigns` for messages** — We want messages to persist across page switches. The 200-per-agent cap is sufficient. If we need more, switch to Phoenix streams later.

---

## UI Styling Notes

Follow existing design system:
- Drawer slides from right (like agent drawer): `translateX(100%) -> 0`
- Tabs use `.workspace-tab-bar` pattern with bottom border accent
- Buttons: ghost style for secondary actions, filled for destructive (red tint)
- Size indicators: `--text-muted` color, monospace font for numbers
- Flash messages for action confirmation
- Copper accent (`--teal`) for interactive elements
