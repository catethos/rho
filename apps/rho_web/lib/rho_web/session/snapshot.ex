defmodule RhoWeb.Session.Snapshot do
  @moduledoc """
  Persists UI state (socket assigns) to disk so workspace state survives
  browser close and process restart.

  Files are stored at `_rho/sessions/{session_id}/ui_snapshot.json` relative
  to the workspace root.
  """
  @filename "ui_snapshot.json"
  @snapshot_fields [
    :agents,
    :agent_messages,
    :active_agent_id,
    :agent_tab_order,
    :total_input_tokens,
    :total_output_tokens,
    :total_cost,
    :total_cached_tokens,
    :total_reasoning_tokens,
    :step_input_tokens,
    :step_output_tokens,
    :debug_mode,
    :debug_projections,
    :ws_states
  ]
  @doc """
  Save a snapshot map to disk for the given session.

  When `thread_id` is provided, saves to `snapshots/{thread_id}.json`.
  Otherwise falls back to `ui_snapshot.json`.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec save(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(session_id, workspace, state, opts \\ []) when is_map(state) do
    dir = session_dir(session_id, workspace)
    path = snapshot_path(dir, opts[:thread_id])
    serialized = state |> Map.put(:snapshot_at, System.system_time(:millisecond)) |> serialize()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         json <- Jason.encode!(serialized, pretty: true) do
      File.write(path, json)
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Load a snapshot from disk.

  When `thread_id` is provided, loads from `snapshots/{thread_id}.json`.
  Otherwise falls back to `ui_snapshot.json`.

  Returns `{:ok, map}` with atom keys restored, or `:none` if no snapshot exists.
  """
  @spec load(String.t(), String.t(), keyword()) :: {:ok, map()} | :none
  def load(session_id, workspace, opts \\ []) do
    dir = session_dir(session_id, workspace)
    path = snapshot_path(dir, opts[:thread_id])

    case File.read(path) do
      {:ok, json} -> {:ok, json |> Jason.decode!() |> deserialize()}
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> :none
  end

  @doc "Delete the snapshot file for the given session."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(session_id, workspace) do
    path = Path.join(session_dir(session_id, workspace), @filename)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc """
  Extract snapshotable state from a socket's assigns.

  Picks only the fields that should be persisted, dropping process-specific
  state like PIDs, uploads, inflight streams, and pending responses.
  """
  @spec build_snapshot(Phoenix.LiveView.Socket.t()) :: map()
  def build_snapshot(%{assigns: assigns}) do
    assigns |> Map.take(@snapshot_fields) |> Map.put(:active_page, Map.get(assigns, :active_page))
  end

  @doc "Apply a loaded snapshot into a socket, restoring persisted assigns."
  @spec apply_snapshot(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_snapshot(socket, snapshot) when is_map(snapshot) do
    Enum.reduce(snapshot, socket, fn
      {:snapshot_at, _}, sock -> sock
      {key, value}, sock -> Phoenix.Component.assign(sock, key, value)
    end)
  end

  @doc false
  def serialize(state) when is_map(state) do
    Map.new(state, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(%MapSet{} = ms) do
    %{"__type__" => "MapSet", "values" => MapSet.to_list(ms)}
  end

  defp serialize_value(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    %{"__type__" => "atom", "value" => Atom.to_string(value)}
  end

  defp serialize_value(value) when is_map(value) do
    if has_tuple_keys?(value) do
      entries =
        Enum.map(value, fn {k, v} ->
          %{"key" => serialize_value(k), "value" => serialize_value(v)}
        end)

      %{"__type__" => "tuple_keyed_map", "entries" => entries}
    else
      Map.new(value, fn {k, v} -> {to_string(k), serialize_value(v)} end)
    end
  end

  defp serialize_value(value) when is_list(value) do
    Enum.map(value, &serialize_value/1)
  end

  defp serialize_value(value) when is_pid(value) do
    nil
  end

  defp serialize_value(value) when is_reference(value) do
    nil
  end

  defp serialize_value(value) when is_function(value) do
    nil
  end

  defp serialize_value(value) when is_tuple(value) do
    %{"__type__" => "tuple", "elements" => serialize_value(Tuple.to_list(value))}
  end

  defp serialize_value(value) do
    value
  end

  defp has_tuple_keys?(map) when map_size(map) == 0 do
    false
  end

  defp has_tuple_keys?(map) do
    Enum.any?(map, fn {key, _value} -> is_tuple(key) end)
  end

  @doc false
  def deserialize(data) when is_map(data) do
    case data do
      %{"__type__" => "MapSet", "values" => values} ->
        MapSet.new(values)

      %{"__type__" => "atom", "value" => str} ->
        safe_to_atom(str)

      %{"__type__" => "tuple", "elements" => elements} ->
        elements |> deserialize() |> List.to_tuple()

      %{"__type__" => "tuple_keyed_map", "entries" => entries} ->
        Map.new(entries, fn %{"key" => k, "value" => v} -> {deserialize(k), deserialize(v)} end)

      map ->
        Map.new(map, fn {k, v} -> {safe_to_atom(k), deserialize(v)} end)
    end
  end

  def deserialize(data) when is_list(data) do
    Enum.map(data, &deserialize/1)
  end

  def deserialize(data) do
    data
  end

  defp session_dir(session_id, workspace) do
    Path.join([workspace, "_rho", "sessions", session_id])
  end

  defp snapshot_path(dir, nil) do
    Path.join(dir, @filename)
  end

  defp snapshot_path(dir, thread_id) when is_binary(thread_id) do
    Path.join([dir, "snapshots", "#{thread_id}.json"])
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end
end
