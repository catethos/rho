defmodule Rho.Stdlib.Tools.FsRead do
  @moduledoc "Tool for reading text files within the workspace."

  @behaviour Rho.Plugin

  @impl Rho.Plugin
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
      execute: fn args, _ctx -> execute(args, workspace) end
    }
  end

  defp execute(args, workspace) do
    path = args[:path]
    offset = args[:offset] || 0
    limit = args[:limit]

    full_path = Rho.Stdlib.Tools.PathUtils.resolve_path(workspace, path)

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

defmodule Rho.Stdlib.Tools.FsWrite do
  @moduledoc "Tool for writing/creating text files within the workspace."

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_mount_opts, %{workspace: workspace}), do: [tool_def(workspace)]

  defp tool_def(workspace) do
    %{
      tool:
        ReqLLM.tool(
          name: "fs_write",
          description: "Write or create a text file. Creates parent directories if needed.",
          parameter_schema: [
            path: [
              type: :string,
              required: true,
              doc: "File path (relative to workspace or absolute)"
            ],
            content: [type: :string, required: true, doc: "Content to write to the file"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, workspace) end
    }
  end

  defp execute(args, workspace) do
    path = args[:path]
    content = args[:content]

    full_path = Rho.Stdlib.Tools.PathUtils.resolve_path(workspace, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    {:ok, "Wrote #{byte_size(content)} bytes to #{full_path}"}
  rescue
    e -> {:error, Exception.message(e)}
  end
end

defmodule Rho.Stdlib.Tools.FsEdit do
  @moduledoc "Tool for find-and-replace editing of text files within the workspace."

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_mount_opts, %{workspace: workspace}), do: [tool_def(workspace)]

  defp tool_def(workspace) do
    %{
      tool:
        ReqLLM.tool(
          name: "fs_edit",
          description:
            "Find and replace text in a file. Replaces the first occurrence of 'old' with 'new', searching from the given start line.",
          parameter_schema: [
            path: [
              type: :string,
              required: true,
              doc: "File path (relative to workspace or absolute)"
            ],
            old: [type: :string, required: true, doc: "Text to find (exact match)"],
            new: [type: :string, required: true, doc: "Replacement text"],
            start: [
              type: :integer,
              doc: "Line number to start searching from (0-based, default 0)"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, workspace) end
    }
  end

  defp execute(args, workspace) do
    path = args[:path]
    old = args[:old]
    new_text = args[:new]
    start = args[:start] || 0

    full_path = Rho.Stdlib.Tools.PathUtils.resolve_path(workspace, path)
    content = File.read!(full_path)
    lines = String.split(content, "\n")
    {before, after_lines} = Enum.split(lines, start)
    section = Enum.join(after_lines, "\n")

    unless String.contains?(section, old) do
      raise "Text not found in #{path} after line #{start}"
    end

    new_section = String.replace(section, old, new_text, global: false)

    new_content =
      case before do
        [] -> new_section
        _ -> Enum.join(before, "\n") <> "\n" <> new_section
      end

    File.write!(full_path, new_content)
    {:ok, "Edited #{full_path}"}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
