defmodule Rho.Stdlib.DataTable.SessionJanitor do
  @moduledoc """
  Listens for `rho.agent.stopped` signals on `Rho.Comms` and shuts down
  the matching `Rho.Stdlib.DataTable.Server` when the primary agent for
  a session terminates.

  This avoids a new cross-app teardown protocol: data tables follow the
  lifetime of the primary agent they are tied to.
  """

  use GenServer

  require Logger

  alias Rho.Comms
  alias Rho.Stdlib.DataTable

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case Comms.subscribe("rho.agent.stopped") do
      {:ok, sub_id} ->
        {:ok, %{sub_id: sub_id}}

      {:error, reason} ->
        Logger.warning(
          "[DataTable.SessionJanitor] failed to subscribe to rho.agent.stopped: #{inspect(reason)}"
        )

        {:ok, %{sub_id: nil}}
    end
  end

  @impl true
  def handle_info({:signal, %{data: data}}, state) do
    with true <- primary_agent?(data),
         session_id when is_binary(session_id) <- session_id_of(data) do
      DataTable.stop(session_id)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp primary_agent?(%{primary?: true}), do: true
  defp primary_agent?(%{"primary?" => true}), do: true
  defp primary_agent?(%{primary: true}), do: true
  defp primary_agent?(%{"primary" => true}), do: true
  # If no primary flag is present, assume the event refers to the primary agent.
  # This keeps the janitor conservative: non-primary agents typically don't publish
  # rho.agent.stopped with a session_id.
  defp primary_agent?(_), do: true

  defp session_id_of(%{session_id: sid}) when is_binary(sid), do: sid
  defp session_id_of(%{"session_id" => sid}) when is_binary(sid), do: sid
  defp session_id_of(_), do: nil
end
