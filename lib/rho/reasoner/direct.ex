defmodule Rho.Reasoner.Direct do
  @moduledoc """
  Standard tool-use reasoner: send tools+prompt to the LLM, execute tool calls,
  return results. This is the default reasoner strategy extracted from AgentLoop.
  """

  @behaviour Rho.Reasoner

  require Logger

  @max_stream_retries 2
  @terminal_tools MapSet.new(["create_anchor", "clear_memory", "finish", "end_turn"])

  @doc """
  Executes one reason+act iteration.

  Receives an `%Rho.AgentLoop.Runtime{}` as the context parameter, using:
    * `model` - the LLM model identifier
    * `gen_opts` - keyword list of generation options
    * `emit` - callback for streaming events
    * `lifecycle` - `%Rho.Lifecycle{}` with before_tool/after_tool hooks
    * `subagent` - boolean, true if running as subagent
  """
  @impl Rho.Reasoner
  def run(projection, runtime) do
    %{context: messages} = projection
    model = runtime.model
    gen_opts = runtime.gen_opts
    emit = runtime.emit
    tool_map = runtime.tool_map

    stream_opts = Keyword.merge([tools: runtime.req_tools], gen_opts)

    process_opts = [on_result: fn chunk -> emit.(%{type: :text_delta, text: chunk}) end]

    case stream_with_retry(model, messages, stream_opts, process_opts, emit, 1) do
      {:ok, response} ->
        usage = ReqLLM.Response.usage(response)
        step = Map.get(projection, :step)
        emit.(%{type: :llm_usage, step: step, usage: usage, model: model})

        tool_calls = ReqLLM.Response.tool_calls(response)

        case tool_calls do
          [] ->
            handle_no_tool_calls(response, runtime)

          tool_calls ->
            handle_tool_calls(response, tool_calls, tool_map, runtime)
        end

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  # -- No tool calls: done or subagent nudge --

  defp handle_no_tool_calls(response, runtime) do
    text = ReqLLM.Response.text(response)

    if runtime.subagent do
      {:continue, %{type: :subagent_nudge, text: text}}
    else
      {:done, %{type: :response, text: text}}
    end
  end

  # -- Tool calls: execute and decide continue/done --

  defp handle_tool_calls(response, tool_calls, tool_map, runtime) do
    emit = runtime.emit
    lifecycle = runtime.lifecycle
    response_text = ReqLLM.Response.text(response)

    if response_text && String.trim(response_text) != "" do
      emit.(%{type: :llm_text, text: response_text})
    end

    awaited =
      tool_calls
      |> Enum.map(fn tc ->
        name = ReqLLM.ToolCall.name(tc)
        args = ReqLLM.ToolCall.args_map(tc) || %{}
        call_id = tc.id
        tool_def = Map.get(tool_map, name)
        call = %{name: name, args: args, call_id: call_id}

        emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})

        case lifecycle.before_tool.(call) do
          {:deny, reason} ->
            event = %{
              type: :tool_result, name: name, status: :error,
              output: "Denied: #{reason}", call_id: call_id,
              latency_ms: 0, error_type: :denied
            }
            {nil, call, "Denied: #{reason}", event}

          :ok ->
            task = Task.async(fn ->
              if tool_def do
                t0 = System.monotonic_time(:millisecond)

                case tool_def.execute.(args) do
                  {:final, output} ->
                    latency_ms = System.monotonic_time(:millisecond) - t0
                    output_str = to_string(output)
                    {output_str, %{type: :tool_result, name: name, status: :ok, output: output_str, call_id: call_id, latency_ms: latency_ms}, :final}

                  {:ok, output} ->
                    latency_ms = System.monotonic_time(:millisecond) - t0
                    output_str = to_string(output)
                    {output_str, %{type: :tool_result, name: name, status: :ok, output: output_str, call_id: call_id, latency_ms: latency_ms}, :normal}

                  {:error, reason} ->
                    latency_ms = System.monotonic_time(:millisecond) - t0
                    error_str = "Error: #{reason}"
                    error_type = classify_tool_error(reason)
                    {error_str, %{type: :tool_result, name: name, status: :error, output: to_string(reason), call_id: call_id, latency_ms: latency_ms, error_type: error_type}, :normal}
                end
              else
                error_str = "Error: unknown tool #{name}"
                {error_str, %{type: :tool_result, name: name, status: :error, output: "unknown tool #{name}", call_id: call_id, latency_ms: 0, error_type: :unknown_tool}, :normal}
              end
            end)

            {task, call, nil, nil}
        end
      end)
      |> Enum.map(fn
        {nil, _call, denied_result, event} ->
          emit.(event)
          {ReqLLM.Context.tool_result(event.call_id, denied_result), nil}

        {task, meta, nil, nil} ->
          {result, event, disposition} = Task.await(task, :infinity)

          result = lifecycle.after_tool.(meta, result)

          emit.(%{event | output: result})

          final_output = if disposition == :final, do: result, else: nil
          {ReqLLM.Context.tool_result(meta.call_id, result), final_output}
      end)

    {tool_results, final_outputs} = Enum.unzip(awaited)
    final_output = Enum.find(final_outputs, & &1)

    # Check for terminal tool calls
    called_names = MapSet.new(tool_calls, &ReqLLM.ToolCall.name/1)
    terminal = MapSet.intersection(called_names, @terminal_tools)

    cond do
      MapSet.size(terminal) > 0 ->
        # For `end_turn`, the answer is in the streaming text, not tool args.
        # For `finish` (subagents), the answer is in the tool args.
        terminal_text =
          Enum.find_value(tool_calls, fn tc ->
            name = ReqLLM.ToolCall.name(tc)
            args = ReqLLM.ToolCall.args_map(tc) || %{}

            case name do
              "finish" -> args["result"]
              _ -> nil
            end
          end)

        {:done, %{type: :response, text: terminal_text || response_text}}

      final_output != nil ->
        {:done, %{type: :response, text: final_output}}

      true ->
        assistant_msg = ReqLLM.Context.assistant("", tool_calls: tool_calls)
        entries = %{
          type: :tool_step,
          assistant_msg: assistant_msg,
          tool_results: tool_results,
          tool_calls: tool_calls,
          response_text: response_text
        }
        {:continue, entries}
    end
  end

  # -- Helpers --

  defp stream_with_retry(model, context, stream_opts, process_opts, emit, attempt) do
    case ReqLLM.stream_text(model, context, stream_opts) do
      {:ok, stream_response} ->
        case ReqLLM.StreamResponse.process_stream(stream_response, process_opts) do
          {:ok, _response} = ok ->
            ok

          {:error, reason} ->
            if attempt <= @max_stream_retries and retryable?(reason) do
              Logger.warning("[reasoner.direct] stream_process failed (attempt #{attempt}): #{inspect(reason)}, retrying...")
              Process.sleep(1_000 * attempt)
              stream_with_retry(model, context, stream_opts, process_opts, emit, attempt + 1)
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        if attempt <= @max_stream_retries and retryable?(reason) do
          Logger.warning("[reasoner.direct] stream_text failed (attempt #{attempt}): #{inspect(reason)}, retrying...")
          Process.sleep(1_000 * attempt)
          stream_with_retry(model, context, stream_opts, process_opts, emit, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp retryable?(%Mint.TransportError{reason: reason}), do: retryable?(reason)
  defp retryable?({:timeout, _}), do: true
  defp retryable?({:closed, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(:closed), do: true
  defp retryable?({:http_task_failed, inner}), do: retryable?(inner)
  defp retryable?({:http_streaming_failed, inner}), do: retryable?(inner)
  defp retryable?({:provider_build_failed, inner}), do: retryable?(inner)
  defp retryable?(:econnrefused), do: true
  defp retryable?(:econnreset), do: true
  defp retryable?(_), do: false

  defp classify_tool_error(reason) when is_binary(reason) do
    reason_down = String.downcase(reason)

    cond do
      String.contains?(reason_down, "timeout") -> :timeout
      String.contains?(reason_down, "permission") or String.contains?(reason_down, "denied") -> :permission_denied
      String.contains?(reason_down, "not found") or String.contains?(reason_down, "no such") -> :not_found
      String.contains?(reason_down, "invalid") or String.contains?(reason_down, "argument") -> :invalid_args
      true -> :runtime_error
    end
  end

  defp classify_tool_error(_), do: :runtime_error
end
