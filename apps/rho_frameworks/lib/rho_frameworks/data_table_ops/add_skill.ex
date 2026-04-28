defmodule RhoFrameworks.DataTableOps.AddSkill do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.Scope

  @spec run(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, table, %{} = row) when is_binary(table) do
    DataTableOps.with_source(scope, fn ->
      stamped = DataTableOps.stamp(row, scope)

      case DataTable.add_rows(scope.session_id, [stamped], table: table) do
        {:ok, [inserted]} ->
          DataTableOps.emit(scope, :add_skill, table, %{row: inserted})
          {:ok, inserted}

        {:ok, inserted} when is_list(inserted) ->
          DataTableOps.emit(scope, :add_skill, table, %{rows: inserted})
          {:ok, List.first(inserted)}

        {:error, _} = err ->
          err
      end
    end)
  end
end
