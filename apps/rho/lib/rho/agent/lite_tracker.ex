defmodule Rho.Agent.LiteTracker do
  @moduledoc """
  ETS-based tracker for lightweight (Task-based) agents.

  Stores `{agent_id, task_ref, task_pid, status, result}` tuples.
  Used by `await_task` / `await_all` to locate lite workers that
  don't have a GenServer in the Elixir Registry.
  """

  @table :rho_lite_tasks

  @doc "Ensure the ETS table exists. Idempotent."
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Register a lite worker task."
  def register(agent_id, task_ref, task_pid) do
    ensure_table()
    :ets.insert(@table, {agent_id, task_ref, task_pid, :running, nil})
    :ok
  end

  @doc "Mark a lite worker as complete with a result."
  def complete(agent_id, result) do
    ensure_table()
    :ets.update_element(@table, agent_id, [{4, :done}, {5, result}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Look up a lite worker. Returns `{status, result, task_pid}` or `nil`.
  """
  def lookup(agent_id) do
    ensure_table()

    case :ets.lookup(@table, agent_id) do
      [{_, _ref, pid, status, result}] -> {status, result, pid}
      [] -> nil
    end
  end

  @doc "Remove a lite worker entry."
  def delete(agent_id) do
    ensure_table()
    :ets.delete(@table, agent_id)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
