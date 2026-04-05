defmodule RhoWeb.SignalComponents do
  @moduledoc """
  Signal timeline and signal chip components.
  """
  use Phoenix.Component

  attr(:open, :boolean, default: false)

  def signal_timeline(assigns) do
    ~H"""
    <div class={"signal-timeline #{if @open, do: "open", else: "collapsed"}"}>
      <button class="timeline-toggle" phx-click="toggle_timeline">
        <span class="timeline-label">Signal Timeline</span>
        <span class="timeline-arrow"><%= if @open, do: "▼", else: "▶" %></span>
      </button>
      <div :if={@open} class="timeline-track" id="signal-timeline-track" phx-hook="SignalTimeline" phx-update="ignore">
      </div>
    </div>
    """
  end
end
