defmodule RhoWeb.FinchTelemetry do
  @moduledoc """
  Attaches to Finch telemetry events and tracks connection pool metrics.

  Tracks:
  - Queue wait times (how long requests wait for a connection)
  - Queue exceptions (pool exhaustion events)
  - Request durations (how long connections are held)
  - Connection lifecycle (new vs reused, idle timeouts)
  - Pool utilization snapshots via `Finch.get_pool_status/2`

  All metrics are stored in ETS for cheap reads from the Observatory
  or API endpoints.
  """

  require Logger

  @table __MODULE__
  @max_samples 200

  # --- Public API ---

  def start_link(_opts \\ []) do
    # ETS table + telemetry attachment in one init
    init()
    :ignore
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc "Get a snapshot of all tracked metrics."
  def metrics do
    %{
      queue: %{
        wait_times_ms: get_samples(:queue_wait_times),
        exceptions: get_counter(:queue_exceptions),
        total_checkouts: get_counter(:queue_checkouts)
      },
      requests: %{
        durations_ms: get_samples(:request_durations),
        in_flight: get_counter(:requests_in_flight),
        total: get_counter(:requests_total)
      },
      connections: %{
        opened: get_counter(:connections_opened),
        reused: get_counter(:connections_reused),
        idle_expired: get_counter(:connections_idle_expired)
      },
      pool_status: pool_status(),
      recent_exceptions: get_list(:recent_exceptions)
    }
  end

  @doc "Get current pool utilization from Finch atomics (cheap read)."
  def pool_status do
    case Finch.get_pool_status(ReqLLM.Finch, :default) do
      {:ok, pools} ->
        Enum.flat_map(pools, fn {_shp, pool_metrics} ->
          Enum.map(pool_metrics, fn m ->
            %{
              pool_index: m.pool_index,
              pool_size: m.pool_size,
              available: m.available_connections,
              in_use: m.in_use_connections,
              utilization_pct: Float.round(m.in_use_connections / m.pool_size * 100, 1)
            }
          end)
        end)

      {:error, :not_found} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Reset all counters and samples."
  def reset do
    :ets.delete_all_objects(@table)
    init_counters()
  end

  # --- Init ---

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
      init_counters()
    end

    attach_handlers()
  end

  defp init_counters do
    for key <- [
          :queue_exceptions,
          :queue_checkouts,
          :requests_in_flight,
          :requests_total,
          :connections_opened,
          :connections_reused,
          :connections_idle_expired
        ] do
      :ets.insert(@table, {{:counter, key}, 0})
    end

    for key <- [:queue_wait_times, :request_durations] do
      :ets.insert(@table, {{:samples, key}, []})
    end

    :ets.insert(@table, {{:list, :recent_exceptions}, []})
  end

  defp attach_handlers do
    events = [
      {[:finch, :queue, :start], &__MODULE__.handle_queue_start/4},
      {[:finch, :queue, :stop], &__MODULE__.handle_queue_stop/4},
      {[:finch, :queue, :exception], &__MODULE__.handle_queue_exception/4},
      {[:finch, :request, :start], &__MODULE__.handle_request_start/4},
      {[:finch, :request, :stop], &__MODULE__.handle_request_stop/4},
      {[:finch, :request, :exception], &__MODULE__.handle_request_exception/4},
      {[:finch, :connect, :stop], &__MODULE__.handle_connect_stop/4},
      {[:finch, :reused_connection], &__MODULE__.handle_reused_connection/4},
      {[:finch, :conn_max_idle_time_exceeded], &__MODULE__.handle_idle_expired/4}
    ]

    for {event, handler} <- events do
      handler_id = {__MODULE__, event}

      # Detach first to avoid duplicate attachment on hot reload
      :telemetry.detach(handler_id)
      :telemetry.attach(handler_id, event, handler, nil)
    end
  end

  # --- Telemetry Handlers ---

  def handle_queue_start(_event, _measurements, _metadata, _config) do
    # Nothing to track on start — duration comes from stop
    :ok
  end

  def handle_queue_stop(_event, measurements, _metadata, _config) do
    duration_ms = native_to_ms(measurements.duration)
    increment(:queue_checkouts)
    add_sample(:queue_wait_times, duration_ms)

    if duration_ms > 100 do
      Logger.warning(
        "[FinchTelemetry] Slow connection checkout: #{Float.round(duration_ms, 1)}ms"
      )
    end
  end

  def handle_queue_exception(_event, measurements, metadata, _config) do
    duration_ms = native_to_ms(measurements.duration)
    increment(:queue_exceptions)

    exception_record = %{
      at: System.system_time(:millisecond),
      waited_ms: Float.round(duration_ms, 1),
      reason: inspect(metadata[:reason]),
      kind: metadata[:kind]
    }

    add_to_list(:recent_exceptions, exception_record, 50)

    Logger.error(
      "[FinchTelemetry] Pool exhaustion! Connection checkout failed after #{Float.round(duration_ms, 1)}ms. " <>
        "Reason: #{inspect(metadata[:reason])}"
    )
  end

  def handle_request_start(_event, _measurements, _metadata, _config) do
    increment(:requests_in_flight)
    increment(:requests_total)
  end

  def handle_request_stop(_event, measurements, _metadata, _config) do
    decrement(:requests_in_flight)
    duration_ms = native_to_ms(measurements.duration)
    add_sample(:request_durations, duration_ms)
  end

  def handle_request_exception(_event, _measurements, _metadata, _config) do
    decrement(:requests_in_flight)
  end

  def handle_connect_stop(_event, _measurements, metadata, _config) do
    unless metadata[:error] do
      increment(:connections_opened)
    end
  end

  def handle_reused_connection(_event, _measurements, _metadata, _config) do
    increment(:connections_reused)
  end

  def handle_idle_expired(_event, _measurements, _metadata, _config) do
    increment(:connections_idle_expired)
  end

  # --- ETS Helpers ---

  defp increment(key) do
    :ets.update_counter(@table, {:counter, key}, {2, 1})
  rescue
    ArgumentError -> :ok
  end

  defp decrement(key) do
    :ets.update_counter(@table, {:counter, key}, {2, -1})
  rescue
    ArgumentError -> :ok
  end

  defp get_counter(key) do
    case :ets.lookup(@table, {:counter, key}) do
      [{_, val}] -> val
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp add_sample(key, value) do
    ets_key = {:samples, key}

    case :ets.lookup(@table, ets_key) do
      [{_, samples}] ->
        :ets.insert(@table, {ets_key, Enum.take([value | samples], @max_samples)})

      [] ->
        :ets.insert(@table, {ets_key, [value]})
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_samples(key) do
    case :ets.lookup(@table, {:samples, key}) do
      [{_, samples}] -> samples
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp add_to_list(key, value, max) do
    ets_key = {:list, key}

    case :ets.lookup(@table, ets_key) do
      [{_, list}] ->
        :ets.insert(@table, {ets_key, Enum.take([value | list], max)})

      [] ->
        :ets.insert(@table, {ets_key, [value]})
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_list(key) do
    case :ets.lookup(@table, {:list, key}) do
      [{_, list}] -> list
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :microsecond) / 1000
  end
end
