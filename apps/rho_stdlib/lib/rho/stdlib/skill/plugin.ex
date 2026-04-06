defmodule Rho.Stdlib.Skill.Plugin do
  @moduledoc """
  Skill plugin. Surfaces discovered skills to the agent:

  - `prompt_sections/2` injects the "Available Skills" reference section.
  - `tools/2` exposes the `skill` tool for on-demand skill expansion.

  Skill discovery and parsing live on `Rho.Stdlib.Skill.Loader` / `Rho.Skill`.
  This module is the `Plugin` adapter that wires them into the turn.

  ## Same-turn injection is NOT allowed

  The `skill` tool returns expanded skill content as tool output. That
  output becomes a tape entry, and the *next* turn's prompt assembly
  picks it up. Injecting expanded content into the current turn's
  prompt mid-call would bypass the tape and break replay determinism.
  A regression test guards this invariant.
  """

  @behaviour Rho.Plugin

  alias Rho.PromptSection
  alias Rho.Stdlib.Skill.Loader

  @impl Rho.Plugin
  def tools(_opts, %{workspace: workspace} = _context) when is_binary(workspace) do
    skills = Loader.discover(workspace)
    if skills == [], do: [], else: [skill_tool(workspace, skills)]
  end

  def tools(_opts, _context), do: []

  @impl Rho.Plugin
  def prompt_sections(_opts, %{workspace: workspace} = context) when is_binary(workspace) do
    skills = Loader.discover(workspace)

    if skills == [] do
      []
    else
      messages = Map.get(context, :messages)

      expanded =
        if messages,
          do: Loader.expanded_hints(extract_user_text(messages), skills),
          else: MapSet.new()

      [
        %PromptSection{
          key: :skills,
          heading: "Available Skills",
          body: Loader.render_prompt(skills, expanded),
          kind: :reference,
          priority: :normal
        }
      ]
    end
  end

  def prompt_sections(_opts, _context), do: []

  # --- Tool definition ---

  defp skill_tool(workspace, skills) do
    %{
      tool:
        ReqLLM.tool(
          name: "skill",
          description:
            "Load a skill's full prompt content by name. Use this when you need the " <>
              "detailed instructions from a skill listed in <available_skills>.",
          parameter_schema: [
            name: [
              type: :string,
              required: true,
              doc: "The skill name to expand (e.g. \"code-review\")"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args -> execute_skill_expand(args, workspace, skills) end
    }
  end

  defp execute_skill_expand(args, _workspace, skills) do
    name = args["name"] || args[:name] || ""

    if String.trim(name) == "" do
      {:error, "name is required"}
    else
      case Enum.find(skills, &(String.downcase(&1.name) == String.downcase(name))) do
        nil ->
          available = Enum.map_join(skills, ", ", & &1.name)
          {:ok, "No skill found: \"#{name}\". Available: #{available}"}

        skill ->
          {:ok, "## Skill: #{skill.name}\n\n#{skill.body}"}
      end
    end
  end

  defp extract_user_text(messages) do
    messages
    |> Enum.filter(&(Map.get(&1, :role) == :user))
    |> Enum.map_join(" ", &to_string(Map.get(&1, :content, "")))
  end
end
