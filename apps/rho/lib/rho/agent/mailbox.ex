defmodule Rho.Agent.Mailbox do
  @moduledoc """
  Queue and mailbox operations for `Rho.Agent.Worker`.

  The worker owns when queued work is processed. This module owns how regular
  submit turns and multi-agent signals are queued and selected.
  """

  require Logger

  @doc """
  Enqueues a submitted turn while the worker is busy.
  """
  @spec enqueue_submit(struct(), term(), keyword(), String.t()) :: struct()
  def enqueue_submit(state, content, opts, turn_id) do
    queue_size = :queue.len(state.queue)

    Logger.warning(
      "[worker] Submit while busy: agent=#{state.agent_id} status=#{state.status} " <>
        "current_turn=#{state.current_turn_id} task_alive=#{is_pid(state.task_pid) and Process.alive?(state.task_pid)} " <>
        "queue_size=#{queue_size} idle_ms=#{System.monotonic_time(:millisecond) - (state.last_activity_at || 0)}"
    )

    %{state | queue: :queue.in({content, opts, turn_id}, state.queue)}
  end

  @doc """
  Enqueues a signal for later processing.
  """
  @spec enqueue_signal(struct(), term()) :: struct()
  def enqueue_signal(state, signal) do
    %{state | mailbox: :queue.in(signal, state.mailbox)}
  end

  @doc """
  Returns the next queued item, preferring signals over regular submits.
  """
  @spec next(struct()) ::
          {:signal, struct(), term()}
          | {:submit, struct(), term(), keyword(), String.t()}
          | {:empty, struct()}
  def next(state) do
    case :queue.out(state.mailbox) do
      {{:value, signal}, mailbox} ->
        {:signal, %{state | mailbox: mailbox}, signal}

      {:empty, _} ->
        next_submit(state)
    end
  end

  defp next_submit(state) do
    case :queue.out(state.queue) do
      {{:value, {content, opts, turn_id}}, queue} ->
        {:submit, %{state | queue: queue}, content, opts, turn_id}

      {:empty, _} ->
        {:empty, state}
    end
  end
end
