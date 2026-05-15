defmodule Rho.Runner.LiteLoop do
  @moduledoc """
  Minimal runner loop for lite-mode agent tasks.

  Lite mode skips tape recording, transformers, compaction, and
  `Rho.ToolExecutor`. It is intended for short-lived worker tasks where the
  turn strategy still owns LLM classification, but tools are executed directly.
  """

  alias Rho.Runner.Runtime

  @doc """
  Runs the lite loop from a prepared runtime.
  """
  @spec run([map()], Runtime.t(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def run(messages, %Runtime{} = runtime, max_steps) do
    context = build_context(runtime, messages)
    do_loop(context, runtime, step: 1, max_steps: max_steps)
  end

  defp build_context(runtime, messages) do
    [Rho.Runner.build_system_message(runtime) | messages]
  end

  defp do_loop(_context, _runtime, step: step, max_steps: max_value)
       when step > max_value do
    {:error, "max steps exceeded (#{max_value})"}
  end

  defp do_loop(context, runtime, step: step, max_steps: max_value) do
    runtime.emit.(%{type: :step_start, step: step, max_steps: max_value})

    projection = %{context: context, tools: runtime.req_tools, step: step}
    result = runtime.turn_strategy.run(projection, runtime)

    handle_result(result, context, runtime, step, max_value)
  end

  defp handle_result({:respond, text}, _context, _runtime, _step, _max_value) do
    {:ok, text || ""}
  end

  defp handle_result(
         {:call_tools, tool_calls, response_text},
         context,
         runtime,
         step,
         max_value
       ) do
    {results, final} =
      execute_tools(tool_calls, runtime.tool_map, runtime.context, runtime.emit)

    if final != nil do
      {:ok, final}
    else
      entries = runtime.turn_strategy.build_tool_step(tool_calls, results, response_text)
      next_context = context ++ [entries.assistant_msg | entries.tool_results]
      do_loop(next_context, runtime, step: step + 1, max_steps: max_value)
    end
  end

  defp handle_result({:think, _thought}, context, runtime, step, max_value) do
    do_loop(context, runtime, step: step + 1, max_steps: max_value)
  end

  # Invariant: `reason` is a binary — TypedStructured.dispatch_parsed/2
  # is the only emitter and it builds the reason from string interpolation.
  defp handle_result({:parse_error, reason, _raw}, context, runtime, step, max_value) do
    correction = ReqLLM.Context.user("Parse error: #{reason}. Please try again.")
    do_loop(context ++ [correction], runtime, step: step + 1, max_steps: max_value)
  end

  defp handle_result({:error, reason}, _context, runtime, _step, _max_value) do
    runtime.emit.(%{type: :error, reason: reason})
    {:error, "LLM call failed: #{inspect(reason)}"}
  end

  defp execute_tools(tool_calls, tool_map, context, emit) do
    results =
      tool_calls
      |> Enum.map(fn tc ->
        Task.async(fn -> execute_tool(tc, tool_map, context, emit) end)
      end)
      |> Task.await_many(:timer.minutes(5))

    {Enum.map(results, & &1.result_map), Enum.find_value(results, & &1.final)}
  end

  defp execute_tool(tc, tool_map, context, emit) do
    name = tc.name
    args = tc.args
    call_id = tc.call_id
    tool_def = Map.get(tool_map, name)

    emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})
    t0 = System.monotonic_time(:millisecond)

    result =
      if tool_def do
        case Rho.ToolArgs.prepare(args, tool_def.tool.parameter_schema) do
          {:ok, prepared_args, _repairs} ->
            try do
              tool_def.execute.(prepared_args, context)
            rescue
              e -> {:error, Exception.message(e)}
            end

          {:error, reason} ->
            {:error, "Arg preparation failed: #{inspect(reason)}"}
        end
      else
        {:error, "unknown tool: #{name}"}
      end

    latency_ms = System.monotonic_time(:millisecond) - t0

    {output_str, status, final, effects} =
      case result do
        {:final, output} ->
          coerced = coerce_output(output)
          {coerced, :ok, coerced, []}

        %Rho.ToolResponse{text: text, effects: fx} ->
          {text || "", :ok, nil, fx || []}

        {:ok, output} ->
          {coerce_output(output), :ok, nil, []}

        {:error, reason} ->
          {"Error: #{inspect(reason)}", :error, nil, []}
      end

    event = %{
      type: :tool_result,
      name: name,
      status: status,
      output: output_str,
      call_id: call_id,
      latency_ms: latency_ms
    }

    emit.(if effects != [], do: Map.put(event, :effects, effects), else: event)

    %{
      result_map: %{name: name, args: args, call_id: call_id, result: output_str, status: status},
      final: final
    }
  end

  # Coerce an arbitrary tool return value into a string suitable for the
  # message context. Binaries pass through unchanged so happy-path tools
  # keep emitting their text byte-for-byte; anything else (tuples, structs,
  # atoms) goes through `inspect/1` to avoid `String.Chars` crashes.
  defp coerce_output(output) when is_binary(output), do: output
  defp coerce_output(output), do: inspect(output)
end
