defmodule RhoWeb.DataTable.Rows do
  @moduledoc """
  Pure row operations for the interactive data table component.
  """

  alias RhoWeb.DataTable.Streams

  @doc """
  Sorts rows by a field while accepting atom or string row keys.
  """
  def sort(rows, nil, _dir), do: rows

  def sort(rows, field, dir) do
    sorted =
      Enum.sort_by(rows, fn row ->
        val = get_field(row, field) || ""
        if is_binary(val), do: String.downcase(val), else: val
      end)

    if dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  @doc """
  Groups rows by up to two fields while preserving first-seen group order.
  """
  def group([], _group_by), do: []

  def group(rows, []), do: [{"All", {:rows, rows}}]

  def group(row_entries, [field]) do
    row_entries
    |> group_preserving_order(field)
    |> Enum.map(fn {label, group_rows} -> {label, {:rows, group_rows}} end)
  end

  def group(row_entries, [field1, field2 | _]) do
    row_entries
    |> group_preserving_order(field1)
    |> Enum.map(fn {label, group_rows} ->
      sub_groups = group_preserving_order(group_rows, field2)
      {label, {:nested, sub_groups}}
    end)
  end

  @doc """
  Collects every top-level and nested group id in a grouped row tree.
  """
  def collect_group_ids(group_tree) do
    Enum.reduce(group_tree, MapSet.new(), fn {group_label, children}, acc ->
      group_id = Streams.group_id_for(group_label)
      new_acc = MapSet.put(acc, group_id)

      case children do
        {:nested, child_groups} ->
          Enum.reduce(child_groups, new_acc, fn {sub_label, _rows}, inner_acc ->
            MapSet.put(inner_acc, Streams.group_id_for(group_label, sub_label))
          end)

        {:rows, _} ->
          new_acc
      end
    end)
  end

  @doc """
  Counts leaf rows below a grouped row node.
  """
  def count_nested_rows({:rows, rows}), do: length(rows)

  def count_nested_rows({:nested, nested_groups}) do
    Enum.reduce(nested_groups, 0, fn {_label, rows}, acc -> acc + length(rows) end)
  end

  @doc """
  Returns a row's stable id using the same mixed atom/string lookup as the table.
  """
  def row_id(row), do: Rho.MapAccess.get(row, :id)

  @doc """
  Returns visible row ids as strings, preserving row order and skipping nil ids.
  """
  def visible_row_ids(visible_rows) when is_list(visible_rows) do
    visible_rows
    |> Enum.reduce([], fn row, acc ->
      case row_id(row) do
        nil -> acc
        id -> [to_string(id) | acc]
      end
    end)
    |> Enum.reverse()
  end

  def visible_row_ids(_), do: []

  @doc """
  Computes the select-all checkbox state for the current visible rows.
  """
  def select_all_state(rows, %MapSet{} = selected) do
    visible = MapSet.new(visible_row_ids(rows))

    cond do
      MapSet.size(visible) == 0 -> :none
      MapSet.subset?(visible, selected) -> :all
      MapSet.disjoint?(visible, selected) -> :none
      true -> :some
    end
  end

  def select_all_state(_rows, _), do: :none

  defp group_preserving_order(group_entries, field) do
    {groups, order} =
      Enum.reduce(group_entries, {%{}, %{}}, fn row, {groups, order} ->
        key =
          (get_field(row, field) || "")
          |> to_string()

        new_groups = Map.update(groups, key, [row], &[row | &1])
        new_order = Map.put_new(order, key, map_size(order))
        {new_groups, new_order}
      end)

    order
    |> Enum.sort_by(fn {_key, idx} -> idx end)
    |> Enum.map(fn {key, _} -> {key, Enum.reverse(Map.get(groups, key, []))} end)
  end

  defp get_field(row, field) when is_atom(field) do
    Map.get(row, field) || Map.get(row, Atom.to_string(field))
  end

  defp get_field(row, field) when is_binary(field) do
    Map.get(row, field) || get_existing_atom_key(row, field)
  end

  defp get_existing_atom_key(row, field) do
    Enum.find_value(row, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == field, do: value

      _ ->
        nil
    end)
  end
end
