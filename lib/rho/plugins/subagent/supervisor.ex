defmodule Rho.Plugins.Subagent.Supervisor do
  @moduledoc "DynamicSupervisor for Subagent.Worker processes."

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_worker(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Rho.Plugins.Subagent.Worker, opts})
  end

  @impl true
  def init(_init_arg) do
    # Create the subagent status ETS table here so it's owned by the supervisor
    # (long-lived process), not by individual workers
    if :ets.whereis(:rho_subagent_status) == :undefined do
      :ets.new(:rho_subagent_status, [:named_table, :public, :set, read_concurrency: true])
    end

    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
