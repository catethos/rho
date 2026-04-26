defmodule Rho.Agent.EventLog do
  @moduledoc """
  Persistent event log for a session. Subscribes to `Rho.Events` and writes
  filtered events to a JSONL file on disk.

  File path: `{workspace}/_rho/sessions/{session_id}/events.jsonl`
  """

  use GenServer, restart: :transient

  require Logger

  alias Rho.Events.Event

  @filtered_kinds ~w(text_delta structured_partial)a
  @max_tool_result_bytes 4096
  @max_tool_args_bytes 2048

  defstruct [:session_id, :file, :path, :workspace, seq: 0]

  # --- Public API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Rho.EventLogRegistry, session_id}}
    )
  end

  @doc "Stop the event log for a session."
  def stop(session_id) do
    case Registry.lookup(Rho.EventLogRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
      [] -> :ok
    end
  end

  @doc "Read events from the log. Returns `{events, last_seq}`."
  def read(session_id, opts \\ []) do
    case Registry.lookup(Rho.EventLogRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, {:read, opts})
      [] -> {[], 0}
    end
  end

  @doc "Returns the JSONL file path for a session."
  def path(session_id) do
    case Registry.lookup(Rho.EventLogRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, :path)
      [] -> nil
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    case Rho.Agent.Primary.validate_session_id(session_id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid session_id: #{inspect(reason)}"
    end

    dir = Path.join([workspace, "_rho", "sessions", session_id])
    File.mkdir_p!(dir)
    file_path = Path.join(dir, "events.jsonl")

    # Open file for append (binary mode for IO.binwrite)
    {:ok, file} = File.open(file_path, [:append, :binary])

    # Subscribe to session events and global lifecycle events
    Rho.Events.subscribe(session_id)
    Rho.Events.subscribe_lifecycle()

    state = %__MODULE__{
      session_id: session_id,
      file: file,
      path: file_path,
      workspace: workspace
    }

    Logger.debug("EventLog started for session #{session_id} at #{file_path}")

    {:ok, state}
  end

  @impl true
  def handle_call({:read, opts}, _from, state) do
    after_seq = Keyword.get(opts, :after, 0)
    limit = Keyword.get(opts, :limit, 100)

    # Flush to ensure all written data is readable
    :ok = IO.binwrite(state.file, "")

    events =
      state.path
      |> File.stream!()
      |> Stream.map(&decode_line/1)
      |> Stream.reject(&is_nil/1)
      |> Stream.filter(fn event -> event["seq"] > after_seq end)
      |> Enum.take(limit)

    last_seq =
      case List.last(events) do
        nil -> after_seq
        event -> event["seq"]
      end

    {:reply, {events, last_seq}, state}
  end

  @impl true
  def handle_call(:path, _from, state) do
    {:reply, state.path, state}
  end

  @impl true
  def handle_info(%Event{kind: kind, data: data} = event, state) do
    # Filter out high-frequency reconstructable events
    # Drop events that belong to a different session (lifecycle topic is global)
    event_session = data[:session_id] || data["session_id"]
    foreign? = is_binary(event_session) and event_session != state.session_id

    if kind in @filtered_kinds or foreign? do
      {:noreply, state}
    else
      try do
        state = write_event(state, event)
        {:noreply, state}
      rescue
        error ->
          Logger.warning("[EventLog] Failed to write event #{kind}: #{inspect(error)}")
          {:noreply, state}
      end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Unsubscribe from events
    Rho.Events.unsubscribe(state.session_id)

    # Close file
    if state.file, do: File.close(state.file)

    :ok
  end

  # --- Private ---

  defp write_event(state, %Event{kind: kind, data: data, agent_id: agent_id, timestamp: ts}) do
    seq = state.seq + 1

    turn_id = data[:turn_id] || data["turn_id"]

    event = %{
      seq: seq,
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: Atom.to_string(kind),
      agent_id: agent_id || data[:agent_id] || data["agent_id"],
      session_id: state.session_id,
      turn_id: turn_id,
      emitted_at: ts,
      data: truncate_data(data)
    }

    line = Jason.encode!(sanitize(event)) <> "\n"
    IO.binwrite(state.file, line)

    %{state | seq: seq}
  end

  defp truncate_data(data) when is_map(data) do
    data
    |> truncate_field(:output, @max_tool_result_bytes)
    |> truncate_field("output", @max_tool_result_bytes)
    |> truncate_args(:args, @max_tool_args_bytes)
    |> truncate_args("args", @max_tool_args_bytes)
  end

  defp truncate_data(data), do: data

  defp truncate_field(data, key, max_bytes) do
    case Map.get(data, key) do
      val when is_binary(val) and byte_size(val) > max_bytes ->
        Map.put(data, key, String.slice(val, 0, max_bytes) <> "... [truncated]")

      _ ->
        data
    end
  end

  defp truncate_args(data, key, max_bytes) do
    case Map.get(data, key) do
      args when is_map(args) ->
        Map.put(data, key, truncate_arg_values(args, max_bytes))

      _ ->
        data
    end
  end

  defp truncate_arg_values(args, max_bytes) do
    Map.new(args, fn {k, v} ->
      if is_binary(v) and byte_size(v) > max_bytes do
        {k, String.slice(v, 0, max_bytes) <> "... [truncated]"}
      else
        {k, v}
      end
    end)
  end

  # Recursively convert structs to plain maps so Jason.encode! won't blow up
  # on values like ReqLLM.Tool that lack a Jason.Encoder implementation.
  defp sanitize(%_{} = struct), do: struct |> Map.from_struct() |> sanitize()
  defp sanitize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> sanitize()
  defp sanitize(fun) when is_function(fun), do: inspect(fun)
  defp sanitize(pid) when is_pid(pid), do: inspect(pid)
  defp sanitize(ref) when is_reference(ref), do: inspect(ref)
  defp sanitize(port) when is_port(port), do: inspect(port)
  defp sanitize(other), do: other

  defp decode_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, event} -> event
      {:error, _} -> nil
    end
  end
end
