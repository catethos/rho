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

  @doc """
  Classifies an exception raised inside an fs tool into a typed error
  tuple. Distinguishes path-escape errors from generic failures so
  callers can return `{:error, {:path_escape, msg}}` consistently.
  """
  def classify_rescue(e, fallback) when is_atom(fallback) do
    msg = Exception.message(e)

    if match?(%RuntimeError{}, e) and String.contains?(msg, "Path escapes workspace") do
      {:path_escape, msg}
    else
      {fallback, msg}
    end
  end
end
