defmodule RhoWeb.DataTable.Tabs do
  @moduledoc """
  Pure tab-strip helpers for named data-table rendering.
  """

  def display_order(order, tables) when is_list(order) do
    if hide_empty_default_main?(order, tables) do
      Enum.reject(order, &(&1 == "main"))
    else
      order
    end
  end

  def display_order(_, _), do: []

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
  def closable?(name) when is_binary(name), do: true
  def closable?(_), do: false

  defp hide_empty_default_main?(order, tables) do
    "main" in order and Enum.any?(order, &(&1 != "main")) and row_count(tables, "main") == 0
  end

  defp table_name(%{name: name}), do: name
  defp table_name(%{"name" => name}), do: name
  defp table_name(_), do: nil
end
