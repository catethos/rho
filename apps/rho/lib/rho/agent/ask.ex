defmodule Rho.Agent.Ask do
  @moduledoc """
  Bus-backed synchronous ask helper for `Rho.Agent.Worker`.

  The worker remains the GenServer owner. This module owns the public
  `ask/3` orchestration and the event-await semantics, which are intentionally
  bus-only: it waits on `Rho.Events` session events rather than direct process
  messages from the worker.
  """

  @ask_inactivity_timeout 120_000

  @type submit_fun :: (pid(), term(), keyword() -> {:ok, String.t()})
  @type info_fun :: (pid() -> %{session_id: String.t()})

  @doc """
  Subscribes to the worker's session bus, submits input, and waits for a
  turn-level or finish-level result.
  """
  @spec ask(pid(), term(), keyword(), info_fun(), submit_fun()) :: term()
  def ask(pid, content, opts, info_fun, submit_fun) when is_pid(pid) do
    session_id = info_fun.(pid).session_id
    Rho.Events.subscribe(session_id)

    try do
      {:ok, turn_id} = submit_fun.(pid, content, opts)
      await_mode = Keyword.get(opts, :await, :turn)
      await_reply(turn_id, await_mode)
    after
      Rho.Events.unsubscribe(session_id)
    end
  end

  @doc false
  def await_reply(turn_id, :turn) do
    await_reply_turn(turn_id, System.monotonic_time(:millisecond))
  end

  def await_reply(_turn_id, :finish), do: await_reply_finish(nil)

  defp await_reply_turn(turn_id, last_activity_at) do
    remaining = @ask_inactivity_timeout - (System.monotonic_time(:millisecond) - last_activity_at)
    remaining = max(remaining, 0)

    receive do
      %Rho.Events.Event{kind: :turn_finished, data: %{turn_id: ^turn_id} = data} ->
        unwrap_result(Map.get(data, :result))

      %Rho.Events.Event{} ->
        # Any event is proof of life: reset the inactivity timer.
        await_reply_turn(turn_id, System.monotonic_time(:millisecond))
    after
      remaining ->
        {:error, "ask timed out: no activity for #{div(@ask_inactivity_timeout, 1000)}s"}
    end
  end

  defp await_reply_finish(last_result) do
    timeout =
      if last_result do
        30_000
      else
        @ask_inactivity_timeout
      end

    receive do
      %Rho.Events.Event{kind: :turn_finished, data: data} ->
        case Map.get(data, :result) do
          {:final, value} -> {:ok, value}
          {:ok, _text} = ok -> await_reply_finish(ok)
          {:error, _} = err -> err
          other -> await_reply_finish(other)
        end

      %Rho.Events.Event{} ->
        await_reply_finish(last_result)
    after
      timeout -> last_result || {:error, "ask timed out: no activity for #{div(timeout, 1000)}s"}
    end
  end

  defp unwrap_result({:final, value}), do: {:ok, value}
  defp unwrap_result(other), do: other
end
