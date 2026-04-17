defmodule Rho.Stdlib.Tools.Bash do
  @moduledoc false
  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_mount_opts, %{workspace: workspace}), do: [tool_def(workspace)]
  def tools(_mount_opts, _context), do: [tool_def(nil)]

  defp tool_def(workspace) do
    %{
      tool:
        ReqLLM.tool(
          name: "bash",
          description: "Execute a shell command and return its output",
          parameter_schema: [
            cmd: [type: :string, required: true, doc: "The shell command to execute"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, workspace) end
    }
  end

  @doc "Executes a bash command. Returns {:ok, output} or {:error, reason}."
  def execute(%{"cmd" => cmd}, workspace), do: execute(%{cmd: cmd}, workspace)

  def execute(%{cmd: cmd}, workspace) do
    opts = [stderr_to_stdout: true]
    opts = if workspace, do: Keyword.put(opts, :cd, workspace), else: opts

    case System.cmd("sh", ["-c", cmd], opts) do
      {output, 0} -> {:ok, output || "(no output)"}
      {output, code} -> {:error, "exit code #{code}: #{output}"}
    end
  end
end
