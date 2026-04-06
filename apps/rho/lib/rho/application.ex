defmodule Rho.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    tape_module = Rho.Config.tape_module()

    tape_children =
      if function_exported?(tape_module, :children, 1) do
        tape_module.children([])
      else
        []
      end

    # Create agent registry ETS table (once, before any workers start)
    Rho.Agent.Registry.init_table()

    children =
      [
        {Registry, keys: :unique, name: Rho.AgentRegistry},
        {Task.Supervisor, name: Rho.TaskSupervisor},
        Rho.PluginRegistry,
        Rho.TransformerRegistry,
        Rho.Comms.SignalBus
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
end
