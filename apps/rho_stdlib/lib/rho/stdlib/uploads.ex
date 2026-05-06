defmodule Rho.Stdlib.Uploads do
  @moduledoc """
  Public client API for the per-session upload server, plus a one-shot
  `parse_one_off/1` for callers that hold a server-side path and want a
  single observation without participating in a session lifecycle.

  See `docs/superpowers/specs/2026-05-06-file-upload-design.md` §5.1.
  """

  alias Rho.Stdlib.Uploads.{Handle, Server, Supervisor}

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id) when is_binary(session_id) do
    case Supervisor.start_for(session_id) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @spec put(String.t(), map()) :: {:ok, Handle.t()} | {:error, term()}
  defdelegate put(session_id, params), to: Server

  @spec get(String.t(), String.t()) :: {:ok, Handle.t()} | :error
  defdelegate get(session_id, id), to: Server

  @spec list(String.t()) :: [Handle.t()]
  defdelegate list(session_id), to: Server

  @spec delete(String.t(), String.t()) :: :ok
  defdelegate delete(session_id, id), to: Server

  @spec stop(String.t()) :: :ok
  defdelegate stop(session_id), to: Server

  @doc """
  Parse a server-side file synchronously without spawning a per-session
  server. Used by `Rho.Stdlib.Plugins.DocIngest` for path-based callers.

  No temp files are created. The input file is NOT deleted by this call —
  it belongs to the caller.

  Returns `{:error, :no_observer}` until Phase 2 wires `Observer.parse_path/1`.
  """
  @spec parse_one_off(String.t()) :: {:ok, term()} | {:error, term()}
  def parse_one_off(path) when is_binary(path) do
    if Code.ensure_loaded?(Rho.Stdlib.Uploads.Observer) and
         function_exported?(Rho.Stdlib.Uploads.Observer, :parse_path, 1) do
      Rho.Stdlib.Uploads.Observer.parse_path(path)
    else
      {:error, :no_observer}
    end
  end
end
