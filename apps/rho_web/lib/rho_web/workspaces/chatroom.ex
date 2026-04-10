defmodule RhoWeb.Workspaces.Chatroom do
  @moduledoc """
  Workspace metadata for the Chatroom panel.
  """
  use RhoWeb.Workspace

  @impl true
  def key, do: :chatroom

  @impl true
  def label, do: "Chatroom"

  @impl true
  def icon, do: "chat"

  @impl true
  def auto_open?, do: false

  @impl true
  def default_surface, do: :tab

  @impl true
  def projection, do: RhoWeb.Projections.ChatroomProjection

  @impl true
  def component, do: RhoWeb.ChatroomComponent

  @impl true
  def component_assigns(ws_state, shared) do
    %{
      chatroom_state: ws_state,
      agents: shared.agents,
      session_id: shared.session_id
    }
  end

  # Chatroom mention/broadcast handlers stay in SessionLive because they
  # need session-level orchestration (SessionCore.send_message, agent routing).
end
