defmodule RhoFrameworks.DataTableOps.ReplaceRows do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.Scope

  @spec run(Scope.t(), String.t(), [map()]) ::
          {:ok, [map()]} | {:error, term()}
  def run(%Scope{} = scope, table, rows)
      when is_binary(table) and is_list(rows) do
    DataTableOps.with_source(scope, fn ->
      stamped = DataTableOps.stamp_all(rows, scope)

      case DataTable.replace_all(scope.session_id, stamped, table: table) do
        {:ok, inserted} ->
          DataTableOps.emit(scope, :replace_rows, table, %{count: length(inserted)})
          {:ok, inserted}

        {:error, _} = err ->
          err
      end
    end)
  end
end
