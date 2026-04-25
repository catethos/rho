defmodule Rho.CLI.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def prep_stop(_state) do
    # Ensure sandbox cleanup on application shutdown
    for pid <- Rho.Agent.Supervisor.active_agents() do
      try do
        GenServer.stop(pid, :shutdown, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @impl true
  def start(_type, _args) do
    sources = [".env", System.get_env("DOTENV_FILE")] |> Enum.reject(&is_nil/1)
    Dotenvy.source(sources)

    # Initialize skill loader cache ETS table
    Rho.Stdlib.Skill.Loader.init_cache_table()

    children = [
      Rho.CLI.Repl
    ]

    opts = [strategy: :one_for_one, name: Rho.CLI.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Initialize Python interpreter if any agent uses the :python tool
    maybe_init_python()

    # Initialize erlang_python if any agent uses :py_agent mount
    maybe_init_erlang_python()

    # Register built-in plugins
    register_builtin_plugins()

    {:ok, pid}
  end

  defp register_builtin_plugins do
    # Infrastructure plugin — always registered globally
    Rho.PluginRegistry.register(Rho.Stdlib.Builtin)

    # Register config-driven plugins for each agent
    for agent_name <- Rho.CLI.Config.agent_names() do
      config = Rho.CLI.Config.agent(agent_name)

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

    # Also register as transformer if it implements the behaviour
    if function_exported?(mod, :transform, 3) do
      Rho.TransformerRegistry.register(mod,
        scope: {:agent, agent_name},
        opts: opts
      )
    end
  end

  defp maybe_init_python do
    if :python in all_plugin_names() do
      init_pythonx()
    end
  end

  defp init_pythonx do
    deps = Rho.CLI.Config.python_deps()

    dep_lines = Enum.map_join(deps, "\n", &"  \"#{&1}\",")

    pyproject = """
    [project]
    name = "rho-python"
    version = "0.0.0"
    requires-python = ">=3.11"
    dependencies = [
    #{dep_lines}
    ]
    """

    Logger.info("Initializing Pythonx with deps: #{inspect(deps)}")
    Pythonx.uv_init(pyproject)
  end

  defp maybe_init_erlang_python do
    if :py_agent in all_plugin_names() do
      init_erlang_python()
    end
  end

  defp init_erlang_python do
    {:ok, _} = Application.ensure_all_started(:erlang_python)

    py_agents_dir = Path.join(:code.priv_dir(:rho_stdlib) |> to_string(), "py_agents")

    :py.exec("""
    import sys, os
    if '#{py_agents_dir}' not in sys.path:
        sys.path.insert(0, '#{py_agents_dir}')
    """)

    export_env_keys_to_python()

    venv_path = System.get_env("RHO_PY_AGENT_VENV")

    if venv_path do
      :py.activate_venv(String.to_charlist(venv_path))
    end

    Logger.info("erlang_python initialized, py_agents path: #{py_agents_dir}")
  end

  defp export_env_keys_to_python do
    for key <- ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] do
      case System.get_env(key) do
        nil ->
          :ok

        val ->
          escaped = String.replace(val, "\\", "\\\\") |> String.replace("'", "\\'")
          :py.exec("os.environ['#{key}'] = '#{escaped}'")
      end
    end
  end

  defp all_plugin_names do
    Rho.CLI.Config.agent_names()
    |> Enum.flat_map(fn name -> Rho.CLI.Config.agent(name).plugins end)
    |> Enum.map(fn
      {name, _opts} when is_atom(name) -> name
      name when is_atom(name) -> name
    end)
  end
end
