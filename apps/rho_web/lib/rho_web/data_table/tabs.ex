defmodule RhoWeb.DataTable.Tabs do
  @moduledoc """
  Pure tab-strip helpers for named data-table rendering.
  """

  @hidden_plumbing_tables MapSet.new(["meta"])

  def display_order(order, tables) when is_list(order) do
    order
    |> maybe_hide_empty_default_main(tables)
    |> Enum.reject(&hidden_plumbing_table?/1)
  end

  def display_order(_, _), do: []

  def display_order(order, tables, active_table) when is_list(order) do
    order
    |> display_order(tables)
    |> collapse_duplicate_skill_framework_tabs(active_table)
  end

  def display_order(order, tables, _active_table), do: display_order(order, tables)

  def display_order_for_state(%{table_order: order, tables: tables}) do
    display_order(order, tables)
  end

  def display_order_for_state(%{table_order: order}) do
    display_order(order, [])
  end

  def display_order_for_state(_), do: []

  def row_count(tables, name) when is_list(tables) do
    case Enum.find(tables, &(table_name(&1) == name)) do
      nil -> 0
      %{row_count: n} -> n
      %{"row_count" => n} -> n
      _ -> 0
    end
  end

  def row_count(_, _), do: 0

  def closable?("main"), do: false
  def closable?("meta"), do: false
  def closable?(name) when is_binary(name), do: true
  def closable?(_), do: false

  defp maybe_hide_empty_default_main(order, tables) do
    if hide_empty_default_main?(order, tables),
      do: Enum.reject(order, &(&1 == "main")),
      else: order
  end

  defp hidden_plumbing_table?(name), do: MapSet.member?(@hidden_plumbing_tables, name)

  defp hide_empty_default_main?(order, tables) do
    "main" in order and Enum.any?(order, &(&1 != "main")) and row_count(tables, "main") == 0
  end

  defp collapse_duplicate_skill_framework_tabs(order, active_table) do
    {kept, _seen} =
      Enum.reduce(order, {[], %{}}, fn name, {kept, seen} ->
        case canonical_skill_framework_key(name) do
          nil ->
            {kept ++ [name], seen}

          key ->
            case Map.fetch(seen, key) do
              :error ->
                {kept ++ [name], Map.put(seen, key, name)}

              {:ok, existing} when name == active_table ->
                {replace_once(kept, existing, name), Map.put(seen, key, name)}

              {:ok, _existing} ->
                {kept, seen}
            end
        end
      end)

    kept
  end

  defp canonical_skill_framework_key("library:" <> name) do
    name
    |> String.trim()
    |> String.replace(~r/\s+skill\s+framework\z/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.downcase()
    |> case do
      "" -> nil
      key -> {:library, key}
    end
  end

  defp canonical_skill_framework_key(_), do: nil

  defp replace_once([old | rest], old, new), do: [new | rest]
  defp replace_once([head | rest], old, new), do: [head | replace_once(rest, old, new)]
  defp replace_once([], _old, new), do: [new]

  defp table_name(%{name: name}), do: name
  defp table_name(%{"name" => name}), do: name
  defp table_name(_), do: nil
end
