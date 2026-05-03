defmodule Rho.Stdlib.Application do
  @moduledoc false

  use Application

  @py_agent_env_keys ~w(OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY)

  @impl true
  def start(_type, _args) do
    Rho.Stdlib.Skill.Loader.init_cache_table()

    children = [
      {Registry, keys: :unique, name: Rho.PythonRegistry},
      {DynamicSupervisor, name: Rho.Stdlib.Tools.Python.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Rho.Stdlib.DataTable.Registry},
      {DynamicSupervisor, name: Rho.Stdlib.DataTable.Supervisor, strategy: :one_for_one},
      Rho.Stdlib.DataTable.SessionJanitor
    ]

    opts = [strategy: :one_for_one, name: Rho.Stdlib.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    maybe_setup_python()
    maybe_setup_erlang_python()
    register_builtin_plugins()

    {:ok, pid}
  end

  defp register_builtin_plugins do
    Rho.TransformerRegistry.register(Rho.Stdlib.Transformers.SubagentNudge)

    for agent_name <- Rho.AgentConfig.agent_names() do
      config = Rho.AgentConfig.agent(agent_name)

      for plugin_entry <- config.plugins do
        register_agent_plugin(agent_name, plugin_entry)
      end
    end
  end

  defp register_agent_plugin(agent_name, plugin_entry) do
    {mod, opts} = Rho.Stdlib.resolve_plugin(plugin_entry)

    Rho.PluginRegistry.register(mod,
      scope: {:agent, agent_name},
      opts: opts
    )

    if function_exported?(mod, :transform, 3) do
      Rho.TransformerRegistry.register(mod,
        scope: {:agent, agent_name},
        opts: opts
      )
    end
  end

  defp maybe_setup_python do
    if :python in all_plugin_names() do
      RhoPython.declare_deps(Rho.AgentConfig.python_deps())
      :ok = RhoPython.await_ready()
    end
  end

  defp maybe_setup_erlang_python do
    if :py_agent in all_plugin_names() do
      py_agents_dir = Path.join(:code.priv_dir(:rho_stdlib) |> to_string(), "py_agents")
      RhoPython.start_erlang_python(py_agents_dir, @py_agent_env_keys)
    end
  end

  defp all_plugin_names do
    Rho.AgentConfig.agent_names()
    |> Enum.flat_map(fn name -> Rho.AgentConfig.agent(name).plugins end)
    |> Enum.map(fn
      {name, _opts} when is_atom(name) -> name
      name when is_atom(name) -> name
    end)
  end
end
