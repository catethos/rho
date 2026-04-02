defmodule Rho.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def prep_stop(_state) do
    # Ensure sandbox cleanup on application shutdown (e.g., Ctrl-C → abort)
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

    memory_mod = Rho.Config.memory_module()

    memory_children =
      if function_exported?(memory_mod, :children, 1) do
        memory_mod.children([])
      else
        []
      end

    # Create agent registry ETS table (once, before any workers start)
    Rho.Agent.Registry.init_table()

    children =
      [
        {Registry, keys: :unique, name: Rho.AgentRegistry},
        {Registry, keys: :unique, name: Rho.SubagentRegistry},
        {Registry, keys: :unique, name: Rho.PythonRegistry},
        {Task.Supervisor, name: Rho.TaskSupervisor},
        {DynamicSupervisor, name: Rho.Tools.Python.Supervisor, strategy: :one_for_one},
        Rho.MountRegistry,
        Rho.Comms.SignalBus,
        Rho.Observatory
      ] ++ memory_children ++ [
        Rho.Plugins.Subagent.Supervisor,
        Rho.Agent.Supervisor,
        {Registry, keys: :unique, name: Rho.EventLogRegistry},
        {DynamicSupervisor, name: Rho.Session.EventLog.Supervisor, strategy: :one_for_one},
        Rho.CLI
      ] ++ web_children()

    opts = [strategy: :one_for_one, name: Rho.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Initialize Python interpreter if any agent uses the :python tool
    maybe_init_python()

    # Initialize erlang_python if any agent uses :py_agent mount
    maybe_init_erlang_python()

    # Register built-in mounts
    register_builtin_mounts()

    {:ok, pid}
  end

  defp register_builtin_mounts do
    # Infrastructure mount — always registered globally
    Rho.MountRegistry.register(Rho.Builtin)

    # Register config-driven mounts for each agent
    for agent_name <- Rho.Config.agent_names() do
      config = Rho.Config.agent(agent_name)

      for mount_entry <- config.mounts do
        {mod, opts} = Rho.Config.resolve_mount(mount_entry)

        Rho.MountRegistry.register(mod,
          scope: {:agent, agent_name},
          opts: opts
        )
      end
    end
  end

  defp maybe_init_python do
    all_mounts =
      Rho.Config.agent_names()
      |> Enum.flat_map(fn name -> Rho.Config.agent(name).mounts end)
      |> Enum.map(fn
        {name, _opts} when is_atom(name) -> name
        name when is_atom(name) -> name
      end)

    if :python in all_mounts do
      deps = Rho.Config.python_deps()

      dep_lines =
        deps
        |> Enum.map(&"  \"#{&1}\",")
        |> Enum.join("\n")

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
  end

  defp maybe_init_erlang_python do
    all_mounts =
      Rho.Config.agent_names()
      |> Enum.flat_map(fn name -> Rho.Config.agent(name).mounts end)
      |> Enum.map(fn
        {name, _opts} when is_atom(name) -> name
        name when is_atom(name) -> name
      end)

    if :py_agent in all_mounts do
      {:ok, _} = Application.ensure_all_started(:erlang_python)

      # Add priv/py_agents to Python's sys.path so agent modules are importable
      py_agents_dir = Path.join(:code.priv_dir(:rho) |> to_string(), "py_agents")

      :py.exec("""
      import sys, os
      if '#{py_agents_dir}' not in sys.path:
          sys.path.insert(0, '#{py_agents_dir}')
      """)

      # Forward relevant env vars to Python (Dotenvy loads into Elixir but not OS env)
      for key <- ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] do
        case System.get_env(key) do
          nil -> :ok
          val ->
            escaped = String.replace(val, "\\", "\\\\") |> String.replace("'", "\\'")
            :py.exec("os.environ['#{key}'] = '#{escaped}'")
        end
      end

      # Activate venv if configured
      venv_path = System.get_env("RHO_PY_AGENT_VENV")

      if venv_path do
        :py.activate_venv(String.to_charlist(venv_path))
      end

      Logger.info("erlang_python initialized, py_agents path: #{py_agents_dir}")
    end
  end

  defp web_children do
    config = Rho.Config.web()

    if config.enabled do
      [
        {Phoenix.PubSub, name: Rho.PubSub},
        RhoWeb.Endpoint
      ]
    else
      []
    end
  end
end
