defmodule RhoWeb.Session.SessionEffects do
  @moduledoc """
  Applies effect descriptors produced by `SessionState.reduce/2` to a
  LiveView socket.

  This is the impure boundary — all side effects (push_event, timers,
  registry lookups) happen here, keeping the reducer pure and testable.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  alias RhoWeb.Session.EffectDispatcher

  @doc """
  Applies a list of effect descriptors to the socket.

  Supported effects:

      {:push_event, name, payload}           — calls Phoenix.LiveView.push_event/3
      {:send_after, delay, message}          — calls Process.send_after/3 to self()
      {:dispatch_tool_effects, effects, ctx} — dispatches Rho.Effect.* structs via EffectDispatcher
  """
  def apply(socket, effects) do
    Enum.reduce(effects, socket, &apply_one/2)
  end

  defp apply_one({:push_event, name, payload}, socket) do
    push_event(socket, name, payload)
  end

  defp apply_one({:send_after, delay, message}, socket) do
    Process.send_after(self(), message, delay)
    socket
  end

  defp apply_one({:dispatch_tool_effects, effects, ctx}, socket) do
    EffectDispatcher.dispatch_all(effects, ctx)
    socket
  end
end
