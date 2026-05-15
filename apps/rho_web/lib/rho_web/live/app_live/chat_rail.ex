defmodule RhoWeb.AppLive.ChatRail do
  @moduledoc """
  Builds chat-rail rows from durable conversation and thread metadata.
  """

  @doc """
  Expands one conversation into one or more chat rail rows.

  A conversation with multiple threads yields one row per thread. The active
  thread can use the in-memory messages from the current LiveView session while
  inactive rows fall back to tape projections.
  """
  def items(conversation, active_id, active_thread_id, active_messages) do
    threads = conversation["threads"] || []

    case threads do
      [] ->
        [item(conversation, nil, active_id, active_thread_id, active_messages, false)]

      [_one] ->
        Enum.map(
          threads,
          &item(conversation, &1, active_id, active_thread_id, active_messages, false)
        )

      many ->
        Enum.map(
          many,
          &item(conversation, &1, active_id, active_thread_id, active_messages, true)
        )
    end
  end

  def item(conversation, thread, active_id, active_thread_id, active_messages, threaded?) do
    thread_id = thread && thread["id"]
    active = row_active?(conversation["id"], thread_id, active_id, active_thread_id)

    messages =
      if active and active_messages != [] do
        active_messages
      else
        trace_messages(thread)
      end

    last_message = last_text_message(messages)
    last_user_message = last_text_message(messages, :user)
    updated_at = row_updated_at(conversation, thread, active)

    %{
      id: row_id(conversation, thread),
      conversation_id: conversation["id"],
      session_id: conversation["session_id"],
      thread_id: thread_id,
      agent_name: conversation_agent_name(conversation),
      title: title(conversation, thread, last_user_message, threaded?),
      preview: preview(thread, last_message, conversation),
      updated_at: updated_at,
      updated_label: relative_time(updated_at),
      active: active
    }
  end

  def row_active?(conversation_id, thread_id, active_id, active_thread_id)
      when conversation_id == active_id do
    is_nil(thread_id) or is_nil(active_thread_id) or thread_id == active_thread_id
  end

  def row_active?(_conversation_id, _thread_id, _active_id, _active_thread_id), do: false

  def text(%{content: content}), do: content_to_text(content)
  def text(%{"content" => content}), do: content_to_text(content)
  def text(_), do: ""

  def truncate(nil, _max_value), do: ""

  def truncate(text, max_value) when is_binary(text) do
    if String.length(text) > max_value do
      String.slice(text, 0, max_value) <> "..."
    else
      text
    end
  end

  defp row_id(%{"id" => conversation_id}, %{"id" => thread_id}),
    do: "#{conversation_id}:#{thread_id}"

  defp row_id(%{"id" => conversation_id}, _thread), do: conversation_id

  defp row_updated_at(conversation, thread, true) do
    conversation["updated_at"] || (thread && thread["updated_at"])
  end

  defp row_updated_at(conversation, thread, _active?) do
    (thread && thread["updated_at"]) || conversation["updated_at"]
  end

  defp trace_messages(%{"tape_name" => tape_name}) when is_binary(tape_name) do
    Rho.Trace.Projection.chat(tape_name, last: 80)
  rescue
    _ -> []
  end

  defp trace_messages(_thread), do: []

  defp last_text_message(messages, role \\ nil) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn message ->
      role_match? = is_nil(role) or Map.get(message, :role) == role
      role_match? and text(message) != ""
    end)
  end

  defp conversation_agent_name(%{"agent_name" => agent_name}) when is_binary(agent_name) do
    agent_name
  end

  defp conversation_agent_name(_conversation), do: :default

  defp conversation_title(%{"title" => title}, _thread, _message)
       when is_binary(title) and title not in ["", "New conversation"] do
    truncate(title, 48)
  end

  defp conversation_title(_conversation, _thread, message) when is_map(message) do
    message |> text() |> truncate(48)
  end

  defp conversation_title(_conversation, %{"name" => name}, _message)
       when is_binary(name) and name not in ["", "Main", "New Thread", "New chat"] do
    truncate(name, 48)
  end

  defp conversation_title(_conversation, _thread, _message), do: "New chat"

  defp title(conversation, thread, message, threaded?) do
    cond do
      custom_conversation_title?(conversation) -> conversation_title(conversation, thread, nil)
      is_map(message) -> message |> text() |> truncate(48)
      not threaded? -> conversation_title(conversation, thread, nil)
      thread_title(thread) -> thread_title(thread)
      true -> "New chat"
    end
  end

  defp custom_conversation_title?(%{"title" => title})
       when is_binary(title) and title not in ["", "New conversation"] do
    true
  end

  defp custom_conversation_title?(_conversation), do: false

  defp thread_title(%{"name" => name})
       when is_binary(name) and name not in ["", "Main", "New Thread", "New chat"] do
    truncate(name, 48)
  end

  defp thread_title(_thread), do: nil

  defp preview(_thread, message, _conversation) when is_map(message) do
    role =
      message
      |> Map.get(:role)
      |> case do
        :user -> "You"
        :assistant -> "Assistant"
        :system -> "System"
        _ -> "Message"
      end

    "#{role}: #{message |> text() |> truncate(70)}"
  end

  defp preview(%{"summary" => summary}, _message, _conversation)
       when is_binary(summary) and summary != "" do
    truncate(summary, 70)
  end

  defp preview(_thread, _message, conversation) do
    case conversation["title"] do
      title when is_binary(title) and title not in ["", "New conversation"] ->
        truncate(title, 70)

      _ ->
        "No messages yet"
    end
  end

  defp content_to_text(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp content_to_text(text) when is_list(text) do
    text
    |> Enum.map_join(" ", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other when is_binary(other) -> other
      _ -> ""
    end)
    |> content_to_text()
  end

  defp content_to_text(text) when is_map(text) do
    text |> inspect(limit: 20) |> content_to_text()
  end

  defp content_to_text(_), do: ""

  defp relative_time(nil), do: ""

  defp relative_time(iso) when is_binary(iso) do
    with {:ok, dt, _} <- DateTime.from_iso8601(iso) do
      seconds = max(DateTime.diff(DateTime.utc_now(), dt, :second), 0)

      cond do
        seconds < 60 -> "now"
        seconds < 3600 -> "#{div(seconds, 60)}m"
        seconds < 86400 -> "#{div(seconds, 3600)}h"
        seconds < 604_800 -> "#{div(seconds, 86400)}d"
        true -> Calendar.strftime(dt, "%b %-d")
      end
    else
      _ -> ""
    end
  end
end
