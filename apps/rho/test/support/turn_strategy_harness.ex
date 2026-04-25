defmodule Rho.Test.TurnStrategyHarness do
  @moduledoc """
  Test harness for replaying a fixture LLM response through a turn strategy.

  Bypasses `Rho.Runner` and drives `strategy.run/2` directly with a
  minimal runtime. Stubs `ReqLLM.stream_text/3` via Mimic to deliver the
  fixture text as a single-token stream.

  NOTE: The old harness used `%Rho.Lifecycle{}` for before_tool deny/allow.
  The new architecture dispatches tool policy through
  `Rho.PluginRegistry.apply_stage(:tool_args_out, ...)`. Since no
  transformers are registered in tests by default, all tools are allowed.
  The `allow_tools` option currently has no effect — all tools execute.

  Returns a metrics map:

      %{
        dispatched: :final | :reprompt | :error | {:tool, name},
        reprompts: 0 | 1,
        tokens: %{input_tokens: n, output_tokens: n},
        events: [map()],
        result: {:continue, step} | {:done, response} | {:error, reason}
      }
  """

  alias Rho.Context
  alias Rho.Runner.{Runtime, TapeConfig}

  @doc """
  Run `strategy_mod` against `fixture_text` with a synthetic tool map.

  `tool_defs` is a list of tool_def maps (same shape as Runner).
  Options:
    * `:user_text` — user message for the projection context (default: "hi")
    * `:allow_tools` — currently unused (see moduledoc); kept for API compat
  """
  @spec run(module(), String.t(), [map()], keyword()) :: map()
  def run(strategy_mod, fixture_text, tool_defs, opts \\ []) do
    user_text = Keyword.get(opts, :user_text, "hi")
    usage = %{input_tokens: byte_size(user_text), output_tokens: byte_size(fixture_text)}

    fake = {:harness_stream, make_ref()}
    Mimic.stub(ReqLLM, :stream_text, fn _model, _ctx, _o -> {:ok, fake} end)
    Mimic.stub(ReqLLM.StreamResponse, :tokens, fn ^fake -> [fixture_text] end)
    Mimic.stub(ReqLLM.StreamResponse, :usage, fn ^fake -> usage end)

    events = :ets.new(:harness_events, [:ordered_set, :public])
    counter = :counters.new(1, [:atomics])

    emit = fn event ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      :ets.insert(events, {i, event})
      :ok
    end

    tool_map = Map.new(tool_defs, fn t -> {t.tool.name, t} end)

    runtime = %Runtime{
      model: "mock:model",
      turn_strategy: strategy_mod,
      emit: emit,
      gen_opts: [],
      tool_defs: tool_defs,
      req_tools: Enum.map(tool_defs, & &1.tool),
      tool_map: tool_map,
      system_prompt: "",
      subagent: false,
      depth: 0,
      tape: %TapeConfig{},
      context: %Context{
        tape_name: nil,
        tape_module: Rho.Tape.Projection.JSONL,
        workspace: ".",
        agent_name: :default,
        depth: 0,
        subagent: false,
        agent_id: "harness",
        session_id: "harness"
      }
    }

    projection = %{context: [ReqLLM.Context.user(user_text)], step: 1}

    result = strategy_mod.run(projection, runtime)
    collected = :ets.tab2list(events) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    :ets.delete(events)

    {dispatched, reprompts} = classify(result)

    %{
      dispatched: dispatched,
      reprompts: reprompts,
      tokens: usage,
      events: collected,
      result: result
    }
  end

  # -- Result classification --

  defp classify({:done, %{type: :response}}), do: {:final, 0}

  defp classify({:continue, %{structured_calls: [{name, _} | _]}}),
    do: {{:tool, name}, 0}

  defp classify({:continue, %{tool_calls: [call | _]}}) when is_map(call) do
    name = Map.get(call, :name) || Map.get(call, "name") || "unknown"
    {{:tool, name}, 0}
  end

  defp classify({:continue, %{type: :tool_step, tool_calls: [], structured_calls: []}}),
    do: {:reprompt, 1}

  defp classify({:continue, _}), do: {:reprompt, 1}

  defp classify({:error, _}), do: {:error, 0}

  defp classify({:parse_error, _, _}), do: {:reprompt, 1}

  defp classify({:final, _, _}), do: {:final, 0}

  defp classify(other), do: {{:unknown, other}, 0}
end
