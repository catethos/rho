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

  @doc """
  Await a tracked task's result. Blocks until the task completes or times out.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec await(String.t(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def await(agent_id, timeout \\ 300_000) do
    case lookup(agent_id) do
      nil ->
        {:error, "unknown lite agent: #{agent_id}"}

      {:done, result, _pid} ->
        delete(agent_id)
        result

      {:running, _result, pid} ->
        await_running(agent_id, pid, timeout)
    end
  end

  defp await_running(agent_id, pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        case lookup(agent_id) do
          {:done, result, _} ->
            delete(agent_id)
            result

          _ ->
            {:error, "lite agent completed but no result found"}
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        delete(agent_id)
        {:error, "lite agent crashed: #{inspect(reason)}"}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, "lite agent timed out after #{div(timeout, 1000)}s"}
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
