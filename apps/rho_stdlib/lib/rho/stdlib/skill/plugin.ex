defmodule Rho.Stdlib.Skill.Plugin do
  @moduledoc """
  Skill plugin — exposes the `skill` tool for on-demand workflow expansion.

  Skill names are inlined into the tool's parameter `@desc` in the BAML
  schema (following the GenBaml pattern), so no separate prompt section is
  needed. The LLM sees available skills directly in the schema line:

      | skill(name: string @desc(create-framework, import-framework, ...))

  Skill discovery and parsing live on `Rho.Stdlib.Skill.Loader` / `Rho.Skill`.
  """

  @behaviour Rho.Plugin

  alias Rho.Stdlib.Skill.Loader

  @impl Rho.Plugin
  def tools(_opts, %{workspace: workspace} = _context) when is_binary(workspace) do
    skills = Loader.discover(workspace)
    if skills == [], do: [], else: [skill_tool(workspace, skills)]
  end

  def tools(_opts, _context), do: []

  # No prompt_sections — skill names are inlined into the tool's
  # parameter @desc via the BAML schema, following the GenBaml pattern.

  # --- Tool definition ---

  defp skill_tool(workspace, skills) do
    skill_names = Enum.map_join(skills, ", ", & &1.name)

    %{
      tool:
        ReqLLM.tool(
          name: "skill",
          description: "Load a skill's workflow instructions by name.",
          parameter_schema: [
            name: [
              type: :string,
              required: true,
              doc: skill_names
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, ctx -> execute_skill_expand(args, workspace, skills, ctx) end
    }
  end

  defp execute_skill_expand(args, _workspace, skills, ctx) do
    name = args[:name] || ""

    if String.trim(name) == "" do
      {:error, "name is required"}
    else
      case Enum.find(skills, &(String.downcase(&1.name) == String.downcase(name))) do
        nil ->
          available = Enum.map_join(skills, ", ", & &1.name)
          {:ok, "No skill found: \"#{name}\". Available: #{available}"}

        skill ->
          body = "## Skill: #{skill.name}\n\n#{skill.body}"

          case render_uses_tools(skill.uses, ctx) do
            "" -> {:ok, body}
            tool_hints -> {:ok, body <> "\n\n## Workflow tools\n" <> tool_hints}
          end
      end
    end
  end

  defp render_uses_tools([], _ctx), do: ""

  defp render_uses_tools(tool_names, ctx) do
    all_tools = Rho.PluginRegistry.collect_tools(ctx)
    names_set = MapSet.new(tool_names)

    all_tools
    |> Enum.filter(fn td -> MapSet.member?(names_set, td.tool.name) end)
    |> Enum.map_join("\n", fn td ->
      params = render_tool_params(td.tool.parameter_schema || [])
      desc = td.tool.description
      line = "  | #{td.tool.name}(#{params})"
      if desc, do: "#{line}  // #{desc}", else: line
    end)
  end

  defp render_tool_params([]), do: ""

  defp render_tool_params(fields) do
    Enum.map_join(fields, ", ", fn {name, opts} ->
      type = Keyword.get(opts, :type, :string)
      optional = if Keyword.get(opts, :required, false), do: "", else: "?"
      doc = Keyword.get(opts, :doc)
      base = "#{name}#{optional}: #{type}"
      if doc, do: "#{base} @desc(#{doc})", else: base
    end)
  end
end
