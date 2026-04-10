defmodule RhoWeb.Workspace.Registry do
  @moduledoc """
  Explicit registry of workspace modules.

  Workspace modules are listed here rather than discovered at runtime,
  which is reliable in releases and predictable in dev reload.

  Each entry must implement the `RhoWeb.Workspace` behaviour.
  """

  @workspaces [
    RhoWeb.Workspaces.DataTable,
    RhoWeb.Workspaces.Chatroom,
    RhoWeb.Workspaces.LensDashboard
  ]

  @doc "All registered workspace modules."
  def all, do: @workspaces

  @doc "Look up a workspace module by its key atom."
  def get(key) when is_atom(key) do
    Enum.find(@workspaces, fn mod -> mod.key() == key end)
  end

  @doc """
  Return a map of `%{key => workspace_module}` for all registered workspaces.
  """
  def to_map do
    Map.new(@workspaces, fn mod -> {mod.key(), mod} end)
  end
end
