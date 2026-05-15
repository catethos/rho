defmodule Rho.Runner.RuntimeBuilder do
  @moduledoc """
  Builds immutable `Rho.Runner.Runtime` values from RunSpecs or legacy opts.
  """

  alias Rho.Context
  alias Rho.PromptSection
  alias Rho.Runner.{Emit, Runtime, TapeConfig}

  @default_system_prompt "You are a helpful assistant."

  @conciseness_section PromptSection.new(
                         key: :conciseness,
                         body:
                           "Be concise between tool calls. Do not summarize what tools just did — " <>
                             "the results speak for themselves. Only add text when you need user input, " <>
                             "hit a blocker, or reach a natural milestone. Prefer calling the next tool immediately.",
                         priority: :low,
                         kind: :instructions,
                         position: :postlude
                       )

  @doc "Builds runtime configuration from an explicit RunSpec."
  def from_spec(%Rho.RunSpec{} = spec) do
    tool_defs = spec.tools || []
    tape_name = spec.tape_name
    memory_mod = spec.tape_module || Rho.Tape.Projection.JSONL
    context = context_from_spec(spec, tape_name, memory_mod)
    tape = build_tape(tape_name, memory_mod, compact_threshold: spec.compact_threshold)
    strategy = spec.turn_strategy || Rho.TurnStrategy.Direct
    base_prompt = spec.system_prompt || @default_system_prompt

    {stable_prompt, volatile_prompt} =
      build_system_prompt(base_prompt, context, strategy, tool_defs)

    raw_emit = Emit.resolve(spec.emit)
    emit = Emit.wrap_with_tape(raw_emit, tape_name, memory_mod, context, spec.model, strategy)

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

  @doc "Builds runtime configuration from the legacy `run/3` options."
  def from_legacy(model, opts) when is_list(opts) do
    tool_defs = opts[:tools] || []
    tape_name = opts[:tape_name]
    memory_mod = opts[:tape_module] || Rho.Tape.Projection.JSONL

    context = context_from_opts(opts, tape_name, memory_mod)
    tape = build_tape(tape_name, memory_mod, opts)
    strategy = opts[:turn_strategy] || opts[:reasoner] || Rho.TurnStrategy.Direct
    base_prompt = opts[:system_prompt] || @default_system_prompt

    {stable_prompt, volatile_prompt} =
      build_system_prompt(base_prompt, context, strategy, tool_defs)

    emit =
      opts
      |> Emit.resolve()
      |> Emit.wrap_with_tape(tape_name, memory_mod, context, model, strategy)

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

  defp context_from_spec(spec, tape_name, memory_mod) do
    %Context{
      tape_name: tape_name,
      tape_module: memory_mod,
      workspace: spec.workspace,
      agent_name: spec.agent_name,
      depth: spec.depth || 0,
      agent_id: spec.agent_id,
      session_id: spec.session_id,
      conversation_id: spec.conversation_id,
      thread_id: spec.thread_id,
      turn_id: spec.turn_id,
      prompt_format: spec.prompt_format || :markdown,
      user_id: spec.user_id,
      organization_id: spec.organization_id
    }
  end

  defp context_from_opts(opts, tape_name, memory_mod) do
    %Context{
      tape_name: tape_name,
      tape_module: memory_mod,
      workspace: opts[:workspace],
      agent_name: opts[:agent_name],
      depth: opts[:depth] || 0,
      agent_id: opts[:agent_id],
      session_id: opts[:session_id],
      conversation_id: opts[:conversation_id],
      thread_id: opts[:thread_id],
      turn_id: opts[:turn_id],
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

  defp build_system_prompt(base, ctx, strategy, tool_defs) do
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
    {PromptSection.render(stable, format), PromptSection.render(volatile, format)}
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

  defp normalize_section(%PromptSection{} = s), do: s
  defp normalize_section(text) when is_binary(text), do: PromptSection.from_string(text)

  defp build_gen_opts(nil), do: []

  defp build_gen_opts(provider) do
    [provider_options: [openrouter_provider: provider]]
  end
end
