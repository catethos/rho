defmodule RhoFrameworks.UseCases.PickTemplate do
  @moduledoc """
  Use a similar role profile (selected during `:similar_roles`) as a
  template for the new framework.

  Creates the library record from intake metadata, ensures the session's
  library table is initialised, and clones the role's skills (with
  descriptions and full proficiency-level data) into it via
  `RhoFrameworks.Roles.clone_skills_for_library/2`. The downstream
  `:save` step then persists the rows back through `SaveFramework`
  exactly as it would on the from-scratch path.

  Input:

      %{
        intake:           %{name: String.t(), description: String.t() | nil},
        template_role_ids: [role_profile_id]   # picked from selected
      }

  Returns `{:ok, %{library_id, table_name, row_count, template_role_ids}}`.
  """

  @behaviour RhoFrameworks.UseCase

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Roles
  alias RhoFrameworks.{Scope, Workbench}

  @impl true
  def describe do
    %{
      id: :pick_template,
      label: "Use similar role as a template",
      cost_hint: :instant,
      doc: "Clone a similar role profile's skills into a new framework library."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    intake = Map.get(input, :intake, %{})
    role_ids = Map.get(input, :template_role_ids, []) |> Enum.reject(&(&1 in [nil, ""]))

    cond do
      role_ids == [] ->
        {:error, :no_template_selected}

      is_nil(get_field(intake, :name)) or get_field(intake, :name) == "" ->
        {:error, :missing_framework_name}

      true ->
        do_run(scope, intake, role_ids)
    end
  end

  defp do_run(scope, intake, role_ids) do
    name = get_field(intake, :name)
    description = get_field(intake, :description) || ""

    with {:ok, %{library: lib, table: spec}} <-
           Editor.create(%{name: name, description: description}, scope),
         :ok <- DataTable.ensure_table(scope.session_id, spec.name, spec.schema),
         library_rows <- Roles.clone_skills_for_library(scope.organization_id, role_ids),
         {:ok, inserted} <- Workbench.replace_rows(scope, library_rows, table: spec.name) do
      {:ok,
       %{
         library_id: lib.id,
         table_name: spec.name,
         row_count: length(inserted),
         template_role_ids: role_ids
       }}
    end
  end

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_field(_, _), do: nil
end
