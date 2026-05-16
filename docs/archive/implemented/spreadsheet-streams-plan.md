# Replace Tabulator.js with LiveView Streams

## Overview

Replace the Tabulator.js-based spreadsheet with a plain HTML table powered by LiveView streams.
Each `rows_delta` signal (5 rows) renders immediately via `stream_insert` — no push_event, no JS
hook coordination, no batching queues.

## Files to Change

| File | Action |
|------|--------|
| `lib/rho_web/live/spreadsheet_live.ex` | **Rewrite** — streams, HTML table, inline editing |
| `lib/rho_web/inline_js.ex` | **Edit** — remove Spreadsheet hook, add AutoFocus hook |
| `lib/rho_web/inline_css.ex` | **Edit** — replace Tabulator CSS with HTML table styles |
| `lib/rho_web/components/layouts/root.html.heex` | **Edit** — remove Tabulator CDN includes |
| `lib/rho/mounts/spreadsheet.ex` | **No changes** — signal bus publishing stays as-is |

## 1. SpreadsheetLive (`spreadsheet_live.ex`)

### Mount changes

Replace flat `assign(:rows, [])` with:

```elixir
socket
|> stream(:rows, [])              # LiveView stream — no data in assigns
|> assign(:rows_map, %{})         # Canonical state for get_table reads
|> assign(:next_id, 1)
|> assign(:editing, nil)          # {row_id, field} or nil
```

Remove: `@columns`, `row_stream_queue`, `push_event("table_init", ...)`.

### Signal handlers

Each handler updates `rows_map` (canonical state) and calls `stream_insert`/`stream_delete`
(UI). No more `push_event`.

```elixir
defp handle_rows_delta(socket, data) do
  new_rows = data[:rows] || []
  {rows, next_id} = assign_ids(new_rows, socket.assigns.next_id)

  rows_map = Enum.reduce(rows, socket.assigns.rows_map, fn r, m -> Map.put(m, r.id, r) end)

  socket
  |> assign(:rows_map, rows_map)
  |> assign(:next_id, next_id)
  |> stream(:rows, rows, at: -1)  # Append — triggers DOM insert for each row
end

defp handle_replace_all(socket) do
  socket
  |> assign(:rows_map, %{})
  |> assign(:next_id, 1)
  |> stream(:rows, [], reset: true)
end

defp handle_update_cells(socket, data) do
  changes = data[:changes] || []
  rows_map = apply_cell_changes_to_map(socket.assigns.rows_map, changes)
  changed_rows = get_changed_rows(rows_map, changes)

  socket = assign(socket, :rows_map, rows_map)
  Enum.reduce(changed_rows, socket, fn row, s -> stream_insert(s, :rows, row) end)
end

defp handle_delete_rows(socket, data) do
  ids = data[:ids] || []
  rows_map = Map.drop(socket.assigns.rows_map, ids)

  socket = assign(socket, :rows_map, rows_map)
  Enum.reduce(ids, socket, fn id, s ->
    stream_delete(s, :rows, %{id: id})
  end)
end
```

### get_table reads from rows_map

```elixir
def handle_info({:spreadsheet_get_table, {caller_pid, ref}, filter}, socket) do
  rows = socket.assigns.rows_map |> Map.values() |> filter_rows(filter)
  send(caller_pid, {ref, {:ok, rows}})
  {:noreply, socket}
end
```

### Inline editing

Three events replace Tabulator's built-in editors:

```elixir
def handle_event("start_edit", %{"id" => id, "field" => field}, socket) do
  {:noreply, assign(socket, :editing, {String.to_integer(id), field})}
end

def handle_event("save_edit", %{"id" => id, "field" => field, "value" => value}, socket) do
  row_id = String.to_integer(id)
  field_atom = String.to_existing_atom(field)
  rows_map = Map.update!(socket.assigns.rows_map, row_id, &Map.put(&1, field_atom, value))
  row = rows_map[row_id]

  socket =
    socket
    |> assign(:rows_map, rows_map)
    |> assign(:editing, nil)
    |> stream_insert(:rows, row)

  {:noreply, socket}
end

def handle_event("cancel_edit", _params, socket) do
  {:noreply, assign(socket, :editing, nil)}
end
```

### Render template

Replace the `phx-update="ignore"` Tabulator div with a streamed HTML table:

```heex
<div class="spreadsheet-panel">
  <div class="spreadsheet-toolbar">
    <h2 class="spreadsheet-title">Skill Framework Editor</h2>
    <span class="ss-row-count"><%= map_size(@rows_map) %> rows</span>
  </div>

  <div class="ss-table-wrap">
    <table class="ss-table">
      <thead>
        <tr>
          <th class="ss-th ss-th-id">ID</th>
          <th class="ss-th ss-th-cat">Category</th>
          <th class="ss-th ss-th-cluster">Cluster</th>
          <th class="ss-th ss-th-skill">Skill</th>
          <th class="ss-th ss-th-desc">Description</th>
          <th class="ss-th ss-th-lvl">Lvl</th>
          <th class="ss-th ss-th-lvlname">Level Name</th>
          <th class="ss-th ss-th-lvldesc">Level Description</th>
        </tr>
      </thead>
      <tbody id="spreadsheet-rows" phx-update="stream">
        <tr :for={{dom_id, row} <- @streams.rows} id={dom_id} class="ss-row ss-row-new">
          <td class="ss-td ss-td-id"><%= row.id %></td>
          <.editable_cell row={row} field={:category} editing={@editing} />
          <.editable_cell row={row} field={:cluster} editing={@editing} />
          <.editable_cell row={row} field={:skill_name} editing={@editing} />
          <.editable_cell row={row} field={:skill_description} editing={@editing} type="textarea" />
          <.editable_cell row={row} field={:level} editing={@editing} type="number" />
          <.editable_cell row={row} field={:level_name} editing={@editing} />
          <.editable_cell row={row} field={:level_description} editing={@editing} type="textarea" />
        </tr>
      </tbody>
    </table>
  </div>
</div>
```

### editable_cell component

```elixir
defp editable_cell(assigns) do
  editing? = assigns.editing == {assigns.row.id, Atom.to_string(assigns.field)}
  value = Map.get(assigns.row, assigns.field, "")
  type = Map.get(assigns, :type, "input")

  assigns = assign(assigns, editing?: editing?, value: value, input_type: type)

  ~H"""
  <td
    class={"ss-td ss-td-#{@field}"}
    phx-click="start_edit"
    phx-value-id={@row.id}
    phx-value-field={@field}
  >
    <%= if @editing? do %>
      <form phx-submit="save_edit" phx-click-away="cancel_edit">
        <input type="hidden" name="id" value={@row.id} />
        <input type="hidden" name="field" value={@field} />
        <%= if @input_type == "textarea" do %>
          <textarea
            name="value"
            class="ss-cell-input"
            phx-hook="AutoFocus"
            id={"edit-#{@row.id}-#{@field}"}
            phx-keydown="cancel_edit"
            phx-key="Escape"
          ><%= @value %></textarea>
        <% else %>
          <input
            type={if @input_type == "number", do: "number", else: "text"}
            name="value"
            value={@value}
            class="ss-cell-input"
            phx-hook="AutoFocus"
            id={"edit-#{@row.id}-#{@field}"}
            phx-blur="save_edit"
            phx-value-id={@row.id}
            phx-value-field={@field}
            phx-keydown="cancel_edit"
            phx-key="Escape"
          />
        <% end %>
      </form>
    <% else %>
      <span class="ss-cell-text"><%= @value %></span>
    <% end %>
  </td>
  """
end
```

## 2. Inline JS (`inline_js.ex`)

### Remove
- The entire `Spreadsheet` hook (lines 128-228)

### Add

```javascript
AutoFocus: {
  mounted() {
    this.el.focus();
    if (this.el.select) this.el.select();
  }
}
```

(The existing `AutoResize` hook stays for the chat textarea.)

## 3. Inline CSS (`inline_css.ex`)

### Remove
- All Tabulator-related CSS (the `.tabulator` blocks, `row-stream-in` animation)

### Add

```css
/* Spreadsheet table */
.ss-table-wrap {
  flex: 1;
  overflow: auto;
  position: relative;
}
.ss-table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  font-size: 13px;
}
.ss-th {
  position: sticky;
  top: 0;
  background: var(--bg-secondary, #1a1a2e);
  color: var(--text-secondary, #a0a0b0);
  padding: 8px 10px;
  text-align: left;
  font-weight: 600;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border-bottom: 1px solid var(--border-color, #2a2a3e);
  z-index: 1;
}
/* Column widths */
.ss-th-id, .ss-td-id { width: 50px; }
.ss-th-cat, .ss-td-category { width: 120px; }
.ss-th-cluster, .ss-td-cluster { width: 120px; }
.ss-th-skill, .ss-td-skill_name { width: 160px; }
.ss-th-desc, .ss-td-skill_description { width: 200px; }
.ss-th-lvl, .ss-td-level { width: 40px; text-align: center; }
.ss-th-lvlname, .ss-td-level_name { width: 100px; }
.ss-th-lvldesc, .ss-td-level_description { width: auto; }

.ss-row {
  border-bottom: 1px solid var(--border-color, #1a1a2e);
  transition: background 0.15s;
}
.ss-row:hover {
  background: var(--bg-hover, rgba(255,255,255,0.03));
}
.ss-td {
  padding: 6px 10px;
  color: var(--text-primary, #e0e0e8);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
  vertical-align: top;
}
.ss-td-skill_description,
.ss-td-level_description {
  white-space: normal;
  max-height: 60px;
  overflow: hidden;
}

/* Streaming animation — new rows flash on insert */
@keyframes ss-flash {
  from { background: rgba(99, 102, 241, 0.2); }
  to   { background: transparent; }
}
.ss-row-new {
  animation: ss-flash 0.8s ease-out;
}

/* Inline editing */
.ss-cell-input {
  width: 100%;
  background: var(--bg-input, #0f0f1a);
  color: var(--text-primary, #e0e0e8);
  border: 1px solid var(--accent, #6366f1);
  border-radius: 3px;
  padding: 4px 6px;
  font: inherit;
  outline: none;
}
textarea.ss-cell-input {
  min-height: 60px;
  resize: vertical;
}

/* Empty state */
.ss-empty {
  text-align: center;
  padding: 40px;
  color: var(--text-secondary, #a0a0b0);
}
```

## 4. Root layout (`root.html.heex`)

Remove lines loading Tabulator CSS/JS from CDN:
```html
<!-- REMOVE these -->
<link href="https://unpkg.com/tabulator-tables@6.3.1/dist/css/tabulator_midnight.min.css" rel="stylesheet">
<script type="text/javascript" src="https://unpkg.com/tabulator-tables@6.3.1/dist/js/tabulator.min.js"></script>
```

## 5. No changes needed

- `lib/rho/mounts/spreadsheet.ex` — signal bus publishing stays as-is
- `lib/rho_web/live/session_projection.ex` — no changes
- `lib/rho/agent/worker.ex` — no changes

## Why This Works for Streaming

```
Signal: spreadsheet_rows_delta (5 rows)
  → handle_rows_delta
    → stream(:rows, batch, at: -1)
      → LiveView diffs only the 5 new <tr> elements
        → Browser inserts 5 rows, triggers ss-flash animation
        → Next signal arrives, repeat

Total: 100 rows = 20 signals = 20 small DOM patches over ~200ms
```

Each `stream_insert` produces an independent DOM patch sent over the WebSocket.
The browser renders between patches because they're separate messages — no batching
queue or tick timer needed.

## Editing + Streaming Race Condition

Safe by design: `stream_insert` of *new* rows (different IDs) does not re-render
*existing* rows. If the user is editing row 5 while rows 50-55 stream in, the editing
cell is untouched. Only `stream_insert` of row 5 itself (on save_edit) re-renders it.

## Migration Order

1. Remove Tabulator CDN from root layout
2. Remove Spreadsheet hook from inline_js.ex, add AutoFocus
3. Replace spreadsheet CSS in inline_css.ex
4. Rewrite spreadsheet_live.ex (mount, handlers, render, editing)
5. Test manually — generate skills, verify streaming + editing
