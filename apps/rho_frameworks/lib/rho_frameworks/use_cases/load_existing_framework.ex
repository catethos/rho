defmodule RhoFrameworks.UseCases.LoadExistingFramework do
  @moduledoc """
  Hydrate an existing org-owned framework into the session's `library:<name>`
  named table so the `:identify_gaps` and `:generate` steps on the
  `extend_existing` branch have something to read.

  Wraps `RhoFrameworks.Workbench.load_framework/2` for the library skills.
  Role profiles attached to the library are counted but not loaded into
  the `role_profile` named table (that table is per-role, not per-library
  — loading happens on demand via the role tools).

  Input: `%{library_id: String.t()}`.

  Returns `{:ok, %{library_id, library_name, table_name, skill_count, role_count, has_proficiency}}`
  on success. The summary is stored under `summaries[:load_existing_library]`
  — separate from `summaries[:similar_roles]` so the `:good_matches` /
  `:no_similar_roles` guards stay intact.

  `has_proficiency` is `true` when every loaded skill has a non-empty
  `proficiency_levels` list. Edit-flow uses this to skip the regenerate-
  proficiency step on libraries whose skills are already populated (e.g.
  forked from a published standard).
  """

  @behaviour RhoFrameworks.UseCase

  alias RhoFrameworks.{Library, Scope, Workbench}

  @impl true
  def describe do
    %{
      id: :load_existing_framework,
      label: "Load existing framework",
      cost_hint: :instant,
      doc: "Hydrate an existing framework's skills into the session's library table."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    library_id = Map.get(input, :library_id) || Map.get(input, "library_id")

    cond do
      is_nil(library_id) or library_id == "" ->
        {:error, :missing_library_id}

      true ->
        do_run(library_id, scope)
    end
  end

  defp do_run(library_id, %Scope{} = scope) do
    case Workbench.load_framework(scope, library_id) do
      {:ok, %{library: lib, table: table, count: count}} ->
        role_count = length(Library.list_role_profiles_for_library(lib.id))
        has_proficiency = library_has_proficiency?(lib.id)

        {:ok,
         %{
           library_id: lib.id,
           library_name: lib.name,
           table_name: table,
           skill_count: count,
           role_count: role_count,
           has_proficiency: has_proficiency
         }}

      {:error, :not_found} ->
        {:error, :library_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp library_has_proficiency?(library_id) do
    skills = Library.list_skills(library_id)

    skills != [] and
      Enum.all?(skills, fn skill ->
        is_list(skill.proficiency_levels) and skill.proficiency_levels != []
      end)
  end
end
