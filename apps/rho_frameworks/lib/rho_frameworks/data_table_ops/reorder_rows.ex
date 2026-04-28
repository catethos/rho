defmodule RhoFrameworks.DataTableOps.ReorderRows do
  @moduledoc false

  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.Scope

  @doc """
  Phase 1 stub. Records the requested row ordering as a
  `:framework_mutation` event so subscribers learn the intent. The
  underlying table doesn't yet store sort_order; later phases can wire
  this through to a real `:order` column.
  """
  @spec run(Scope.t(), String.t(), [String.t()]) :: :ok
  def run(%Scope{} = scope, table, ordered_ids)
      when is_binary(table) and is_list(ordered_ids) do
    DataTableOps.with_source(scope, fn ->
      DataTableOps.emit(scope, :reorder_rows, table, %{ordered_ids: ordered_ids})
      :ok
    end)
  end
end
