defmodule RhoFrameworks.DataTableOps.SetMeta do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Scope

  @table "meta"

  @spec run(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, %{} = fields) do
    DataTableOps.with_source(scope, fn ->
      with :ok <- DataTable.ensure_table(scope.session_id, @table, DataTableSchemas.meta_schema()),
           stamped = DataTableOps.stamp(fields, scope),
           {:ok, [row]} <- DataTable.replace_all(scope.session_id, [stamped], table: @table) do
        DataTableOps.emit(scope, :set_meta, @table, %{row: row})
        {:ok, row}
      end
    end)
  end
end
