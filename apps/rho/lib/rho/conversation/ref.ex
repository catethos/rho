defmodule Rho.Conversation.Ref do
  @moduledoc """
  Resolves user-facing debug references to a concrete tape.
  """

  @type resolved :: %{
          conversation_id: String.t() | nil,
          session_id: String.t() | nil,
          thread_id: String.t() | nil,
          tape_name: String.t(),
          workspace: String.t() | nil,
          event_log_path: String.t() | nil
        }

  @doc "Resolve a conversation id, session id, thread id, or tape name."
  @spec resolve(String.t()) :: {:ok, resolved()} | {:error, :not_found}
  def resolve(ref) when is_binary(ref) do
    cond do
      conversation = Rho.Conversation.get(ref) ->
        {:ok, from_conversation(conversation)}

      conversation = Rho.Conversation.get_by_session(ref) ->
        {:ok, from_conversation(conversation)}

      pair = Rho.Conversation.get_by_thread(ref) ->
        {conversation, thread} = pair
        {:ok, from_conversation(conversation, thread)}

      tape_exists?(ref) ->
        {:ok,
         %{
           conversation_id: nil,
           session_id: nil,
           thread_id: nil,
           tape_name: ref,
           workspace: nil,
           event_log_path: nil
         }}

      true ->
        {:error, :not_found}
    end
  end

  defp from_conversation(conversation) do
    thread =
      Rho.Conversation.active_thread(conversation["id"]) ||
        List.first(conversation["threads"] || []) ||
        %{}

    from_conversation(conversation, thread)
  end

  defp from_conversation(conversation, thread) do
    workspace = conversation["workspace"]
    session_id = conversation["session_id"]

    %{
      conversation_id: conversation["id"],
      session_id: session_id,
      thread_id: thread["id"],
      tape_name: thread["tape_name"],
      workspace: workspace,
      event_log_path: event_log_path(workspace, session_id)
    }
  end

  defp event_log_path(workspace, session_id)
       when is_binary(workspace) and is_binary(session_id) do
    path = Path.join([workspace, "_rho", "sessions", session_id, "events.jsonl"])
    if File.exists?(path), do: path
  end

  defp event_log_path(_workspace, _session_id), do: nil

  defp tape_exists?(tape_name) do
    File.exists?(Rho.Tape.Store.path_for(tape_name)) or Rho.Tape.Store.last_id(tape_name) > 0
  rescue
    _ -> false
  end
end
