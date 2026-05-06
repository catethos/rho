defmodule Rho.Stdlib.Uploads.Server do
  @moduledoc """
  Per-session GenServer holding upload metadata in process state and
  managing the `<tmp>/rho_uploads/<session_id>/` directory on disk.

  Mirrors `Rho.Stdlib.DataTable.Server` — `restart: :temporary`, traps
  exits so `terminate/2` can clean up the on-disk directory after any
  in-flight `GenServer.call` parses have replied.
  """

  use GenServer, restart: :temporary

  alias Rho.Stdlib.Uploads.Handle

  @registry Rho.Stdlib.Uploads.Registry

  # --- Public API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {@registry, session_id}}
  end

  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def put(session_id, params), do: call(session_id, {:put, params})
  def get(session_id, id), do: call(session_id, {:get, id})
  def list(session_id), do: call(session_id, :list, [])
  def delete(session_id, id), do: call(session_id, {:delete, id})

  def put_observation(session_id, id, observation),
    do: call(session_id, {:put_observation, id, observation})

  def stop(session_id) do
    case whereis(session_id) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal)
        catch
          # noproc: server already dead (Registry entry not yet GC'd)
          :exit, {:noproc, _} ->
            :ok

          # Server already stopped normally before we got here
          :exit, :normal ->
            :ok

          # Server exited with :shutdown (e.g. parent exited with :shutdown,
          # which ExUnit does to test processes). GenServer.stop wraps the
          # proc_lib exit as {{:shutdown, {:sys, :terminate, _}}, {GenServer, ...}}
          :exit, {{:shutdown, _}, _} ->
            :ok

          :exit, :shutdown ->
            :ok

          :exit, {:shutdown, _} ->
            :ok
        end
    end
  end

  # --- GenServer ---

  @impl true
  def init(session_id) do
    Process.flag(:trap_exit, true)
    dir = session_dir(session_id)
    # Idempotent: wipe any stale directory from a crashed prior server in
    # the same session id, then make a fresh one.
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {:ok, %{session_id: session_id, dir: dir, handles: %{}}}
  end

  @impl true
  def handle_call({:put, params}, _from, state) do
    %{filename: filename, mime: mime, tmp_path: tmp_path, size: size} = params

    id = "upl_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    ext = Path.extname(filename)
    dest = Path.join(state.dir, id <> ext)

    case File.cp(tmp_path, dest) do
      :ok ->
        handle = %Handle{
          id: id,
          session_id: state.session_id,
          filename: filename,
          mime: mime,
          size: size,
          path: dest,
          uploaded_at: DateTime.utc_now()
        }

        {:reply, {:ok, handle}, %{state | handles: Map.put(state.handles, id, handle)}}

      {:error, reason} ->
        {:reply, {:error, {:io_error, reason}}, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.handles, id) do
      {:ok, h} -> {:reply, {:ok, h}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.handles), state}
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.fetch(state.handles, id) do
      {:ok, h} ->
        _ = File.rm(h.path)
        {:reply, :ok, %{state | handles: Map.delete(state.handles, id)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:put_observation, id, obs}, _from, state) do
    case Map.fetch(state.handles, id) do
      {:ok, h} ->
        h2 = %{h | observation: obs}
        {:reply, :ok, %{state | handles: Map.put(state.handles, id, h2)}}

      :error ->
        {:reply, :error, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = File.rm_rf(state.dir)
    :ok
  end

  # --- Internal ---

  @tmp_root "rho_uploads"

  defp session_dir(sid), do: Path.join([System.tmp_dir!(), @tmp_root, sid])

  defp call(session_id, msg, default \\ {:error, :not_running}) do
    case whereis(session_id) do
      nil -> default
      pid -> GenServer.call(pid, msg)
    end
  end
end
