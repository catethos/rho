# Plan: Row Selection in DataTable + Selection-Aware Agent

## Goal

Let the user **select one or more rows** in any DataTable panel and have
the agent see those selections so it can edit them surgically by ID,
without having to infer a locator from natural language.

This is a complement to `edit_row` (the locator-driven path), not a
replacement: locator-driven is faster when the user types a request;
selection-driven is precise when the user wants surgical multi-row
edits or when the rows have no obvious key.

Mirrors the architecture of the active-table plan: state lives in
`Rho.Stdlib.DataTable.Server`, the LiveView publishes events, a small
listener bridges PubSub → server, and the DataTable plugin's
`prompt_sections/2` exposes the state to the agent.

---

## Part 1 — Selection state model

### 1.1 Per-table selection in `DataTable.Server`

Selection is per-table. Switching tabs preserves each table's selection
(matches user expectation: select things in `library:Foo`, peek at
`library:Bar`, switch back, selection still there).

State change in `apps/rho_stdlib/lib/rho/stdlib/data_table/server.ex`:

```elixir
state = %{
  session_id: session_id,
  tables: %{"main" => main},
  table_order: ["main"],
  active_table: nil,
  selections: %{}   # NEW — %{table_name => MapSet.t(row_id)}
}
```

### 1.2 Server handlers

```elixir
def handle_call({:set_selection, name, ids}, _from, state)
    when is_binary(name) and is_list(ids) do
  case Map.fetch(state.tables, name) do
    {:ok, table} ->
      pruned = prune_selection(MapSet.new(ids), table)
      new_state = %{state | selections: Map.put(state.selections, name, pruned)}

      publish(
        state.session_id,
        %{event: :selection_changed, table_name: name, count: MapSet.size(pruned)},
        :user
      )

      {:reply, :ok, new_state}

    :error ->
      {:reply, {:error, :not_found}, state}
  end
end

def handle_call({:get_selection, name}, _from, state) do
  set = Map.get(state.selections, name, MapSet.new())
  {:reply, MapSet.to_list(set), state}
end

def handle_call({:clear_selection, name}, _from, state) do
  {:reply, :ok, %{state | selections: Map.delete(state.selections, name)}}
end
```

Where `prune_selection/2` drops IDs that no longer exist in the table —
defends against stale selection after deletes:

```elixir
defp prune_selection(ids, %Table{rows_by_id: rows_by_id}) do
  MapSet.filter(ids, &Map.has_key?(rows_by_id, &1))
end
```

### 1.3 Auto-prune on row mutations

`with_table/4` (the helper that wraps every mutation) gains a step that
prunes the selection after the table updates:

```elixir
defp with_table(state, name, source, fun) do
  case Map.fetch(state.tables, name) do
    :error -> ...
    {:ok, table} ->
      case fun.(table) do
        {:ok, updated_table, reply} ->
          new_tables = Map.put(state.tables, name, updated_table)
          new_selections = maybe_prune_selection(state.selections, name, updated_table)
          new_state = %{state | tables: new_tables, selections: new_selections}
          ...
      end
  end
end

defp maybe_prune_selection(selections, name, table) do
  case Map.fetch(selections, name) do
    :error -> selections
    {:ok, ids} -> Map.put(selections, name, prune_selection(ids, table))
  end
end
```

Drop-table and replace-all also clear/prune.

### 1.4 Client API in `apps/rho_stdlib/lib/rho/stdlib/data_table.ex`

```elixir
@spec set_selection(session_id(), table_name(), [String.t()]) ::
        :ok | {:error, term()}
def set_selection(session_id, name, ids) when is_list(ids) do
  call(session_id, {:set_selection, name, ids})
end

@spec get_selection(session_id(), table_name()) :: [String.t()] | {:error, term()}
def get_selection(session_id, name) do
  case call(session_id, {:get_selection, name}) do
    list when is_list(list) -> list
    other -> other
  end
end

@spec clear_selection(session_id(), table_name()) :: :ok | {:error, term()}
def clear_selection(session_id, name) do
  call(session_id, {:clear_selection, name})
end
```

---

## Part 2 — UI: checkbox column + selection bar

### 2.1 Checkbox column in `RhoWeb.DataTableComponent`

- File: `apps/rho_web/lib/rho_web/components/data_table_component.ex`
- Add a sticky leftmost column rendering a checkbox per row.
- Header checkbox toggles select-all for the *currently visible* rows
  (post-filter, post-stream-page). Indeterminate state when partial.
- Row click on the checkbox cell dispatches `phx-click="toggle_row"`
  with `phx-value-row-id`. (Body click does NOT toggle — too easy to
  mis-tap.)
- Cmd/Ctrl-click on the row body extends the selection (optional v2).

Component reads the selection from a new assign `selected_ids` (a
MapSet), passed in by the workspace's `component_assigns/2`.

### 2.2 Selection bar

Above the table, when `MapSet.size(selected_ids) > 0`:

```
3 rows selected   [Clear]
```

Renders as a small pill. The `Clear` button sends
`{:data_table_clear_selection, table_name}` to the LV.

### 2.3 Visual treatment

- Selected rows get `bg-blue-50` (or the equivalent in the design
  system).
- Subtle left-border accent (`border-l-2 border-blue-500`) for
  scanning down a long table.

### 2.4 Component events

```elixir
def handle_event("toggle_row", %{"row-id" => id}, socket) do
  send(self(), {:data_table_toggle_row, socket.assigns.table_name, id})
  {:noreply, socket}
end

def handle_event("toggle_all", _params, socket) do
  visible_ids = current_visible_row_ids(socket)
  send(self(), {:data_table_toggle_all, socket.assigns.table_name, visible_ids})
  {:noreply, socket}
end

def handle_event("clear_selection", _params, socket) do
  send(self(), {:data_table_clear_selection, socket.assigns.table_name})
  {:noreply, socket}
end
```

---

## Part 3 — LiveView state + event publishing

### 3.1 Workspace state

`apps/rho_web/lib/rho_web/projections/data_table_projection.ex`
gains a `selections` field:

```elixir
%{
  active_table: ...,
  ...,
  selections: %{}   # %{table_name => MapSet.t()}
}
```

### 3.2 LV handlers in `apps/rho_web/lib/rho_web/live/app_live.ex`

```elixir
def handle_info({:data_table_toggle_row, table, id}, socket) do
  state = read_dt_state(socket)
  current = Map.get(state.selections, table, MapSet.new())

  new_set =
    if MapSet.member?(current, id),
      do: MapSet.delete(current, id),
      else: MapSet.put(current, id)

  socket = update_selection(socket, state, table, new_set)
  {:noreply, socket}
end

def handle_info({:data_table_toggle_all, table, visible_ids}, socket) do
  state = read_dt_state(socket)
  current = Map.get(state.selections, table, MapSet.new())
  visible = MapSet.new(visible_ids)
  all_selected? = MapSet.subset?(visible, current)

  new_set =
    if all_selected?,
      do: MapSet.difference(current, visible),
      else: MapSet.union(current, visible)

  socket = update_selection(socket, state, table, new_set)
  {:noreply, socket}
end

def handle_info({:data_table_clear_selection, table}, socket) do
  state = read_dt_state(socket)
  socket = update_selection(socket, state, table, MapSet.new())
  {:noreply, socket}
end

defp update_selection(socket, state, table, new_set) do
  sid = socket.assigns.session_id

  publish_row_selection(sid, table, MapSet.to_list(new_set))

  new_state = %{state | selections: Map.put(state.selections, table, new_set)}
  SignalRouter.write_ws_state(socket, :data_table, new_state)
end
```

### 3.3 New event kind: `:row_selection`

- File: `apps/rho/lib/rho/events/event.ex`
- Document under "View / panel events":

> `:row_selection` — `%{table_name: String.t(), row_ids: [String.t()]}`.
> Emitted by the LiveView whenever the user changes which rows are
> selected in a DataTable panel. Consumed by
> `Rho.Stdlib.DataTable.ActiveViewListener` and forwarded into
> `DataTable.set_selection/3`.

### 3.4 Helper

```elixir
defp publish_row_selection(nil, _table, _ids), do: :ok
defp publish_row_selection(_sid, nil, _ids), do: :ok

defp publish_row_selection(sid, table, ids)
     when is_binary(sid) and is_binary(table) and is_list(ids) do
  event = %Rho.Events.Event{
    kind: :row_selection,
    session_id: sid,
    agent_id: nil,
    timestamp: System.monotonic_time(:millisecond),
    data: %{table_name: table, row_ids: ids},
    source: :user
  }

  Rho.Events.broadcast(sid, event)
  :ok
end
```

Mirror in `session_live.ex` if we want the legacy path to work (unused
in production, but tests touch it).

---

## Part 4 — Bridge: extend `ActiveViewListener`

We already have a listener that subscribes to session topics on
`:agent_started`. Extend it (don't add a second listener) to also
forward `:row_selection`:

- File: `apps/rho_stdlib/lib/rho/stdlib/data_table/active_view_listener.ex`

```elixir
def handle_info(
      %Event{
        kind: :row_selection,
        session_id: sid,
        data: %{table_name: name, row_ids: ids}
      },
      state
    )
    when is_binary(sid) and is_binary(name) and is_list(ids) do
  _ = DataTable.set_selection(sid, name, ids)
  {:noreply, state}
end
```

Rename the module to `Rho.Stdlib.DataTable.ViewListener` if "ActiveView"
feels narrow; otherwise leave it — the moduledoc will explain that it
handles both focus and selection. (Recommendation: keep the name; one
listener per concern is fine even when the concern broadens.)

---

## Part 5 — Agent prompt section

### 5.1 Render selection in the existing `:data_table_index` section

Extend `render_table_index/2` in
`apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex` to show
selected rows under the table line they belong to:

```
- main (12 rows)
- library:Healthcare (47 rows) ← currently open in panel
  Selected (3):
    - b27dd80d…  skill_name="Diagnostic Interpretation"
    - 8a4e1f02…  skill_name="Clinical Reasoning"
    - 3c9d04bb…  skill_name="Pattern Recognition"

Default `table:` argument is "main". When the user refers to "the table"
or "this row", they mean the table marked "currently open in panel".
Selected rows above are the user's explicit picks — prefer their IDs
over locator inference for edits.
```

### 5.2 Token-budget rules

- Cap at 10 rows per table; render `… + N more selected` if the count
  is larger.
- Per-row preview = `id (8 chars) + first key field (skill_name, name,
  title, …) trimmed to 60 chars`.
- Pick the preview field by checking the table's schema:
  `schema.key_fields |> hd()` if present, else first non-id column.
- If the agent is configured with `prompt_format: :xml`, emit each
  selection block as `<selected table="..." count="...">…</selected>`
  rather than the markdown bullet form.

### 5.3 Implementation sketch

```elixir
defp render_table_line(t, active, selections) do
  base = "- #{t.name} (#{t.row_count} rows)"
  marker = if t.name == active, do: " ← currently open in panel", else: ""

  selection_block =
    case Map.get(selections, t.name) do
      nil -> ""
      [] -> ""
      ids -> render_selection_block(t, ids)
    end

  base <> marker <> selection_block
end

defp render_selection_block(table_summary, ids) do
  shown = Enum.take(ids, 10)
  rest = length(ids) - length(shown)

  rows = fetch_preview_rows(table_summary, shown)

  preview_lines =
    Enum.map(rows, fn row ->
      "    - #{short_id(row.id)}  #{key_field_preview(row, table_summary)}"
    end)

  rest_line = if rest > 0, do: ["    … + #{rest} more selected"], else: []

  "\n  Selected (#{length(ids)}):\n" <>
    Enum.join(preview_lines ++ rest_line, "\n")
end
```

`fetch_preview_rows/2` is one extra `DataTable.query_rows` call per
table with selections — acceptable cost (this is per-turn, not
per-token).

---

## Part 6 — Agent system prompt nudge

`.rho.exs` `spreadsheet` agent — replace the "Editing tables" block:

```text
Editing tables:
  - The "Active data tables" section lists every table. The one marked
    "currently open in panel" is what the user sees.
  - **Selected rows are explicit user picks.** When the user says "these"
    or "the highlighted rows", use those exact IDs with `update_cells` —
    do not re-resolve via locator.
  - For a single-field edit by locator (no selection): use `edit_row`
    with flat string params (`match_field`, `match_value`, `set_field`,
    `set_value`).
  - For batch edits across many known IDs: `update_cells`.
  - For destructive replaces: `replace_all`.
```

The nudge "do not re-resolve via locator" is critical — without it,
small models default to `edit_row` even when the IDs are right there.

---

## Part 7 — Out of scope (deliberately deferred)

- **`edit_selected` convenience tool** — fans a single patch out to all
  selected rows. Skip for v1; let the agent compose `update_cells`
  changes from the prompt section. Add only if observation shows the
  agent struggling to fan out.
- **Range select (Shift-click)** — useful but not load-bearing; the
  checkbox click + select-all header covers the common cases.
- **Cross-table selection** — selections are scoped per-table.
- **Persisted selection** across page reloads — selection is ephemeral.
  If valuable later, store in the LV's saved-state plumbing alongside
  `active_table`.
- **Selection-aware delete** (`delete_selected`) — same reasoning as
  `edit_selected`. Defer.
- **Server-side selection size cap.** A user could select 10k rows.
  Prompt-section rendering already truncates to 10 visible + count;
  the IDs themselves still live in the MapSet but cost is small.

---

## Implementation order

Each step independently reviewable / mergeable.

1. **Server state + client API** (Part 1)
   - Add `selections` field, `:set_selection` / `:get_selection` /
     `:clear_selection` handlers, prune-on-mutate.
   - Tests: round-trip, prune after delete_rows, prune after
     replace_all, returns `[]` for unknown table.

2. **`:row_selection` event + LiveView publishing** (Parts 3.1 — 3.4)
   - Add `selections` to `DataTableProjection` init.
   - Wire `handle_info` for toggle_row / toggle_all / clear.
   - Publish `:row_selection` on each change.
   - Manually verify with `Rho.Events.subscribe/1` in IEx + clicking
     a checkbox.

3. **Listener extension** (Part 4)
   - Add `:row_selection` clause to `ActiveViewListener.handle_info/2`.
   - Test: broadcast → assert `DataTable.get_selection/2` reflects it.

4. **DataTableComponent UI** (Parts 2.1 — 2.4)
   - Checkbox column, selection bar, visual treatment.
   - Workspace `component_assigns/2` injects `selected_ids`.
   - Manual: select 3 rows, confirm bar shows "3 rows selected", clear
     button works.

5. **Plugin prompt section update** (Parts 5.1 — 5.3)
   - Extend `render_table_index/2` to show selection block.
   - Tests: with mocked selections, rendered body contains the IDs and
     truncates correctly past the 10-row cap.

6. **Agent system prompt update** (Part 6)
   - One-line edits in `.rho.exs`.
   - Smoke test: with 2 rows selected, ask "rename these to X and Y" →
     expect a single `update_cells` call carrying both IDs (no
     `edit_row` call).

---

## Testing checklist

- [ ] `mix test --app rho_stdlib` passes after each step.
- [ ] `mix test --app rho_web` passes (no regression in the existing
      DataTable component tests).
- [ ] Manual: open a library, click two row checkboxes → selection bar
      shows "2 rows selected"; clear button empties it.
- [ ] Manual: select 3 rows, switch to a different tab, switch back —
      selections still there.
- [ ] Manual: select a row, then delete that row via the agent →
      selection bar count goes to 0 (auto-prune).
- [ ] Manual: select 12 rows, peek the next agent prompt (via
      `mix rho.trace` or a debug log) — selection block lists 10 +
      "… + 2 more selected".
- [ ] Manual: ask the agent "rename the highlighted skills to ..."
      with 3 rows selected → exactly one `update_cells` call with all 3
      IDs in its `changes_json` payload.

---

## Files touched (summary)

| File | Change |
|------|--------|
| `apps/rho_stdlib/lib/rho/stdlib/data_table/server.ex` | Add `selections` state + handlers + prune helpers |
| `apps/rho_stdlib/lib/rho/stdlib/data_table.ex` | Add `set_selection/3`, `get_selection/2`, `clear_selection/2` |
| `apps/rho_stdlib/lib/rho/stdlib/data_table/active_view_listener.ex` | New `:row_selection` clause |
| `apps/rho/lib/rho/events/event.ex` | Document `:row_selection` kind |
| `apps/rho_web/lib/rho_web/projections/data_table_projection.ex` | Add `selections: %{}` to init |
| `apps/rho_web/lib/rho_web/live/app_live.ex` | toggle_row / toggle_all / clear handlers + `publish_row_selection/3` |
| `apps/rho_web/lib/rho_web/live/session_live.ex` | Same handlers (legacy path) |
| `apps/rho_web/lib/rho_web/components/data_table_component.ex` | Checkbox column + select-all header + selection bar + events |
| `apps/rho_web/lib/rho_web/workspaces/data_table.ex` | Inject `selected_ids` into `component_assigns/2` |
| `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex` | Extend `prompt_sections/2` to render selection blocks |
| `.rho.exs` | Update spreadsheet agent's "Editing tables" guidance |
| `CLAUDE.md` | Note the new public API in `Rho.Stdlib.DataTable` entry-points list |

---

## Risks / open questions

- **Selection on a re-rendered stream** — `data_table_component`
  uses LV streams for large tables. After a `replace_all` the stream is
  re-keyed; the checkboxes need to re-read selection from
  `selected_ids` rather than carrying their own state. Confirm during
  Part 2.

- **Render cost of `fetch_preview_rows`** — one query per table per
  turn. Acceptable for 1-3 selected tables; pathological if every named
  table has selections AND large preview field strings. Cap by
  showing only the *active* table's selection in detail; other tables
  collapse to `Selected (N)` with no preview.

- **What if the user selects, then the agent edits, and the edit
  changes the row's key field?** Selection survives (we key on row id,
  not field value). Verify in tests after Part 1.

- **Should the server publish a `:selection_changed` event?** Yes, for
  symmetry with `:table_changed` — but only the server's own tools and
  future workspace mirrors need it. The LV doesn't (it's the source).
  Easy to add later.
