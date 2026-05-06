defmodule Rho.Stdlib.Uploads.Supervisor do
  @moduledoc "DynamicSupervisor for per-session `Rho.Stdlib.Uploads.Server`s."
  use DynamicSupervisor

  alias Rho.Stdlib.Uploads.Server

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a server for the given session. Idempotent."
  def start_for(session_id) when is_binary(session_id) do
    case Server.whereis(session_id) do
      nil ->
        DynamicSupervisor.start_child(__MODULE__, {Server, session_id: session_id})

      pid ->
        {:ok, pid}
    end
  end
end
