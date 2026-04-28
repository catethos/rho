defmodule Rho.ToolExecutor do
  @moduledoc """
  Shared tool dispatch pipeline for turn strategies.

  Handles: transformer pipeline (`:tool_args_out` / `:tool_result_in`),
  arg preparation via `Rho.ToolArgs`, async execution with inactivity
  timeout, result normalization, telemetry, and event emission.

  Both `TurnStrategy.Direct` and `TurnStrategy.TypedStructured` delegate
  tool execution here instead of duplicating ~200 lines of identical
  dispatch logic.

  ## Result format

  Each executed tool call returns a map:

      %{
        name:        String.t(),
        args:        map(),
        call_id:     String.t(),
        result:      String.t(),
        status:      :ok | :error,
        disposition: :normal | :final,
        event:       map()
      }

  The `disposition` field distinguishes normal tool results from tools
  that signal the end of the agent loop (`:final`).

  ## Options

    * `:skip_prepare` — skip `Rho.ToolArgs.prepare/2` arg coercion.
      Used by TypedStructured where `ActionSchema` already handles
      schema-guided coercion.
  """

  require Logger

  alias Rho.TurnStrategy.Shared

  @doc """
  Execute tool calls in parallel through the transformer pipeline.

  Each element of `tool_calls` must be a map with `:name`, `:args`,
  and `:call_id` keys.

  Returns a list of result maps (see module doc).

  Throws `{:rho_transformer_halt, reason}` if any transformer halts.
  """
  def run(tool_calls, tool_map, context, emit, opts \\ []) do
    dispatched = Enum.map(tool_calls, &dispatch(&1, tool_map, context, emit, opts))
    Enum.map(dispatched, &collect(&1, context, emit))
  end

  @doc """
  Execute a single tool call through the transformer pipeline.

  Convenience wrapper around `run/5` for strategies that dispatch
  one tool at a time (e.g. TypedStructured).
  """
  def execute_one(name, args, call_id, tool_map, context, emit, opts \\ []) do
    [result] = run([%{name: name, args: args, call_id: call_id}], tool_map, context, emit, opts)
    result
  end

  # -- Dispatch phase --
  #
  # For each tool call: emit :tool_start, run :tool_args_out transformer,
  # then either return an immediate result (denied/arg_error) or spawn
  # a Task for async execution.

  defp dispatch(%{name: name, args: args, call_id: call_id}, tool_map, context, emit, opts) do
    tool_def = Map.get(tool_map, name)

    emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})

    args_data = %{tool_name: name, args: args}

    case Rho.PluginRegistry.apply_stage(:tool_args_out, args_data, context) do
      {:deny, reason} ->
        result = "Denied: #{inspect(reason)}"

        event = %{
          type: :tool_result,
          name: name,
          status: :error,
          output: result,
          call_id: call_id,
          latency_ms: 0,
          error_type: :denied
        }

        {:immediate, build_result(name, args, call_id, result, :error, :normal, event)}

      {:halt, reason} ->
        throw({:rho_transformer_halt, reason})

      {:cont, %{args: new_args}} ->
        spawn_tool(tool_def, new_args, context, name, call_id, opts)
    end
  end

  defp spawn_tool(nil, _args, _ctx, name, call_id, _opts) do
    task =
      Task.async(fn ->
        error_str = "Error: unknown tool #{name}"

        event = %{
          type: :tool_result,
          name: name,
          status: :error,
          output: "unknown tool #{name}",
          call_id: call_id,
          latency_ms: 0,
          error_type: :unknown_tool
        }

        {error_str, event, :normal}
      end)

    {:task, task, %{name: name, args: %{}, call_id: call_id}}
  end

  defp spawn_tool(tool_def, args, ctx, name, call_id, opts) do
    if Keyword.get(opts, :skip_prepare, false) do
      task = Task.async(fn -> execute_and_normalize(tool_def, args, ctx, name, call_id) end)
      {:task, task, %{name: name, args: args, call_id: call_id}}
    else
      case Rho.ToolArgs.prepare(args, tool_def.tool.parameter_schema) do
        {:ok, prepared_args, _repairs} ->
          task =
            Task.async(fn ->
              execute_and_normalize(tool_def, prepared_args, ctx, name, call_id)
            end)

          {:task, task, %{name: name, args: prepared_args, call_id: call_id}}

        {:error, reason} ->
          error_str = "Error: arg preparation failed: #{inspect(reason)}"

          event = %{
            type: :tool_result,
            name: name,
            status: :error,
            output: error_str,
            call_id: call_id,
            latency_ms: 0,
            error_type: :arg_error
          }

          {:immediate, build_result(name, args, call_id, error_str, :error, :normal, event)}
      end
    end
  end

  # -- Collect phase --
  #
  # Await dispatched tasks, apply :tool_result_in transformer, emit
  # :tool_result events, and return result maps.

  defp collect({:immediate, result}, _context, emit) do
    emit.(result.event)
    result
  end

  defp collect({:task, task, meta}, context, emit) do
    timeout = Shared.tool_inactivity_timeout()

    {result_str, event, disposition} =
      case Shared.await_tool_with_inactivity(task, timeout) do
        :timeout ->
          error_str = "Error: tool execution inactive for #{div(timeout, 1000)}s"

          event = %{
            type: :tool_result,
            name: meta.name,
            status: :error,
            output: "tool execution inactive",
            call_id: meta.call_id,
            latency_ms: timeout,
            error_type: :timeout
          }

          {error_str, event, :normal}

        result ->
          result
      end

    result_str = apply_result_in(meta.name, result_str, context)
    event = %{event | output: result_str}
    emit.(event)

    build_result(meta.name, meta.args, meta.call_id, result_str, event.status, disposition, event)
  end

  # -- Execution + normalization --

  defp execute_and_normalize(tool_def, args, ctx, name, call_id) do
    t0 = System.monotonic_time(:millisecond)
    result = tool_def.execute.(args, ctx)
    latency_ms = System.monotonic_time(:millisecond) - t0

    :telemetry.execute(
      [:rho, :tool, :execute],
      %{duration_ms: latency_ms},
      %{tool_name: name, status: if(match?({:error, _}, result), do: :error, else: :ok)}
    )

    normalize_result(result, name, call_id, latency_ms)
  end

  defp normalize_result(%Rho.ToolResponse{} = resp, name, call_id, latency_ms) do
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

  defp normalize_result({:final, output}, name, call_id, latency_ms) do
    output_str = coerce_output(output)

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

  defp normalize_result({:ok, output}, name, call_id, latency_ms) do
    output_str = coerce_output(output)

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

  defp normalize_result({:error, reason}, name, call_id, latency_ms) do
    {error_type, output_text} = error_info(reason)
    error_str = "Error: #{output_text}"

    {error_str,
     %{
       type: :tool_result,
       name: name,
       status: :error,
       output: output_text,
       call_id: call_id,
       latency_ms: latency_ms,
       error_type: error_type
     }, :normal}
  end

  defp error_info(reason) when is_atom(reason),
    do: {reason, Atom.to_string(reason)}

  defp error_info({type, detail}) when is_atom(type),
    do: {type, format_error_detail(detail)}

  defp error_info(reason) when is_binary(reason),
    do: {:runtime_error, reason}

  defp error_info(other),
    do: {:runtime_error, inspect(other)}

  defp format_error_detail(detail) when is_binary(detail), do: detail
  defp format_error_detail(detail), do: inspect(detail)

  # -- Transformer: :tool_result_in --

  defp apply_result_in(name, result, ctx) do
    case Rho.PluginRegistry.apply_stage(
           :tool_result_in,
           %{tool_name: name, result: result},
           ctx
         ) do
      {:cont, %{result: new}} -> coerce_output(new)
      {:halt, reason} -> throw({:rho_transformer_halt, reason})
    end
  end

  # Coerce an arbitrary tool return value into a string. Binaries pass
  # through unchanged so happy-path tools keep emitting their text
  # byte-for-byte; anything else (tuples, structs, atoms) goes through
  # `inspect/1` to avoid `String.Chars` crashes.
  defp coerce_output(output) when is_binary(output), do: output
  defp coerce_output(output), do: inspect(output)

  # -- Result map builder --

  defp build_result(name, args, call_id, result, status, disposition, event) do
    %{
      name: name,
      args: args,
      call_id: call_id,
      result: result,
      status: status,
      disposition: disposition,
      event: event
    }
  end
end
