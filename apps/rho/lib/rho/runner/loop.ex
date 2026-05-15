defmodule Rho.Runner.Loop do
  @moduledoc """
  Normal-mode runner loop orchestration.

  This module owns compaction, prompt-out transformer dispatch, strategy result
  handling, tool execution via `Rho.ToolExecutor`, post-step injection, and
  context advancement. `Rho.Runner` remains the public entry point and owns
  initial runtime/context construction.
  """

  require Logger

  alias Rho.Recorder
  alias Rho.Runner.{Runtime, TapeConfig}

  @doc """
  Runs the normal agent loop from an initial context and prepared runtime.
  """
  @spec run([map()], Runtime.t(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def run(context, %Runtime{} = runtime, max_steps) do
    do_loop(context, runtime, step: 1, max_steps: max_steps)
  end

  defp do_loop(_context, _runtime, step: step, max_steps: max_value)
       when step > max_value do
    {:error, "max steps exceeded (#{max_value})"}
  end

  defp do_loop(context, runtime, step: step, max_steps: max_value) do
    runtime.emit.(%{type: :step_start, step: step, max_steps: max_value})

    t0 = System.monotonic_time(:millisecond)

    with {:ok, context} <- maybe_compact(context, runtime),
         t1 = System.monotonic_time(:millisecond),
         :ok <- warn_if_slow(t1 - t0, 5_000, "[runner] compact took #{t1 - t0}ms at step #{step}"),
         {:ok, projection} <- run_prompt_out(context, runtime, step) do
      t2 = System.monotonic_time(:millisecond)
      warn_if_slow(t2 - t1, 5_000, "[runner] prompt_out took #{t2 - t1}ms at step #{step}")

      Logger.info(
        "[runner] step #{step} calling strategy #{inspect(runtime.turn_strategy)} " <>
          "agent=#{runtime.context.agent_name} agent_id=#{runtime.context.agent_id}"
      )

      result = runtime.turn_strategy.run(projection, runtime)
      t3 = System.monotonic_time(:millisecond)

      Logger.info(
        "[runner] step #{step} strategy returned in #{t3 - t2}ms " <>
          "result_type=#{elem(result, 0)} agent_id=#{runtime.context.agent_id}"
      )

      warn_if_slow(t3 - t2, 30_000, "[runner] strategy.run took #{t3 - t2}ms at step #{step}")

      handle_strategy_result(result, context, runtime, step, max_value)
    else
      {:error, reason} ->
        Logger.error(
          "[runner] step #{step} failed: #{inspect(reason)} " <>
            "agent=#{runtime.context.agent_name} session=#{runtime.context.session_id} " <>
            "agent_id=#{runtime.context.agent_id}"
        )

        runtime.emit.(%{type: :error, reason: reason})
        {:error, reason}
    end
  end

  defp maybe_compact(context, %Runtime{tape: %TapeConfig{name: nil}}), do: {:ok, context}

  defp maybe_compact(context, %Runtime{tape: %TapeConfig{compact_supported: false}}),
    do: {:ok, context}

  defp maybe_compact(context, runtime) do
    %Runtime{
      tape: %TapeConfig{name: tape, tape_module: mem, compact_threshold: threshold},
      model: model,
      gen_opts: gen_opts
    } = runtime

    compact_opts = [model: model, gen_opts: gen_opts, threshold: threshold]

    case mem.compact_if_needed(tape, compact_opts) do
      {:ok, :not_needed} ->
        {:ok, context}

      {:ok, _entry} ->
        runtime.emit.(%{type: :compact, tape_name: tape})
        {:ok, Recorder.rebuild_context(runtime)}

      {:error, reason} ->
        Logger.warning("[runner] compaction failed: #{inspect(reason)}")
        {:error, {:compact_failed, reason}}
    end
  end

  defp run_prompt_out(
         context,
         %Runtime{req_tools: req_tools, context: ctx, emit: emit},
         step
       ) do
    data = %{messages: context, system: nil}

    case Rho.PluginRegistry.apply_stage(:prompt_out, data, ctx) do
      {:cont, %{messages: messages}} ->
        projection = %{context: messages, tools: req_tools, step: step}
        emit.(%{type: :before_llm, projection: projection})
        {:ok, projection}

      {:halt, reason} ->
        {:error, {:halt, reason}}
    end
  end

  defp handle_strategy_result({:respond, text}, context, runtime, step, max_value) do
    Recorder.record_assistant_text(runtime, text)

    next_step = step + 1

    case run_post_step(runtime, next_step, max_value, :text_response) do
      [] ->
        {:ok, text}

      msgs ->
        Recorder.record_injected_messages(runtime, msgs)
        updated_context = advance_text_response_context(context, text, msgs, runtime)
        do_loop(updated_context, runtime, step: next_step, max_steps: max_value)
    end
  end

  defp handle_strategy_result(
         {:call_tools, tool_calls, response_text},
         context,
         runtime,
         step,
         max_value
       ) do
    emit = runtime.emit

    if response_text && String.trim(response_text) != "" do
      emit.(%{type: :llm_text, text: response_text})
    end

    tool_names = Enum.map(tool_calls, & &1.name)
    Logger.info("[runner] dispatching #{length(tool_calls)} tool calls: #{inspect(tool_names)}")

    results =
      Rho.ToolExecutor.run(
        tool_calls,
        runtime.tool_map,
        runtime.context,
        emit
      )

    Logger.info("[runner] all tool results collected")

    classify_tool_outcome(tool_calls, results, response_text, context, runtime, step, max_value)
  catch
    {:rho_transformer_halt, reason} ->
      runtime.emit.(%{type: :error, reason: {:halt, reason}})
      {:error, {:halt, reason}}
  end

  defp handle_strategy_result({:think, thought}, context, runtime, step, max_value) do
    runtime.emit.(%{type: :llm_text, text: thought})

    entries = runtime.turn_strategy.build_think_step(thought)
    Recorder.record_tool_step(runtime, entries)

    next_step = step + 1
    injected = run_post_step(runtime, next_step, max_value, :think_step)
    Recorder.record_injected_messages(runtime, injected)

    updated_context = advance_context(context, entries, injected, runtime)
    do_loop(updated_context, runtime, step: next_step, max_steps: max_value)
  end

  defp handle_strategy_result(
         {:parse_error, reason, raw_text},
         context,
         runtime,
         step,
         max_value
       ) do
    correction =
      "[System] Your response could not be parsed: #{inspect(reason)}. " <>
        "Please respond with valid JSON matching the action schema."

    Recorder.record_assistant_text(runtime, raw_text)
    Recorder.record_injected_messages(runtime, [correction])

    updated_context =
      case runtime.tape.name do
        nil ->
          context ++
            [ReqLLM.Context.assistant(raw_text || ""), ReqLLM.Context.user(correction)]

        _tape ->
          Recorder.rebuild_context(runtime)
      end

    do_loop(updated_context, runtime, step: step + 1, max_steps: max_value)
  end

  defp handle_strategy_result({:error, reason}, _context, _runtime, _step, _max_value),
    do: {:error, reason}

  defp classify_tool_outcome(
         tool_calls,
         results,
         response_text,
         context,
         runtime,
         step,
         max_value
       ) do
    final_output =
      Enum.find_value(results, fn r ->
        if r.disposition == :final, do: r.result
      end)

    if final_output != nil do
      Recorder.record_assistant_text(runtime, final_output)
      {:ok, final_output}
    else
      entries =
        runtime.turn_strategy.build_tool_step(tool_calls, results, response_text)

      Recorder.record_tool_step(runtime, entries)

      next_step = step + 1
      injected = run_post_step(runtime, next_step, max_value, :tool_step)
      Recorder.record_injected_messages(runtime, injected)

      updated_context = advance_context(context, entries, injected, runtime)
      do_loop(updated_context, runtime, step: next_step, max_steps: max_value)
    end
  end

  defp run_post_step(%Runtime{context: ctx}, step, max_value, step_kind) do
    data = %{step: step, max_steps: max_value, entries_appended: [], step_kind: step_kind}

    case Rho.PluginRegistry.apply_stage(:post_step, data, ctx) do
      {:cont, nil} -> []
      {:inject, messages} -> List.wrap(messages)
      {:halt, _reason} -> []
    end
  end

  defp advance_text_response_context(
         _context,
         _text,
         _msgs,
         %Runtime{tape: %TapeConfig{name: tape}} = runtime
       )
       when tape != nil do
    Recorder.rebuild_context(runtime)
  end

  defp advance_text_response_context(context, text, msgs, _runtime) do
    context ++ [ReqLLM.Context.assistant(text || "") | Enum.map(msgs, &ReqLLM.Context.user/1)]
  end

  defp advance_context(
         _context,
         _entries,
         _injected,
         %Runtime{tape: %TapeConfig{name: tape}} = runtime
       )
       when tape != nil do
    Recorder.rebuild_context(runtime)
  end

  defp advance_context(
         context,
         %{assistant_msg: assistant_msg, tool_results: tool_results},
         injected,
         _runtime
       ) do
    base = context ++ [assistant_msg | tool_results]
    base ++ Enum.map(injected, &ReqLLM.Context.user/1)
  end

  defp warn_if_slow(duration_ms, threshold, message) do
    if duration_ms > threshold, do: Logger.warning(message)
    :ok
  end
end
