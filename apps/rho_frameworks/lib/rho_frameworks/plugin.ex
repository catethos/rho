defmodule RhoFrameworks.Plugin do
  @moduledoc """
  Plugin that provides library-centric, role-centric, and lens-centric tools
  for the Prism skill assessment domain.

  Aggregates tools from domain-specific modules:
  - `RhoFrameworks.Tools.LibraryTools` — skill library CRUD, forking, dedup
  - `RhoFrameworks.Tools.RoleTools` — role profiles, gap analysis, career ladders
  - `RhoFrameworks.Tools.LensTools` — scoring, dashboard, lens switching
  - `RhoFrameworks.Tools.SharedTools` — cross-domain utilities
  """

  @behaviour Rho.Plugin

  alias RhoFrameworks.Tools.{LibraryTools, RoleTools, LensTools, SharedTools}
  alias RhoFrameworks.Library

  @impl Rho.Plugin
  def tools(_mount_opts, %{organization_id: nil}), do: []
  def tools(_mount_opts, %{organization_id: _} = context), do: build_tools(context)
  def tools(_mount_opts, _context), do: []

  @impl Rho.Plugin
  def prompt_sections(_mount_opts, context) do
    [static_section(), library_context_section(context)]
    |> Enum.reject(&is_nil/1)
  end

  defp static_section do
    """
    # Skill Library & Role Profile System

    Two data table modes:

    **Library Mode** — category, cluster, skill_name, skill_description, proficiency_levels. Use `save_to_library` to persist.
    **Role Profile Mode** — category, cluster, skill_name, skill_description, required_level, required. Use `save_role_profile` to persist.
    """
  end

  defp library_context_section(%{organization_id: org_id}) when is_binary(org_id) do
    case Library.library_summary(org_id) do
      [] ->
        nil

      libraries ->
        lines =
          Enum.map_join(libraries, "\n", fn lib ->
            "- **#{lib.name}** (id: #{lib.id}, #{version_label(lib)}, #{lib.skill_count} skills) — categories: #{Enum.map_join(lib.categories, ", ", & &1.category)}"
          end)

        """
        # Existing Skill Libraries

        #{lines}
        """
    end
  end

  defp library_context_section(_), do: nil

  defp version_label(%{version: v}) when not is_nil(v), do: "v#{v}"
  defp version_label(%{immutable: true}), do: "immutable"
  defp version_label(_), do: "draft"

  defp build_tools(context) do
    LibraryTools.__tools__(context) ++
      RoleTools.__tools__(context) ++
      LensTools.__tools__(context) ++
      SharedTools.__tools__(context)
  end
end
