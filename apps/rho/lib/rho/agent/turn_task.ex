defmodule Rho.Agent.TurnTask do
  @moduledoc """
  Bookkeeping for the runner task owned by `Rho.Agent.Worker`.

  The worker still owns the GenServer lifecycle and turn construction. This
  module owns the operational mechanics of starting, cancelling, and watching
  the task process that runs a turn.
  """

  require Logger

  alias Rho.Agent.Registry, as: AgentRegistry

  @turn_watchdog_interval 30_000
  @turn_inactivity_limit 60_000

  @doc """
  Starts a supervised turn task and updates worker state bookkeeping.
  """
  @spec start(struct(), String.t(), term(), term(), (-> term())) :: struct()
  def start(state, turn_id, task_id, persistent_tools, task_fun) when is_function(task_fun, 0) do
    task = Task.Supervisor.async_nolink(Rho.TaskSupervisor, task_fun)

    AgentRegistry.update_status(state.agent_id, :busy)
    maybe_publish_task_accepted(state, task_id)
    schedule_watchdog()

    %{
      state
      | status: :busy,
        task_ref: task.ref,
        task_pid: task.pid,
        current_turn_id: turn_id,
        persistent_tools: persistent_tools,
        current_task_id: task_id,
        last_activity_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Requests shutdown for the active task and marks the worker as cancelling.
  """
  @spec cancel(struct()) :: struct()
  def cancel(%{status: :busy, task_pid: pid} = state) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    %{state | status: :cancelling}
  end

  def cancel(state), do: state

  @doc """
  Enforces the turn inactivity watchdog.

  Options exist for focused tests; production callers use the default limits.
  """
  @spec handle_watchdog(struct(), keyword()) :: struct()
  def handle_watchdog(state, opts \\ [])

  def handle_watchdog(%{status: :busy, task_pid: pid} = state, opts) when is_pid(pid) do
    inactivity_limit = Keyword.get(opts, :inactivity_limit, @turn_inactivity_limit)
    watchdog_interval = Keyword.get(opts, :watchdog_interval, @turn_watchdog_interval)
    idle_ms = System.monotonic_time(:millisecond) - (state.last_activity_at || 0)

    if idle_ms >= inactivity_limit do
      Logger.warning(
        "[worker] Turn watchdog fired: no activity for #{div(idle_ms, 1000)}s, " <>
          "killing runner task (step=#{state.current_step}, tool=#{state.current_tool})"
      )

      Process.exit(pid, :turn_inactive)
    else
      schedule_watchdog(watchdog_interval)
    end

    state
  end

  def handle_watchdog(state, _opts), do: state

  defp maybe_publish_task_accepted(_state, nil), do: :ok

  defp maybe_publish_task_accepted(state, task_id) do
    Rho.Events.broadcast(
      state.session_id,
      Rho.Events.event(:task_accepted, state.session_id, state.agent_id, %{task_id: task_id})
    )
  end

  defp schedule_watchdog(interval \\ @turn_watchdog_interval) do
    Process.send_after(self(), :turn_watchdog, interval)
  end
end
