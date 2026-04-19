defmodule Rho.TurnStrategy.Direct do
  @moduledoc """
  Standard tool-use strategy: send tools+prompt to the LLM, execute tool
  calls, return results. Default TurnStrategy.

  Tool policy / result rewriting flow through Transformer stages
  `:tool_args_out` and `:tool_result_in` via `Rho.PluginRegistry`.
  """

  @behaviour Rho.TurnStrategy

  require Logger

  alias Rho.LLM.Admission
  alias Rho.TurnStrategy.Shared

  @terminal_tools MapSet.new(["create_anchor", "clear_memory", "finish", "end_turn"])

  @impl Rho.TurnStrategy
  def prompt_sections(_tool_defs, _context), do: []

  @impl Rho.TurnStrategy
  def run(projection, runtime) do
    %{context: messages} = projection
    model = runtime.model
    gen_opts = runtime.gen_opts
    emit = runtime.emit

    stream_opts = Keyword.merge([tools: runtime.req_tools], gen_opts)
    process_opts = [on_result: fn chunk -> emit.(%{type: :text_delta, text: chunk}) end]

    Logger.debug("[direct] starting LLM stream")
    t_llm_start = System.monotonic_time(:millisecond)

    case stream_with_retry(model, messages, stream_opts, process_opts, emit, 1) do
      {:ok, response} ->
        Logger.debug(
          "[direct] LLM stream completed in #{System.monotonic_time(:millisecond) - t_llm_start}ms"
        )

        process_response(response, projection, runtime)

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  defp process_response(response, projection, runtime) do
    emit = runtime.emit
    usage = ReqLLM.Response.usage(response)
    step = Map.get(projection, :step)
    emit.(%{type: :llm_usage, step: step, usage: usage, model: runtime.model})

    tool_calls = ReqLLM.Response.tool_calls(response)

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
          _ -> handle_tool_calls(response, tool_calls, runtime.tool_map, runtime)
        end
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

    dispatched = Enum.map(tool_calls, &dispatch_tool_call(&1, tool_map, emit, ctx))
    awaited = Enum.map(dispatched, &collect_tool_result(&1, emit, ctx))

    {tool_results, final_outputs} = Enum.unzip(awaited)
    final_output = Enum.find(final_outputs, & &1)

    classify_tool_outcome(tool_calls, tool_results, final_output, response_text)
  catch
    {:rho_transformer_halt, reason} ->
      runtime.emit.(%{type: :error, reason: {:halt, reason}})
      {:error, {:halt, reason}}
  end

  defp dispatch_tool_call(tc, tool_map, emit, ctx) do
    name = ReqLLM.ToolCall.name(tc)
    args = ReqLLM.ToolCall.args_map(tc) || %{}
    call_id = tc.id
    tool_def = Map.get(tool_map, name)

    emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})

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
        if tool_def do
          case Rho.ToolArgs.prepare(new_args, tool_def.tool.parameter_schema) do
            {:ok, prepared_args, _repairs} ->
              call = %{name: name, args: prepared_args, call_id: call_id}

              task =
                Task.async(fn ->
                  execute_tool_def(tool_def, prepared_args, ctx, name, call_id)
                end)

              {task, call, nil, nil}

            {:error, reason} ->
              error_str = "Error: arg preparation failed: #{inspect(reason)}"

              {nil, %{name: name, args: new_args, call_id: call_id}, error_str,
               %{
                 type: :tool_result,
                 name: name,
                 status: :error,
                 output: error_str,
                 call_id: call_id,
                 latency_ms: 0,
                 error_type: :arg_error
               }}
          end
        else
          call = %{name: name, args: new_args, call_id: call_id}
          task = Task.async(fn -> execute_tool_def(nil, new_args, ctx, name, call_id) end)
          {task, call, nil, nil}
        end
    end
  end

  defp execute_tool_def(nil, _args, _ctx, name, call_id) do
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

  defp execute_tool_def(tool_def, cast_args, ctx, name, call_id) do
    t0 = System.monotonic_time(:millisecond)
    result = tool_def.execute.(cast_args, ctx)
    latency_ms = System.monotonic_time(:millisecond) - t0

    :telemetry.execute(
      [:rho, :tool, :execute],
      %{duration_ms: latency_ms},
      %{tool_name: name, status: if(match?({:error, _}, result), do: :error, else: :ok)}
    )

    normalize_tool_result(result, name, call_id, latency_ms)
  end

  defp collect_tool_result({nil, _call, denied_result, event}, emit, _ctx) do
    emit.(event)
    {ReqLLM.Context.tool_result(event.call_id, denied_result), nil}
  end

  defp collect_tool_result({task, meta, nil, nil}, emit, ctx) do
    {result, event, disposition} = await_tool_with_inactivity(task)

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
  end

  defp classify_tool_outcome(tool_calls, tool_results, final_output, response_text) do
    called_names = MapSet.new(tool_calls, &ReqLLM.ToolCall.name/1)
    terminal = MapSet.intersection(called_names, @terminal_tools)

    cond do
      MapSet.size(terminal) > 0 ->
        terminal_text = extract_finish_text(tool_calls)
        {:done, %{type: :response, text: terminal_text || response_text}}

      final_output != nil ->
        {:done, %{type: :response, text: final_output}}

      true ->
        assistant_msg = ReqLLM.Context.assistant("", tool_calls: tool_calls)

        {:continue,
         %{
           type: :tool_step,
           assistant_msg: assistant_msg,
           tool_results: tool_results,
           tool_calls: tool_calls,
           response_text: response_text
         }}
    end
  end

  defp extract_finish_text(tool_calls) do
    Enum.find_value(tool_calls, fn tc ->
      if ReqLLM.ToolCall.name(tc) == "finish" do
        (ReqLLM.ToolCall.args_map(tc) || %{})["result"]
      end
    end)
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
    error_type = Shared.classify_tool_error(reason)

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
    stream_opts = Keyword.put_new(stream_opts, :receive_timeout, 120_000)

    # One admission slot per attempt (see Structured.stream_with_retry
    # for rationale). Acquire timeout is terminal; retries go through
    # normal backoff.
    result =
      Admission.with_slot(fn -> do_stream(model, context, stream_opts, process_opts) end)

    case result do
      {:ok, _response} = ok ->
        ok

      {:error, :acquire_timeout} = err ->
        Logger.error("[turn_strategy.direct] admission timeout — no LLM slot available after 60s")

        err

      {:error, reason} ->
        maybe_retry_stream(reason, model, context, stream_opts, process_opts, emit, attempt)
    end
  end

  defp do_stream(model, context, stream_opts, process_opts) do
    try do
      case ReqLLM.stream_text(model, context, stream_opts) do
        {:ok, stream_response} ->
          ReqLLM.StreamResponse.process_stream(stream_response, process_opts)

        {:error, _} = err ->
          err
      end
    rescue
      # Transport-level failures from the underlying Finch/Req stream
      # (e.g. pool exhaustion, mid-stream disconnect) can escape as
      # raised exceptions. Convert to `{:error, reason}` so the retry
      # path gets a chance instead of crashing the agent loop.
      exception ->
        Logger.warning("[turn_strategy.direct] stream raised: #{Exception.message(exception)}")

        {:error, exception}
    end
  end

  defp maybe_retry_stream(reason, model, context, stream_opts, process_opts, emit, attempt) do
    if Shared.should_retry?(reason, attempt) do
      Logger.warning(
        "[turn_strategy.direct] stream failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
      )

      Shared.retry_backoff(attempt)
      stream_with_retry(model, context, stream_opts, process_opts, emit, attempt + 1)
    else
      Logger.error(
        "[turn_strategy.direct] stream FAILED after #{attempt} attempts: #{inspect(reason)} model=#{model}"
      )

      {:error, reason}
    end
  end

  defp await_tool_with_inactivity(task) do
    timeout = Shared.tool_inactivity_timeout()

    case Shared.await_tool_with_inactivity(task, timeout) do
      :timeout ->
        error_str = "Error: tool execution inactive for #{div(timeout, 1000)}s"

        {error_str,
         %{
           type: :tool_result,
           name: "unknown",
           status: :error,
           output: "tool execution inactive",
           call_id: nil,
           latency_ms: timeout,
           error_type: :timeout
         }, :normal}

      result ->
        result
    end
  end
end
