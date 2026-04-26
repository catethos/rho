defmodule Rho.LLM.Admission do
  @moduledoc """
  Global concurrency limiter (counting semaphore) for in-flight LLM streams.

  Caps total simultaneous `ReqLLM.stream_text/3` calls across the node.
  When saturated, callers block up to `acquire_timeout` waiting for a
  slot to free up.

  ## Why

  Finch's HTTP pool is the only backpressure mechanism by default. When
  saturated, it raises after a 5s checkout timeout — a hard failure
  rather than graceful queueing. With multiple active users and
  multi-agent fan-out (e.g. `save_and_generate` spawning N subagents),
  Finch exhaustion becomes common. This module queues in application
  code so pool exhaustion becomes the exceptional path, not the norm.

  ## Capacity

  Should be set *below* the Finch pool count so the pool has headroom
  for retries and transient surges. E.g. pool `count: 256` → admission
  capacity `200`, leaving 56 connections of slack.

  ## Usage

      Rho.LLM.Admission.with_slot(fn ->
        ReqLLM.stream_text(model, messages, opts)
      end)

  If the caller exits before releasing (crash, kill, GenServer.call
  timeout), the slot is reclaimed automatically via process monitor.
  """

  use GenServer

  require Logger

  @default_capacity 200
  @default_acquire_timeout :timer.seconds(60)

  # -- Public API --

  @doc "Starts the admission controller."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires a slot, blocking up to `timeout` ms. Returns `:ok` or
  `{:error, :acquire_timeout}`.

  When possible, prefer `with_slot/2` — it handles release for you.
  """
  @spec acquire(non_neg_integer()) :: :ok | {:error, :acquire_timeout}
  def acquire(timeout \\ @default_acquire_timeout) do
    GenServer.call(__MODULE__, :acquire, timeout)
  catch
    :exit, {:timeout, _} ->
      # Clean up our potentially-queued waiter before returning.
      GenServer.cast(__MODULE__, {:cancel, self()})
      {:error, :acquire_timeout}
  end

  @doc "Releases a previously-acquired slot."
  @spec release() :: :ok
  def release, do: GenServer.cast(__MODULE__, {:release, self()})

  @doc """
  Runs `fun` while holding a slot. Releases on completion or exception.
  Returns `{:error, :acquire_timeout}` if a slot can't be obtained.
  """
  @spec with_slot((-> result), non_neg_integer()) ::
          result | {:error, :acquire_timeout}
        when result: term()
  def with_slot(fun, timeout \\ @default_acquire_timeout) when is_function(fun, 0) do
    case acquire(timeout) do
      :ok ->
        try do
          fun.()
        after
          release()
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Returns `{in_flight, capacity, waiting}` for observability."
  @spec stats() :: %{
          in_flight: non_neg_integer(),
          capacity: pos_integer(),
          waiting: non_neg_integer()
        }
  def stats, do: GenServer.call(__MODULE__, :stats)

  # -- Telemetry events --
  #
  # Emitted under the `[:rho, :llm, :admission, _]` prefix. See module
  # docs for the catalog.
  #
  #   [:rho, :llm, :admission, :acquire]
  #     measurements: %{wait_ms, in_flight, capacity, waiting}
  #     metadata:     %{pid, source: :immediate | :promoted}
  #
  #   [:rho, :llm, :admission, :release]
  #     measurements: %{hold_ms, in_flight, capacity, waiting}
  #     metadata:     %{pid, reason: :release | :down}
  #
  #   [:rho, :llm, :admission, :queued]
  #     measurements: %{queue_depth, in_flight, capacity}
  #     metadata:     %{pid}
  #
  #   [:rho, :llm, :admission, :timeout]
  #     measurements: %{wait_ms, in_flight, capacity, waiting}
  #     metadata:     %{pid}

  # -- GenServer --

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    state = %{
      capacity: capacity,
      # %{pid => {monitor_ref, acquired_at_monotonic_ms}} for in-flight holders
      holders: %{},
      # :queue of {from, pid, monitor_ref, queued_at_monotonic_ms} for waiters
      waiters: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    now = monotonic_ms()

    if map_size(state.holders) < state.capacity do
      ref = Process.monitor(pid)
      holders = Map.put(state.holders, pid, {ref, now})
      new_state = %{state | holders: holders}
      emit_acquire(new_state, pid, 0, :immediate)
      {:reply, :ok, new_state}
    else
      ref = Process.monitor(pid)
      waiters = :queue.in({from, pid, ref, now}, state.waiters)
      new_state = %{state | waiters: waiters}
      emit_queued(new_state, pid)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      in_flight: map_size(state.holders),
      capacity: state.capacity,
      waiting: :queue.len(state.waiters)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        # Not a current holder — ignore (could be a duplicate release
        # or a release after crash-cleanup).
        {:noreply, state}

      {{ref, acquired_at}, holders} ->
        Process.demonitor(ref, [:flush])
        new_state = %{state | holders: holders}
        emit_release(new_state, pid, monotonic_ms() - acquired_at, :release)
        promote_next_waiter(new_state)
    end
  end

  def handle_cast({:cancel, pid}, state) do
    # Caller timed out waiting; remove them from the queue if still
    # there. If they've already been promoted (race), their subsequent
    # release will drop the slot.
    now = monotonic_ms()
    {waiters, cancelled} = remove_waiter(state.waiters, pid, now)

    case cancelled do
      {wait_ms, ref} ->
        Process.demonitor(ref, [:flush])
        new_state = %{state | waiters: waiters}
        emit_timeout(new_state, pid, wait_ms)
        {:noreply, new_state}

      nil ->
        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.holders, pid) do
      {^ref, acquired_at} ->
        holders = Map.delete(state.holders, pid)
        new_state = %{state | holders: holders}
        emit_release(new_state, pid, monotonic_ms() - acquired_at, :down)
        promote_next_waiter(new_state)

      _ ->
        # Waiter died — remove from queue.
        {waiters, _} = remove_waiter(state.waiters, pid, monotonic_ms())
        {:noreply, %{state | waiters: waiters}}
    end
  end

  # -- Internal --

  # A slot just freed. Hand it to the next queued waiter, if any.
  defp promote_next_waiter(state) do
    case :queue.out(state.waiters) do
      {{:value, {from, pid, ref, queued_at}}, rest} ->
        wait_ms = monotonic_ms() - queued_at
        holders = Map.put(state.holders, pid, {ref, monotonic_ms()})
        new_state = %{state | holders: holders, waiters: rest}
        GenServer.reply(from, :ok)
        emit_acquire(new_state, pid, wait_ms, :promoted)
        {:noreply, new_state}

      {:empty, _} ->
        {:noreply, state}
    end
  end

  defp remove_waiter(waiters, pid, _now) do
    {list, cancelled} =
      waiters
      |> :queue.to_list()
      |> Enum.reduce({[], nil}, fn
        {_, ^pid, ref, queued_at}, {acc, nil} ->
          {acc, {monotonic_ms() - queued_at, ref}}

        entry, {acc, cancelled} ->
          {[entry | acc], cancelled}
      end)

    {list |> Enum.reverse() |> :queue.from_list(), cancelled}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # -- Telemetry emit helpers --

  defp emit_acquire(state, pid, wait_ms, source) do
    :telemetry.execute(
      [:rho, :llm, :admission, :acquire],
      %{
        wait_ms: wait_ms,
        in_flight: map_size(state.holders),
        capacity: state.capacity,
        waiting: :queue.len(state.waiters)
      },
      %{pid: pid, source: source}
    )
  end

  defp emit_release(state, pid, hold_ms, reason) do
    :telemetry.execute(
      [:rho, :llm, :admission, :release],
      %{
        hold_ms: hold_ms,
        in_flight: map_size(state.holders),
        capacity: state.capacity,
        waiting: :queue.len(state.waiters)
      },
      %{pid: pid, reason: reason}
    )
  end

  defp emit_queued(state, pid) do
    :telemetry.execute(
      [:rho, :llm, :admission, :queued],
      %{
        queue_depth: :queue.len(state.waiters),
        in_flight: map_size(state.holders),
        capacity: state.capacity
      },
      %{pid: pid}
    )
  end

  defp emit_timeout(state, pid, wait_ms) do
    :telemetry.execute(
      [:rho, :llm, :admission, :timeout],
      %{
        wait_ms: wait_ms,
        in_flight: map_size(state.holders),
        capacity: state.capacity,
        waiting: :queue.len(state.waiters)
      },
      %{pid: pid}
    )
  end
end
