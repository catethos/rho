defmodule Rho.Tools.FsRead do
  @moduledoc "Tool for reading text files within the workspace."

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{workspace: workspace}), do: [tool_def(workspace)]

  defp tool_def(workspace) do
    %{
      tool:
        ReqLLM.tool(
          name: "fs_read",
          description: "Read a text file. Returns file contents with optional line slicing.",
          parameter_schema: [
            path: [
              type: :string,
              required: true,
              doc: "File path (relative to workspace or absolute)"
            ],
            offset: [
              type: :integer,
              doc: "Line offset to start reading from (0-based, default 0)"
            ],
            limit: [type: :integer, doc: "Maximum number of lines to return"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args -> execute(args, workspace) end
    }
  end

  defp execute(args, workspace) do
    path = args["path"] || args[:path]
    offset = args["offset"] || args[:offset] || 0
    limit = args["limit"] || args[:limit]

    full_path = Rho.Tools.PathUtils.resolve_path(workspace, path)

    case File.read(full_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        slice =
          if limit,
            do: Enum.slice(lines, offset, limit),
            else: Enum.drop(lines, offset)

        {:ok, Enum.join(slice, "\n")}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
