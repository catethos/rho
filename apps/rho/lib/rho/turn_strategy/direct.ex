defmodule Rho.TurnStrategy.Direct do
  @moduledoc """
  Standard tool-use strategy: send tools+prompt to the LLM, execute tool
  calls, return results. Default TurnStrategy.

  Tool policy / result rewriting flow through Transformer stages
  `:tool_args_out` and `:tool_result_in` via `Rho.PluginRegistry`.
  """

  @behaviour Rho.TurnStrategy

  require Logger

  @max_stream_retries 2
  @terminal_tools MapSet.new(["create_anchor", "clear_memory", "finish", "end_turn"])

  @impl Rho.TurnStrategy
  def prompt_sections(_tool_defs, _context), do: []

  @impl Rho.TurnStrategy
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

        # :response_in stage
        response_data = %{
          text: ReqLLM.Response.text(response),
          tool_calls: tool_calls,
          usage: usage
        }

        case Rho.PluginRegistry.apply_stage(:response_in, response_data, runtime.context) do
          {:halt, reason} ->
            emit.(%{type: :error, reason: {:halt, reason}})
            {:error, {:halt, reason}}

          {:cont, _} ->
            case tool_calls do
              [] -> handle_no_tool_calls(response, runtime)
              _ -> handle_tool_calls(response, tool_calls, tool_map, runtime)
            end
        end

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  # -- No tool calls --

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
    ctx = runtime.context
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

        emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})

        # :tool_args_out stage — {:cont, data} / {:deny, reason} / {:halt, reason}
        args_data = %{tool_name: name, args: args}

        case Rho.PluginRegistry.apply_stage(:tool_args_out, args_data, ctx) do
          {:deny, reason} ->
            event = %{
              type: :tool_result,
              name: name,
              status: :error,
              output: "Denied: #{reason}",
              call_id: call_id,
              latency_ms: 0,
              error_type: :denied
            }

            {nil, %{name: name, args: args, call_id: call_id}, "Denied: #{reason}", event}

          {:halt, reason} ->
            throw({:rho_transformer_halt, reason})

          {:cont, %{args: new_args}} ->
            cast_args =
              if tool_def,
                do: Rho.ToolArgs.cast(new_args, tool_def.tool.parameter_schema),
                else: new_args

            call = %{name: name, args: cast_args, call_id: call_id}

            task =
              Task.async(fn ->
                if tool_def do
                  t0 = System.monotonic_time(:millisecond)

                  result = tool_def.execute.(cast_args, ctx)
                  latency_ms = System.monotonic_time(:millisecond) - t0

                  :telemetry.execute(
                    [:rho, :tool, :execute],
                    %{duration_ms: latency_ms},
                    %{
                      tool_name: name,
                      status: if(match?({:error, _}, result), do: :error, else: :ok)
                    }
                  )

                  normalize_tool_result(result, name, call_id, latency_ms)
                else
                  error_str = "Error: unknown tool #{name}"

                  {error_str,
                   %{
                     type: :tool_result,
                     name: name,
                     status: :error,
                     output: "unknown tool #{name}",
                     call_id: call_id,
                     latency_ms: 0,
                     error_type: :unknown_tool
                   }, :normal}
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
          {result, event, disposition} = Task.await(task, :timer.minutes(5))

          # :tool_result_in stage
          result =
            case Rho.PluginRegistry.apply_stage(
                   :tool_result_in,
                   %{tool_name: meta.name, result: result},
                   ctx
                 ) do
              {:cont, %{result: new}} -> to_string(new)
              {:halt, reason} -> throw({:rho_transformer_halt, reason})
            end

          emit.(%{event | output: result})

          final_output = if disposition == :final, do: result, else: nil
          {ReqLLM.Context.tool_result(meta.call_id, result), final_output}
      end)

    {tool_results, final_outputs} = Enum.unzip(awaited)
    final_output = Enum.find(final_outputs, & &1)

    called_names = MapSet.new(tool_calls, &ReqLLM.ToolCall.name/1)
    terminal = MapSet.intersection(called_names, @terminal_tools)

    cond do
      MapSet.size(terminal) > 0 ->
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
  catch
    {:rho_transformer_halt, reason} ->
      runtime.emit.(%{type: :error, reason: {:halt, reason}})
      {:error, {:halt, reason}}
  end

  # -- Tool result normalization --

  defp normalize_tool_result(%Rho.ToolResponse{} = resp, name, call_id, latency_ms) do
    output_str = resp.text || ""

    {output_str,
     %{
       type: :tool_result,
       name: name,
       status: :ok,
       output: output_str,
       call_id: call_id,
       latency_ms: latency_ms,
       effects: resp.effects
     }, :normal}
  end

  defp normalize_tool_result({:final, output}, name, call_id, latency_ms) do
    output_str = to_string(output)

    {output_str,
     %{
       type: :tool_result,
       name: name,
       status: :ok,
       output: output_str,
       call_id: call_id,
       latency_ms: latency_ms
     }, :final}
  end

  defp normalize_tool_result({:ok, output}, name, call_id, latency_ms) do
    output_str = to_string(output)

    {output_str,
     %{
       type: :tool_result,
       name: name,
       status: :ok,
       output: output_str,
       call_id: call_id,
       latency_ms: latency_ms
     }, :normal}
  end

  defp normalize_tool_result({:error, reason}, name, call_id, latency_ms) do
    error_str = "Error: #{reason}"
    error_type = classify_tool_error(reason)

    {error_str,
     %{
       type: :tool_result,
       name: name,
       status: :error,
       output: to_string(reason),
       call_id: call_id,
       latency_ms: latency_ms,
       error_type: error_type
     }, :normal}
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
              Logger.warning(
                "[turn_strategy.direct] stream_process failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
              )

              Process.sleep(1_000 * attempt)
              stream_with_retry(model, context, stream_opts, process_opts, emit, attempt + 1)
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        if attempt <= @max_stream_retries and retryable?(reason) do
          Logger.warning(
            "[turn_strategy.direct] stream_text failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
          )

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
      String.contains?(reason_down, "timeout") ->
        :timeout

      String.contains?(reason_down, "permission") or String.contains?(reason_down, "denied") ->
        :permission_denied

      String.contains?(reason_down, "not found") or String.contains?(reason_down, "no such") ->
        :not_found

      String.contains?(reason_down, "invalid") or String.contains?(reason_down, "argument") ->
        :invalid_args

      true ->
        :runtime_error
    end
  end

  defp classify_tool_error(_), do: :runtime_error
end
