defmodule RhoWeb.Session.Welcome do
  @moduledoc """
  Legacy empty-state greeting hook for the spreadsheet agent.

  The workbench home now owns the saved-library summary and first-step
  actions, so fresh spreadsheet chats no longer receive a synthetic
  assistant message.
  """

  @doc """
  Preserve the old mount hook without injecting a hard-coded chat message.
  """
  def maybe_render(socket), do: socket

  @doc """
  Preserve the old new-agent hook without injecting a hard-coded chat message.
  """
  def render_for_new_agent(socket, _agent_id), do: socket

  @doc """
  Preserve the old reopen hook without injecting a hard-coded chat message.
  """
  def render_for_active_agent(socket), do: socket
end
