defmodule RhoWeb.DataTable.Commands do
  @moduledoc """
  Pure command payload builders for `RhoWeb.DataTableComponent`.

  These functions own the shape of changes sent to `Rho.Stdlib.DataTable`.
  The LiveComponent still owns socket state, optimistic stream updates, and
  rendering.
  """

  alias RhoWeb.DataTable.Schema

  @doc """
  Builds an `update_cells/3` change and optimistic-edit key for a cell edit.
  """
  def cell_change(rows, %Schema{} = schema, id, field, value) do
    {parent_id, child_index} = parse_compound_id(id)

    change =
      if child_index do
        build_child_change(rows, schema, parent_id, child_index, field, value)
      else
        %{"id" => parent_id, "field" => field, "value" => value}
      end

    {change, {parent_id, child_index, field}}
  end

  @doc "Builds the conflict resolution cell update payload."
  def conflict_resolution_change(id, resolution) do
    {%{"id" => id, "field" => "resolution", "value" => resolution}, {id, nil, "resolution"}}
  end

  @doc """
  Builds all row changes needed to rename a group value.

  Unknown fields simply produce no changes; this avoids creating atoms from
  user-provided field names.
  """
  def group_edit_changes(_rows, _field, old_value, new_value)
      when new_value in ["", nil] or new_value == old_value do
    []
  end

  def group_edit_changes(rows, field, old_value, new_value) when is_list(rows) do
    Enum.flat_map(rows, fn row ->
      val = get_field(row, field)

      if to_string(val) == old_value do
        [%{"id" => to_string(row_id(row)), "field" => field, "value" => new_value}]
      else
        []
      end
    end)
  end

  @doc "Builds a new top-level row using component placeholder defaults."
  def new_row(%Schema{} = schema, params) when is_map(params) do
    schema.columns
    |> Map.new(fn col ->
      default =
        case col.type do
          :number -> 0
          _ -> "(new)"
        end

      {col.key, default}
    end)
    |> maybe_put(params, "category")
    |> maybe_put(params, "cluster")
  end

  @doc "Builds an update that appends a blank child row."
  def add_child_change(rows, %Schema{} = schema, parent_id) do
    children_key = schema.children_key
    row = find_row(rows, parent_id)
    children = (row && get_field(row, children_key)) || []
    next_level = next_child_level(children)

    blank_child =
      schema.child_columns
      |> Map.new(fn col ->
        default = if col.type == :number, do: 0, else: ""
        {col.key, default}
      end)
      |> Map.put(:level, next_level)

    new_children = children ++ [blank_child]
    %{"id" => parent_id, "field" => to_string(children_key), "value" => new_children}
  end

  @doc "Builds an update that removes a child row by rendered index."
  def delete_child_change(rows, %Schema{} = schema, parent_id, idx_str) do
    children_key = schema.children_key
    row = find_row(rows, parent_id)
    children = (row && get_field(row, children_key)) || []
    {idx, ""} = Integer.parse(idx_str)

    new_children = List.delete_at(children, idx)
    %{"id" => parent_id, "field" => to_string(children_key), "value" => new_children}
  end

  @doc "Parses rendered row ids, including child ids of the form `parent:child:index`."
  def parse_compound_id(id) when is_binary(id) do
    case String.split(id, ":child:") do
      [parent, child_idx] ->
        case Integer.parse(child_idx) do
          {n, ""} -> {parent, n}
          _ -> {id, nil}
        end

      [_single] ->
        {id, nil}
    end
  end

  def parse_compound_id(id), do: {to_string(id), nil}

  defp build_child_change(rows, schema, parent_id, child_index, field, value) do
    children_key = schema.children_key
    key_fields = schema.child_key_fields || []

    row = find_row(rows, parent_id)
    children = (row && get_field(row, children_key)) || []
    child = Enum.at(children, child_index) || %{}
    child_key = build_child_key(child, key_fields)

    %{
      "id" => parent_id,
      "child_key" => child_key,
      "field" => field,
      "value" => value
    }
  end

  defp build_child_key(child, key_fields) when is_list(key_fields) and key_fields != [] do
    Map.new(key_fields, fn f ->
      {Atom.to_string(f), get_field(child, f)}
    end)
  end

  defp build_child_key(_, _), do: %{}

  defp find_row(row_entries, id) do
    Enum.find(row_entries, fn row -> to_string(row_id(row)) == id end)
  end

  defp row_id(row) do
    get_field(row, :id) || get_field(row, "id") || get_field(row, :skill_name) ||
      get_field(row, "skill_name") || :erlang.phash2(row)
  end

  defp next_child_level([]), do: 1

  defp next_child_level(children) do
    children
    |> Enum.reduce(0, fn child, best -> max(get_child_level(child), best) end)
    |> Kernel.+(1)
  end

  defp get_child_level(child) do
    (get_field(child, :level) || 0)
    |> to_integer()
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
  defp to_integer(_), do: 0

  defp maybe_put(map, params, key) do
    case Map.get(params, key) do
      nil ->
        map

      "" ->
        map

      val ->
        atom_key = existing_atom(key) || key
        Map.put(map, atom_key, val)
    end
  end

  defp get_field(nil, _field), do: nil

  defp get_field(row, field) when is_atom(field),
    do: Map.get(row, field) || Map.get(row, Atom.to_string(field))

  defp get_field(row, field) when is_binary(field),
    do: Map.get(row, existing_atom(field)) || Map.get(row, field)

  defp existing_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end
end
