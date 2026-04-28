defmodule RhoFrameworks.DataTableOps.SetProficiencyLevel do
  @moduledoc false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableOps
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope

  @doc """
  Update the `proficiency_levels` field for a single skill in `table`,
  matched by `skill_name`. `levels` is a list of `%{level, level_name,
  level_description}` maps.
  """
  @spec run(Scope.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, table, skill_name, levels)
      when is_binary(table) and is_binary(skill_name) and is_list(levels) do
    DataTableOps.with_source(scope, fn ->
      case DataTable.get_rows(scope.session_id, table: table, filter: %{skill_name: skill_name}) do
        {:error, reason} ->
          {:error, reason}

        [] ->
          {:error, :not_found}

        [row | _] ->
          row_id = to_string(MapAccess.get(row, :id))

          changes = [
            %{
              "id" => row_id,
              "field" => "proficiency_levels",
              "value" => normalize_levels(levels)
            }
          ]

          case DataTable.update_cells(scope.session_id, changes, table: table) do
            :ok ->
              DataTableOps.emit(scope, :set_proficiency_level, table, %{
                skill_name: skill_name,
                levels: levels
              })

              {:ok, %{skill_name: skill_name, level_count: length(levels)}}

            {:error, _} = err ->
              err
          end
      end
    end)
  end

  defp normalize_levels(levels) do
    Enum.map(levels, fn lvl ->
      %{
        level: MapAccess.get(lvl, :level, 1),
        level_name: MapAccess.get(lvl, :level_name),
        level_description: MapAccess.get(lvl, :level_description)
      }
    end)
  end
end
