defmodule RhoFrameworks.Tools.SharedTools do
  @moduledoc """
  Shared tools extracted from RhoFrameworks.Plugin.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  These tools are not specific to library or role contexts and can be
  used across different tool surfaces.
  """

  use Rho.Tool

  alias Rho.Stdlib.DataTable

  tool :add_proficiency_levels,
       "Update existing skeleton skills in the data table with proficiency levels. " <>
         "Matches each entry by skill_name to a row already in the table (saved by save_and_generate). " <>
         "Skills not found in the table are skipped." do
    param(:levels_json, :string,
      required: true,
      doc:
        ~s(JSON string: [{"skill_name":"SQL","levels":[{"level":1,"level_name":"Novice","level_description":"..."},...]},...]  )
    )

    param(:table, :string, doc: "Target named table (default: \"library\")")

    run(fn args, ctx ->
      raw = args[:levels_json] || "[]"
      table = args[:table] || "library"

      skills =
        case Jason.decode(raw) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      if skills == [] do
        {:error, "No valid data. Ensure levels_json is a valid JSON array."}
      else
        # Fetch existing rows to match by skill_name
        existing_rows =
          case DataTable.get_rows(ctx.session_id, table: table) do
            {:error, _} -> []
            rows -> rows
          end

        rows_by_name =
          Map.new(existing_rows, fn row ->
            {to_string(row[:skill_name] || row["skill_name"] || ""), row}
          end)

        {changes, matched, skipped} =
          Enum.reduce(skills, {[], [], []}, fn skill_entry, {ch_acc, m_acc, s_acc} ->
            skill_name = skill_entry["skill_name"] || ""
            levels = skill_entry["levels"] || []

            proficiency_levels =
              Enum.map(levels, fn lvl ->
                %{
                  level: lvl["level"] || 1,
                  level_name: lvl["level_name"] || "",
                  level_description: lvl["level_description"] || ""
                }
              end)

            case Map.get(rows_by_name, skill_name) do
              nil ->
                {ch_acc, m_acc, [skill_name | s_acc]}

              row ->
                row_id = to_string(row[:id] || row["id"])

                change = %{
                  "id" => row_id,
                  "field" => "proficiency_levels",
                  "value" => proficiency_levels
                }

                {[change | ch_acc], [skill_name | m_acc], s_acc}
            end
          end)

        if changes == [] do
          skipped_names = Enum.reverse(skipped) |> Enum.join(", ")
          known = known_tables_hint(ctx.session_id, table)

          {:error,
           "No matching skeleton skills found in '#{table}' table. " <>
             "Skipped: #{skipped_names}. " <>
             known <>
             "If the framework lives in a different named table, retry with the correct `table:` arg. " <>
             "Otherwise ensure save_and_generate was called first."}
        else
          case DataTable.update_cells(ctx.session_id, changes, table: table) do
            :ok ->
              msg = "Updated #{length(matched)} skill(s)."

              msg =
                case skipped do
                  [] -> msg
                  _ -> msg <> " Skipped #{length(skipped)}."
                end

              {:ok, msg}

            {:error, reason} ->
              {:error, "Failed to update rows: #{inspect(reason)}"}
          end
        end
      end
    end)
  end

  # Render a "Known tables: [...]" hint from the session's DataTable.
  # Used to make `add_proficiency_levels` errors actionable when the
  # caller passed (or defaulted to) a table that has no skeletons.
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
