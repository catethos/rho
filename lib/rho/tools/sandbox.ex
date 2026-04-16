defmodule Rho.Tools.Sandbox do
  @moduledoc """
  Tools for inspecting and managing the sandbox filesystem.

  Provides `sandbox_diff` to show changes and `sandbox_commit` to apply
  them to the real workspace. Only available when sandbox mode is active.
  """

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{sandbox: %Rho.Sandbox{} = sandbox}),
    do: [diff_tool(sandbox), commit_tool(sandbox)]

  def tools(_mount_opts, _context), do: []

  @impl Rho.Mount
  def bindings(_mount_opts, %{sandbox: %Rho.Sandbox{} = sandbox}) do
    file_count =
      case File.ls(sandbox.mount_path) do
        {:ok, files} -> length(files)
        _ -> 0
      end

    [
      %{
        name: "sandbox_workspace",
        kind: :filesystem,
        size: file_count,
        access: :tool,
        persistence: :session,
        summary: "Sandbox overlay at #{sandbox.mount_path}"
      }
    ]
  end

  def bindings(_mount_opts, _context), do: []

  defp diff_tool(sandbox) do
    %{
      tool:
        ReqLLM.tool(
          name: "sandbox_diff",
          description:
            "Show all file changes made in the sandbox compared to the original workspace. " <>
              "Lists added (A), modified (M), and deleted (D) files.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args -> Rho.Sandbox.diff(sandbox) end
    }
  end

  defp commit_tool(sandbox) do
    %{
      tool:
        ReqLLM.tool(
          name: "sandbox_commit",
          description:
            "Apply all sandbox changes to the real workspace. " <>
              "Copies modified files from the sandbox overlay to the actual filesystem. " <>
              "This is irreversible — use sandbox_diff first to review changes.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        case Rho.Sandbox.commit(sandbox) do
          :ok -> {:ok, "Changes committed to #{sandbox.workspace}"}
          error -> error
        end
      end
    }
  end
end
