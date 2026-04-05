defmodule Rho.Skills do
  @moduledoc """
  Unified skills extension. Discovers SKILL.md files, injects the skills
  list into the system prompt, and provides the `skill` tool for the LLM
  to load full skill content at runtime.
  """

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{workspace: workspace} = _context) when is_binary(workspace) do
    skills = Rho.Skill.discover(workspace)
    if skills == [], do: [], else: [skill_tool(workspace, skills)]
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Mount
  def prompt_sections(_mount_opts, %{workspace: workspace} = context) when is_binary(workspace) do
    alias Rho.Mount.PromptSection

    skills = Rho.Skill.discover(workspace)

    if skills == [] do
      []
    else
      messages = Map.get(context, :messages)

      expanded =
        if messages,
          do: Rho.Skill.expanded_hints(extract_user_text(messages), skills),
          else: MapSet.new()

      [
        %PromptSection{
          key: :skills,
          heading: "Available Skills",
          body: Rho.Skill.render_prompt(skills, expanded),
          kind: :reference,
          priority: :normal
        }
      ]
    end
  end

  def prompt_sections(_mount_opts, _context), do: []

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
