defmodule RhoFrameworks.DataTableOps.UpdateCells do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.Scope

  @spec run(Scope.t(), String.t(), [map()]) :: :ok | {:error, term()}
  def run(%Scope{} = scope, table, changes)
      when is_binary(table) and is_list(changes) do
    DataTableOps.with_source(scope, fn ->
      case DataTable.update_cells(scope.session_id, changes, table: table) do
        :ok ->
          DataTableOps.emit(scope, :update_cells, table, %{count: length(changes)})
          :ok

        {:error, _} = err ->
          err
      end
    end)
  end
end
