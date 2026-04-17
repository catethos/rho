defmodule Rho.AgentLoop.Recorder do
  @moduledoc """
  Unified tape recording for the agent loop.

  This is the single module that writes semantic content to the tape:
  user messages, assistant text, tool calls, tool results, and injected
  messages. All writes are no-ops when the tape name is `nil` (no
  persistence configured).

  Also provides `rebuild_context/1` to reconstruct the LLM message list
  from the tape after recording or compaction.
  """

  alias Rho.AgentLoop.Runtime

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
      # Structured reasoner: record as plain assistant + user messages
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
      # Direct reasoner: record as tool_call/tool_result entries
      Enum.each(tool_calls, fn tc ->
        append_with_tape_write(runtime, mem, tape, :tool_call, %{
          "name" => ReqLLM.ToolCall.name(tc),
          "args" => ReqLLM.ToolCall.args_map(tc) || %{},
          "call_id" => tc.id
        })
      end)

      Enum.each(tool_results, fn %{tool_call_id: call_id, content: content} ->
        append_with_tape_write(runtime, mem, tape, :tool_result, %{
          "name" => "tool",
          "status" => "ok",
          "output" => extract_text(content),
          "call_id" => call_id
        })
      end)
    end

    :ok
  end

  @spec record_injected_messages(Runtime.t(), [String.t()]) :: :ok
  def record_injected_messages(%Runtime{tape: %{name: nil}}, _messages), do: :ok

  def record_injected_messages(%Runtime{tape: %{name: tape, tape_module: mem}} = runtime, messages) do
    for msg <- messages do
      append_with_tape_write(runtime, mem, tape, :message, %{"role" => "user", "content" => msg})
    end

    :ok
  end

  @spec rebuild_context(Runtime.t()) :: [map()]
  def rebuild_context(%Runtime{system_prompt: prompt, tape: %{name: tape}}) do
    system_msg =
      ReqLLM.Context.system([
        ReqLLM.Message.ContentPart.text(prompt, %{
          cache_control: %{type: "ephemeral"}
        })
      ])

    [system_msg | Rho.Tape.Context.build(tape)]
  end

  # -- Tape-write transformer pipeline --

  defp append_with_tape_write(%Runtime{context: ctx}, mem, tape, kind, data)
       when not is_nil(ctx) do
    entry = %{kind: kind, data: data}

    {:cont, %{kind: new_kind, data: new_data}} =
      Rho.PluginRegistry.apply_stage(:tape_write, entry, ctx)

    result = mem.append(tape, new_kind, new_data)
    publish_entry_appended(ctx, tape, new_kind, new_data)
    result
  end

  defp append_with_tape_write(_runtime, mem, tape, kind, data) do
    mem.append(tape, kind, data)
  end

  defp publish_entry_appended(%{session_id: sid, agent_id: aid}, tape, kind, data)
       when is_binary(sid) do
    Rho.Comms.publish(
      "rho.session.#{sid}.tape.entry_appended",
      %{
        tape_name: tape,
        kind: kind,
        data: data,
        agent_id: aid,
        session_id: sid
      },
      source: "/session/#{sid}/agent/#{aid || "unknown"}"
    )

    :ok
  end

  defp publish_entry_appended(_ctx, _tape, _kind, _data), do: :ok

  # -- Text extraction --

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> ""
    end)
  end

  defp extract_text(other), do: inspect(other)
end
