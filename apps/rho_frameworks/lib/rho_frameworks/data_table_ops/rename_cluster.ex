defmodule RhoFrameworks.DataTableOps.RenameCluster do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope

  @spec run(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{updated: non_neg_integer()}} | {:error, term()}
  def run(%Scope{} = scope, table, old_name, new_name)
      when is_binary(table) and is_binary(old_name) and is_binary(new_name) do
    DataTableOps.with_source(scope, fn ->
      rows = DataTable.get_rows(scope.session_id, table: table, filter: %{cluster: old_name})

      case rows do
        {:error, reason} ->
          {:error, reason}

        rows when is_list(rows) ->
          changes =
            Enum.map(rows, fn row ->
              %{
                "id" => to_string(MapAccess.get(row, :id)),
                "field" => "cluster",
                "value" => new_name
              }
            end)

          case DataTable.update_cells(scope.session_id, changes, table: table) do
            :ok ->
              DataTableOps.emit(scope, :rename_cluster, table, %{
                from: old_name,
                to: new_name,
                count: length(rows)
              })

              {:ok, %{updated: length(rows)}}

            {:error, _} = err ->
              err
          end
      end
    end)
  end
end
