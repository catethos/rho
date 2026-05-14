defmodule Rho.Stdlib.Tools.DebugTape do
  @moduledoc "Developer-only trace inspection tools."

  def tool_defs do
    [
      list_recent_conversations(),
      get_conversation(),
      get_tape_slice(),
      get_visible_context(),
      get_trace_findings(),
      get_debug_bundle_summary()
    ]
  end

  defp list_recent_conversations do
    %{
      tool:
        ReqLLM.tool(
          name: "list_recent_conversations",
          description: "List recent durable Rho conversations for trace debugging.",
          parameter_schema: [
            limit: [type: :integer, doc: "Max conversations (default: 10)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        limit = args[:limit] || 10

        conversations =
          Rho.Conversation.list(include_archived: true)
          |> Enum.take(limit)
          |> Enum.map(
            &Map.take(&1, ["id", "session_id", "title", "active_thread_id", "updated_at"])
          )

        json(conversations)
      end
    }
  end

  defp get_conversation do
    %{
      tool:
        ReqLLM.tool(
          name: "get_conversation",
          description: "Get durable conversation metadata by conversation id or session id.",
          parameter_schema: [
            ref: [type: :string, required: true, doc: "Conversation id or session id"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        ref = args[:ref] || ""

        conversation =
          Rho.Conversation.get(ref) ||
            Rho.Conversation.get_by_session(ref)

        case conversation do
          nil -> {:error, {:not_found, "No conversation found for #{ref}"}}
          conversation -> json(conversation)
        end
      end
    }
  end

  defp get_tape_slice do
    %{
      tool:
        ReqLLM.tool(
          name: "get_tape_slice",
          description: "Read a slice of tape entries for a debug reference.",
          parameter_schema: [
            ref: [type: :string, required: true, doc: "Conversation, session, thread, or tape"],
            last: [type: :integer, doc: "Last N entries (default: 50)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        with {:ok, resolved} <- Rho.Conversation.Ref.resolve(args[:ref] || "") do
          last = args[:last] || 50

          entries =
            resolved.tape_name
            |> Rho.Trace.Projection.entries(last: last)
            |> Enum.map(&Rho.Tape.Entry.to_map/1)

          json(%{resolved: resolved, entries: entries})
        end
      end
    }
  end

  defp get_visible_context do
    %{
      tool:
        ReqLLM.tool(
          name: "get_visible_context",
          description: "Return the exact LLM-visible context for a debug reference.",
          parameter_schema: [
            ref: [type: :string, required: true, doc: "Conversation, session, thread, or tape"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        with {:ok, resolved} <- Rho.Conversation.Ref.resolve(args[:ref] || "") do
          json(%{resolved: resolved, context: Rho.Trace.Projection.context(resolved.tape_name)})
        end
      end
    }
  end

  defp get_trace_findings do
    %{
      tool:
        ReqLLM.tool(
          name: "get_trace_findings",
          description: "Run deterministic analyzer findings for a debug reference.",
          parameter_schema: [
            ref: [type: :string, required: true, doc: "Conversation, session, thread, or tape"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        with {:ok, resolved} <- Rho.Conversation.Ref.resolve(args[:ref] || "") do
          json(%{resolved: resolved, findings: Rho.Trace.Projection.failures(resolved.tape_name)})
        end
      end
    }
  end

  defp get_debug_bundle_summary do
    %{
      tool:
        ReqLLM.tool(
          name: "get_debug_bundle_summary",
          description: "Build a debug bundle and return its summary.",
          parameter_schema: [
            ref: [type: :string, required: true, doc: "Conversation, session, thread, or tape"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        case Rho.Trace.Bundle.write(args[:ref] || "") do
          {:ok, summary} -> json(summary)
          {:error, reason} -> {:error, {:bundle_failed, inspect(reason)}}
        end
      end
    }
  end

  defp json(data), do: {:ok, Jason.encode!(data, pretty: true)}
end
