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
    depth = opts[:depth] || 0

    context = %Context{
      tape_name: tape_name,
      tape_module: memory_mod,
      workspace: opts[:workspace],
      agent_name: opts[:agent_name],
      depth: depth,
      subagent: subagent,
      agent_id: opts[:agent_id],
      session_id: opts[:session_id],
      prompt_format: opts[:prompt_format] || :markdown,
      user_id: opts[:user_id],
      organization_id: opts[:organization_id]
    }

    tape = %Tape{
      name: tape_name,
      tape_module: memory_mod,
      compact_threshold: opts[:compact_threshold] || 100_000,
      compact_supported: function_exported?(memory_mod, :compact_if_needed, 2)
    }

    strategy =
      opts[:turn_strategy] || opts[:reasoner] || Rho.TurnStrategy.Direct

    base_prompt = opts[:system_prompt] || "You are a helpful assistant."

    system_prompt =
      build_system_prompt(base_prompt, subagent, context, strategy, tool_defs)

    raw_emit = resolve_emit(opts)

    emit =
      if tape_name do
        fn event ->
          if event.type not in [:llm_text, :tool_start, :tool_result] do
            memory_mod.append_from_event(tape_name, event)
          end

          raw_emit.(event)
        end
      else
        raw_emit
      end

    req_tools = Enum.map(tool_defs, & &1.tool)
    tool_map = Map.new(tool_defs, fn t -> {t.tool.name, t} end)

    %Runtime{
      model: model,
      turn_strategy: strategy,
      emit: emit,
      gen_opts: build_gen_opts(opts[:provider]),
      tool_defs: tool_defs,
      req_tools: req_tools,
      tool_map: tool_map,
      system_prompt: system_prompt,
      subagent: subagent,
      depth: depth,
      tape: tape,
      context: context,
      lifecycle: nil
    }
  end

  # -- System prompt assembly --

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

      PromptSection.render([base_section | plugin_sections], format)
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
    postlude_text = PromptSection.render(plugin_postlude, format)

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

  defp build_gen_opts(nil),
    do: [provider_options: [openrouter_cache_control: %{type: "ephemeral"}]]

  defp build_gen_opts(provider) do
    [
      provider_options: [
        openrouter_provider: provider,
        openrouter_cache_control: %{type: "ephemeral"}
      ]
    ]
  end

  # -- Main loop --

  defp do_loop(_context, _runtime, step: step, max_steps: max)
       when step > max do
    {:error, "max steps exceeded (#{max})"}
  end

  defp do_loop(context, runtime, step: step, max_steps: max) do
    runtime.emit.(%{type: :step_start, step: step, max_steps: max})

    with {:ok, context} <- maybe_compact(context, runtime),
         {:ok, projection} <- run_prompt_out(context, runtime, step) do
      runtime.turn_strategy.run(projection, runtime)
      |> handle_strategy_result(context, runtime, step, max)
    else
      {:error, reason} ->
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
end
