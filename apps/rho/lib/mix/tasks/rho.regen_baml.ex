defmodule Mix.Tasks.Rho.RegenBaml do
  @moduledoc """
  Regenerate the dynamic `action.baml` for an agent, without running it.

  Resolves the agent's plugins → tool_defs → writes
  `apps/rho/priv/baml_src/dynamic/action.baml` via `RhoBaml.SchemaWriter.write!`.

  Useful for inspecting the generated schema after editing `SchemaWriter`
  without needing the LV/agent loop.

      mix rho.regen_baml spreadsheet
      mix rho.regen_baml default
  """
  use Mix.Task
  @shortdoc "Regenerate dynamic action.baml for an agent (no LLM call)"
  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:rho_stdlib)
    {:ok, _} = Application.ensure_all_started(:rho_frameworks)
    valid = Rho.AgentConfig.agent_names() |> Map.new(&{Atom.to_string(&1), &1})

    agent_name =
      case args do
        [name] ->
          Map.get(valid, name) ||
            Mix.raise(
              "Unknown agent #{inspect(name)}. Known: #{Enum.map_join(valid, ", ", fn {k, _} -> k end)}"
            )

        _ ->
          Mix.raise("Usage: mix rho.regen_baml <agent_name>")
      end

    config = Rho.AgentConfig.agent(agent_name)

    context = %Rho.Context{
      agent_name: agent_name,
      tape_module: Rho.Tape.Projection.JSONL,
      workspace: ".",
      depth: 0,
      organization_id: "regen-baml",
      user_id: "regen-baml",
      session_id: "regen-baml"
    }

    defs = Rho.PluginRegistry.collect_tools(context)
    baml_path = RhoBaml.baml_path(:rho)
    :ok = RhoBaml.SchemaWriter.write!(baml_path, defs, model: config.model)
    target = Path.join([baml_path, "dynamic", "action.baml"])
    Mix.shell().info("Wrote #{target} (#{length(defs)} tool variants)")
  end
end
