defmodule Rho.AgentLoop do
  @moduledoc """
  Recursive LLM tool-calling loop.

  Sends messages to an LLM, executes any tool calls it requests, feeds
  results back, and repeats until the LLM responds with plain text or a
  termination condition is met (max steps or terminal tool).

  ## Key concepts

  * **Runtime** (`Rho.AgentLoop.Runtime`) — immutable configuration for one
    loop invocation: model, tools, emit callback, system prompt, and
    references to the tape and lifecycle. Built once in `run/3`, then
    threaded everywhere.

  * **Tape** (`Rho.AgentLoop.Tape`) — persistent conversation log. When a
    `tape_name` is provided, messages, tool calls, and results are recorded
    so context can be rebuilt across turns. Without a tape, context is kept
    only in-memory for the current invocation.

  * **Recorder** (`Rho.AgentLoop.Recorder`) — the single module responsible
    for writing to the tape. All semantic writes (user messages, assistant
    text, tool calls/results, injected messages) go through it.

  * **Reasoner** (`Rho.Reasoner`) — strategy for one reason+act iteration:
    call the LLM, execute tool calls, return a result indicating whether to
    continue looping or stop. `Rho.Reasoner.Direct` is the default (and
    currently only) implementation.

  * **Lifecycle** (`Rho.Lifecycle`) — the four mount hook functions
    (`before_llm`, `before_tool`, `after_tool`, `after_step`) captured as
    a struct of closures. Built from `MountRegistry` at loop start, then
    passed to the reasoner so it never touches the registry directly.

  * **Mount** (`Rho.Mount`) — a plugin module that contributes tools,
    prompt sections, or lifecycle hooks to an agent. Registered in
    `MountRegistry` and discovered via ETS.

  * **Mount.Context** (`Rho.Mount.Context`) — the typed struct passed to
    mount callbacks identifying the current agent, model, tape, and other
    ambient state.
  """

  require Logger

  alias Rho.AgentLoop.{Recorder, Runtime, Tape}
  alias Rho.Lifecycle
  alias Rho.Mount.Context

  @doc """
  Runs the agent loop: sends messages to the LLM, executes any tool calls,
  and loops until the LLM responds with plain text or max steps is reached.

  ## Options
    * `:system_prompt` - system prompt string (default: "You are a helpful assistant.")
    * `:tools` - list of tool definition maps, each with `:tool` (ReqLLM.Tool) and `:execute` (fn)
    * `:max_steps` - max tool-calling iterations (default: from config)
    * `:emit` - callback `fn(event) -> :ok` invoked on loop events (observation only).
    * `:on_event` - legacy callback (deprecated, use `:emit`). Supports `{:override, ...}` returns.
    * `:on_text` - legacy streaming text callback (deprecated, use `:emit` with `:text_delta` events).
    * `:tape_name` - if set, enables tape recording and View-based context assembly.
    * `:reasoner` - module implementing `Rho.Reasoner` (default: `Rho.Reasoner.Direct`)

  ## Event types
    * `%{type: :text_delta, text: string}` - streaming text chunk from LLM
    * `%{type: :llm_text, text: string}` - LLM emitted text alongside tool calls
    * `%{type: :tool_start, name: string, args: map, call_id: string}` - tool invocation starting
    * `%{type: :tool_result, name: string, status: :ok | :error, output: string, call_id: string}` - tool finished
    * `%{type: :step_start, step: integer, max_steps: integer}` - loop step beginning
    * `%{type: :llm_usage, step: integer, usage: map}` - token usage stats
    * `%{type: :compact, tape_name: string}` - tape compaction occurred
    * `%{type: :error, reason: term}` - LLM call failed

  Returns {:ok, text_response} or {:error, reason}.
  """
  def run(model, messages, opts \\ []) do
    runtime = build_runtime(model, messages, opts)
    max_steps = opts[:max_steps] || Rho.Config.agent().max_steps

    Recorder.record_input_messages(runtime, messages)

    context = build_initial_context(runtime, messages)

    do_loop(context, runtime, step: 1, max_steps: max_steps)
  end

  # -- Build runtime --

  defp build_runtime(model, messages, opts) do
    tool_defs = opts[:tools] || []
    tape_name = opts[:tape_name]
    memory_mod = opts[:memory_mod] || Rho.Memory.Tape
    subagent = opts[:subagent] || false
    depth = opts[:depth] || 0

    mount_context = %Context{
      model: model,
      tape_name: tape_name,
      memory_mod: memory_mod,
      input_messages: messages,
      opts: opts,
      workspace: opts[:workspace],
      agent_name: opts[:agent_name],
      depth: depth,
      subagent: subagent,
      prompt_format: opts[:prompt_format] || :markdown
    }

    tape = %Tape{
      name: tape_name,
      memory_mod: memory_mod,
      compact_threshold: opts[:compact_threshold] || 100_000,
      compact_supported: function_exported?(memory_mod, :compact_if_needed, 2)
    }

    lifecycle =
      if subagent,
        do: Lifecycle.noop(),
        else: Lifecycle.from_mount_registry(mount_context)

    reasoner = opts[:reasoner] || Rho.Reasoner.Direct

    base_prompt = opts[:system_prompt] || "You are a helpful assistant."

    extra_sections =
      with {:module, _} <- Code.ensure_loaded(reasoner),
           true <- function_exported?(reasoner, :prompt_sections, 1) do
        reasoner.prompt_sections(tool_defs)
      else
        _ -> []
      end

    system_prompt = build_system_prompt(base_prompt, subagent, mount_context, extra_sections)

    raw_emit = resolve_emit(opts)

    emit =
      if tape_name do
        fn event ->
          # Only record events that Recorder doesn't handle (usage, errors).
          # Semantic content (messages, tool calls, tool results) is recorded
          # by Recorder to avoid duplicate tape entries.
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
      reasoner: reasoner,
      emit: emit,
      gen_opts: build_gen_opts(opts[:provider]),
      tool_defs: tool_defs,
      req_tools: req_tools,
      tool_map: tool_map,
      system_prompt: system_prompt,
      subagent: subagent,
      depth: depth,
      tape: tape,
      mount_context: mount_context,
      lifecycle: lifecycle
    }
  end

  # -- Setup helpers --

  defp build_system_prompt(base, true = _subagent, _ctx, _extra), do: base

  defp build_system_prompt(base, _subagent, ctx, extra) do
    alias Rho.Mount.PromptSection

    base_section =
      PromptSection.new(
        key: :base_prompt,
        body: base,
        priority: :high,
        kind: :instructions
      )

    mount_sections = Rho.MountRegistry.collect_prompt_material(ctx)
    format = ctx[:prompt_format] || :markdown

    PromptSection.render([base_section | mount_sections] ++ extra, format)
  end

  defp build_initial_context(runtime, messages) do
    system_msg =
      ReqLLM.Context.system([
        ReqLLM.Message.ContentPart.text(runtime.system_prompt, %{
          cache_control: %{type: "ephemeral"}
        })
      ])

    tail =
      if runtime.tape.name,
        do: runtime.tape.memory_mod.build_context(runtime.tape.name),
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
         {:ok, projection} <- run_before_llm(context, runtime, step) do
      runtime.reasoner.run(projection, runtime)
      |> handle_reasoner_result(context, runtime, step, max)
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
      tape: %Tape{name: tape, memory_mod: mem, compact_threshold: threshold},
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
        Logger.warning("[agent_loop] compaction failed: #{inspect(reason)}")
        {:error, {:compact_failed, reason}}
    end
  end

  # -- Before-LLM hook --

  defp run_before_llm(
         context,
         %Runtime{req_tools: req_tools, lifecycle: lifecycle, emit: emit},
         step
       ) do
    projection =
      %{context: context, tools: req_tools, step: step}
      |> lifecycle.before_llm.()

    emit.(%{type: :before_llm, projection: projection})

    {:ok, projection}
  end

  # -- Reasoner result handling --

  defp handle_reasoner_result({:done, %{type: :response, text: text}}, _ctx, runtime, _step, _max) do
    Recorder.record_assistant_text(runtime, text)
    {:ok, text}
  end

  defp handle_reasoner_result({:final, value, _entries}, _ctx, _opts, _step, _max),
    do: {:final, value}

  defp handle_reasoner_result({:error, reason}, _ctx, _opts, _step, _max),
    do: {:error, reason}

  defp handle_reasoner_result(
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

  defp handle_reasoner_result(
         {:continue, %{type: :tool_step} = entries},
         context,
         runtime,
         step,
         max
       ) do
    Recorder.record_tool_step(runtime, entries)
    next_step = step + 1
    injected = run_after_step(runtime, next_step, max)
    Recorder.record_injected_messages(runtime, injected)

    updated_context = advance_context(context, entries, injected, runtime)
    do_loop(updated_context, runtime, step: next_step, max_steps: max)
  end

  # -- After-step hook --

  defp run_after_step(%Runtime{lifecycle: lifecycle}, step, max) do
    lifecycle.after_step.(step, max)
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

  # -- Resolve emit callback --

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
