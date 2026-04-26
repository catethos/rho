defmodule Rho.Stdlib.Application do
  @moduledoc false

  use Application

  require Logger

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

    maybe_init_python()
    maybe_init_erlang_python()
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

  defp maybe_init_python do
    if :python in all_plugin_names() do
      init_pythonx()
    end
  end

  defp init_pythonx do
    deps = Rho.AgentConfig.python_deps()

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
    Rho.AgentConfig.agent_names()
    |> Enum.flat_map(fn name -> Rho.AgentConfig.agent(name).plugins end)
    |> Enum.map(fn
      {name, _opts} when is_atom(name) -> name
      name when is_atom(name) -> name
    end)
  end
end
