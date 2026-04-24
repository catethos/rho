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

  @impl Rho.Plugin
  def tools(_mount_opts, %{organization_id: nil}), do: []

  def tools(mount_opts, %{organization_id: _} = context) do
    all = build_tools(context)
    mark_deferred(all, mount_opts)
  end

  def tools(_mount_opts, _context), do: []

  # No prompt_sections — library context is available via
  # manage_library(action: "list") on demand, saving tokens per turn.

  defp build_tools(context) do
    LibraryTools.__tools__(context) ++
      RoleTools.__tools__(context) ++
      LensTools.__tools__(context) ++
      SharedTools.__tools__(context)
  end

  defp mark_deferred(tools, mount_opts) do
    case Keyword.get(mount_opts, :deferred) do
      nil ->
        tools

      names when is_list(names) ->
        deferred = MapSet.new(names, &to_string/1)

        Enum.map(tools, fn tool_def ->
          if MapSet.member?(deferred, tool_def.tool.name),
            do: Map.put(tool_def, :deferred, true),
            else: tool_def
        end)
    end
  end
end
