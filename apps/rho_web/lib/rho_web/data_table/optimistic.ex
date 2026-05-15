defmodule RhoWeb.DataTable.Optimistic do
  @moduledoc """
  Applies optimistic cell edits over server-owned DataTable rows.

  The DataTable server remains authoritative. This module only overlays local
  pending edits so the UI can reflect a cell or child-cell change before the
  next invalidation snapshot arrives.
  """

  def apply(rows, optimistic) when optimistic == %{}, do: rows

  def apply(rows, optimistic) when is_list(rows) do
    Enum.map(rows, fn row ->
      id = to_string(row_id(row))
      apply_row(row, id, optimistic)
    end)
  end

  def apply(rows, _optimistic), do: rows

  def apply_row(row, id, optimistic) do
    Enum.reduce(optimistic, row, fn
      {{^id, nil, field}, value}, acc ->
        put_cell(acc, field, value)

      {{^id, child_idx, field}, value}, acc when is_integer(child_idx) ->
        update_child(acc, child_idx, field, value)

      _, acc ->
        acc
    end)
  end

  def put_cell(row, field, value) do
    cond do
      is_atom_key?(row, field) ->
        Map.put(row, String.to_existing_atom(field), value)

      map_key?(row, field) ->
        Map.put(row, field, value)

      true ->
        Map.put(row, field, value)
    end
  end

  defp row_id(row) do
    Rho.MapAccess.get(row, :id)
  end

  defp is_atom_key?(row, field) when is_binary(field) do
    atom =
      try do
        String.to_existing_atom(field)
      rescue
        ArgumentError -> nil
      end

    atom && map_key?(row, atom)
  end

  defp is_atom_key?(_row, _field), do: false

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp update_child(row, idx, field, value) do
    children_key =
      case {Map.fetch(row, :proficiency_levels), Map.fetch(row, "proficiency_levels")} do
        {{:ok, _}, _} -> :proficiency_levels
        {_, {:ok, _}} -> "proficiency_levels"
        _ -> nil
      end

    case children_key && Map.get(row, children_key) do
      nil ->
        row

      children when is_list(children) ->
        updated =
          List.update_at(children, idx, fn child ->
            put_cell(child || %{}, field, value)
          end)

        Map.put(row, children_key, updated)

      _ ->
        row
    end
  end
end
