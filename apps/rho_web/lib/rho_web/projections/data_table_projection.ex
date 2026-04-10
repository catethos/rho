defmodule RhoWeb.Projections.DataTableProjection do
  @moduledoc """
  Pure reducer that transforms data table signals into plain map state.

  Operates entirely on plain maps — no `Socket.t()` dependency.
  State shape: `%{rows_map: %{}, next_id: integer(), partial_streamed: %{}, known_fields: [String.t()]}`.

  Known fields are configured at init time via a `DataTable.Schema`, making
  this projection generic across any table shape.
  """

  @behaviour RhoWeb.Projection

  alias RhoWeb.DataTable.Schema

  @default_known_fields ~w(id sort_order category cluster skill_name skill_description level level_name level_description proficiency_levels)

  # Suffixes this projection handles
  @handled_suffixes ~w(
    data_table_rows_delta
    data_table_replace_all
    data_table_update_cells
    data_table_delete_rows
    data_table_user_edit
    data_table_schema_change
    structured_partial
  )

  @impl true
  def handles?(type) when is_binary(type) do
    suffix = type |> String.split(".") |> List.last()
    suffix in @handled_suffixes
  end

  @impl true
  def init do
    init(nil)
  end

  @doc "Initialize with an optional `DataTable.Schema` to configure known fields."
  def init(%Schema{} = schema) do
    %{
      rows_map: %{},
      next_id: 1,
      partial_streamed: %{},
      pending_ops: MapSet.new(),
      cell_timestamps: %{},
      known_fields: Schema.known_field_names(schema),
      schema: schema,
      mode_label: nil
    }
  end

  def init(_) do
    %{
      rows_map: %{},
      next_id: 1,
      partial_streamed: %{},
      pending_ops: MapSet.new(),
      cell_timestamps: %{},
      known_fields: @default_known_fields,
      schema: nil,
      mode_label: nil
    }
  end

  @impl true
  def reduce(nil, signal), do: reduce(init(), signal)

  def reduce(state, %{type: type, data: data} = signal) do
    suffix = type |> String.split(".") |> List.last()

    case suffix do
      "data_table_rows_delta" -> reduce_rows_delta(state, data)
      "data_table_replace_all" -> reduce_replace_all(state)
      "data_table_update_cells" -> reduce_update_cells(state, data)
      "data_table_delete_rows" -> reduce_delete_rows(state, data)
      "data_table_user_edit" -> reduce_user_edit(state, data, signal)
      "data_table_schema_change" -> reduce_schema_change(state, data)
      "structured_partial" -> reduce_structured_partial(state, data)
      _ -> state
    end
  end

  @doc """
  Apply an optimistic user edit locally and record the client_op_id as pending.
  Returns the updated state. The pending op will be cleared when the confirmed
  signal arrives via `reduce_user_edit`.
  """
  def apply_optimistic_edit(state, row_id, field_atom, value, client_op_id) do
    case Map.get(state.rows_map, row_id) do
      nil ->
        state

      row ->
        updated_row = Map.put(row, field_atom, value)

        %{
          state
          | rows_map: Map.put(state.rows_map, row_id, updated_row),
            pending_ops: MapSet.put(state.pending_ops, client_op_id)
        }
    end
  end

  @doc """
  Apply an optimistic edit to a child entry within a parent row's nested list.
  """
  def apply_optimistic_child_edit(
        state,
        parent_id,
        child_index,
        field_atom,
        value,
        children_key,
        client_op_id
      ) do
    case Map.get(state.rows_map, parent_id) do
      nil ->
        state

      row ->
        children = Map.get(row, children_key) || []

        updated_children =
          List.update_at(children, child_index, fn child ->
            child
            |> Map.put(field_atom, value)
            |> Map.put(Atom.to_string(field_atom), value)
          end)

        updated_row = Map.put(row, children_key, updated_children)

        %{
          state
          | rows_map: Map.put(state.rows_map, parent_id, updated_row),
            pending_ops: MapSet.put(state.pending_ops, client_op_id)
        }
    end
  end

  # --- Reducers ---

  defp reduce_rows_delta(state, data) do
    new_rows = data[:rows] || data["rows"] || []
    known = state.known_fields
    new_rows = Enum.map(new_rows, &atomize_keys(&1, known))

    agent_id = data[:agent_id] || data["agent_id"]
    already = Map.get(state.partial_streamed, agent_id, 0)

    if already > 0 and length(new_rows) <= already do
      new_partial = Map.put(state.partial_streamed, agent_id, already - length(new_rows))
      %{state | partial_streamed: new_partial}
    else
      to_skip = min(already, length(new_rows))
      remaining = Enum.drop(new_rows, to_skip)
      {rows, next_id} = assign_ids(remaining, state.next_id)

      rows_map = Enum.reduce(rows, state.rows_map, fn r, m -> Map.put(m, r[:id], r) end)

      new_partial =
        if already > 0,
          do: Map.delete(state.partial_streamed, agent_id),
          else: state.partial_streamed

      %{state | rows_map: rows_map, next_id: next_id, partial_streamed: new_partial}
    end
  end

  defp reduce_replace_all(state) do
    %{
      state
      | rows_map: %{},
        next_id: 1,
        partial_streamed: %{},
        pending_ops: MapSet.new(),
        cell_timestamps: %{}
    }
  end

  defp reduce_schema_change(state, data) do
    schema = data[:schema] || data["schema"]
    schema_key = data[:schema_key] || data["schema_key"]
    mode_label = data[:mode_label] || data["mode_label"]

    resolved =
      case schema do
        %Schema{} = s -> s
        _ -> resolve_schema_key(schema_key)
      end

    case resolved do
      %Schema{} = s ->
        %{state | schema: s, mode_label: mode_label, known_fields: Schema.known_field_names(s)}

      nil ->
        if mode_label, do: %{state | mode_label: mode_label}, else: state
    end
  end

  defp resolve_schema_key(:skill_library), do: RhoWeb.DataTable.Schemas.skill_library()
  defp resolve_schema_key(:role_profile), do: RhoWeb.DataTable.Schemas.role_profile()
  defp resolve_schema_key("skill_library"), do: RhoWeb.DataTable.Schemas.skill_library()
  defp resolve_schema_key("role_profile"), do: RhoWeb.DataTable.Schemas.role_profile()
  defp resolve_schema_key(_), do: nil

  defp reduce_update_cells(state, data) do
    changes = data[:changes] || data["changes"] || []
    rows_map = apply_cell_changes_to_map(state.rows_map, changes)
    %{state | rows_map: rows_map}
  end

  defp reduce_delete_rows(state, data) do
    ids = data[:ids] || data["ids"] || []
    rows_map = Map.drop(state.rows_map, ids)
    %{state | rows_map: rows_map}
  end

  defp reduce_user_edit(state, data, signal) do
    client_op_id = data[:client_op_id] || data["client_op_id"]

    # If this is a confirmed echo of our own optimistic op, deduplicate
    if client_op_id && MapSet.member?(state.pending_ops, client_op_id) do
      %{state | pending_ops: MapSet.delete(state.pending_ops, client_op_id)}
    else
      # Remote edit — apply with last-write-wins at cell level
      row_id = data[:row_id] || data["row_id"]
      field = data[:field] || data["field"]
      value = data[:value] || data["value"]
      emitted_at = get_in(signal, [:meta, :emitted_at]) || 0
      known = state.known_fields

      field_atom =
        if is_binary(field) and field in known,
          do: String.to_existing_atom(field),
          else: field

      case Map.get(state.rows_map, row_id) do
        nil ->
          state

        row ->
          cell_ts_key = {row_id, field_atom}
          cell_timestamps = Map.get(state, :cell_timestamps, %{})
          existing_ts = Map.get(cell_timestamps, cell_ts_key, 0)

          if emitted_at >= existing_ts do
            updated_row = Map.put(row, field_atom, value)
            cell_timestamps = Map.put(cell_timestamps, cell_ts_key, emitted_at)

            %{
              state
              | rows_map: Map.put(state.rows_map, row_id, updated_row),
                cell_timestamps: cell_timestamps
            }
          else
            state
          end
      end
    end
  end

  defp reduce_structured_partial(state, data) do
    parsed = data[:parsed] || data["parsed"]
    agent_id = data[:agent_id] || data["agent_id"]

    case parsed do
      %{"action" => "add_rows", "action_input" => %{"rows_json" => partial_json}}
      when is_binary(partial_json) ->
        stream_partial_rows(state, partial_json, agent_id)

      %{"action" => "replace_all", "action_input" => %{"rows_json" => partial_json}}
      when is_binary(partial_json) ->
        stream_partial_rows(state, partial_json, agent_id)

      _ ->
        state
    end
  end

  defp stream_partial_rows(state, partial_json, agent_id) do
    known = state.known_fields

    case extract_complete_rows(partial_json) do
      rows when is_list(rows) and rows != [] ->
        already_streamed = Map.get(state.partial_streamed, agent_id, 0)
        new_count = length(rows)

        if new_count > already_streamed do
          new_rows =
            rows
            |> Enum.drop(already_streamed)
            |> Enum.map(&atomize_keys(&1, known))

          {id_rows, next_id} = assign_ids(new_rows, state.next_id)

          rows_map =
            Enum.reduce(id_rows, state.rows_map, fn r, m -> Map.put(m, r.id, r) end)

          new_partial = Map.put(state.partial_streamed, agent_id, new_count)

          %{state | rows_map: rows_map, next_id: next_id, partial_streamed: new_partial}
        else
          state
        end

      _ ->
        state
    end
  end

  # --- JSON extraction helpers ---

  @doc false
  def extract_complete_rows(partial_json) do
    trimmed = String.trim(partial_json)

    case Jason.decode(trimmed) do
      {:ok, rows} when is_list(rows) ->
        rows

      _ ->
        extract_complete_objects(trimmed)
    end
  end

  defp extract_complete_objects(text) do
    inner =
      case text do
        "[" <> rest -> rest
        other -> other
      end

    do_extract_objects(inner, 0, "", [])
  end

  defp do_extract_objects("", _depth, _acc, found), do: Enum.reverse(found)

  defp do_extract_objects(<<"{", rest::binary>>, 0, _acc, found) do
    do_extract_objects(rest, 1, "{", found)
  end

  defp do_extract_objects(<<"{", rest::binary>>, depth, acc, found) when depth > 0 do
    do_extract_objects(rest, depth + 1, acc <> "{", found)
  end

  defp do_extract_objects(<<"}", rest::binary>>, 1, acc, found) do
    obj_str = acc <> "}"

    case Jason.decode(obj_str) do
      {:ok, obj} when is_map(obj) ->
        do_extract_objects(rest, 0, "", [obj | found])

      _ ->
        do_extract_objects(rest, 0, "", found)
    end
  end

  defp do_extract_objects(<<"}", rest::binary>>, depth, acc, found) when depth > 1 do
    do_extract_objects(rest, depth - 1, acc <> "}", found)
  end

  defp do_extract_objects(<<"\"", rest::binary>>, depth, acc, found) when depth > 0 do
    {string_content, remaining} = skip_json_string(rest, "")
    do_extract_objects(remaining, depth, acc <> "\"" <> string_content <> "\"", found)
  end

  defp do_extract_objects(<<c, rest::binary>>, depth, acc, found) when depth > 0 do
    do_extract_objects(rest, depth, acc <> <<c>>, found)
  end

  defp do_extract_objects(<<_c, rest::binary>>, 0, acc, found) do
    do_extract_objects(rest, 0, acc, found)
  end

  defp skip_json_string("", acc), do: {acc, ""}

  defp skip_json_string(<<"\\", c, rest::binary>>, acc),
    do: skip_json_string(rest, acc <> "\\" <> <<c>>)

  defp skip_json_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp skip_json_string(<<c, rest::binary>>, acc), do: skip_json_string(rest, acc <> <<c>>)

  # --- Row helpers ---

  @doc false
  def atomize_keys(row, known_fields) when is_map(row) do
    Map.new(row, fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        if k in known_fields, do: {String.to_existing_atom(k), v}, else: {k, v}
    end)
  end

  @doc false
  def assign_ids(rows, start_id) do
    Enum.map_reduce(rows, start_id, fn row, id ->
      # Prefer stable row_id from publisher; fall back to auto-increment
      stable_id = row[:row_id] || row["row_id"]

      if stable_id do
        row =
          row
          |> Map.put(:id, stable_id)
          |> Map.put(:sort_order, id)
          |> Map.delete(:row_id)
          |> Map.delete("row_id")

        {row, id + 1}
      else
        {row |> Map.put(:id, id) |> Map.put(:sort_order, id), id + 1}
      end
    end)
  end

  @doc false
  def filter_rows(rows, nil), do: rows
  def filter_rows(rows, filter) when filter == %{}, do: rows

  def filter_rows(rows, filter) when is_map(filter) do
    Enum.filter(rows, fn row ->
      Enum.all?(filter, fn {k, v} ->
        key = if is_binary(k), do: String.to_existing_atom(k), else: k
        row_val = Map.get(row, key)
        values_match?(row_val, v)
      end)
    end)
  end

  defp values_match?(a, b) when a == b, do: true

  defp values_match?(a, b) when is_integer(a) and is_binary(b) do
    case Integer.parse(b) do
      {n, ""} -> a == n
      _ -> false
    end
  end

  defp values_match?(a, b) when is_binary(a) and is_integer(b) do
    case Integer.parse(a) do
      {n, ""} -> n == b
      _ -> false
    end
  end

  defp values_match?(_, _), do: false

  @doc false
  def apply_cell_changes_to_map(rows_map, changes) do
    Enum.reduce(changes, rows_map, fn change, map ->
      id = change["id"]
      field = String.to_existing_atom(change["field"])
      value = change["value"]

      case Map.get(map, id) do
        nil -> map
        row -> Map.put(map, id, Map.put(row, field, value))
      end
    end)
  end
end
