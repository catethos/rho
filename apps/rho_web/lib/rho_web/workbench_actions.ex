defmodule RhoWeb.WorkbenchActions do
  @moduledoc """
  Pure catalog of first-screen Workbench actions.

  The catalog is intentionally map-based for now. It gives the UI stable
  labels, modes, fields, and execution lanes without coupling the renderer to
  domain execution.
  """

  @actions [
    %{
      id: :create_framework,
      label: "Create Framework",
      summary: "Build a new skill framework from a short brief.",
      mode: :form,
      fields: [
        :name,
        :description,
        :domain,
        :target_roles,
        :taxonomy_size,
        :transferability,
        :specificity
      ],
      execution: :flow
    },
    %{
      id: :extract_jd,
      label: "Extract JD",
      summary: "Pull role requirements and skills from a job description.",
      mode: :upload_or_text,
      fields: [:upload_id, :text, :role_name, :library_name],
      execution: :agent_prompt
    },
    %{
      id: :import_library,
      label: "Import Library",
      summary: "Bring in skills from a CSV or Excel file.",
      mode: :upload,
      fields: [:upload_id, :library_name, :sheet],
      execution: :direct_or_prompt
    },
    %{
      id: :load_library,
      label: "Load Library",
      summary: "Open an existing saved framework.",
      mode: :picker,
      fields: [:library_id],
      execution: :direct
    },
    %{
      id: :create_role_profile,
      label: "Create Role",
      summary: "Start role requirements from a saved skill library.",
      mode: :picker,
      fields: [:library_id, :role_name],
      execution: :direct
    },
    %{
      id: :find_roles,
      label: "Find Roles",
      summary: "Search for similar roles to use as examples.",
      mode: :form,
      fields: [:queries, :library_id, :limit],
      execution: :direct
    }
  ]

  @doc "Workbench home actions in display order."
  def home_actions, do: @actions

  @doc "Fetch an action by atom or string id."
  def get(id) when is_atom(id) do
    Enum.find(@actions, &(&1.id == id))
  end

  def get(id) when is_binary(id) do
    id
    |> String.to_existing_atom()
    |> get()
  rescue
    ArgumentError -> nil
  end
end
