defmodule RhoWeb.Projections.ChatroomProjection do
  @moduledoc """
  Pure reducer that transforms inter-agent and user signals into a
  unified chatroom timeline.

  State shape:
    %{
      messages: [msg],
      streaming: %{agent_id => buffer_string}
    }

  Each message is a plain map:
    %{
      id: String.t(),
      speaker: String.t(),
      direction: :outgoing | :incoming | :broadcast,
      content: String.t(),
      timestamp: integer() | nil,
      agent_id: String.t() | nil
    }
  """

  @behaviour RhoWeb.Projection

  @handled_kinds MapSet.new(~w(message_sent broadcast text_delta llm_text turn_finished)a)

  @impl true
  def handles?(kind), do: kind in @handled_kinds

  @impl true
  def init do
    %{messages: [], streaming: %{}}
  end

  @impl true
  def reduce(state, %{kind: kind, data: data}) do
    case kind do
      :message_sent -> reduce_message_sent(state, data)
      :broadcast -> reduce_broadcast(state, data)
      :text_delta -> reduce_text_delta(state, data)
      :llm_text -> reduce_text_delta(state, data)
      :turn_finished -> reduce_turn_finished(state, data)
      _ -> state
    end
  end

  # --- Reducers ---

  defp reduce_message_sent(state, data) do
    msg = %{
      id: event_id(data),
      speaker: to_string(data[:from] || "unknown"),
      direction: :outgoing,
      content: to_string(data[:message] || ""),
      timestamp: data[:emitted_at],
      agent_id: data[:from]
    }

    append(state, msg)
  end

  defp reduce_broadcast(state, data) do
    msg = %{
      id: event_id(data),
      speaker: to_string(data[:from] || data[:agent_id] || "system"),
      direction: :broadcast,
      content: to_string(data[:message] || data[:text] || ""),
      timestamp: data[:emitted_at],
      agent_id: data[:from] || data[:agent_id]
    }

    append(state, msg)
  end

  defp reduce_text_delta(state, data) do
    agent_id = to_string(data[:agent_id] || "unknown")
    text = data[:text] || ""

    streaming = state.streaming
    buffer = Map.get(streaming, agent_id, "")
    streaming = Map.put(streaming, agent_id, buffer <> text)

    %{state | streaming: streaming}
  end

  defp reduce_turn_finished(state, data) do
    agent_id = to_string(data[:agent_id] || "unknown")

    {buffer, streaming} = Map.pop(state.streaming, agent_id, "")

    state = %{state | streaming: streaming}

    # Only append if there's accumulated text
    if String.trim(buffer) != "" do
      msg = %{
        id: event_id(data),
        speaker: agent_id,
        direction: :incoming,
        content: buffer,
        timestamp: data[:emitted_at],
        agent_id: agent_id
      }

      append(state, msg)
    else
      # Also check for a text result in the turn_finished data
      case data[:result] do
        {:ok, text} when is_binary(text) and text != "" ->
          msg = %{
            id: event_id(data),
            speaker: agent_id,
            direction: :incoming,
            content: text,
            timestamp: data[:emitted_at],
            agent_id: agent_id
          }

          append(state, msg)

        _ ->
          state
      end
    end
  end

  # --- Helpers ---

  @doc false
  def append(%{messages: messages} = state, msg) do
    %{state | messages: messages ++ [msg]}
  end

  @doc false
  def flush_streaming(%{streaming: streaming} = state, agent_id) do
    {buffer, new_streaming} = Map.pop(streaming, agent_id, "")

    if String.trim(buffer) != "" do
      msg = %{
        id: generate_id(),
        speaker: to_string(agent_id),
        direction: :incoming,
        content: buffer,
        timestamp: nil,
        agent_id: to_string(agent_id)
      }

      %{state | messages: state.messages ++ [msg], streaming: new_streaming}
    else
      %{state | streaming: new_streaming}
    end
  end

  defp event_id(data) do
    data[:event_id] || generate_id()
  end

  defp generate_id do
    System.unique_integer([:positive]) |> Integer.to_string()
  end
end
