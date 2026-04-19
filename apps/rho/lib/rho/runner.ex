defmodule Rho.Runner do
  @moduledoc """
  Drives the agent loop: step budget, compaction, Transformer dispatch.

  Runner owns the **outer loop** — stepping, budget, compaction, tape
  recording, and Transformer stage dispatch. A `Rho.TurnStrategy`
  (e.g. `Rho.TurnStrategy.Direct`) owns the **inner turn** — prompt
  assembly, LLM call, tool dispatch, and strategy-owned prompt
  sections.

  This module replaces the old `Rho.AgentLoop` + `Rho.Reasoner` split.
  `Rho.AgentLoop.run/3` remains as a thin delegate.

  ## Prompt merge order

      system base → plugin prompt_sections (prelude)
                  → strategy prompt_sections
                  → plugin prompt_sections (postlude)
                  → tape-derived messages

  ## Options

    * `:system_prompt` — base system prompt string
    * `:tools` — list of tool_def maps
    * `:max_steps` — loop budget (default from `Rho.Config`)
    * `:emit` / `:on_event` / `:on_text` — event callbacks
    * `:tape_name` — tape reference for persistent context
    * `:turn_strategy` / `:reasoner` (alias) — strategy module
    * `:depth`, `:subagent`, `:workspace`, `:agent_name`, `:prompt_format`
  """

  require Logger

  alias Rho.AgentLoop.{Recorder, Runtime, Tape}
  alias Rho.Context

  @doc """
  Runs the agent loop.

  Returns `{:ok, text}`, `{:final, value}`, or `{:error, reason}`.
  """
  def run(model, messages, opts \\ []) do
    runtime = build_runtime(model, messages, opts)
    max_steps = opts[:max_steps] || 50

    Recorder.record_input_messages(runtime, messages)

    context = build_initial_context(runtime, messages)

    do_loop(context, runtime, step: 1, max_steps: max_steps)
  end

  # -- Runtime construction --

  defp build_runtime(model, _messages, opts) do
    tool_defs = opts[:tools] || []
    tape_name = opts[:tape_name]
    memory_mod = opts[:tape_module] || Rho.Tape.Context.Tape
    subagent = opts[:subagent] || false

    context = build_context_struct(opts, tape_name, memory_mod, subagent)
    tape = build_tape(tape_name, memory_mod, opts)
    strategy = opts[:turn_strategy] || opts[:reasoner] || Rho.TurnStrategy.Direct

    base_prompt = opts[:system_prompt] || "You are a helpful assistant."
    system_prompt = build_system_prompt(base_prompt, subagent, context, strategy, tool_defs)

    emit = wrap_emit_with_tape(resolve_emit(opts), tape_name, memory_mod)

    %Runtime{
      model: model,
      turn_strategy: strategy,
      emit: emit,
      gen_opts: build_gen_opts(opts[:provider]),
      tool_defs: tool_defs,
      req_tools: Enum.map(tool_defs, & &1.tool),
      tool_map: Map.new(tool_defs, fn t -> {t.tool.name, t} end),
      system_prompt: system_prompt,
      subagent: subagent,
      depth: opts[:depth] || 0,
      tape: tape,
      context: context,
      lifecycle: nil
    }
  end

  defp build_context_struct(opts, tape_name, memory_mod, subagent) do
    %Context{
      tape_name: tape_name,
      tape_module: memory_mod,
      workspace: opts[:workspace],
      agent_name: opts[:agent_name],
      depth: opts[:depth] || 0,
      subagent: subagent,
      agent_id: opts[:agent_id],
      session_id: opts[:session_id],
      prompt_format: opts[:prompt_format] || :markdown,
      user_id: opts[:user_id],
      organization_id: opts[:organization_id]
    }
  end

  defp build_tape(tape_name, memory_mod, opts) do
    %Tape{
      name: tape_name,
      tape_module: memory_mod,
      compact_threshold: opts[:compact_threshold] || 100_000,
      compact_supported: function_exported?(memory_mod, :compact_if_needed, 2)
    }
  end

  defp wrap_emit_with_tape(raw_emit, nil, _memory_mod), do: raw_emit

  defp wrap_emit_with_tape(raw_emit, tape_name, memory_mod) do
    fn event ->
      maybe_append_to_tape(event, tape_name, memory_mod)
      raw_emit.(event)
    end
  end

  defp maybe_append_to_tape(event, tape_name, memory_mod) do
    if event.type not in [:llm_text, :tool_start, :tool_result] do
      t_tape = System.monotonic_time(:millisecond)
      memory_mod.append_from_event(tape_name, event)
      tape_ms = System.monotonic_time(:millisecond) - t_tape

      warn_if_slow(
        tape_ms,
        2_000,
        "[runner.emit] tape append took #{tape_ms}ms for #{event.type}"
      )
    end
  end

  # -- System prompt assembly --

  @conciseness_section Rho.PromptSection.new(
                         key: :conciseness,
                         body:
                           "Be concise between tool calls. Do not summarize what tools just did — " <>
                             "the results speak for themselves. Only add text when you need user input, " <>
                             "hit a blocker, or reach a natural milestone. Prefer calling the next tool immediately.",
                         priority: :low,
                         kind: :instructions,
                         position: :postlude
                       )

  defp build_system_prompt(base, true = _subagent, ctx, _strategy, _tool_defs) do
    alias Rho.PromptSection

    plugin_sections = Rho.PluginRegistry.collect_prompt_material(ctx)

    if plugin_sections == [] do
      base
    else
      format = ctx[:prompt_format] || :markdown

      base_section =
        PromptSection.new(
          key: :base_prompt,
          body: base,
          priority: :high,
          kind: :instructions,
          position: :prelude
        )

      PromptSection.render([base_section | plugin_sections] ++ [@conciseness_section], format)
    end
  end

  defp build_system_prompt(base, _subagent, ctx, strategy, tool_defs) do
    alias Rho.PromptSection

    base_section =
      PromptSection.new(
        key: :base_prompt,
        body: base,
        priority: :high,
        kind: :instructions,
        position: :prelude
      )

    plugin_sections = Rho.PluginRegistry.collect_prompt_material(ctx)
    strategy_sections = collect_strategy_sections(strategy, tool_defs, ctx)

    format = ctx[:prompt_format] || :markdown

    # Prompt merge order: system base → plugin prelude → strategy →
    # plugin postlude → (tape, appended as messages by the caller).
    # Plugin sections default to :prelude; individual plugins can opt
    # into :postlude via the :position field.
    {plugin_prelude, plugin_postlude} =
      Enum.split_with(plugin_sections, fn s ->
        (s.position || :prelude) == :prelude
      end)

    prelude_text = PromptSection.render([base_section | plugin_prelude], format)
    strategy_text = PromptSection.render(strategy_sections, format)
    postlude_text = PromptSection.render(plugin_postlude ++ [@conciseness_section], format)

    [prelude_text, strategy_text, postlude_text]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp collect_strategy_sections(strategy, tool_defs, ctx) do
    with {:module, _} <- Code.ensure_loaded(strategy),
         true <- function_exported?(strategy, :prompt_sections, 2) do
      strategy.prompt_sections(tool_defs, ctx) |> Enum.map(&normalize_section/1)
    else
      _ ->
        # Legacy 1-arity form on Reasoner behaviour
        if function_exported?(strategy, :prompt_sections, 1) do
          strategy.prompt_sections(tool_defs) |> Enum.map(&normalize_section/1)
        else
          []
        end
    end
  end

  defp normalize_section(%Rho.PromptSection{} = s), do: s
  defp normalize_section(text) when is_binary(text), do: Rho.PromptSection.from_string(text)

  # -- Initial context --

  defp build_initial_context(runtime, messages) do
    system_msg =
      ReqLLM.Context.system([
        ReqLLM.Message.ContentPart.text(runtime.system_prompt, %{
          cache_control: %{type: "ephemeral"}
        })
      ])

    tail =
      if runtime.tape.name,
        do: Rho.Tape.Context.build(runtime.tape.name),
        else: messages

    [system_msg | tail]
  end

  defp build_gen_opts(nil), do: []

  defp build_gen_opts(provider) do
    [provider_options: [openrouter_provider: provider]]
  end

  # -- Main loop --

  defp do_loop(_context, _runtime, step: step, max_steps: max)
       when step > max do
    {:error, "max steps exceeded (#{max})"}
  end

  defp do_loop(context, runtime, step: step, max_steps: max) do
    runtime.emit.(%{type: :step_start, step: step, max_steps: max})

    t0 = System.monotonic_time(:millisecond)

    with {:ok, context} <- maybe_compact(context, runtime),
         t1 = System.monotonic_time(:millisecond),
         :ok <- warn_if_slow(t1 - t0, 5_000, "[runner] compact took #{t1 - t0}ms at step #{step}"),
         {:ok, projection} <- run_prompt_out(context, runtime, step) do
      t2 = System.monotonic_time(:millisecond)
      warn_if_slow(t2 - t1, 5_000, "[runner] prompt_out took #{t2 - t1}ms at step #{step}")
      result = runtime.turn_strategy.run(projection, runtime)
      t3 = System.monotonic_time(:millisecond)
      warn_if_slow(t3 - t2, 30_000, "[runner] strategy.run took #{t3 - t2}ms at step #{step}")

      handle_strategy_result(result, context, runtime, step, max)
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

  # -- Compaction --

  defp maybe_compact(context, %Runtime{tape: %Tape{name: nil}}), do: {:ok, context}
  defp maybe_compact(context, %Runtime{tape: %Tape{compact_supported: false}}), do: {:ok, context}

  defp maybe_compact(context, runtime) do
    %Runtime{
      tape: %Tape{name: tape, tape_module: mem, compact_threshold: threshold},
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

  # -- :prompt_out stage --

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

  # -- Strategy result handling --

  defp handle_strategy_result(
         {:done, %{type: :response, text: text}},
         _ctx,
         runtime,
         _step,
         _max
       ) do
    Recorder.record_assistant_text(runtime, text)
    {:ok, text}
  end

  defp handle_strategy_result({:final, value, _entries}, _ctx, _runtime, _step, _max),
    do: {:final, value}

  defp handle_strategy_result({:error, reason}, _ctx, _runtime, _step, _max),
    do: {:error, reason}

  defp handle_strategy_result(
         {:parse_error, reason, raw_text},
         context,
         runtime,
         step,
         max
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

    do_loop(updated_context, runtime, step: step + 1, max_steps: max)
  end

  defp handle_strategy_result(
         {:continue, %{type: :subagent_nudge, text: text}},
         context,
         runtime,
         step,
         max
       ) do
    nudge_msg =
      "[System] Continue working on your task. Call `finish` with your result when done."

    Recorder.record_assistant_text(runtime, text)
    Recorder.record_injected_messages(runtime, [nudge_msg])

    updated_context =
      case runtime.tape.name do
        nil ->
          context ++ [ReqLLM.Context.assistant(text || ""), ReqLLM.Context.user(nudge_msg)]

        _tape ->
          Recorder.rebuild_context(runtime)
      end

    do_loop(updated_context, runtime, step: step + 1, max_steps: max)
  end

  defp handle_strategy_result(
         {:continue, %{type: :tool_step} = entries},
         context,
         runtime,
         step,
         max
       ) do
    Recorder.record_tool_step(runtime, entries)
    next_step = step + 1
    injected = run_post_step(runtime, next_step, max)
    Recorder.record_injected_messages(runtime, injected)

    updated_context = advance_context(context, entries, injected, runtime)
    do_loop(updated_context, runtime, step: next_step, max_steps: max)
  end

  # -- :post_step stage --

  defp run_post_step(%Runtime{context: ctx}, step, max) do
    data = %{step: step, max_steps: max, entries_appended: []}

    case Rho.PluginRegistry.apply_stage(:post_step, data, ctx) do
      {:cont, nil} -> []
      {:inject, messages} -> List.wrap(messages)
      {:halt, _reason} -> []
    end
  end

  # -- Context advancement --

  defp advance_context(_context, _entries, _injected, %Runtime{tape: %Tape{name: tape}} = runtime)
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

  # -- Emit callback resolution --

  defp resolve_emit(opts) do
    case {opts[:emit], opts[:on_event], opts[:on_text]} do
      {emit, _, _} when is_function(emit) ->
        emit

      {_, on_event, on_text} when is_function(on_event) or is_function(on_text) ->
        fn
          %{type: :text_delta, text: chunk} when is_function(on_text) ->
            on_text.(chunk)
            :ok

          event when is_function(on_event) ->
            on_event.(event)

          _ ->
            :ok
        end

      _ ->
        fn _event -> :ok end
    end
  end

  defp warn_if_slow(duration_ms, threshold, message) do
    if duration_ms > threshold, do: Logger.warning(message)
    :ok
  end
end
