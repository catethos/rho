defmodule Rho.Stdlib.Skill.Plugin do
  @moduledoc """
  Skill plugin — exposes the `skill` tool for on-demand workflow expansion.

  Skill names are inlined into the tool's parameter `@desc` in the BAML
  schema (following the GenBaml pattern), so no separate prompt section is
  needed for the menu. The LLM sees available skills directly in the
  schema line:

      | skill(name: string @desc(create-framework, import-framework, ...))

  ## Preloading

  Pass `preload: ["<skill-name>", ...]` in plugin opts to render those
  skills' bodies into the system prompt up-front. This skips the LLM
  round-trip of `skill(name: "...")` for the most common workflow.
  Preloaded skills are removed from the `skill` tool's `@desc` menu so
  the LLM doesn't redundantly call it.

  Skill discovery and parsing live on `Rho.Stdlib.Skill.Loader` / `Rho.Skill`.
  """

  @behaviour Rho.Plugin

  alias Rho.Stdlib.Skill.Loader

  @impl Rho.Plugin
  def tools(opts, %{workspace: workspace} = _context) when is_binary(workspace) do
    preload = preload_names(opts)
    skills = Loader.discover(workspace)
    callable = Enum.reject(skills, &(String.downcase(&1.name) in preload))

    cond do
      skills == [] -> []
      callable == [] -> []
      true -> [skill_tool(workspace, skills, callable)]
    end
  end

  def tools(_opts, _context), do: []

  @impl Rho.Plugin
  def prompt_sections(opts, %{workspace: workspace} = _ctx) when is_binary(workspace) do
    preload = preload_names(opts)

    if preload == [] do
      []
    else
      workspace
      |> Loader.discover()
      |> Enum.filter(&(String.downcase(&1.name) in preload))
      |> Enum.map(&preloaded_section/1)
    end
  end

  def prompt_sections(_opts, _context), do: []

  defp preload_names(opts) do
    opts
    |> Keyword.get(:preload, [])
    |> Enum.map(&String.downcase/1)
  end

  defp preloaded_section(skill) do
    body =
      "Preloaded — do NOT call `skill(name: \"#{skill.name}\")` for this; the workflow is below.\n\n" <>
        skill.body

    %Rho.PromptSection{
      key: :"skill_#{skill.name}",
      heading: "Skill: #{skill.name}",
      body: body,
      kind: :reference,
      priority: :normal
    }
  end

  # --- Tool definition ---

  defp skill_tool(workspace, all_skills, callable_skills) do
    skill_names = Enum.map_join(callable_skills, ", ", & &1.name)

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
      execute: fn args, ctx -> execute_skill_expand(args, workspace, all_skills, ctx) end
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
