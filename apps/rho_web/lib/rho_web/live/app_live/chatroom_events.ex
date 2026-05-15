defmodule RhoWeb.AppLive.ChatroomEvents do
  @moduledoc """
  Handles chatroom-originated messages for `RhoWeb.AppLive`.

  Chatroom mentions temporarily route a user message through a specific agent,
  while broadcasts use the currently active agent. This module owns the target
  resolution rules so the root LiveView can stay as a mailbox router.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.Session.SessionCore

  def handle_info({:chatroom_mention, target, text}, socket) do
    with sid when is_binary(sid) <- socket.assigns.session_id,
         {:ok, agent_id} <- resolve_mention_target(sid, target) do
      prev_agent_id = socket.assigns.active_agent_id
      socket = assign(socket, :active_agent_id, agent_id)
      {:noreply, socket} = SessionCore.send_message(socket, text)
      {:noreply, assign(socket, :active_agent_id, prev_agent_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:chatroom_broadcast, message}, socket) do
    if socket.assigns.session_id do
      SessionCore.send_message(socket, message)
    else
      {:noreply, socket}
    end
  end

  def resolve_mention_target(sid, target) do
    case Rho.Agent.Worker.whereis(target) do
      pid when is_pid(pid) -> {:ok, target}
      nil -> resolve_mention_by_role(sid, target)
    end
  end

  defp resolve_mention_by_role(sid, target) do
    role_atom = safe_to_existing_atom(target)

    if is_atom(role_atom) do
      case Rho.Agent.Registry.find_by_role(sid, role_atom) do
        [agent | _] -> {:ok, agent.agent_id}
        _ -> :error
      end
    else
      :error
    end
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
