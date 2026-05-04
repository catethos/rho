defmodule Rho.Stdlib.DataTable.Table do
  @moduledoc """
  Pure data struct for a single named data table.

  Holds rows keyed by server-generated row id, an explicit row order, a
  monotonic version counter, and the schema that validates writes.
  """

  alias Rho.Stdlib.DataTable.Schema

  defstruct name: "main",
            schema: nil,
            rows_by_id: %{},
            row_order: [],
            version: 0

  @type row :: map()

  @type t :: %__MODULE__{
          name: String.t(),
          schema: Schema.t(),
          rows_by_id: %{String.t() => row()},
          row_order: [String.t()],
          version: non_neg_integer()
        }

  @doc "Build an empty table with the given name and schema."
  def new(name, %Schema{} = schema) when is_binary(name) do
    %__MODULE__{name: name, schema: schema}
  end

  @doc "Row count."
  def row_count(%__MODULE__{row_order: ids}), do: length(ids)

  @doc "Return rows in declared order."
  def rows(%__MODULE__{rows_by_id: map, row_order: order}) do
    Enum.map(order, &Map.fetch!(map, &1))
  end

  @doc """
  Append new rows. Each row is validated against the table's schema and
  assigned a fresh id (or keeps its existing id if one is supplied under
  the key `:id` or `"id"`).

  Returns `{:ok, updated_table, inserted_rows}` or `{:error, reason}`.
  """
  def add_rows(%__MODULE__{} = table, rows, id_fun)
      when is_list(rows) and is_function(id_fun, 0) do
    Enum.reduce_while(rows, {:ok, table, []}, fn raw_row, {:ok, acc_table, acc_inserted} ->
      case normalize_and_id(raw_row, acc_table.schema, id_fun) do
        {:ok, id, row} ->
          insert_if_unique(acc_table, acc_inserted, id, row)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, updated, inserted} ->
        {:ok, bump_version(updated), Enum.reverse(inserted)}

      err ->
        err
    end
  end

  @doc "Replace all rows with the given list. Same validation as `add_rows/3`."
  def replace_all(%__MODULE__{} = table, rows, id_fun) when is_list(rows) do
    cleared = %{table | rows_by_id: %{}, row_order: []}
    add_rows(cleared, rows, id_fun)
  end

  @doc """
  Update cells. `changes` is a list of maps with `id`, `field`, `value` keys.

  Cells on top-level rows OR nested children (addressed by `"id:child:idx"`)
  are supported.
  """
  def update_cells(%__MODULE__{} = table, changes) when is_list(changes) do
    Enum.reduce_while(changes, {:ok, table}, fn change, {:ok, acc} ->
      apply_change(acc, change)
    end)
    |> case do
      {:ok, updated} -> {:ok, bump_version(updated)}
      err -> err
    end
  end

  @doc "Delete rows by a list of ids."
  def delete_rows(%__MODULE__{} = table, ids) when is_list(ids) do
    id_set = MapSet.new(ids, &to_string/1)

    updated = %{
      table
      | rows_by_id: Map.drop(table.rows_by_id, Enum.to_list(id_set)),
        row_order: Enum.reject(table.row_order, &MapSet.member?(id_set, &1))
    }

    {:ok, bump_version(updated)}
  end

  @doc """
  Delete rows by filter. `filter` is a map of `field => value` matched
  literally against each row.
  """
  def delete_by_filter(%__MODULE__{} = table, filter) when is_map(filter) do
    to_delete =
      table.row_order
      |> Enum.filter(fn id ->
        row = Map.fetch!(table.rows_by_id, id)
        match_filter?(row, filter)
      end)

    delete_rows(table, to_delete)
    |> case do
      {:ok, updated} -> {:ok, updated, length(to_delete)}
      err -> err
    end
  end

  @doc "Filter rows by a map of field/value pairs (does not mutate the table)."
  def filter_rows(%__MODULE__{} = table, nil), do: rows(table)
  def filter_rows(%__MODULE__{} = table, filter) when filter == %{}, do: rows(table)

  def filter_rows(%__MODULE__{} = table, filter) when is_map(filter) do
    Enum.filter(rows(table), &match_filter?(&1, filter))
  end

  @doc """
  Look up rows by id. Returns a `%{id => row}` map containing only ids
  that exist in the table. O(length(ids)).
  """
  def rows_by_ids(%__MODULE__{rows_by_id: map}, ids) when is_list(ids) do
    Map.take(map, Enum.map(ids, &to_string/1))
  end

  @doc """
  Query rows with optional filter, column projection, limit, and offset.

  Options:
    * `:filter` — map of field/value equality filters
    * `:columns` — list of column name strings to include (projection)
    * `:limit` — max rows to return
    * `:offset` — rows to skip before applying limit
  """
  def query_rows(%__MODULE__{} = table, opts \\ []) do
    filter = Keyword.get(opts, :filter)
    columns = Keyword.get(opts, :columns)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    rows = filter_rows(table, filter)

    rows =
      if offset > 0,
        do: Enum.drop(rows, offset),
        else: rows

    rows =
      if limit,
        do: Enum.take(rows, limit),
        else: rows

    rows =
      if columns do
        project_columns(rows, columns)
      else
        rows
      end

    total = row_count_filtered(table, filter)
    %{rows: rows, total: total, offset: offset, limit: limit}
  end

  defp row_count_filtered(table, nil), do: row_count(table)
  defp row_count_filtered(table, filter) when filter == %{}, do: row_count(table)

  defp row_count_filtered(table, filter) do
    Enum.count(rows(table), &match_filter?(&1, filter))
  end

  defp project_columns(rows, columns) do
    # Resolve column names: try atom first, fall back to string
    Enum.map(rows, fn row ->
      Map.new(columns, fn col ->
        key = resolve_column_key(row, col)
        {col, Map.get(row, key)}
      end)
      |> Map.put("id", Map.get(row, :id) || Map.get(row, "id"))
    end)
  end

  defp resolve_column_key(row, col) when is_binary(col) do
    atom_key = try_existing_atom(col)

    cond do
      atom_key && Map.has_key?(row, atom_key) -> atom_key
      Map.has_key?(row, col) -> col
      true -> col
    end
  end

  @doc """
  Summarize the table: row count + per-field unique value samples.

  Samples are kept cheap for LLM consumption: scalar fields return up to
  10 distinct values; complex fields (lists/maps) return a type descriptor
  (e.g. `"list<5>"`) instead of the raw nested value so `describe_table`
  does not leak full row payloads.
  """
  def summarize(%__MODULE__{} = table) do
    rows = rows(table)

    fields =
      case rows do
        [] ->
          []

        [first | _] ->
          first
          |> Map.keys()
          |> Enum.reject(&(&1 in [:id, "id"]))
      end

    field_stats = Enum.map(fields, &field_stat(rows, &1))

    %{
      total_rows: length(rows),
      fields: field_stats,
      version: table.version
    }
  end

  defp field_stat(rows, field) do
    values = Enum.map(rows, &Map.get(&1, field))

    if Enum.any?(values, &complex?/1) do
      %{
        field: field,
        unique_count: values |> Enum.uniq() |> length(),
        type: complex_type_label(values),
        sample: []
      }
    else
      unique = Enum.uniq(values)
      %{field: field, unique_count: length(unique), sample: Enum.take(unique, 10)}
    end
  end

  defp complex?(v), do: is_list(v) or is_map(v)

  defp complex_type_label(values) do
    sample = Enum.find(values, &complex?/1)

    case sample do
      v when is_list(v) -> "list<#{length(v)}>"
      v when is_map(v) -> "map<#{map_size(v)}>"
      _ -> "complex"
    end
  end

  @doc "Snapshot shape for client readers."
  def snapshot(%__MODULE__{} = table) do
    %{
      name: table.name,
      schema: table.schema,
      rows: rows(table),
      row_count: row_count(table),
      version: table.version
    }
  end

  # --- Internal ---

  defp insert_if_unique(acc_table, acc_inserted, id, row) do
    if Map.has_key?(acc_table.rows_by_id, id) do
      {:halt, {:error, {:duplicate_id, id}}}
    else
      row_with_id = Map.put(row, :id, id)

      updated = %{
        acc_table
        | rows_by_id: Map.put(acc_table.rows_by_id, id, row_with_id),
          row_order: acc_table.row_order ++ [id]
      }

      {:cont, {:ok, updated, [row_with_id | acc_inserted]}}
    end
  end

  defp bump_version(%__MODULE__{version: v} = t), do: %{t | version: v + 1}

  defp normalize_and_id(raw_row, schema, id_fun) when is_map(raw_row) do
    {supplied_id, row_without_id} = pop_supplied_id(raw_row)

    case Schema.validate_row(schema, row_without_id) do
      {:ok, row} ->
        id = supplied_id || id_fun.()
        {:ok, id, row}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_and_id(_, _, _), do: {:error, :invalid_row}

  defp pop_supplied_id(row) do
    cond do
      Map.has_key?(row, :id) and row[:id] != nil ->
        {to_string(row[:id]), Map.drop(row, [:id, "id"])}

      Map.has_key?(row, "id") and row["id"] != nil ->
        {to_string(row["id"]), Map.drop(row, [:id, "id"])}

      true ->
        {nil, Map.drop(row, [:id, "id"])}
    end
  end

  defp apply_change(%__MODULE__{} = table, change) do
    id = fetch_change(change, "id") |> to_string()
    field = fetch_change(change, "field")
    value = fetch_change(change, "value")

    cond do
      is_nil(field) ->
        {:halt, {:error, {:missing_change_field, change}}}

      is_binary(field) and String.starts_with?(field, "child:") ->
        apply_child_change(table, id, field, value)

      true ->
        apply_row_change(table, id, field, value)
    end
  end

  defp fetch_change(change, key) when is_map(change) and is_binary(key) do
    Map.get(change, key) || Map.get(change, safe_existing_atom(key))
  end

  defp safe_existing_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp apply_row_change(table, id, field, value) do
    case Map.get(table.rows_by_id, id) do
      nil ->
        {:cont, {:ok, table}}

      row ->
        case resolve_strict_field(field, table.schema) do
          {:ok, resolved_field} ->
            updated_row = Map.put(row, resolved_field, value)

            {:cont, {:ok, %{table | rows_by_id: Map.put(table.rows_by_id, id, updated_row)}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end
  end

  # Strict-mode tables reject writes to fields not declared in the schema.
  # Returns the atom-keyed field name on success so the row stores it under
  # the same key the schema/UI uses. Dynamic-mode tables fall through to
  # the legacy field_to_atom path.
  defp resolve_strict_field(field, %Schema{mode: :strict} = schema) do
    known = known_field_atoms(schema)

    cond do
      is_atom(field) and field in known ->
        {:ok, field}

      is_binary(field) ->
        case Enum.find(known, fn a -> Atom.to_string(a) == field end) do
          nil ->
            {:error, {:unknown_field, field, [available: Enum.map(known, &Atom.to_string/1)]}}

          atom ->
            {:ok, atom}
        end

      true ->
        {:error, {:unknown_field, field, []}}
    end
  end

  defp resolve_strict_field(field, schema), do: {:ok, field_to_atom(field, schema)}

  defp apply_child_change(table, id, field_path, value) do
    # Format: "child_field:child:idx" or "idx:child:field"
    # We'll use format: "children_key:child:idx:field" — but the plan says "row_id:child:idx"
    # Simplest supported: "child:<idx>:<field>"
    case String.split(field_path, ":") do
      ["child", idx_str, child_field] ->
        with {idx, ""} <- Integer.parse(idx_str),
             %{} = row <- Map.get(table.rows_by_id, id),
             children_key when not is_nil(children_key) <- table.schema.children_key,
             children when is_list(children) <- Map.get(row, children_key) do
          update_child_at(table, id, row, children_key, children, idx, child_field, value)
        else
          _ -> {:cont, {:ok, table}}
        end

      _ ->
        {:cont, {:ok, table}}
    end
  end

  defp update_child_at(table, id, row, children_key, children, idx, child_field, value) do
    child_field_atom = field_to_atom(child_field, nil)

    updated_children =
      List.update_at(children, idx, fn child ->
        Map.put(child || %{}, child_field_atom, value)
      end)

    updated_row = Map.put(row, children_key, updated_children)
    {:cont, {:ok, %{table | rows_by_id: Map.put(table.rows_by_id, id, updated_row)}}}
  end

  defp field_to_atom(field, _schema) when is_atom(field), do: field

  defp field_to_atom(field, schema) when is_binary(field) do
    # Only convert to atom if the schema declares this field as an atom column.
    known = schema && known_field_atoms(schema)

    if known do
      Enum.find(known, field, fn atom -> Atom.to_string(atom) == field end)
    else
      try_existing_atom(field) || field
    end
  end

  defp known_field_atoms(nil), do: nil

  defp known_field_atoms(%Schema{} = schema) do
    children = if schema.children_key, do: [schema.children_key], else: []

    (Schema.column_names(schema) ++ Schema.child_column_names(schema) ++ children)
    |> Enum.uniq()
  end

  defp try_existing_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp match_filter?(row, filter) do
    Enum.all?(filter, fn {k, v} ->
      key = normalize_filter_key(row, k)
      row_val = Map.get(row, key)
      values_match?(row_val, v)
    end)
  end

  defp normalize_filter_key(_row, k) when is_atom(k), do: k

  defp normalize_filter_key(row, k) when is_binary(k) do
    cond do
      Map.has_key?(row, k) ->
        k

      atom = try_existing_atom(k) ->
        if Map.has_key?(row, atom), do: atom, else: k

      true ->
        k
    end
  end

  defp values_match?(a, a), do: true

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
end
