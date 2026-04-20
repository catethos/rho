defmodule RhoWeb.ChatOverlayComponent do
  @moduledoc """
  A self-contained chat overlay that can be embedded in any LiveView.

  Opens a floating panel with a chat connected to an agent session.
  The parent LiveView must:
  1. Forward `{:signal, _}` messages via `send_update/3`
  2. Handle the `{:chat_overlay_started, session_id}` info message
  3. Handle the `{:chat_overlay_closed, session_id}` info message
  """
  use Phoenix.LiveComponent

  import RhoWeb.ChatComponents, only: [message_row: 1, envelope_preview: 1]

  alias RhoWeb.Session.SessionCore

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:messages, [])
     |> assign(:pending, false)
     |> assign(:session_id, nil)
     |> assign(:agent_id, nil)
     |> assign(:inflight, %{})
     |> assign(:intent_sent, false)
     |> assign(:next_id, 1)}
  end

  @impl true
  def update(%{signal: {:signal, %Jido.Signal{type: type, data: data} = signal}}, socket) do
    sid = socket.assigns.session_id

    if sid && SessionCore.signal_for_session?(data, sid) do
      correlation_id = get_in(signal.extensions || %{}, ["correlation_id"])
      data = Map.put(data, :correlation_id, correlation_id)
      socket = route_signal(socket, type, data)
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    was_open = socket.assigns[:open] || false
    now_open = assigns[:open] || false

    socket = assign(socket, assigns)

    socket =
      if now_open && !was_open && !socket.assigns.session_id do
        start_session(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      socket = send_chat_message(socket, content)
      {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket) do
    send(self(), {:chat_overlay_closed, socket.assigns.session_id})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div :if={@open} class="chat-overlay-backdrop" phx-click="close" phx-target={@myself}></div>
      <div :if={@open} class="chat-overlay-panel">
        <div class="chat-overlay-header">
          <span class="chat-overlay-title">New Library</span>
          <button class="chat-overlay-close" phx-click="close" phx-target={@myself}>&times;</button>
        </div>

        <div class="chat-overlay-feed" id="chat-overlay-feed" phx-hook="AutoScroll">
          <div :for={msg <- @messages} id={msg.id} class="message-wrapper">
            <.message_row message={msg} />
          </div>

          <div :if={@pending && @inflight == %{}} class="message-wrapper">
            <div class="message message-assistant">
              <div class="message-avatar avatar-assistant">R</div>
              <div class="message-content">
                <div class="message-body pending-indicator">
                  <span class="pending-dots"><span>.</span><span>.</span><span>.</span></span>
                </div>
              </div>
            </div>
          </div>

          <div :for={{agent_id, entry} <- @inflight} id={"overlay-streaming-#{agent_id}"}>
            <div class="message-wrapper">
              <div class="message message-assistant streaming">
                <div class="message-avatar avatar-assistant">R</div>
                <div class="message-content">
                  <.envelope_preview :if={entry[:envelope]} envelope={entry.envelope} stream_id={agent_id} />
                  <div style={if(entry[:envelope], do: "display:none", else: "")}>
                    <div
                      class="message-body"
                      id={"stream-body-#{agent_id}"}
                      phx-update="ignore"
                      phx-hook="StreamingText"
                    ></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="chat-overlay-input-area">
          <form phx-submit="send_message" phx-target={@myself} class="chat-overlay-input-form">
            <textarea
              name="content"
              id="chat-overlay-input"
              placeholder="Describe the library you want to create..."
              rows="1"
              phx-hook="AutoResize"
            ></textarea>
            <button type="submit" class="btn-send">Send</button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # --- Private ---

  defp start_session(socket) do
    new_sid = "overlay_#{System.unique_integer([:positive])}"
    agent_name = socket.assigns[:agent_name]

    start_opts =
      [
        user_id: get_in(socket.assigns, [:current_user, Access.key(:id)]),
        organization_id: get_in(socket.assigns, [:current_organization, Access.key(:id)])
      ]
      |> then(fn opts ->
        if agent_name, do: Keyword.put(opts, :agent_name, agent_name), else: opts
      end)

    {:ok, _pid} = Rho.Agent.Primary.ensure_started(new_sid, start_opts)
    primary_id = Rho.Agent.Primary.agent_id(new_sid)

    # Notify parent to subscribe to signals for this session
    send(self(), {:chat_overlay_started, new_sid})

    socket =
      socket
      |> assign(:session_id, new_sid)
      |> assign(:agent_id, primary_id)

    # Auto-send the intent as the first user message
    intent = socket.assigns[:intent]

    if intent && intent != "" do
      socket
      |> send_chat_message(intent)
      |> assign(:intent_sent, true)
    else
      socket
    end
  end

  defp send_chat_message(socket, content) do
    sid = socket.assigns.session_id
    {id, socket} = next_id(socket)

    user_msg = %{
      id: id,
      role: :user,
      type: :text,
      content: content
    }

    socket = assign(socket, :messages, Enum.take(socket.assigns.messages ++ [user_msg], -200))

    pid = Rho.Agent.Primary.whereis(sid)

    case Rho.Agent.Worker.submit(pid, content) do
      {:ok, _turn_id} ->
        assign(socket, :pending, true)

      {:error, _reason} ->
        socket
    end
  end

  defp next_id(socket) do
    id = socket.assigns.next_id
    {"overlay_msg_#{id}", assign(socket, :next_id, id + 1)}
  end

  # --- Signal routing ---
  # Mirrors SessionState reducer logic for the overlay context.

  defp route_signal(socket, type, data) do
    cond do
      String.ends_with?(type, ".text_delta") ->
        handle_text_delta(socket, data)

      String.ends_with?(type, ".llm_text") ->
        handle_text_delta(socket, data)

      String.ends_with?(type, ".tool_start") ->
        handle_tool_start(socket, data)

      String.ends_with?(type, ".tool_result") ->
        handle_tool_result(socket, data)

      String.ends_with?(type, ".turn_finished") ->
        handle_turn_finished(socket, data)

      String.ends_with?(type, ".step_finished") ->
        handle_step_finished(socket, data)

      true ->
        socket
    end
  end

  defp handle_text_delta(socket, data) do
    agent_id = data[:agent_id] || socket.assigns.agent_id
    text = data[:text] || ""

    inflight = socket.assigns.inflight

    entry =
      Map.get(inflight, agent_id, %{agent_id: agent_id, chunks: [], envelope: nil})

    entry = %{entry | chunks: entry.chunks ++ [text]}

    # Analyze buffer for envelope (same as SessionState)
    buffer = IO.iodata_to_binary(entry.chunks)

    envelope =
      case RhoWeb.StreamEnvelope.analyze(buffer) do
        {:envelope, summary} -> summary
        :no_envelope -> entry[:envelope]
      end

    entry = Map.put(entry, :envelope, envelope)
    inflight = Map.put(inflight, agent_id, entry)

    socket
    |> assign(:inflight, inflight)
    |> assign(:pending, false)
    |> Phoenix.LiveView.push_event("text-chunk", %{agent_id: agent_id, text: text})
  end

  defp handle_tool_start(socket, data) do
    name = data[:name]

    if name in ["end_turn", "finish", "present_ui"] do
      socket
    else
      agent_id = data[:agent_id] || socket.assigns.agent_id

      # Flush inflight text to a thinking message
      {socket, _} = flush_inflight_to_thinking(socket, agent_id)

      {id, socket} = next_id(socket)

      msg = %{
        id: id,
        role: :assistant,
        type: :tool_call,
        name: name,
        args: data[:args],
        call_id: data[:call_id],
        agent_id: agent_id,
        status: :pending,
        content: "Tool: #{name}"
      }

      assign(socket, :messages, socket.assigns.messages ++ [msg])
    end
  end

  defp handle_tool_result(socket, data) do
    cond do
      data[:name] in ["end_turn", "finish", "present_ui"] -> socket
      is_nil(data[:call_id]) -> socket
      true -> update_tool_call_status(socket, data[:call_id], data[:status] || :ok, data[:output])
    end
  end

  defp update_tool_call_status(socket, call_id, status, output) do
    messages =
      Enum.map(socket.assigns.messages, fn msg ->
        if msg[:call_id] == call_id do
          Map.merge(msg, %{status: status, output: output})
        else
          msg
        end
      end)

    assign(socket, :messages, messages)
  end

  defp handle_turn_finished(socket, data) do
    agent_id = data[:agent_id] || socket.assigns.agent_id

    # Flush any remaining inflight text as thinking
    {socket, has_final_answer} = flush_inflight_to_thinking(socket, agent_id)

    # Clear inflight for this agent
    inflight = Map.delete(socket.assigns.inflight, agent_id)

    # Add the final assistant message from the result
    socket =
      case data[:result] do
        {:ok, text} when is_binary(text) and text != "" ->
          if has_final_answer do
            # The thinking message already contains the final answer — skip duplicate
            socket
          else
            {id, socket} = next_id(socket)

            msg = %{
              id: id,
              role: :assistant,
              type: :text,
              content: text,
              agent_id: agent_id
            }

            assign(socket, :messages, socket.assigns.messages ++ [msg])
          end

        {:error, reason} ->
          {id, socket} = next_id(socket)

          msg = %{
            id: id,
            role: :system,
            type: :error,
            content: inspect(reason),
            agent_id: agent_id
          }

          assign(socket, :messages, socket.assigns.messages ++ [msg])

        _ ->
          socket
      end

    socket
    |> assign(:inflight, inflight)
    |> assign(:pending, false)
    |> Phoenix.LiveView.push_event("stream-end", %{agent_id: agent_id})
  end

  defp handle_step_finished(socket, _data) do
    assign(socket, :pending, false)
  end

  defp flush_inflight_to_thinking(socket, agent_id) do
    case Map.get(socket.assigns.inflight, agent_id) do
      %{chunks: chunks} when chunks != [] ->
        raw = Enum.join(chunks)

        if String.trim(raw) != "" do
          has_final_answer = contains_final_answer?(raw)
          {id, socket} = next_id(socket)

          thinking_msg = %{
            id: id,
            role: :assistant,
            type: :thinking,
            content: raw,
            agent_id: agent_id
          }

          inflight =
            Map.put(socket.assigns.inflight, agent_id, %{
              agent_id: agent_id,
              chunks: [],
              envelope: nil
            })

          socket =
            socket
            |> assign(:messages, socket.assigns.messages ++ [thinking_msg])
            |> assign(:inflight, inflight)
            |> Phoenix.LiveView.push_event("stream-end", %{agent_id: agent_id})

          {socket, has_final_answer}
        else
          {socket, false}
        end

      _ ->
        {socket, false}
    end
  end

  defp contains_final_answer?(raw) do
    case Rho.StructuredOutput.parse(raw) do
      {:ok, %{"action" => "final_answer"}} -> true
      _ -> false
    end
  end
end
