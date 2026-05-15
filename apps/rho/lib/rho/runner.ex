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

  alias Rho.Recorder
  alias Rho.Runner.{LiteLoop, Loop, Runtime, RuntimeBuilder}

  @doc """
  Runs the agent loop from a RunSpec.

  Returns `{:ok, text}`, `{:final, value}`, or `{:error, reason}`.
  """
  def run(messages, %Rho.RunSpec{} = spec) do
    runtime = RuntimeBuilder.from_spec(spec)
    max_steps = spec.max_steps || 50

    if runtime.lite do
      LiteLoop.run(messages, runtime, max_steps)
    else
      Recorder.record_input_messages(runtime, messages)
      context = build_initial_context(runtime, messages)
      Loop.run(context, runtime, max_steps)
    end
  end

  @doc """
  Legacy 3-arity form — builds an ad-hoc RunSpec from opts and delegates.

  Prefer `run/2` with an explicit `%RunSpec{}` for new code.
  """
  def run(model, messages, opts) when is_list(opts) do
    runtime = RuntimeBuilder.from_legacy(model, opts)
    max_steps = opts[:max_steps] || 50

    Recorder.record_input_messages(runtime, messages)

    context = build_initial_context(runtime, messages)

    Loop.run(context, runtime, max_steps)
  end

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
end
