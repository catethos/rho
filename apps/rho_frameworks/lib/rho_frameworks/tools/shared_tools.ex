defmodule RhoFrameworks.Tools.SharedTools do
  @moduledoc """
  Shared tools extracted from RhoFrameworks.Plugin.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  These tools are not specific to library or role contexts and can be
  used across different tool surfaces.
  """

  use Rho.Tool

  tool :add_proficiency_levels,
       "Add proficiency levels for skills. Each entry needs skill_name, category, cluster, skill_description, and a levels array. More token-efficient than add_rows when generating proficiency levels." do
    param(:levels_json, :string,
      required: true,
      doc:
        ~s(JSON string: [{"skill_name":"SQL","category":"Data","cluster":"Wrangling","skill_description":"...","levels":[{"level":1,"level_name":"Novice","level_description":"..."},...]},...]  )
    )

    run(fn args, _ctx ->
      raw = args[:levels_json] || "[]"

      skills =
        case Jason.decode(raw) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      if skills == [] do
        {:error, "No valid data. Ensure levels_json is a valid JSON array."}
      else
        rows =
          Enum.flat_map(skills, fn skill_entry ->
            skill_name = skill_entry["skill_name"] || ""
            category = skill_entry["category"] || ""
            cluster = skill_entry["cluster"] || ""
            skill_desc = skill_entry["skill_description"] || ""
            levels = skill_entry["levels"] || []

            Enum.map(levels, fn lvl ->
              %{
                category: category,
                cluster: cluster,
                skill_name: skill_name,
                skill_description: skill_desc,
                level: lvl["level"] || 1,
                level_name: lvl["level_name"] || "",
                level_description: lvl["level_description"] || ""
              }
            end)
          end)

        if rows == [] do
          {:error, "No levels to add."}
        else
          %Rho.ToolResponse{
            text: "Added #{length(rows)} proficiency level(s) for #{length(skills)} skill(s)",
            effects: [
              %Rho.Effect.Table{rows: rows, append?: true}
            ]
          }
        end
      end
    end)
  end
end
