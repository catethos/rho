defmodule Rho.Stdlib.DataTable.ActiveViewListener do
  @moduledoc """
  Listens for view-side events on session topics and forwards them to
  `Rho.Stdlib.DataTable` so the DataTable plugin's `prompt_sections/2`
  can tell the agent which named table the user is currently looking at
  and which rows the user has explicitly selected.

  Subscribes to a session's events when its primary agent starts (via the
  global lifecycle `:agent_started` event) and unsubscribes when it stops.
  This keeps the listener decoupled from the LiveView — the LV broadcasts
  `:view_focus` and `:row_selection`; this process bridges PubSub →
  DataTable.Server.
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
    {:ok, %{sessions: MapSet.new()}}
  end

  @impl true
  def handle_info(%Event{kind: :agent_started, session_id: sid}, state)
      when is_binary(sid) do
    if MapSet.member?(state.sessions, sid) do
      {:noreply, state}
    else
      Rho.Events.subscribe(sid)
      {:noreply, %{state | sessions: MapSet.put(state.sessions, sid)}}
    end
  end

  def handle_info(%Event{kind: :agent_stopped, session_id: sid, data: data}, state)
      when is_binary(sid) do
    if primary_agent?(data) and MapSet.member?(state.sessions, sid) do
      Rho.Events.unsubscribe(sid)
      {:noreply, %{state | sessions: MapSet.delete(state.sessions, sid)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        %Event{kind: :view_focus, session_id: sid, data: %{table_name: name}},
        state
      )
      when is_binary(sid) and is_binary(name) do
    _ = DataTable.set_active_table(sid, name)
    {:noreply, state}
  end

  def handle_info(
        %Event{
          kind: :row_selection,
          session_id: sid,
          data: %{table_name: name, row_ids: ids}
        },
        state
      )
      when is_binary(sid) and is_binary(name) and is_list(ids) do
    _ = DataTable.set_selection(sid, name, ids)
    {:noreply, state}
  end

  def handle_info(%Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Mirrors SessionJanitor: assume events refer to the primary agent unless
  # an explicit `primary?: false` flag says otherwise. Non-primary agents
  # rarely publish session-id-bearing lifecycle events.
  defp primary_agent?(%{primary?: false}), do: false
  defp primary_agent?(%{"primary?" => false}), do: false
  defp primary_agent?(%{primary: false}), do: false
  defp primary_agent?(%{"primary" => false}), do: false
  defp primary_agent?(_), do: true
end
