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
      execute: fn args -> execute(args, workspace) end
    }
  end

  defp execute(args, workspace) do
    path = args["path"] || args[:path]
    old = args["old"] || args[:old]
    new_text = args["new"] || args[:new]
    start = args["start"] || args[:start] || 0

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
