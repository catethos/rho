# Plan: Active-Table Awareness + `edit_row` Tool

## Goal

When a user opens a library / role-profile / any named DataTable in the left
panel, the chat agent should:

1. **Know** which table is currently visible and roughly what's in it
   (without having to spend a tool call to discover it).
2. **Edit a single row** with one tool call given a natural locator
   ("the Python skill", "row where category=Tech"), without juggling
   row IDs in JSON-encoded strings.

This combines:

- **Active-table prompt section** (DataTable plugin gains `prompt_sections/2`)
  fed by a new "current view" signal published by the LiveView.
- **`edit_row` tool** that resolves a `match` locator to a single row id
  and applies a `set` patch in one round trip.
- **Sharpened agent system prompt** that documents the new tool and the
  active-table convention.

---

## Part 1 — Active-table awareness

### 1.1 New event kind: `:view_focus`

Add a new event `kind` representing "the user is now looking at table X".
Distinct from the existing `:view_change` (which is *agent-emitted* via
`EffectDispatcher` — see `apps/rho_stdlib/lib/rho/stdlib/effect_dispatcher.ex:53-59`)
because the source here is the **user** clicking a tab.

- File: `apps/rho/lib/rho/events/event.ex`
- Add to the `@kind` documentation a new entry:
  - `:view_focus` — `%{table_name: String.t(), schema_key: atom() | nil, row_count: non_neg_integer()}`
- No struct change required (`kind` is already `atom()`).

### 1.2 LiveView publishes `:view_focus` when the user switches tabs

The LiveView already maintains `state.active_table`
(`apps/rho_web/lib/rho_web/live/app_live.ex:2521`). On every transition that
is **user-driven** (not effect-driven), broadcast a `:view_focus` event on
the session topic.

- File: `apps/rho_web/lib/rho_web/live/app_live.ex`
- Locate every place that mutates `state.active_table` (lines ~2521, ~3401,
  ~3421-3423, ~3432-3433, ~3655, ~3697-3706).
- Tag the source: only emit `:view_focus` when the change came from a user
  click (`handle_event` on a tab button) or from initial mount — NOT when
  it's the EffectDispatcher's auto-switch (which already publishes
  `:view_change` for downstream consumers).
- Implementation sketch:

  ```elixir
  defp publish_view_focus(state, session_id, table_name) do
    snapshot = Rho.Stdlib.DataTable.summarize_table(session_id, table: table_name)

    payload = %{
      table_name: table_name,
      schema_key: get_in(snapshot, [:elem, 1, :schema_key]),
      row_count: get_in(snapshot, [:elem, 1, :row_count]) || 0
    }

    event = %Rho.Events.Event{
      kind: :view_focus,
      session_id: session_id,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      data: payload,
      source: :user
    }

    Rho.Events.broadcast(session_id, event)
    state
  end
  ```

### 1.3 Per-session `ActiveView` cache

We need a place the DataTable plugin can read from synchronously when
`prompt_sections/2` runs. Options:

- **(Chosen) Reuse the DataTable Server.** Add an `:active_table` field
  to `Rho.Stdlib.DataTable.Server` state and a `set_active_table/2` /
  `get_active_table/1` API. The Server already exists per session and is
  the natural owner of "which tables exist + which one is focused".
- Alternatives considered: a new `ActiveViewRegistry` (extra moving part);
  pure pubsub + plugin-local agent (plugins shouldn't hold long-lived
  state).

Changes:

- File: `apps/rho_stdlib/lib/rho/stdlib/data_table/server.ex`
  - Add `active_table: nil` to state struct.
  - Add `handle_call({:set_active_table, name}, _, state)` and
    `handle_call(:get_active_table, _, state)`.
- File: `apps/rho_stdlib/lib/rho/stdlib/data_table.ex`
  - Add `set_active_table(session_id, name)` and `get_active_table(session_id)`
    client functions (mirroring the existing pattern at lines ~52, ~188).
  - Both return `{:error, :not_running}` when no server, matching the rest
    of the module's contract.

### 1.4 Bridge: a SessionJanitor-style listener

A tiny GenServer subscribes to session topics and forwards `:view_focus`
events into `DataTable.set_active_table/2`. Avoid coupling the LiveView
to the DataTable Server directly.

- File: `apps/rho_stdlib/lib/rho/stdlib/data_table/active_view_listener.ex` (new)
- Behaviour:
  - On `Rho.Events` lifecycle event `:agent_started`, call
    `Rho.Events.subscribe(session_id)`.
  - On `:view_focus` events, call `DataTable.set_active_table(session_id,
    payload.table_name)`.
  - On `:agent_stopped`, unsubscribe.
- Add to `Rho.Stdlib.Application` supervision tree alongside
  `SessionJanitor`.

### 1.5 DataTable plugin: emit `prompt_sections/2`

- File: `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex`
- Add `@impl Rho.Plugin def prompt_sections(_mount_opts, %{session_id: sid})`:

  ```elixir
  def prompt_sections(_mount_opts, %{session_id: sid}) when is_binary(sid) do
    alias Rho.PromptSection

    tables = DataTable.list_tables(sid)
    active = DataTable.get_active_table(sid)

    cond do
      not is_list(tables) or tables == [] ->
        []

      true ->
        body = render_table_index(tables, active)
        [%PromptSection{
          key: :data_table_index,
          heading: "Active data tables",
          body: body,
          kind: :context,
          priority: :normal
        }]
    end
  end

  def prompt_sections(_mount_opts, _ctx), do: []

  defp render_table_index(tables, active) do
    lines =
      Enum.map(tables, fn t ->
        marker = if t.name == active, do: " ← currently open in panel", else: ""
        "- #{t.name} (#{t.row_count} rows)#{marker}"
      end)

    """
    #{Enum.join(lines, "\n")}

    Default `table:` argument is "main". When the user refers to "the table"
    or "this row", they mean the table marked "currently open in panel".
    Pass that name as `table:` on edit/query tools.
    """
  end
  ```

- Token cost: ~5 tokens per table + ~50 tokens of static guidance. With
  2-4 tables typical, well under 100 tokens/turn.

---

## Part 2 — `edit_row` convenience tool

### 2.1 Tool surface

Add to `Rho.Stdlib.Plugins.DataTable` (`apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex`):

```elixir
defp edit_row_tool(session_id) do
  %{
    tool:
      ReqLLM.tool(
        name: "edit_row",
        description:
          "Edit one row by a natural locator. Resolves `match` to a single " <>
          "row id and applies `set`. Errors loudly if 0 or >1 rows match.",
        parameter_schema: [
          table: [type: :string, required: false, doc: "default: main"],
          match_json: [
            type: :string,
            required: true,
            doc: ~s(JSON object of {field: value} pairs that uniquely identify the row, e.g. {"skill_name":"Python"})
          ],
          set_json: [
            type: :string,
            required: true,
            doc: ~s(JSON object of {field: new_value} updates, e.g. {"skill_description":"..."})
          ]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args, _ctx ->
      execute_edit_row(args, session_id)
    end
  }
end
```

Register it in the `tools/2` list at line 26-34.

### 2.2 Execution semantics

```elixir
defp execute_edit_row(args, session_id) do
  table = args[:table] || @default_table

  with {:ok, match} <- decode_object(args[:match_json], "match_json"),
       {:ok, set} <- decode_object(args[:set_json], "set_json"),
       :ok <- validate_nonempty(match, "match_json"),
       :ok <- validate_nonempty(set, "set_json"),
       {:ok, %{rows: rows}} <- DataTable.query_rows(session_id, table: table, filter: match, limit: 2) do
    case rows do
      [] ->
        {:error, "edit_row: no rows in #{inspect(table)} match #{inspect(match)}"}

      [_, _ | _] ->
        {:error, "edit_row: locator is ambiguous — #{length(rows)} rows match. Use a more specific match or use update_cells with explicit ids."}

      [%{"id" => id} = row] ->
        changes =
          Enum.map(set, fn {field, value} -> %{"id" => id, "field" => field, "value" => value} end)

        case DataTable.update_cells(session_id, changes, table: table) do
          :ok ->
            preview = Map.take(row, ["id" | Map.keys(set)])
            {:ok, "Updated row #{id} in #{table}: #{Jason.encode!(Map.merge(preview, set))}"}

          {:error, reason} ->
            {:error, "edit_row failed: #{inspect(reason)}"}
        end
    end
  end
end

defp decode_object(nil, name), do: {:error, "#{name} is required"}
defp decode_object(s, name) do
  case Jason.decode(s) do
    {:ok, m} when is_map(m) -> {:ok, m}
    {:ok, _} -> {:error, "#{name} must be a JSON object"}
    {:error, e} -> {:error, "#{name} is not valid JSON: #{Exception.message(e)}"}
  end
end

defp validate_nonempty(m, _) when map_size(m) > 0, do: :ok
defp validate_nonempty(_, name), do: {:error, "#{name} must be a non-empty object"}
```

### 2.3 Why match-then-update inside one tool

- Saves one LLM round trip versus `query_table` → `update_cells`.
- Centralizes the "ambiguous match" failure mode — `update_cells` today
  silently accepts whatever id the model passes. With `edit_row`, ambiguity
  is a hard error message the model can recover from.
- Keeps `update_cells` as the escape hatch for explicit-id batch edits and
  for cases where the model already knows the id from a prior `query_table`.

---

## Part 3 — Agent system prompt updates

Tighten the chat agent's system prompt to document the new conventions.

- Files to update (whichever `.rho.exs` configs are in active use):
  - `/Users/catethos/workspace/rho/.rho.exs` (root, `default` and `spreadsheet` agents — confirm during implementation)
  - Any other agent that loads the `:data_table` plugin.

- Add a section like:

  ```
  ## Editing tables

  - The "Active data tables" prompt section lists every table in this
    session. The one marked "currently open in panel" is what the user
    sees. When the user says "this row" or "the table", assume that one.
  - To edit a single row, call `edit_row(table: "<name>",
    match_json: <locator>, set_json: <patch>)`. Use the most specific
    locator you can; ambiguous matches will fail.
  - For multi-cell or batch edits where you already know row ids, call
    `update_cells` directly.
  - For destructive replaces, prefer `replace_all`.
  ```

- Remove any existing prompt language that lists tools — the auto-generated
  schema already covers that (see `CLAUDE.md` Prompt token budget rule #1).

---

## Implementation order

Each step is independently reviewable / mergeable.

1. **Server + client API for active table** (Part 1.3)
   - Add `active_table` field, `set_active_table/2`, `get_active_table/1`.
   - Tests: round-trip via `DataTable.set_active_table` → `get_active_table`.

2. **`:view_focus` event kind + LiveView emission** (Parts 1.1, 1.2)
   - Document the new kind in `event.ex`.
   - Wire user-tab-switch handlers to call `publish_view_focus/3`.
   - Manually verify by subscribing in IEx and clicking tabs in the UI.

3. **`ActiveViewListener` GenServer** (Part 1.4)
   - Subscribe on `:agent_started`, call `set_active_table` on
     `:view_focus`, unsubscribe on `:agent_stopped`.
   - Add to `Rho.Stdlib.Application` supervision tree.
   - Test: simulate broadcast → assert server state changes.

4. **DataTable plugin `prompt_sections/2`** (Part 1.5)
   - Test: with mocked `list_tables` + `get_active_table`, assert the
     rendered body contains the marker line for the active table.
   - Visually inspect a real prompt with `Mix.Tasks.Rho.Trace` to confirm
     the body is sane.

5. **`edit_row` tool** (Part 2)
   - Unit test all four branches: no match, single match, multi match,
     update failure.
   - Integration test against a populated `library:test` table.

6. **System prompt updates** (Part 3)
   - One-line edits in `.rho.exs` files.
   - Smoke-test by asking the chat agent: "change the description of the
     Python skill to 'a snake'" and confirm one `edit_row` call lands.

---

## Testing checklist

- [ ] `mix test --app rho_stdlib` passes after each step.
- [ ] `mix test --app rho` passes (no regression in event semantics).
- [ ] Manual: open library in panel → ask chat agent "what tables do you
      see?" → response should name the active library without a
      `list_tables` tool call.
- [ ] Manual: ask "change the description of <skill_name> to X" → exactly
      one `edit_row` call → table updates in the panel.
- [ ] Manual: ask "delete the Python skill" with two Python skills present
      → `edit_row` (or its sibling `delete_row` if added later) should
      surface the ambiguity rather than guess.

---

## Files touched (summary)

| File | Change |
|------|--------|
| `apps/rho/lib/rho/events/event.ex` | Document `:view_focus` kind |
| `apps/rho_web/lib/rho_web/live/app_live.ex` | Publish `:view_focus` on user tab switches |
| `apps/rho_stdlib/lib/rho/stdlib/data_table/server.ex` | Add `active_table` field + handlers |
| `apps/rho_stdlib/lib/rho/stdlib/data_table.ex` | Add `set_active_table/2`, `get_active_table/1` |
| `apps/rho_stdlib/lib/rho/stdlib/data_table/active_view_listener.ex` | NEW — bridge from `:view_focus` to server |
| `apps/rho_stdlib/lib/rho/stdlib/application.ex` | Supervise the listener |
| `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex` | Add `prompt_sections/2` + `edit_row_tool/1` |
| `.rho.exs` (and any other agent configs) | Document `edit_row` + active-table convention in `system_prompt` |

---

## Out of scope (future work)

- **Effect-based row edits with visual highlight** (Option D from the
  prior discussion). Land after this plan if the basic flow works.
- **Propose-then-apply confirmation UX** (Option C). Layer on later for
  destructive operations.
- **Optimistic concurrency** between the LV's inline editor and agent
  edits. Today both last-write-wins; revisit if collisions show up.
- **Active-table memory across sessions.** `active_table` is per-server,
  per-session — fine for chat, but if we ever persist the panel state
  between page reloads, this needs to come from the LV's saved state.
