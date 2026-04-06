defmodule Rho.Stdlib.Tools.PathUtils do
  @moduledoc "Resolves paths relative to workspace, preventing escape."

  def resolve_path(workspace, raw_path) do
    expanded_workspace = Path.expand(workspace)

    full =
      if Path.type(raw_path) == :absolute do
        Path.expand(raw_path)
      else
        Path.join(expanded_workspace, raw_path) |> Path.expand()
      end

    unless String.starts_with?(full, expanded_workspace) do
      raise "Path escapes workspace: #{raw_path}"
    end

    full
  end
end
