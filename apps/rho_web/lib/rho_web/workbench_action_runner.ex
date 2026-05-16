defmodule RhoWeb.WorkbenchActionRunner do
  @moduledoc """
  Helpers for turning Workbench home actions into prompts or UI metadata.

  AppLive owns socket/session mutation. This module keeps the action text and
  direct-run metadata testable and shared.
  """

  @role_candidates_table "role_candidates"

  def build_prompt(:create_framework, params) do
    name = clean(params["name"])
    description = clean(params["description"])
    domain = clean(params["domain"])
    target_roles = clean(params["target_roles"])
    skill_count = clean(params["skill_count"]) || "12"

    [
      "Create a new skill framework in the Workbench.",
      "",
      "Call generate_framework_skeletons with:",
      bullet("name", name),
      bullet("description", description),
      bullet("domain", domain),
      bullet("target_roles", target_roles),
      bullet("skill_count", skill_count),
      "",
      "After the skeleton is generated, keep it open in the Workbench and suggest the next step for missing proficiency levels."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def build_prompt(:extract_jd, params) do
    [
      "Extract a job description into linked Workbench artifacts.",
      "",
      "Use extract_role_from_jd with:",
      bullet("upload_id", clean(params["upload_id"])),
      bullet("text", clean(params["text"])),
      bullet("role_name", clean(params["role_name"])),
      bullet("library_name", clean(params["library_name"])),
      "",
      "Create both the skill framework and role requirements artifacts."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def build_prompt(:import_library, params) do
    [
      "Import the uploaded structured file as a skill library.",
      "",
      "Use import_library_from_upload with:",
      bullet("upload_id", clean(params["upload_id"])),
      bullet("library_name", clean(params["library_name"])),
      bullet("sheet", clean(params["sheet"])),
      "",
      "Open the imported framework in the Workbench."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def validate(:create_framework, params) do
    if clean(params["name"]) do
      :ok
    else
      {:error, "Framework name is required."}
    end
  end

  def validate(:extract_jd, params) do
    has_upload? = clean(params["upload_id"]) != nil
    has_text? = clean(params["text"]) != nil

    if has_upload? or has_text? do
      :ok
    else
      {:error, "Paste a job description or attach a JD file."}
    end
  end

  def validate(:import_library, params) do
    if clean(params["upload_id"]) do
      :ok
    else
      {:error, "Attach a CSV or Excel file to import."}
    end
  end

  def validate(:find_roles, params) do
    if role_queries(params) == [] do
      {:error, "Enter at least one role name or search query."}
    else
      :ok
    end
  end

  def validate(:load_library, params) do
    if clean(params["library_id"]) do
      :ok
    else
      {:error, "Choose a library to load."}
    end
  end

  def validate(:create_role_profile, params) do
    cond do
      is_nil(clean(params["library_id"])) ->
        {:error, "Choose a source library."}

      is_nil(clean(params["role_name"])) ->
        {:error, "Role name is required."}

      true ->
        :ok
    end
  end

  def role_queries(params) do
    params
    |> Map.get("queries", "")
    |> to_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def role_limit(params) do
    case Integer.parse(to_string(params["limit"] || "10")) do
      {n, ""} -> n |> max(1) |> min(25)
      _ -> 10
    end
  end

  def role_candidates_metadata(per_query, total, queries) do
    %{
      workflow: :role_search,
      artifact_kind: :role_candidates,
      title: "Candidate Roles",
      output_table: @role_candidates_table,
      source_role_names: queries,
      source_label: Enum.join(queries, ", "),
      candidate_count: total,
      query_count: length(per_query),
      ui_intent: %{
        surface: :role_candidate_picker,
        artifact_table: @role_candidates_table,
        allowed_actions: [:seed_framework_from_selected, :clone_selected_role],
        props: %{queries: queries}
      }
    }
  end

  defp bullet(_label, nil), do: nil
  defp bullet(label, value), do: "- #{label}: #{value}"

  defp clean(nil), do: nil

  defp clean(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
