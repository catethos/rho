defmodule Rho.Runner do
  @moduledoc """
  Drives the agent loop: step budget, compaction, Transformer dispatch,
  and tool execution.

  Runner owns the **outer loop** — stepping, budget, compaction, tape
  recording, tool execution (via `Rho.ToolExecutor`), and Transformer
  stage dispatch. A `Rho.TurnStrategy` (e.g. `Rho.TurnStrategy.Direct`)
  owns the **inner turn** — prompt assembly, LLM call, and response
  classification into an intent.

  Strategies return intents — Runner handles all side effects:

      {:respond, text}                        → record; :post_step may inject and loop, else done
      {:call_tools, [tool_call], text | nil}  → ToolExecutor.run → classify → loop
      {:think, thought}                       → build_think_step → loop
      {:parse_error, reason, raw}             → inject correction → loop
      {:error, reason}                        → return error

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
    * `:turn_strategy` — strategy module (`:reasoner` accepted as legacy alias)
    * `:depth`, `:workspace`, `:agent_name`, `:prompt_format`
  """

  require Logger

  alias Rho.Context
  alias Rho.Recorder

  # ===================================================================
  # Runner.Runtime — immutable run configuration for one agent loop
  # ===================================================================

  defmodule Runtime do
    @moduledoc """
    Immutable run configuration for one agent loop invocation.

    Bundles everything that stays constant across loop iterations:
    the LLM model, tool definitions, system prompt, emit callback, tape
    config, and lifecycle hooks.
    """

    @enforce_keys [
      :model,
      :turn_strategy,
      :emit,
      :gen_opts,
      :tool_defs,
      :req_tools,
      :tool_map,
      :system_prompt_stable,
      :depth,
      :tape,
      :context
    ]
    defstruct [
      :model,
      :turn_strategy,
      :emit,
      :gen_opts,
      :tool_defs,
      :req_tools,
      :tool_map,
      :system_prompt_stable,
      :depth,
      :tape,
      :context,
      :lifecycle,
      system_prompt_volatile: "",
      lite: false
    ]

    @type t :: %__MODULE__{
            model: term(),
            turn_strategy: module(),
            emit: (map() -> :ok),
            gen_opts: keyword(),
            tool_defs: [map()],
            req_tools: [ReqLLM.Tool.t()],
            tool_map: %{String.t() => map()},
            system_prompt_stable: String.t(),
            system_prompt_volatile: String.t(),
            depth: non_neg_integer(),
            tape: Rho.Runner.TapeConfig.t(),
            context: Context.t(),
            lifecycle: any()
          }
  end

  # ===================================================================
  # Runner.TapeConfig — tape configuration for the loop
  # ===================================================================

  defmodule TapeConfig do
    @moduledoc """
    Configuration for the tape — the persistent conversation log.

    When `name` is `nil`, no tape recording occurs and context lives only
    in-memory for the current loop invocation.
    """

    defstruct name: nil,
              tape_module: Rho.Tape.Projection.JSONL,
              compact_threshold: 100_000,
              compact_supported: false

    @type t :: %__MODULE__{
            name: String.t() | nil,
            tape_module: module(),
            compact_threshold: pos_integer(),
            compact_supported: boolean()
          }
  end

  @doc """
  Runs the agent loop from a RunSpec.

  Returns `{:ok, text}`, `{:final, value}`, or `{:error, reason}`.
  """
  def run(messages, %Rho.RunSpec{} = spec) do
    runtime = build_runtime_from_spec(messages, spec)
    max_steps = spec.max_steps || 50

    if runtime.lite do
      context = build_lite_context(runtime, messages)
      do_lite_loop(context, runtime, step: 1, max_steps: max_steps)
    else
      Recorder.record_input_messages(runtime, messages)
      context = build_initial_context(runtime, messages)
      do_loop(context, runtime, step: 1, max_steps: max_steps)
    end
  end

  @doc """
  Legacy 3-arity form — builds an ad-hoc RunSpec from opts and delegates.

  Prefer `run/2` with an explicit `%RunSpec{}` for new code.
  """
  def run(model, messages, opts) when is_list(opts) do
    runtime = build_runtime(model, messages, opts)
    max_steps = opts[:max_steps] || 50

    Recorder.record_input_messages(runtime, messages)

    context = build_initial_context(runtime, messages)

    do_loop(context, runtime, step: 1, max_steps: max_steps)
  end

  # -- Runtime construction (from RunSpec) --

  defp build_runtime_from_spec(_messages, %Rho.RunSpec{} = spec) do
    tool_defs = spec.tools || []
    tape_name = spec.tape_name
    memory_mod = spec.tape_module || Rho.Tape.Projection.JSONL

    context = %Context{
      tape_name: tape_name,
      tape_module: memory_mod,
      workspace: spec.workspace,
      agent_name: spec.agent_name,
      depth: spec.depth || 0,
      agent_id: spec.agent_id,
      session_id: spec.session_id,
      prompt_format: spec.prompt_format || :markdown,
      user_id: spec.user_id,
      organization_id: spec.organization_id
    }

    tape = build_tape(tape_name, memory_mod, compact_threshold: spec.compact_threshold)
    strategy = spec.turn_strategy || Rho.TurnStrategy.Direct

    base_prompt = spec.system_prompt || "You are a helpful assistant."

    {stable_prompt, volatile_prompt} =
      build_system_prompt(base_prompt, context, strategy, tool_defs)

    raw_emit = if is_function(spec.emit), do: spec.emit, else: fn _event -> :ok end
    emit = wrap_emit_with_tape(raw_emit, tape_name, memory_mod)

    %Runtime{
      model: spec.model,
      turn_strategy: strategy,
      emit: emit,
      gen_opts: build_gen_opts(spec.provider),
      tool_defs: tool_defs,
      req_tools: Enum.map(tool_defs, & &1.tool),
      tool_map: Map.new(tool_defs, fn t -> {t.tool.name, t} end),
      system_prompt_stable: stable_prompt,
      system_prompt_volatile: volatile_prompt,
      depth: spec.depth || 0,
      tape: tape,
      context: context,
      lifecycle: nil,
      lite: spec.lite || false
    }
  end

  # -- Runtime construction (legacy opts) --

  defp build_runtime(model, _messages, opts) do
    tool_defs = opts[:tools] || []
    tape_name = opts[:tape_name]
    memory_mod = opts[:tape_module] || Rho.Tape.Projection.JSONL

    context = build_context_struct(opts, tape_name, memory_mod)
    tape = build_tape(tape_name, memory_mod, opts)
    strategy = opts[:turn_strategy] || opts[:reasoner] || Rho.TurnStrategy.Direct

    base_prompt = opts[:system_prompt] || "You are a helpful assistant."

    {stable_prompt, volatile_prompt} =
      build_system_prompt(base_prompt, context, strategy, tool_defs)

    emit = wrap_emit_with_tape(resolve_emit(opts), tape_name, memory_mod)

    %Runtime{
      model: model,
      turn_strategy: strategy,
      emit: emit,
      gen_opts: build_gen_opts(opts[:provider]),
      tool_defs: tool_defs,
      req_tools: Enum.map(tool_defs, & &1.tool),
      tool_map: Map.new(tool_defs, fn t -> {t.tool.name, t} end),
      system_prompt_stable: stable_prompt,
      system_prompt_volatile: volatile_prompt,
      depth: opts[:depth] || 0,
      tape: tape,
      context: context,
      lifecycle: nil
    }
  end

  defp build_context_struct(opts, tape_name, memory_mod) do
    %Context{
      tape_name: tape_name,
      tape_module: memory_mod,
      workspace: opts[:workspace],
      agent_name: opts[:agent_name],
      depth: opts[:depth] || 0,
      agent_id: opts[:agent_id],
      session_id: opts[:session_id],
      prompt_format: opts[:prompt_format] || :markdown,
      user_id: opts[:user_id],
      organization_id: opts[:organization_id]
    }
  end

  defp build_tape(tape_name, memory_mod, opts) do
    %TapeConfig{
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

  defp build_system_prompt(base, ctx, strategy, tool_defs) do
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

    {plugin_prelude, plugin_postlude} =
      Enum.split_with(plugin_sections, fn s ->
        (s.position || :prelude) == :prelude
      end)

    # Within each render group, render stable sections first then volatile.
    # Joining the two strings preserves the rendered ordering of today's
    # prompt when nothing is marked volatile (volatile_text == "").
    {prelude_stable, prelude_volatile} = render_split([base_section | plugin_prelude], format)
    {strategy_stable, strategy_volatile} = render_split(strategy_sections, format)

    {postlude_stable, postlude_volatile} =
      render_split(plugin_postlude ++ [@conciseness_section], format)

    stable_text =
      [prelude_stable, strategy_stable, postlude_stable]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    volatile_text =
      [prelude_volatile, strategy_volatile, postlude_volatile]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    {stable_text, volatile_text}
  end

  defp render_split(sections, format) do
    {stable, volatile} = Enum.split_with(sections, fn s -> not (s.volatile || false) end)
    {Rho.PromptSection.render(stable, format), Rho.PromptSection.render(volatile, format)}
  end

  defp collect_strategy_sections(strategy, tool_defs, ctx) do
    with {:module, _} <- Code.ensure_loaded(strategy),
         true <- function_exported?(strategy, :prompt_sections, 2) do
      strategy.prompt_sections(tool_defs, ctx) |> Enum.map(&normalize_section/1)
    else
      _ ->
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
    system_msg = build_system_message(runtime)

    tail =
      if runtime.tape.name,
        do: Rho.Tape.Projection.build(runtime.tape.name),
        else: messages

    [system_msg | mark_conversation_prefix(tail)]
  end

  # Adds a second `cache_control: ephemeral` breakpoint on the last
  # non-user message in the tail (typically an assistant or tool-result
  # message just before the most recent user turn). This lets the entire
  # prefix up to and including the last assistant turn be cached, so
  # multi-turn conversations don't replay the whole tape.
  #
  # Anthropic supports up to 4 breakpoints; we use at most 2 (stable
  # system + conversation prefix). Skips when there is nothing meaningful
  # to cache (empty tail or only user messages).
  defp mark_conversation_prefix(tail) when is_list(tail) do
    case last_non_user_index(tail) do
      nil -> tail
      idx -> List.update_at(tail, idx, &add_cache_breakpoint/1)
    end
  end

  defp last_non_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%{role: :user}, _idx} -> nil
      {%{role: "user"}, _idx} -> nil
      {_msg, idx} -> idx
    end)
  end

  defp add_cache_breakpoint(%{content: parts} = msg) when is_list(parts) and parts != [] do
    {init, [last]} = Enum.split(parts, -1)
    %{msg | content: init ++ [put_cache_control(last)]}
  end

  defp add_cache_breakpoint(msg), do: msg

  defp put_cache_control(%{metadata: meta} = part) when is_map(meta) do
    %{part | metadata: Map.put(meta, :cache_control, %{type: "ephemeral"})}
  end

  defp put_cache_control(part) do
    Map.put(part, :metadata, %{cache_control: %{type: "ephemeral"}})
  end

  # Builds the system message with split stable / volatile parts.
  # The stable part carries an ephemeral `cache_control` breakpoint so its
  # bytes can be re-used as a cache prefix on subsequent calls. The
  # volatile part is appended after with no breakpoint, so it doesn't
  # invalidate the earlier cached prefix when its body changes.
  @doc false
  def build_system_message(%Runtime{
        system_prompt_stable: stable,
        system_prompt_volatile: volatile
      }) do
    parts =
      case volatile do
        v when is_binary(v) and v != "" ->
          [
            ReqLLM.Message.ContentPart.text(stable, %{cache_control: %{type: "ephemeral"}}),
            ReqLLM.Message.ContentPart.text(v)
          ]

        _ ->
          [
            ReqLLM.Message.ContentPart.text(stable, %{cache_control: %{type: "ephemeral"}})
          ]
      end

    ReqLLM.Context.system(parts)
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

  # ===================================================================
  # Lite loop — no tape, no transformers, no compaction
  # ===================================================================
  #
  # Minimal agent loop for single-shot worker tasks. The turn strategy
  # handles the LLM call; tools are executed directly (no ToolExecutor
  # pipeline, no transformer stages).

  defp build_lite_context(runtime, messages) do
    [build_system_message(runtime) | messages]
  end

  defp do_lite_loop(_context, _runtime, step: step, max_steps: max)
       when step > max do
    {:error, "max steps exceeded (#{max})"}
  end

  defp do_lite_loop(context, runtime, step: step, max_steps: max) do
    runtime.emit.(%{type: :step_start, step: step, max_steps: max})

    projection = %{context: context, tools: runtime.req_tools, step: step}
    result = runtime.turn_strategy.run(projection, runtime)

    handle_lite_result(result, context, runtime, step, max)
  end

  # -- {:respond, text} in lite mode --

  defp handle_lite_result({:respond, text}, _context, _runtime, _step, _max) do
    {:ok, text || ""}
  end

  # -- {:call_tools, ...} in lite mode — direct execution --

  defp handle_lite_result({:call_tools, tool_calls, response_text}, context, runtime, step, max) do
    {results, final} =
      execute_tools_lite(tool_calls, runtime.tool_map, runtime.context, runtime.emit)

    cond do
      final != nil ->
        {:ok, final}

      true ->
        entries = runtime.turn_strategy.build_tool_step(tool_calls, results, response_text)
        next_context = context ++ [entries.assistant_msg | entries.tool_results]
        do_lite_loop(next_context, runtime, step: step + 1, max_steps: max)
    end
  end

  # -- {:think, ...} in lite mode --

  defp handle_lite_result({:think, _thought}, context, runtime, step, max) do
    do_lite_loop(context, runtime, step: step + 1, max_steps: max)
  end

  # -- {:parse_error, ...} in lite mode --

  # Invariant: `reason` is a binary — TypedStructured.dispatch_parsed/2
  # is the only emitter and it builds the reason from string interpolation.
  defp handle_lite_result({:parse_error, reason, _raw}, context, runtime, step, max) do
    correction = ReqLLM.Context.user("Parse error: #{reason}. Please try again.")
    do_lite_loop(context ++ [correction], runtime, step: step + 1, max_steps: max)
  end

  # -- {:error, ...} in lite mode --

  defp handle_lite_result({:error, reason}, _context, runtime, _step, _max) do
    runtime.emit.(%{type: :error, reason: reason})
    {:error, "LLM call failed: #{inspect(reason)}"}
  end

  # -- Direct tool execution (no transformer pipeline) --

  defp execute_tools_lite(tool_calls, tool_map, context, emit) do
    results =
      tool_calls
      |> Enum.map(fn tc ->
        Task.async(fn -> execute_tool_lite(tc, tool_map, context, emit) end)
      end)
      |> Task.await_many(:timer.minutes(5))

    {Enum.map(results, & &1.result_map), Enum.find_value(results, & &1.final)}
  end

  defp execute_tool_lite(tc, tool_map, context, emit) do
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

  # -- Compaction --

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

  # ===================================================================
  # Strategy result handling — intent-based dispatch
  # ===================================================================

  # -- {:respond, text} --
  # LLM responded without calling tools. Run :post_step — if any
  # transformer injects messages, continue looping; otherwise terminate.

  defp handle_strategy_result({:respond, text}, context, runtime, step, max) do
    Recorder.record_assistant_text(runtime, text)

    next_step = step + 1

    case run_post_step(runtime, next_step, max, :text_response) do
      [] ->
        {:ok, text}

      msgs ->
        Recorder.record_injected_messages(runtime, msgs)
        updated_context = advance_text_response_context(context, text, msgs, runtime)
        do_loop(updated_context, runtime, step: next_step, max_steps: max)
    end
  end

  # -- {:call_tools, tool_calls, response_text} --
  # LLM wants to call tools. Execute via ToolExecutor, then classify
  # outcome (terminal / final / continue).

  defp handle_strategy_result(
         {:call_tools, tool_calls, response_text},
         context,
         runtime,
         step,
         max
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

    classify_tool_outcome(tool_calls, results, response_text, context, runtime, step, max)
  catch
    {:rho_transformer_halt, reason} ->
      runtime.emit.(%{type: :error, reason: {:halt, reason}})
      {:error, {:halt, reason}}
  end

  # -- {:think, thought} --
  # Structured-output strategy wants to reason. Build think step entries
  # and continue looping.

  defp handle_strategy_result({:think, thought}, context, runtime, step, max) do
    runtime.emit.(%{type: :llm_text, text: thought})

    entries = runtime.turn_strategy.build_think_step(thought)
    Recorder.record_tool_step(runtime, entries)

    next_step = step + 1
    injected = run_post_step(runtime, next_step, max, :think_step)
    Recorder.record_injected_messages(runtime, injected)

    updated_context = advance_context(context, entries, injected, runtime)
    do_loop(updated_context, runtime, step: next_step, max_steps: max)
  end

  # -- {:parse_error, reason, raw_text} --
  # Strategy couldn't parse LLM output. Inject a correction message
  # and retry.

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

  # -- {:error, reason} --

  defp handle_strategy_result({:error, reason}, _ctx, _runtime, _step, _max),
    do: {:error, reason}

  # ===================================================================
  # Tool outcome classification
  # ===================================================================

  defp classify_tool_outcome(tool_calls, results, response_text, context, runtime, step, max) do
    final_output =
      Enum.find_value(results, fn r ->
        if r.disposition == :final, do: r.result
      end)

    cond do
      final_output != nil ->
        Recorder.record_assistant_text(runtime, final_output)
        {:ok, final_output}

      true ->
        entries =
          runtime.turn_strategy.build_tool_step(tool_calls, results, response_text)

        Recorder.record_tool_step(runtime, entries)

        next_step = step + 1
        injected = run_post_step(runtime, next_step, max, :tool_step)
        Recorder.record_injected_messages(runtime, injected)

        updated_context = advance_context(context, entries, injected, runtime)
        do_loop(updated_context, runtime, step: next_step, max_steps: max)
    end
  end

  # -- :post_step stage --

  defp run_post_step(%Runtime{context: ctx}, step, max, step_kind) do
    data = %{step: step, max_steps: max, entries_appended: [], step_kind: step_kind}

    case Rho.PluginRegistry.apply_stage(:post_step, data, ctx) do
      {:cont, nil} -> []
      {:inject, messages} -> List.wrap(messages)
      {:halt, _reason} -> []
    end
  end

  # Advance context after a text-only response that triggered an inject.
  # Mirrors the assistant + injected-user pattern used by other branches.
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

  # -- Context advancement --

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

  # Coerce an arbitrary tool return value into a string suitable for the
  # message context. Binaries pass through unchanged so happy-path tools
  # keep emitting their text byte-for-byte; anything else (tuples, structs,
  # atoms) goes through `inspect/1` to avoid `String.Chars` crashes.
  defp coerce_output(output) when is_binary(output), do: output
  defp coerce_output(output), do: inspect(output)
end
