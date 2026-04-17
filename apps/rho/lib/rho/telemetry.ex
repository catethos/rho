defmodule Rho.Telemetry do
  @moduledoc """
  Telemetry handler for Finch HTTP pool events and LLM stream diagnostics.

  Attaches to Finch's built-in telemetry to log connection pool health,
  checkout durations, and connection errors — critical for diagnosing
  stale-connection and pool-exhaustion issues after long idle periods.
  """

  require Logger

  @finch_events [
    [:finch, :queue, :start],
    [:finch, :queue, :stop],
    [:finch, :queue, :exception],
    [:finch, :request, :start],
    [:finch, :request, :stop],
    [:finch, :request, :exception],
    [:finch, :connect, :start],
    [:finch, :connect, :stop]
  ]

  @admission_events [
    [:rho, :llm, :admission, :acquire],
    [:rho, :llm, :admission, :release],
    [:rho, :llm, :admission, :queued],
    [:rho, :llm, :admission, :timeout]
  ]

  @log_dir Path.expand("../../../../logs", __DIR__)

  def attach do
    setup_file_logger()

    :telemetry.attach_many(
      "rho-finch-telemetry",
      @finch_events,
      &__MODULE__.handle_event/4,
      nil
    )

    :telemetry.attach_many(
      "rho-admission-telemetry",
      @admission_events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc """
  Adds an Erlang logger handler that writes warning+ logs to logs/rho.log.
  Uses built-in :logger_std_h — no extra deps needed.
  Rotates at 10MB, keeps 5 files.
  """
  def setup_file_logger do
    File.mkdir_p!(@log_dir)
    log_file = Path.join(@log_dir, "rho.log")

    config = %{
      config: %{
        file: String.to_charlist(log_file),
        max_no_bytes: 10_000_000,
        max_no_files: 5
      },
      level: :warning,
      formatter:
        {:logger_formatter,
         %{
           template: [:time, " ", :level, " ", :msg, "\n"],
           single_line: true
         }}
    }

    :logger.add_handler(:rho_file, :logger_std_h, config)
  end

  # --- Queue (connection checkout) ---

  def handle_event([:finch, :queue, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    idle_ms =
      System.convert_time_unit(Map.get(measurements, :idle_time, 0), :native, :millisecond)

    if duration_ms > 100 do
      Logger.warning(
        "[finch.pool] slow checkout: #{duration_ms}ms (idle_time: #{idle_ms}ms) " <>
          "request=#{format_request(metadata)}"
      )
    end
  end

  def handle_event([:finch, :queue, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[finch.pool] checkout FAILED after #{duration_ms}ms — pool exhausted. " <>
        "reason=#{inspect(metadata[:reason])} request=#{format_request(metadata)}"
    )

    log_pool_status()
  end

  # --- Request lifecycle ---

  def handle_event([:finch, :request, :stop], measurements, _metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 60_000 do
      Logger.warning("[finch.request] long request: #{duration_ms}ms")
    end
  end

  def handle_event([:finch, :request, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[finch.request] exception after #{duration_ms}ms — " <>
        "kind=#{metadata[:kind]} reason=#{inspect(metadata[:reason])}"
    )
  end

  # --- Connection lifecycle ---

  def handle_event([:finch, :connect, :stop], measurements, _metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 1_000 do
      Logger.warning("[finch.connect] slow TCP connect: #{duration_ms}ms")
    end
  end

  # --- Admission controller ---

  def handle_event([:rho, :llm, :admission, :queued], measurements, metadata, _config) do
    # Only noisy-log when queueing is non-trivial (>4 waiters).
    if measurements.queue_depth > 4 do
      Logger.warning(
        "[admission] queued — depth=#{measurements.queue_depth} " <>
          "in_flight=#{measurements.in_flight}/#{measurements.capacity} " <>
          "pid=#{inspect(metadata.pid)}"
      )
    end
  end

  def handle_event([:rho, :llm, :admission, :acquire], measurements, metadata, _config) do
    # Only log if the caller actually waited.
    if measurements.wait_ms > 500 do
      Logger.info(
        "[admission] acquired after #{measurements.wait_ms}ms wait " <>
          "(#{metadata.source}) — in_flight=#{measurements.in_flight}/#{measurements.capacity}"
      )
    end
  end

  def handle_event([:rho, :llm, :admission, :timeout], measurements, metadata, _config) do
    Logger.error(
      "[admission] TIMEOUT after #{measurements.wait_ms}ms — " <>
        "in_flight=#{measurements.in_flight}/#{measurements.capacity} " <>
        "waiting=#{measurements.waiting} pid=#{inspect(metadata.pid)}"
    )
  end

  def handle_event([:rho, :llm, :admission, :release], _measurements, _metadata, _config),
    do: :ok

  # Catch-all for events we attach to but don't need to log (start events, fast paths)
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # --- Pool status snapshot ---

  defp log_pool_status do
    urls = [
      "https://api.anthropic.com",
      "https://api.openai.com",
      "https://openrouter.ai"
    ]

    for url <- urls, do: log_single_pool(url)
  rescue
    _ -> :ok
  end

  defp log_single_pool(url) do
    case Finch.get_pool_status(ReqLLM.Finch, URI.parse(url)) do
      {:ok, statuses} ->
        for s <- List.wrap(statuses) do
          Logger.error(
            "[finch.pool] #{url} — " <>
              "size=#{s.pool_size} in_use=#{s.in_use_connections} available=#{s.available_connections}"
          )
        end

      _ ->
        :ok
    end
  end

  defp format_request(%{request: %{host: host, path: path}}), do: "#{host}#{path}"
  defp format_request(%{request: req}) when is_struct(req), do: inspect(req, limit: 3)
  defp format_request(_), do: "unknown"
end
