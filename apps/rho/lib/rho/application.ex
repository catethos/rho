defmodule Rho.Application do
  @moduledoc false

  use Application

  @impl true
  def prep_stop(_state) do
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
    [".env", System.get_env("DOTENV_FILE")]
    |> Enum.reject(&is_nil/1)
    |> Dotenvy.source()

    Rho.Telemetry.attach()

    tape_module = Rho.Config.tape_module()

    tape_children =
      if function_exported?(tape_module, :children, 1) do
        tape_module.children([])
      else
        []
      end

    # Create agent registry ETS table (once, before any workers start)
    Rho.Agent.Registry.init_table()

    # Create lite-worker tracker ETS table here so the application master
    # owns it. Otherwise the first short-lived tool task that spawns a
    # lite worker becomes the owner, and the table dies with it — leaving
    # later `await_task`/`await_all` calls unable to find any worker.
    Rho.Agent.LiteTracker.ensure_table()

    children =
      [
        {Phoenix.PubSub, name: Rho.PubSub},
        {Registry, keys: :unique, name: Rho.AgentRegistry},
        {Task.Supervisor, name: Rho.TaskSupervisor},
        Rho.PluginRegistry,
        Rho.TransformerRegistry,
        Rho.SessionOwners,
        # Caps total concurrent LLM streams below the Finch pool size so
        # pool exhaustion becomes the exceptional path, not the norm.
        {Rho.LLM.Admission, capacity: admission_capacity()}
      ] ++
        tape_children ++
        [
          Rho.Agent.Supervisor,
          {Registry, keys: :unique, name: Rho.EventLogRegistry},
          {DynamicSupervisor, name: Rho.Agent.EventLog.Supervisor, strategy: :one_for_one}
        ]

    opts = [strategy: :one_for_one, name: Rho.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Admission capacity should sit below the Finch pool `count` so the
  # pool retains headroom for retries and transient surges. Override in
  # config for tuning without touching code.
  defp admission_capacity do
    Application.get_env(:rho, :llm_admission_capacity, 200)
  end
end
