# Intelligent Spreadsheet Editor — Implementation Plan

## Overview

Two-panel LiveView page: left panel is a Tabulator.js spreadsheet (1,500+ rows), right panel is a Rho agent chat that can read/edit the table. Interactive version of the `skill_generation` library.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SpreadsheetLive (LiveView)                             │
│                                                         │
│  ┌──────────────────────┐  ┌────────────────────────┐   │
│  │  Tabulator.js Hook   │  │  Chat Panel            │   │
│  │  (JS owns the DOM)   │  │  (reuse ChatComponents)│   │
│  │                      │  │                         │   │
│  │  pushEvent ──────────┼──┼─► handle_event          │   │
│  │  ◄────────── handleEvent  push_event              │   │
│  └──────────────────────┘  └────────────────────────┘   │
│                                                         │
│  assigns.table_data = %{rows: [...], columns: [...]}    │
│         │                                               │
│         ▼                                               │
│  Rho.Session (agent worker)                             │
│         │                                               │
│         ▼                                               │
│  Rho.Mounts.Spreadsheet (custom mount)                  │
│  Tools: get_table, update_cells, add_rows,              │
│         delete_rows, generate_skills,                   │
│         generate_proficiencies                           │
└─────────────────────────────────────────────────────────┘
```

## Data Model

### Row Shape (flat, same as skill_generation output)

```elixir
%{
  id: integer(),           # row identifier (auto-increment)
  category: String.t(),
  cluster: String.t(),
  skill_name: String.t(),
  skill_description: String.t(),
  level: integer(),        # 1-5
  level_name: String.t(),  # "Novice", "Practitioner", etc.
  level_description: String.t()  # observable behavior text
}
```

One row per skill × proficiency level. 300 skills × 5 levels = 1,500 rows.

### Column Definition

```elixir
@columns [
  %{field: "id", title: "ID", width: 60, editor: false},
  %{field: "category", title: "Category", width: 150, editor: "input"},
  %{field: "cluster", title: "Cluster", width: 150, editor: "input"},
  %{field: "skill_name", title: "Skill", width: 200, editor: "input"},
  %{field: "skill_description", title: "Description", width: 300, editor: "textarea"},
  %{field: "level", title: "Lvl", width: 50, editor: "number"},
  %{field: "level_name", title: "Level Name", width: 120, editor: "input"},
  %{field: "level_description", title: "Level Description", width: 400, editor: "textarea"}
]
```

## Implementation Steps

### Step 1: Route + LiveView skeleton

**Files:** `router.ex`, `lib/rho_web/live/spreadsheet_live.ex`

- Add route: `live("/spreadsheet/:session_id", SpreadsheetLive, :show)` and `live("/spreadsheet", SpreadsheetLive, :new)`
- Create `SpreadsheetLive` with two-panel layout
- Mount: initialize `table_data` (empty list), create session, subscribe to signal bus
- Render: left div with `id="spreadsheet"` + `phx-hook="Spreadsheet"`, right div with chat components

### Step 2: Tabulator JS Hook

**File:** `lib/rho_web/inline_js.ex`

Add `Spreadsheet` hook to `window.RhoHooks`:

```javascript
Spreadsheet: {
  mounted() {
    // Load Tabulator CSS + JS from CDN
    // Initialize table with columns from data attribute
    // On cell edit: this.pushEvent("cell_edited", {id, field, value, oldValue})
    // Listen for server pushes:
    //   "table_init"  → table.setData(rows)
    //   "table_update" → table.updateData(rows)  // partial update
    //   "table_add"   → table.addData(rows)
    //   "table_delete" → table.deleteRow(ids)
    //   "table_replace" → table.replaceData(rows)  // full replace
  },
  destroyed() {
    if (this.table) this.table.destroy();
  }
}
```

Tabulator loaded from CDN: `https://cdn.jsdelivr.net/npm/tabulator-tables@6/dist/js/tabulator.min.js`

### Step 3: LiveView ↔ Tabulator data flow

**File:** `lib/rho_web/live/spreadsheet_live.ex`

```elixir
# Server holds canonical state
assign(socket, :rows, [])

# On mount (connected), push initial data to JS
push_event(socket, "table_init", %{rows: socket.assigns.rows, columns: @columns})

# User edits a cell in Tabulator
def handle_event("cell_edited", %{"id" => id, "field" => field, "value" => val}, socket) do
  rows = update_row(socket.assigns.rows, id, field, val)
  {:noreply, assign(socket, :rows, rows)}
end

# Agent edits via tool → signal bus → handle_info → push to JS
def handle_info({:table_updated, changes}, socket) do
  push_event(socket, "table_update", %{rows: changes})
end
```

### Step 4: Chat panel (reuse existing components)

**File:** `lib/rho_web/live/spreadsheet_live.ex`

- Reuse `ChatComponents.chat_feed/1`, `chat_input_with_upload/1`, `message_row/1`, `tool_call_row/1`
- Subscribe to Rho signal bus for the session (same pattern as SessionLive)
- Use `SessionProjection` for projecting agent events into chat assigns
- `handle_event("send_message", ...)` → `Rho.Session.submit(session_id, message)`

### Step 5: Spreadsheet Mount

**File:** `lib/rho/mounts/spreadsheet.ex`

```elixir
defmodule Rho.Mounts.Spreadsheet do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_opts, context) do
    pid = context.spreadsheet_pid  # the LiveView process
    [
      get_table_tool(pid),
      update_cells_tool(pid),
      add_rows_tool(pid),
      delete_rows_tool(pid),
      generate_framework_tool(pid),
      generate_proficiencies_tool(pid)
    ]
  end

  @impl Rho.Mount
  def prompt_sections(_opts, _context) do
    ["""
    You are a skill framework editor assistant. The user has a spreadsheet of skills
    with columns: category, cluster, skill_name, skill_description, level, level_name,
    level_description. You can read and modify the table using your tools.

    When the user asks to generate skills, use generate_framework.
    When they ask to add proficiency levels, use generate_proficiencies.
    For specific edits, use update_cells or add_rows/delete_rows.
    Always call get_table first to understand the current state before making changes.
    """]
  end
end
```

**Tool definitions:**

| Tool | Parameters | What it does |
|------|-----------|--------------|
| `get_table` | `filter` (optional: category, cluster) | Returns current rows as JSON (or filtered subset). Sends `{:get_table, ...}` to LiveView pid |
| `update_cells` | `changes: [%{id, field, value}]` | Bulk cell updates. Sends `{:update_cells, changes}` to LiveView |
| `add_rows` | `rows: [%{category, cluster, ...}]` | Append rows. Sends `{:add_rows, rows}` to LiveView |
| `delete_rows` | `ids: [integer]` or `filter: %{category: ...}` | Remove rows. Sends `{:delete_rows, ids}` to LiveView |
| `generate_framework` | `context: string, num_categories: int` | Calls skill_generation pipeline, returns framework, adds rows to table |
| `generate_proficiencies` | `skill_ids: [int], levels: int` | Generates proficiency rows for specified skills |

### Step 6: Spreadsheet CSS

**File:** `lib/rho_web/inline_css.ex`

```css
.spreadsheet-layout {
  display: flex;
  height: 100vh;
  overflow: hidden;
}
.spreadsheet-panel {
  flex: 1;
  min-width: 0;
  overflow: hidden;
}
.chat-panel {
  width: 380px;
  min-width: 320px;
  max-width: 480px;
  border-left: 1px solid var(--border);
  display: flex;
  flex-direction: column;
}
```

### Step 7: Register mount + wire up

**Files:** `lib/rho/config.ex`, `.rho.exs`

- Add `:spreadsheet` to `@mount_modules` map in Config
- Create a spreadsheet agent profile in `.rho.exs` with mounts: `[:spreadsheet, :bash]`
- SpreadsheetLive starts a session with this profile, passing its own pid as context

### Step 8: Integration with skill_generation

The `generate_framework` and `generate_proficiencies` tools need to call the skill_generation library. Two options:

**Option A: Direct dependency** — Add `skill_generation` as a dep in mix.exs (if it's published to hex or available as a path dep).

**Option B: HTTP/API** — If skill_generation runs as a separate service, call it via HTTP.

**Option C: Re-implement in Rho** — Port the BAML calls into the mount's tool execute functions, using Rho's own LLM integration (ReqLLM). The mount sends structured prompts to the LLM and parses skill/proficiency JSON back. This keeps Rho self-contained.

Recommend **Option C** for now — the generation prompts can be embedded in the mount, and Rho already has LLM access. Can always swap to a proper dependency later.

## File Inventory

| File | Action | Purpose |
|------|--------|---------|
| `lib/rho_web/router.ex` | Edit | Add `/spreadsheet` routes |
| `lib/rho_web/live/spreadsheet_live.ex` | Create | Main LiveView |
| `lib/rho/mounts/spreadsheet.ex` | Create | Mount with table-editing tools |
| `lib/rho_web/inline_js.ex` | Edit | Add Spreadsheet hook |
| `lib/rho_web/inline_css.ex` | Edit | Add spreadsheet layout styles |
| `lib/rho_web/components/layouts/root.html.heex` | Edit | Add Tabulator CDN links |
| `lib/rho/config.ex` | Edit | Register :spreadsheet mount |

## Key Design Decisions

1. **LiveView holds canonical row state** — single source of truth. Both user edits and agent tool calls mutate it, then push diffs to Tabulator.
2. **Tabulator owns the DOM** — LiveView never renders table HTML. All table rendering is JS-side via the hook.
3. **Agent communicates via `send/2` to LiveView pid** — tool execute functions send messages to the LiveView process, which updates assigns and pushes events to Tabulator.
4. **Chat reuses existing components** — no need to rebuild chat UI.
5. **Tabulator from CDN** — no build tooling needed, consistent with existing marked/dompurify pattern.

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Agent tool execution blocks on LiveView process | Use `call` with timeout, or async with `Task` + reply |
| Large table JSON on `get_table` overflows LLM context | Paginate or filter; return summary + subset |
| Tabulator CDN unavailable | Bundle as fallback in priv/static |
| Cell edit conflicts (user + agent edit same cell) | Last-write-wins for MVP; add OT/CRDT later if needed |
