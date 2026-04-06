defmodule Rho.Agent.Supervisor do
  @moduledoc """
  DynamicSupervisor for all agent worker processes.

  One flat supervisor for all agents across all sessions.
  Session scoping is logical (via session_id), not structural.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new agent worker under this supervisor."
  def start_worker(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Rho.Agent.Worker, opts})
  end

  @doc "List all active agent worker pids."
  def active_agents do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.filter(fn {_, pid, _, _} -> is_pid(pid) end)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end
end
