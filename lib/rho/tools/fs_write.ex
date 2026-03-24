defmodule Rho.Tools.FsWrite do
  @moduledoc "Tool for writing/creating text files within the workspace."

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{workspace: workspace}), do: [tool_def(workspace)]

  defp tool_def(workspace) do
    %{
      tool:
        ReqLLM.tool(
          name: "fs_write",
          description: "Write or create a text file. Creates parent directories if needed.",
          parameter_schema: [
            path: [type: :string, required: true, doc: "File path (relative to workspace or absolute)"],
            content: [type: :string, required: true, doc: "Content to write to the file"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args -> execute(args, workspace) end
    }
  end

  defp execute(args, workspace) do
    path = args["path"] || args[:path]
    content = args["content"] || args[:content]

    full_path = Rho.Tools.PathUtils.resolve_path(workspace, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    {:ok, "Wrote #{byte_size(content)} bytes to #{full_path}"}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
