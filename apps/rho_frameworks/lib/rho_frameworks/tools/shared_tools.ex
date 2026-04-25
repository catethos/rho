defmodule RhoFrameworks.Tools.SharedTools do
  @moduledoc """
  Shared tools extracted from RhoFrameworks.Plugin.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  These tools are not specific to library or role contexts and can be
  used across different tool surfaces.
  """

  use Rho.Tool

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.MapAccess
  alias RhoFrameworks.Scope

  tool :add_proficiency_levels,
       "Update existing skeleton skills in the data table with proficiency levels. " <>
         "Matches each entry by skill_name to a row already in the table (saved by save_library action=generate). " <>
         "Skills not found in the table are skipped." do
    param(:levels_json, :string, required: true, doc: "JSON array of {skill_name, levels}")
    param(:table, :string, doc: "default: library")

    run(fn args, ctx ->
      raw = args[:levels_json] || "[]"
      table = MapAccess.get(args, :table, "library")

      skill_levels =
        cond do
          is_list(raw) ->
            raw

          is_binary(raw) ->
            case Jason.decode(raw) do
              {:ok, list} when is_list(list) -> list
              _ -> []
            end

          true ->
            []
        end

      if skill_levels == [] do
        {:error, "No valid data. Ensure levels_json is a valid JSON array."}
      else
        rt = Scope.from_context(ctx)
        params = %{table_name: table, skill_levels: skill_levels}

        case Editor.apply_proficiency_levels(params, rt) do
          {:ok, %{updated_count: count, skipped: skipped}} ->
            msg = "Updated #{count} skill(s)."
            msg = if skipped != [], do: msg <> " Skipped #{length(skipped)}.", else: msg
            {:ok, msg}

          {:error, {:no_matches, skipped}} ->
            skipped_names = Enum.join(skipped, ", ")
            known = known_tables_hint(ctx.session_id, table)

            {:error,
             "No matching skeleton skills found in '#{table}' table. " <>
               "Skipped: #{skipped_names}. " <>
               known <>
               "If the framework lives in a different named table, retry with the correct `table:` arg. " <>
               "Otherwise ensure save_library action=generate was called first."}

          {:error, {:not_running, tbl}} ->
            known = known_tables_hint(ctx.session_id, table)

            {:error,
             "No '#{tbl}' table is active. " <>
               known <>
               "Ensure save_library action=generate or load_library was called first."}

          {:error, {:update_failed, reason}} ->
            {:error, "Failed to update rows: #{inspect(reason)}"}
        end
      end
    end)
  end

  defp known_tables_hint(session_id, attempted) do
    case DataTable.list_tables(session_id) do
      tables when is_list(tables) and tables != [] ->
        names =
          tables
          |> Enum.map(& &1.name)
          |> Enum.reject(&(&1 == attempted))

        case names do
          [] -> ""
          list -> "Known tables in this session: #{Enum.join(list, ", ")}. "
        end

      _ ->
        ""
    end
  end
end
