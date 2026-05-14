defmodule Rho.Recorder do
  @moduledoc """
  Unified tape recording for the agent loop.

  This is the single module that writes semantic content to the tape:
  user messages, assistant text, tool calls, tool results, and injected
  messages. All writes are no-ops when the tape name is `nil` (no
  persistence configured).

  Also provides `rebuild_context/1` to reconstruct the LLM message list
  from the tape after recording or compaction.
  """

  alias Rho.Runner.Runtime

  @spec record_input_messages(Runtime.t(), [map()]) :: :ok
  def record_input_messages(%Runtime{tape: %{name: nil}}, _messages), do: :ok

  def record_input_messages(%Runtime{tape: %{name: tape, tape_module: mem}} = runtime, messages) do
    for %{role: :user, content: content} <- messages do
      append_with_tape_write(
        runtime,
        mem,
        tape,
        :message,
        %{"role" => "user", "content" => extract_text(content)}
      )
    end

    :ok
  end

  @spec record_assistant_text(Runtime.t(), String.t() | nil) :: :ok
  def record_assistant_text(%Runtime{tape: %{name: nil}}, _text), do: :ok
  def record_assistant_text(_runtime, nil), do: :ok

  def record_assistant_text(%Runtime{tape: %{name: tape, tape_module: mem}} = runtime, text) do
    append_with_tape_write(runtime, mem, tape, :message, %{
      "role" => "assistant",
      "content" => text
    })

    :ok
  end

  @spec record_tool_step(Runtime.t(), map()) :: :ok
  def record_tool_step(%Runtime{tape: %{name: nil}}, _entries), do: :ok

  def record_tool_step(%Runtime{tape: %{name: tape, tape_module: mem}} = runtime, entries) do
    %{tool_calls: tool_calls, tool_results: tool_results} = entries

    with text when is_binary(text) <- entries[:response_text],
         trimmed when trimmed != "" <- String.trim(text) do
      append_with_tape_write(runtime, mem, tape, :message, %{
        "role" => "assistant",
        "content" => text
      })
    end

    if tool_calls == [] do
      # TypedStructured strategy: record as plain assistant + user messages
      %{assistant_msg: assistant_msg} = entries

      append_with_tape_write(runtime, mem, tape, :message, %{
        "role" => "assistant",
        "content" => extract_text(assistant_msg.content)
      })

      for result_msg <- tool_results do
        append_with_tape_write(runtime, mem, tape, :message, %{
          "role" => "user",
          "content" => extract_text(result_msg.content)
        })
      end
    else
      # Direct strategy: record as tool_call/tool_result entries
      Enum.each(tool_calls, fn tc ->
        append_with_tape_write(runtime, mem, tape, :tool_call, %{
          "name" => ReqLLM.ToolCall.name(tc),
          "args" => ReqLLM.ToolCall.args_map(tc) || %{},
          "call_id" => tc.id
        })
      end)

      meta_by_call_id = Map.new(entries[:tool_meta] || [], &{&1.call_id, &1})

      Enum.each(tool_results, fn %{tool_call_id: call_id, content: content} ->
        meta = Map.get(meta_by_call_id, call_id, %{})

        append_with_tape_write(
          runtime,
          mem,
          tape,
          :tool_result,
          tool_result_payload(call_id, content, meta)
        )
      end)
    end

    :ok
  end

  @spec record_injected_messages(Runtime.t(), [String.t()]) :: :ok
  def record_injected_messages(%Runtime{tape: %{name: nil}}, _messages), do: :ok

  def record_injected_messages(
        %Runtime{tape: %{name: tape, tape_module: mem}} = runtime,
        messages
      ) do
    for msg <- messages do
      append_with_tape_write(runtime, mem, tape, :message, %{"role" => "user", "content" => msg})
    end

    :ok
  end

  @spec rebuild_context(Runtime.t()) :: [map()]
  def rebuild_context(%Runtime{tape: %{name: tape}} = runtime) do
    [Rho.Runner.build_system_message(runtime) | Rho.Tape.Projection.build(tape)]
  end

  # Build a tape `:tool_result` payload, preserving the real tool name plus
  # status/error_type when the strategy supplied them via `:tool_meta`. Falls
  # back to a generic ok-shaped entry for callers that don't pass meta.
  defp tool_result_payload(call_id, content, meta) do
    base = %{
      "name" => Map.get(meta, :name) || "tool",
      "status" => meta |> Map.get(:status, :ok) |> Atom.to_string(),
      "output" => extract_text(content),
      "call_id" => call_id
    }

    case meta[:error_type] do
      nil -> base
      type when is_atom(type) -> Map.put(base, "error_type", Atom.to_string(type))
      type -> Map.put(base, "error_type", to_string(type))
    end
  end

  # -- Tape-write transformer pipeline --

  defp append_with_tape_write(%Runtime{context: ctx} = runtime, mem, tape, kind, data)
       when not is_nil(ctx) do
    meta = runtime_meta(runtime)
    entry = %{kind: kind, data: data, meta: meta}

    {:cont, transformed} = Rho.PluginRegistry.apply_stage(:tape_write, entry, ctx)

    append_mem(mem, tape, transformed.kind, transformed.data, Map.get(transformed, :meta, meta))
  end

  defp append_with_tape_write(_runtime, mem, tape, kind, data) do
    append_mem(mem, tape, kind, data, %{})
  end

  defp append_mem(mem, tape, kind, data, meta) do
    if function_exported?(mem, :append, 4) do
      mem.append(tape, kind, data, meta)
    else
      mem.append(tape, kind, data)
    end
  end

  defp runtime_meta(%Runtime{} = runtime) do
    %{}
    |> maybe_put_meta("conversation_id", runtime.context.conversation_id)
    |> maybe_put_meta("thread_id", runtime.context.thread_id)
    |> maybe_put_meta("session_id", runtime.context.session_id)
    |> maybe_put_meta("agent_id", runtime.context.agent_id)
    |> maybe_put_meta("turn_id", runtime.context.turn_id)
    |> maybe_put_meta("model", runtime.model && to_string(runtime.model))
    |> maybe_put_meta("strategy", inspect(runtime.turn_strategy))
  end

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, _key, ""), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  # -- Text extraction --

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    Enum.map_join(content, fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> ""
    end)
  end

  defp extract_text(content), do: inspect(content)
end