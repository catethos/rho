defmodule Rho.Stdlib.DataTable.SessionJanitor do
  @moduledoc """
  Listens for `:agent_stopped` events on `Rho.Events` lifecycle topic and
  shuts down the matching `Rho.Stdlib.DataTable.Server` when the primary
  agent for a session terminates.

  This avoids a new cross-app teardown protocol: data tables follow the
  lifetime of the primary agent they are tied to.
  """

  use GenServer

  require Logger

  alias Rho.Events.Event
  alias Rho.Stdlib.DataTable

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Rho.Events.subscribe_lifecycle()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Event{kind: :agent_stopped, data: data}, state) do
    with true <- primary_agent?(data),
         session_id when is_binary(session_id) <- session_id_of(data) do
      DataTable.stop(session_id)
    end

    {:noreply, state}
  end

  def handle_info(%Event{}, state), do: {:noreply, state}
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
