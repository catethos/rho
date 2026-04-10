defmodule RhoWeb.ChatroomComponent do
  @moduledoc """
  LiveComponent for the chatroom workspace — an interleaved timeline
  showing messages from all agents and users with speaker labels,
  color-coded by agent_id, and direction indicators.
  """
  use Phoenix.LiveComponent

  @agent_colors ~w(#6366f1 #ec4899 #14b8a6 #f59e0b #8b5cf6 #ef4444 #22c55e #3b82f6)

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:mention_input, fn -> "" end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    messages = assigns.chatroom_state.messages
    streaming = assigns.chatroom_state.streaming
    agents = assigns[:agents] || %{}

    assigns =
      assigns
      |> assign(:messages, messages)
      |> assign(:streaming_entries, streaming_entries(streaming))
      |> assign(:agents, agents)

    ~H"""
    <div class={["chatroom-workspace", @class]}>
      <div class="chatroom-timeline" id="chatroom-timeline" phx-hook="AutoScroll">
        <%= if @messages == [] and map_size(@chatroom_state.streaming) == 0 do %>
          <div class="chatroom-empty">
            No messages yet. Agents will appear here when they communicate.
          </div>
        <% end %>

        <div :for={msg <- @messages} class={"chatroom-msg chatroom-msg-#{msg.direction}"}>
          <div class="chatroom-msg-header">
            <span class="chatroom-speaker" style={"color: #{speaker_color(msg.agent_id)}"}>
              <%= display_speaker(msg.speaker, @agents) %>
            </span>
            <span class="chatroom-direction"><%= direction_icon(msg.direction) %></span>
            <span :if={msg.timestamp} class="chatroom-timestamp">
              <%= format_timestamp(msg.timestamp) %>
            </span>
          </div>
          <div class="chatroom-msg-body"><%= msg.content %></div>
        </div>

        <%!-- Streaming indicators --%>
        <div :for={{agent_id, buffer} <- @streaming_entries} class="chatroom-msg chatroom-msg-streaming">
          <div class="chatroom-msg-header">
            <span class="chatroom-speaker" style={"color: #{speaker_color(agent_id)}"}>
              <%= display_speaker(agent_id, @agents) %>
            </span>
            <span class="chatroom-direction chatroom-typing">typing...</span>
          </div>
          <div class="chatroom-msg-body chatroom-streaming-text"><%= buffer %></div>
        </div>
      </div>

      <div class="chatroom-input-area">
        <form phx-submit="chatroom_send" phx-target={@myself} class="chatroom-input-form">
          <input
            type="text"
            name="message"
            value={@mention_input}
            placeholder="@agent message... (e.g. @researcher find papers on X)"
            autocomplete="off"
            class="chatroom-input"
          />
          <button type="submit" class="chatroom-send-btn">Send</button>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("chatroom_send", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" do
      case parse_mention(message) do
        {:ok, target, text} ->
          send(self(), {:chatroom_mention, target, text})

        :no_mention ->
          send(self(), {:chatroom_broadcast, message})
      end
    end

    {:noreply, assign(socket, :mention_input, "")}
  end

  # --- Helpers ---

  @doc false
  def parse_mention(message) do
    case Regex.run(~r/^@(\S+)\s+(.+)$/s, message) do
      [_, target, text] -> {:ok, target, text}
      _ -> :no_mention
    end
  end

  defp streaming_entries(streaming) do
    streaming
    |> Enum.filter(fn {_agent_id, buffer} -> String.trim(buffer) != "" end)
    |> Enum.sort_by(fn {agent_id, _} -> agent_id end)
  end

  defp display_speaker(speaker, agents) when is_map(agents) do
    case Map.get(agents, speaker) do
      %{role: role} -> to_string(role)
      _ -> speaker || "unknown"
    end
  end

  defp speaker_color(nil), do: "#9ca3af"

  defp speaker_color(agent_id) when is_binary(agent_id) do
    index = :erlang.phash2(agent_id, length(@agent_colors))
    Enum.at(@agent_colors, index)
  end

  defp speaker_color(agent_id), do: speaker_color(to_string(agent_id))

  defp direction_icon(:outgoing), do: "->"
  defp direction_icon(:incoming), do: "<-"
  defp direction_icon(:broadcast), do: "*"
  defp direction_icon(_), do: ""

  defp format_timestamp(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} ->
        Calendar.strftime(dt, "%H:%M:%S")

      _ ->
        ""
    end
  end

  defp format_timestamp(_), do: ""
end
