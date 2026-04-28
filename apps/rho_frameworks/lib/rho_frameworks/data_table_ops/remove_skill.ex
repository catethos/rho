defmodule RhoFrameworks.DataTableOps.RemoveSkill do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.Scope

  @spec run(Scope.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def run(%Scope{} = scope, table, id)
      when is_binary(table) and is_binary(id) do
    DataTableOps.with_source(scope, fn ->
      case DataTable.delete_rows(scope.session_id, [id], table: table) do
        :ok ->
          DataTableOps.emit(scope, :remove_skill, table, %{id: id})
          :ok

        {:error, _} = err ->
          err
      end
    end)
  end
end
