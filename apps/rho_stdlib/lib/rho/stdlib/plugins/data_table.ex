defmodule Rho.Stdlib.Plugins.DataTable do
  @moduledoc """
  Agent-facing data table tools.

  Row state is owned by `Rho.Stdlib.DataTable.Server` — a per-session
  GenServer. Tools in this plugin are thin wrappers around the
  `Rho.Stdlib.DataTable` client API. They do not publish any legacy UI
  signals: the server publishes its own coarse invalidation events
  via `Rho.Events` as `:data_table` events, which the LiveView
  consumes by refetching snapshots.
  """

  @behaviour Rho.Plugin

  alias Rho.Stdlib.DataTable

  @default_table "main"

  # --- Plugin callbacks ---

  @impl Rho.Plugin
  def tools(mount_opts, %{session_id: session_id}) when is_binary(session_id) do
    # Ensure the server exists so tools that read before any write succeed.
    _ = DataTable.ensure_started(session_id)

    all = [
      describe_table_tool(session_id),
      query_table_tool(session_id),
      list_tables_tool(session_id),
      update_cells_tool(session_id),
      edit_row_tool(session_id),
      add_rows_tool(session_id),
      delete_rows_tool(session_id),
      replace_all_tool(session_id)
    ]

    mark_deferred(all, mount_opts)
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Plugin
  def prompt_sections(_mount_opts, %{session_id: sid} = ctx) when is_binary(sid) do
    case DataTable.list_tables(sid) do
      tables when is_list(tables) and tables != [] ->
        active =
          case DataTable.get_active_table(sid) do
            name when is_binary(name) -> name
            _ -> nil
          end

        selections = collect_selections(sid, tables, active)

        [
          %Rho.PromptSection{
            key: :data_table_index,
            heading: "Active data tables",
            body: render_table_index(sid, tables, active, selections, ctx),
            kind: :reference,
            priority: :normal,
            volatile: true
          }
        ]

      _ ->
        []
    end
  end

  def prompt_sections(_mount_opts, _context), do: []

  # Cap detail rendering: only the active table gets full per-row preview.
  # Other tables collapse to `Selected (N)` with no preview, capping the
  # cost of `fetch_preview_rows` at one query per turn.
  @selection_preview_cap 10

  defp collect_selections(sid, tables, active) do
    Enum.reduce(tables, %{}, fn t, acc ->
      case DataTable.get_selection(sid, t.name) do
        ids when is_list(ids) and ids != [] -> Map.put(acc, t.name, {t, ids, t.name == active})
        _ -> acc
      end
    end)
  end

  defp render_table_index(sid, tables, active, selections, ctx) do
    lines =
      Enum.map(tables, fn t ->
        marker = if t.name == active, do: " ← currently open in panel", else: ""
        base = "- #{t.name} (#{t.row_count} rows)#{marker}"
        cols = render_columns_line(t, t.name == active)
        block = render_selection_block(sid, Map.get(selections, t.name), ctx)
        base <> cols <> block
      end)

    """
    #{Enum.join(lines, "\n")}

    Default `table:` argument is "main". When the user refers to "the table"
    or "this row", they mean the table marked "currently open in panel".
    Selected rows above are the user's explicit picks — prefer their IDs
    over locator inference for edits. The `columns:` line lists the exact
    field names — use them verbatim in `update_cells`/`edit_row`; never
    guess from the UI column header.\
    """
  end

  # Show the column names ONLY for the active table — that's the one the
  # agent is most likely to write to, and the one the user is referring to
  # with "this row" / "the table". For other tables the header line
  # remains compact.
  defp render_columns_line(_t, false), do: ""

  defp render_columns_line(%{schema: %Rho.Stdlib.DataTable.Schema{} = schema}, true) do
    base =
      case Rho.Stdlib.DataTable.Schema.column_names(schema) do
        [] -> ""
        cols -> "\n  columns: " <> Enum.map_join(cols, ", ", &Atom.to_string/1)
      end

    base <> render_child_columns_line(schema)
  end

  defp render_columns_line(_, _), do: ""

  defp render_child_columns_line(%Rho.Stdlib.DataTable.Schema{children_key: nil}), do: ""

  defp render_child_columns_line(
         %Rho.Stdlib.DataTable.Schema{
           children_key: key,
           child_key_fields: key_fields
         } = schema
       ) do
    case Rho.Stdlib.DataTable.Schema.child_column_names(schema) do
      [] ->
        ""

      cols ->
        col_str = Enum.map_join(cols, ", ", &Atom.to_string/1)
        key_str = Enum.map_join(key_fields, ", ", &Atom.to_string/1)

        "\n  child columns (#{Atom.to_string(key)}[]): #{col_str}" <>
          "\n  child key: #{key_str} — address one child via " <>
          "child_key={\"#{List.first(key_fields)}\":<value>}"
    end
  end

  defp render_selection_block(_sid, nil, _ctx), do: ""

  defp render_selection_block(sid, {table_summary, ids, active?}, ctx) do
    count = length(ids)

    if not active? do
      # Non-active tables: collapsed count only. Avoids the per-table
      # query cost when the user has selections in multiple tabs.
      if xml?(ctx),
        do: "\n  <selected table=\"#{table_summary.name}\" count=\"#{count}\" />",
        else: "\n  Selected (#{count})"
    else
      shown = Enum.take(ids, @selection_preview_cap)
      rest = count - length(shown)
      rows = fetch_preview_rows(sid, table_summary.name, shown)
      previews = Enum.map(shown, &row_preview(&1, rows, table_summary))
      rest_line = if rest > 0, do: ["    … + #{rest} more selected"], else: []

      if xml?(ctx) do
        inner =
          previews
          |> Enum.map(fn line -> "  " <> line end)
          |> Enum.concat(rest_line)
          |> Enum.join("\n")

        "\n  <selected table=\"#{table_summary.name}\" count=\"#{count}\">\n" <>
          inner <> "\n  </selected>"
      else
        "\n  Selected (#{count}):\n" <>
          Enum.join(previews ++ rest_line, "\n")
      end
    end
  end

  defp xml?(%{prompt_format: :xml}), do: true
  defp xml?(_), do: false

  # Look up the selected rows by id directly, so the preview works even
  # when selections sit past any limit-based window. Returns a
  # `%{id => row}` map for O(1) lookup during render.
  defp fetch_preview_rows(_sid, _table, []), do: %{}

  defp fetch_preview_rows(sid, table, ids) do
    case DataTable.get_rows_by_ids(sid, ids, table: table) do
      {:ok, rows_by_id} -> rows_by_id
      _ -> %{}
    end
  end

  # Full row id, not a slice — agents need to copy these into tool args
  # verbatim. The 10-row cap keeps the section bounded.
  defp row_preview(id, rows, table_summary) do
    row = Map.get(rows, id)
    field_part = key_field_preview(row, table_summary)
    "    - #{id}#{field_part}"
  end

  defp key_field_preview(nil, _), do: ""

  defp key_field_preview(row, %{schema: %Rho.Stdlib.DataTable.Schema{} = schema}) do
    case pick_preview_field(schema, row) do
      nil ->
        ""

      field ->
        case fetch_field(row, field) do
          nil -> ""
          val -> "  " <> Atom.to_string(field) <> "=" <> trim_value(val)
        end
    end
  end

  defp key_field_preview(_, _), do: ""

  defp pick_preview_field(%Rho.Stdlib.DataTable.Schema{key_fields: [first | _]}, _row), do: first

  defp pick_preview_field(%Rho.Stdlib.DataTable.Schema{columns: cols}, _row) do
    case Enum.find(cols, fn col -> col.name not in [:id] end) do
      nil -> nil
      col -> col.name
    end
  end

  defp pick_preview_field(_, _), do: nil

  defp fetch_field(row, field) when is_atom(field) do
    Map.get(row, field) || Map.get(row, Atom.to_string(field))
  end

  defp trim_value(val) when is_binary(val) do
    val
    |> String.replace("\n", " ")
    |> String.slice(0, 60)
    |> Kernel.then(fn s -> "\"" <> s <> "\"" end)
  end

  defp trim_value(val), do: inspect(val, limit: 5, printable_limit: 60)

  defp mark_deferred(tools, mount_opts) do
    case Keyword.get(mount_opts, :deferred) do
      nil ->
        tools

      names when is_list(names) ->
        deferred = MapSet.new(names, &to_string/1)

        Enum.map(tools, fn tool_def ->
          if MapSet.member?(deferred, tool_def.tool.name),
            do: Map.merge(tool_def, %{deferred: true}),
            else: tool_def
        end)
    end
  end

  # --- Tool definitions ---

  defp describe_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "describe_table",
          description: "Data table shape: row count, columns, samples.",
          parameter_schema: [
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table

        case DataTable.summarize_table(session_id, table: table) do
          {:ok, summary} -> {:ok, Jason.encode!(summary)}
          {:error, reason} -> {:error, "describe_table failed: #{inspect(reason)}"}
        end
      end
    }
  end

  defp query_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "query_table",
          description:
            "Read data table rows. Pass `ids_json` (a JSON array of row IDs " <>
              "copied from the prompt's Selected block) to fetch exactly those " <>
              "rows — preferred when acting on the user's selection. Otherwise " <>
              "use filter_field/filter_value for equality search, or no filter " <>
              "to read the whole table (subject to limit).",
          parameter_schema: [
            table: [type: :string, required: false, doc: "default: main"],
            ids_json: [
              type: :string,
              required: false,
              doc:
                ~s(JSON array of row IDs, e.g. ["abc123","def456"]. ) <>
                  "When set, filter_* are ignored."
            ],
            columns: [type: :string, required: false, doc: "comma-separated names"],
            filter_field: [type: :string, required: false],
            filter_value: [type: :string, required: false],
            limit: [type: :string, required: false, doc: "default: 50"],
            offset: [type: :string, required: false, doc: "default: 0"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_query_table(args, session_id)
      end
    }
  end

  defp execute_query_table(args, session_id) do
    table = args[:table] || @default_table
    columns = parse_columns(args)

    schema =
      case DataTable.get_schema(session_id, table) do
        {:ok, s} -> s
        _ -> nil
      end

    case parse_ids(args[:ids_json]) do
      {:ok, ids} when ids != [] ->
        execute_query_by_ids(session_id, table, ids, columns, schema)

      {:error, msg} ->
        {:error, "query_table failed: #{msg}"}

      _ ->
        execute_query_by_filter(args, session_id, table, columns, schema)
    end
  end

  defp execute_query_by_filter(args, session_id, table, columns, schema) do
    filter = parse_filter(args)
    limit = parse_positive_int(args[:limit], 50)
    offset = parse_non_neg_int(args[:offset], 0)

    case DataTable.query_rows(session_id,
           table: table,
           filter: filter,
           columns: columns,
           limit: limit,
           offset: offset
         ) do
      {:ok, result} ->
        result = maybe_elide_complex_columns(result, columns, schema)
        {:ok, Jason.encode!(result)}

      {:error, reason} ->
        {:error, "query_table failed: #{inspect(reason)}"}
    end
  end

  defp execute_query_by_ids(session_id, table, ids, columns, schema) do
    case DataTable.get_rows_by_ids(session_id, ids, table: table) do
      {:ok, rows_by_id} ->
        # Preserve the order the agent supplied so it can correlate rows
        # back to its input list.
        rows = ids |> Enum.map(&Map.get(rows_by_id, &1)) |> Enum.reject(&is_nil/1)
        rows = if columns, do: project_columns(rows, columns), else: rows

        result = %{rows: rows, total: length(rows), offset: 0, limit: length(ids)}
        result = maybe_elide_complex_columns(result, columns, schema)
        {:ok, Jason.encode!(result)}

      {:error, reason} ->
        {:error, "query_table failed: #{inspect(reason)}"}
    end
  end

  # Mirror Table.query_rows' projection so the ids_json path returns the
  # same row shape (id + requested column keys only).
  defp project_columns(rows, columns) do
    Enum.map(rows, fn row ->
      Map.new(columns, fn col ->
        key = resolve_column_key(row, col)
        {col, Map.get(row, key)}
      end)
      |> Map.put("id", Map.get(row, :id) || Map.get(row, "id"))
    end)
  end

  defp resolve_column_key(row, col) when is_binary(col) do
    atom_key =
      try do
        String.to_existing_atom(col)
      rescue
        ArgumentError -> nil
      end

    cond do
      atom_key && map_key?(row, atom_key) -> atom_key
      map_key?(row, col) -> col
      true -> col
    end
  end

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp parse_ids(nil), do: {:ok, []}
  defp parse_ids(""), do: {:ok, []}

  defp parse_ids(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "ids_json must contain only string ids"}
        end

      {:ok, _} ->
        {:error, "ids_json must be a JSON array"}

      {:error, e} ->
        {:error, "ids_json is not valid JSON: #{Exception.message(e)}"}
    end
  end

  defp parse_ids(_), do: {:ok, []}

  # When no explicit column projection is requested, replace complex (list/map)
  # cell values with a compact type descriptor like "<list<5>>". The
  # `children_key` column is exempt — children are addressable by natural key
  # via update_cells/edit_row, so the agent needs to see them to pick which
  # child to edit. Callers that genuinely want other complex fields must
  # ask for them in `columns`.
  defp maybe_elide_complex_columns(%{rows: rows} = result, nil, schema) do
    keep_keys = preserve_keys(schema)
    %{result | rows: Enum.map(rows, &elide_complex_values(&1, keep_keys))}
  end

  defp maybe_elide_complex_columns(result, _columns, _schema), do: result

  defp preserve_keys(%Rho.Stdlib.DataTable.Schema{children_key: key}) when is_atom(key) do
    MapSet.new([key, Atom.to_string(key)])
  end

  defp preserve_keys(_), do: MapSet.new()

  defp elide_complex_values(row, keep_keys) when is_map(row) do
    Map.new(row, fn
      {k, v} ->
        cond do
          MapSet.member?(keep_keys, k) -> {k, v}
          is_list(v) -> {k, "<list<#{length(v)}>>"}
          is_map(v) -> {k, "<map<#{map_size(v)}>>"}
          true -> {k, v}
        end
    end)
  end

  defp parse_filter(args) do
    case {args[:filter_field], args[:filter_value]} do
      {f, v} when is_binary(f) and is_binary(v) -> %{f => v}
      _ -> nil
    end
  end

  defp parse_columns(args) do
    case args[:columns] do
      s when is_binary(s) and s != "" ->
        s |> String.split(",") |> Enum.map(&String.trim/1)

      _ ->
        nil
    end
  end

  defp parse_positive_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp parse_non_neg_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_non_neg_int(_, default), do: default

  defp list_tables_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "list_tables",
          description: "List data tables with row counts.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args, _ctx ->
        case DataTable.list_tables(session_id) do
          list when is_list(list) ->
            result =
              Enum.map(list, fn entry ->
                %{
                  name: entry.name,
                  row_count: entry.row_count,
                  version: entry.version
                }
              end)

            {:ok, Jason.encode!(result)}

          {:error, reason} ->
            {:error, "list_tables failed: #{inspect(reason)}"}
        end
      end
    }
  end

  defp update_cells_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "update_cells",
          description:
            "Update data table cells. Each change is a JSON object: " <>
              ~s({"id": "<row_id>", "field": "<col>", "value": <new>}) <>
              " for a top-level cell, or " <>
              ~s({"id": "<row_id>", "child_key": {"<key>": <val>}, ) <>
              ~s("field": "<child_col>", "value": <new>}) <>
              " for a nested child (a row in the parent's children list, " <>
              "addressed by natural key — e.g. child_key={\"level\": 3}). " <>
              "Field names must match the schema; unknown fields error.",
          parameter_schema: [
            changes_json: [
              type: :string,
              required: true,
              doc:
                ~s(JSON array of change objects, e.g. [{"id":"abc","field":"skill_name","value":"Python"}, ) <>
                  ~s({"id":"abc","child_key":{"level":3},"field":"level_description","value":"..."}])
            ],
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table
        changes_raw = args[:changes_json] || "[]"

        case Jason.decode(changes_raw) do
          {:ok, changes} when is_list(changes) ->
            case DataTable.update_cells(session_id, changes, table: table) do
              :ok -> {:ok, "Updated #{length(changes)} cell(s)"}
              {:error, reason} -> {:error, "update_cells failed: #{inspect(reason)}"}
            end

          {:ok, _other} ->
            {:error, "changes_json must be a JSON array of change objects"}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, "changes_json is not valid JSON: #{Exception.message(err)}"}
        end
      end
    }
  end

  defp edit_row_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "edit_row",
          description:
            "Edit one row by a natural locator. Prefer the flat string params " <>
              "(match_field/match_value, set_field/set_value) — they avoid JSON " <>
              "encoding entirely. Use match_json/set_json only for multi-field " <>
              "locators or updates. To edit a nested child cell (e.g. one " <>
              "proficiency level), add child_match_field + child_match_value " <>
              "(or child_match_json); set_field/set_value then apply to that " <>
              "child. Errors if 0 or >1 rows or children match.",
          parameter_schema: [
            table: [type: :string, required: false, doc: "default: main"],
            match_field: [
              type: :string,
              required: false,
              doc: "Field name for single-field locator, e.g. \"skill_name\""
            ],
            match_value: [
              type: :string,
              required: false,
              doc: "Value for single-field locator, e.g. \"Python\""
            ],
            set_field: [
              type: :string,
              required: false,
              doc: "Field name for single-field update, e.g. \"skill_description\""
            ],
            set_value: [
              type: :string,
              required: false,
              doc: "New value for single-field update"
            ],
            match_json: [
              type: :string,
              required: false,
              doc:
                ~s(Multi-field locator as JSON object. Used only when match_field is empty. ) <>
                  ~s(Must be valid JSON with double-quoted keys/strings, e.g. {"category":"Tech","skill_name":"Python"})
            ],
            set_json: [
              type: :string,
              required: false,
              doc:
                ~s(Multi-field update as JSON object. Used only when set_field is empty. ) <>
                  ~s(Must be valid JSON, e.g. {"description":"...", "level":3})
            ],
            child_match_field: [
              type: :string,
              required: false,
              doc:
                "Child key field, e.g. \"level\". Required (with child_match_value) " <>
                  "to edit a nested child instead of the parent row."
            ],
            child_match_value: [
              type: :string,
              required: false,
              doc: "Child key value, e.g. \"3\"."
            ],
            child_match_json: [
              type: :string,
              required: false,
              doc:
                ~s(Multi-field child locator as JSON object, e.g. {"level":3}. ) <>
                  ~s(Used only when child_match_field is empty.)
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_edit_row(args, session_id)
      end
    }
  end

  defp execute_edit_row(args, session_id) do
    table = args[:table] || @default_table

    with {:ok, match} <- resolve_match(args),
         {:ok, child_match} <- resolve_child_match(args),
         {:ok, set} <- resolve_set(args),
         {:ok, %{rows: rows}} <-
           DataTable.query_rows(session_id, table: table, filter: match, limit: 2) do
      apply_edit_row(session_id, table, match, child_match, set, rows)
    end
  end

  # Flat path wins when both match_field and match_value are present.
  defp resolve_match(args) do
    case {args[:match_field], args[:match_value]} do
      {f, v} when is_binary(f) and f != "" and is_binary(v) ->
        {:ok, %{f => v}}

      _ ->
        case decode_object(args[:match_json], "match_json") do
          {:ok, m} ->
            validate_nonempty(m, "match_json") |> wrap_with(m)

          {:error, "match_json is required"} ->
            {:error, "edit_row: provide match_field+match_value (preferred) or match_json"}

          err ->
            err
        end
    end
  end

  defp resolve_set(args) do
    case {args[:set_field], args[:set_value]} do
      {f, v} when is_binary(f) and f != "" and is_binary(v) ->
        {:ok, %{f => v}}

      _ ->
        case decode_object(args[:set_json], "set_json") do
          {:ok, m} ->
            validate_nonempty(m, "set_json") |> wrap_with(m)

          {:error, "set_json is required"} ->
            {:error, "edit_row: provide set_field+set_value (preferred) or set_json"}

          err ->
            err
        end
    end
  end

  # Returns {:ok, nil} when no child locator is provided (edits target the
  # parent row). Returns {:ok, %{...}} when a child locator is present, or
  # {:error, msg} when the locator is malformed.
  defp resolve_child_match(args) do
    flat_field = args[:child_match_field]
    flat_value = args[:child_match_value]
    json = args[:child_match_json]

    cond do
      is_binary(flat_field) and flat_field != "" and is_binary(flat_value) ->
        {:ok, %{flat_field => flat_value}}

      is_binary(json) and json != "" ->
        case decode_object(json, "child_match_json") do
          {:ok, m} -> validate_nonempty(m, "child_match_json") |> wrap_with(m)
          err -> err
        end

      true ->
        {:ok, nil}
    end
  end

  defp wrap_with(:ok, value), do: {:ok, value}
  defp wrap_with({:error, _} = err, _value), do: err

  defp apply_edit_row(_sid, table, match, _child_match, _set, []) do
    {:error, "edit_row: no rows in #{inspect(table)} match #{inspect(match)}"}
  end

  defp apply_edit_row(_sid, _table, _match, _child_match, _set, [_, _ | _] = rows) do
    {:error,
     "edit_row: locator is ambiguous — #{length(rows)} rows match. Use a more " <>
       "specific match, or call update_cells with explicit ids."}
  end

  defp apply_edit_row(sid, table, _match, child_match, set, [row]) do
    id = row_id(row)
    changes = build_edit_changes(id, child_match, set)

    case DataTable.update_cells(sid, changes, table: table) do
      :ok ->
        target_label = if child_match, do: " child #{Jason.encode!(child_match)}", else: ""
        {:ok, "Updated row #{id}#{target_label} in #{table}: #{Jason.encode!(set)}"}

      {:error, reason} ->
        {:error, "edit_row failed: #{inspect(reason)}"}
    end
  end

  defp build_edit_changes(id, nil, set) do
    Enum.map(set, fn {field, value} ->
      %{"id" => id, "field" => field, "value" => value}
    end)
  end

  defp build_edit_changes(id, child_match, set) when is_map(child_match) do
    Enum.map(set, fn {field, value} ->
      %{"id" => id, "child_key" => child_match, "field" => field, "value" => value}
    end)
  end

  defp row_id(%{id: id}) when is_binary(id), do: id
  defp row_id(%{"id" => id}) when is_binary(id), do: id
  defp row_id(row), do: to_string(Map.get(row, :id) || Map.get(row, "id") || "")

  defp decode_object(nil, name), do: {:error, "#{name} is required"}
  defp decode_object("", name), do: {:error, "#{name} is required"}

  defp decode_object(s, name) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, _} -> {:error, "#{name} must be a JSON object"}
      {:error, e} -> {:error, "#{name} is not valid JSON: #{Exception.message(e)}"}
    end
  end

  defp decode_object(_, name), do: {:error, "#{name} must be a JSON string"}

  defp validate_nonempty(m, _) when is_map(m) and map_size(m) > 0, do: :ok
  defp validate_nonempty(_, name), do: {:error, "#{name} must be a non-empty object"}

  defp add_rows_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "add_rows",
          description: "Add rows to data table.",
          parameter_schema: [
            rows_json: [type: :string, required: true, doc: "JSON row array"],
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table
        rows_raw = args[:rows_json] || "[]"

        case Jason.decode(rows_raw) do
          {:ok, []} ->
            {:error, "rows_json was an empty array — nothing to add"}

          {:ok, rows} when is_list(rows) ->
            case DataTable.add_rows(session_id, rows, table: table) do
              {:ok, inserted} -> {:ok, "Added #{length(inserted)} row(s)"}
              {:error, reason} -> {:error, "add_rows failed: #{format_table_error(reason)}"}
            end

          {:ok, _other} ->
            {:error, "rows_json must be a JSON array of row objects"}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, "rows_json is not valid JSON: #{Exception.message(err)}"}
        end
      end
    }
  end

  defp format_table_error({:unknown_fields, fields, meta}) when is_list(meta) do
    allowed = Keyword.get(meta, :allowed, [])
    required = Keyword.get(meta, :required, [])

    "unknown field(s): #{join_fields(fields)}. " <>
      "Allowed fields: #{Enum.join(allowed, ", ")}. " <>
      "Required fields: #{Enum.join(required, ", ")}."
  end

  defp format_table_error({:missing_required, fields, meta}) when is_list(meta) do
    allowed = Keyword.get(meta, :allowed, [])

    "missing required field(s): #{join_fields(fields)}. " <>
      "Allowed fields: #{Enum.join(allowed, ", ")}."
  end

  defp format_table_error(reason), do: inspect(reason)

  defp join_fields(fields) do
    fields |> List.wrap() |> Enum.map_join(", ", &to_string/1)
  end

  defp delete_rows_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "delete_rows",
          description: "Delete data table rows by ID or filter.",
          parameter_schema: [
            ids_json: [type: :string, doc: "JSON array of row IDs"],
            filter_json: [type: :string, doc: "JSON filter object"],
            table: [type: :string, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_delete_rows(args, session_id)
      end
    }
  end

  defp execute_delete_rows(args, session_id) do
    table = args[:table] || @default_table

    cond do
      args[:ids_json] ->
        delete_by_ids(session_id, args[:ids_json], table)

      args[:filter_json] ->
        delete_by_filter(session_id, args[:filter_json], table)

      true ->
        {:error, "Provide ids_json or filter_json"}
    end
  end

  defp delete_by_ids(session_id, ids_json, table) do
    case Jason.decode(ids_json) do
      {:ok, ids} when is_list(ids) ->
        ids = Enum.map(ids, &to_string/1)

        case DataTable.delete_rows(session_id, ids, table: table) do
          :ok -> {:ok, "Deleted #{length(ids)} row(s)"}
          {:error, reason} -> {:error, "delete_rows failed: #{inspect(reason)}"}
        end

      _ ->
        {:error, "ids_json must be a JSON array"}
    end
  end

  defp delete_by_filter(session_id, filter_json, table) do
    case Jason.decode(filter_json) do
      {:ok, filter} when is_map(filter) and filter != %{} ->
        case DataTable.delete_by_filter(session_id, filter, table: table) do
          {:ok, count} -> {:ok, "Deleted #{count} row(s) by filter"}
          {:error, reason} -> {:error, "delete_by_filter failed: #{inspect(reason)}"}
        end

      _ ->
        {:error, "filter_json must be a non-empty JSON object"}
    end
  end

  defp replace_all_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "replace_all",
          description: "Replace all data table rows.",
          parameter_schema: [
            rows_json: [type: :string, required: true, doc: "JSON row array"],
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table
        rows_raw = args[:rows_json] || "[]"

        case Jason.decode(rows_raw) do
          {:ok, rows} when is_list(rows) ->
            case DataTable.replace_all(session_id, rows, table: table) do
              {:ok, inserted} -> {:ok, "Replaced table with #{length(inserted)} row(s)"}
              {:error, reason} -> {:error, "replace_all failed: #{inspect(reason)}"}
            end

          {:ok, _other} ->
            {:error, "rows_json must be a JSON array of row objects"}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, "rows_json is not valid JSON: #{Exception.message(err)}"}
        end
      end
    }
  end
end
