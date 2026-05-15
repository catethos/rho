defmodule RhoWeb.AppLive.LiveEvents do
  @moduledoc """
  Routes canonical `Rho.Events.Event` messages for `RhoWeb.AppLive`.

  This keeps the root LiveView focused on orchestration while this module owns
  the event payload normalization and the small set of event kinds that need
  direct LiveView-side handling.
  """

  require Logger

  alias Rho.Events.Event, as: LiveEvent
  alias RhoWeb.AppLive
  alias RhoWeb.AppLive.DataTableEvents
  alias RhoWeb.AppLive.WorkspaceEvents
  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry

  def handle_info(%LiveEvent{} = event, socket) do
    if socket.assigns.session_id do
      route(event, socket)
    else
      {:noreply, socket}
    end
  end

  def route(%LiveEvent{kind: :data_table} = event, socket) do
    {:noreply, DataTableEvents.apply_event(socket, event.data)}
  end

  def route(%LiveEvent{kind: :workspace_open} = event, socket) do
    {:noreply, WorkspaceEvents.apply_open_workspace_event(socket, event.data)}
  end

  def route(%LiveEvent{} = event, socket) do
    data = Map.put_new(event.data, :correlation_id, event.data[:turn_id])
    signal = %{kind: event.kind, data: data, emitted_at: event.timestamp}

    socket =
      try do
        SignalRouter.route(socket, signal, WorkspaceRegistry.all())
      rescue
        e ->
          Logger.error(
            "[app_live] LiveEvent processing crashed: #{Exception.message(e)} " <>
              "kind=#{event.kind} agent_id=#{event.agent_id}
" <> Exception.format(:error, e, __STACKTRACE__)
          )

          socket
      end

    socket =
      if refresh_conversation_event?(event.kind) do
        AppLive.touch_active_conversation(socket)
        AppLive.refresh_conversations(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def deserialize_event_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {safe_to_existing_atom(k), v} end)
  end

  def deserialize_event_data(data) do
    data
  end

  def refresh_conversation_event?(kind)
      when kind in [:message_sent, :turn_finished, :tool_start, :tool_result, :error] do
    true
  end

  def refresh_conversation_event?(_kind) do
    false
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp safe_to_existing_atom(str) do
    str
  end
end
