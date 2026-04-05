defmodule Rho.Test.ReasonerHarness do
  @moduledoc """
  Test harness for replaying a fixture LLM response through a reasoner.

  Bypasses `Rho.AgentLoop` and drives `reasoner.run/2` directly with a
  minimal runtime. Stubs `ReqLLM.stream_text/3` via Mimic to deliver the
  fixture text as a single-token stream.

  Returns a metrics map:

      %{
        dispatched: :final | :reprompt | :error | {:tool, name},
        heuristic_hits: non_neg_integer(),
        reprompts: 0 | 1,
        tokens: %{input_tokens: n, output_tokens: n},
        events: [map()],
        result: {:continue, step} | {:done, response} | {:error, reason}
      }

  ## heuristic_hits

  For `:structured`, the harness inspects the fixture text via
  `structured_heuristics/2` and counts the recovery paths the parser
  would have taken (bare-array detection, `_raw` wrapping, code-block
  fallback, raw-response fallback, unknown-action handling). For any
  other reasoner, returns 0.
  """

  alias Rho.AgentLoop.{Runtime, Tape}
  alias Rho.Lifecycle
  alias Rho.Mount.Context

  @doc """
  Run `reasoner_mod` against `fixture_text` with a synthetic tool map.

  `tool_defs` is a list of tool_def maps (same shape as AgentLoop).
  Options:
    * `:user_text` — user message for the projection context (default: "hi")
    * `:allow_tools` — if true, lifecycle `before_tool` returns `:ok` so
      the tool's `execute` fn runs and `handle_tool_result/5` fires
      (default: false — every call is denied for dispatch-only measurement)
  """
  @spec run(module(), String.t(), [map()], keyword()) :: map()
  def run(reasoner_mod, fixture_text, tool_defs, opts \\ []) do
    user_text = Keyword.get(opts, :user_text, "hi")
    allow_tools = Keyword.get(opts, :allow_tools, false)
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
      reasoner: reasoner_mod,
      emit: emit,
      gen_opts: [],
      tool_defs: tool_defs,
      req_tools: Enum.map(tool_defs, & &1.tool),
      tool_map: tool_map,
      system_prompt: "",
      subagent: false,
      depth: 0,
      tape: %Tape{},
      mount_context: %Context{
        model: "mock:model",
        agent_name: :default,
        tape_name: nil,
        workspace: ".",
        agent_id: "harness",
        session_id: "harness",
        depth: 0,
        subagent: false
      },
      lifecycle: %Lifecycle{
        before_llm: fn p -> p end,
        # By default deny every tool call (dispatch-only measurement).
        # With `:allow_tools` the tool's execute fn runs and
        # `handle_tool_result/5` is exercised.
        before_tool:
          if(allow_tools, do: fn _call -> :ok end, else: fn _call -> {:deny, "harness"} end),
        after_tool: fn _call, result -> result end,
        after_step: fn _, _ -> [] end
      }
    }

    projection = %{context: [ReqLLM.Context.user(user_text)], step: 1}

    result = reasoner_mod.run(projection, runtime)
    collected = :ets.tab2list(events) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    :ets.delete(events)

    {dispatched, reprompts} = classify(result)

    heuristic_hits =
      case reasoner_mod do
        Rho.Reasoner.Structured -> length(structured_heuristics(fixture_text, tool_map))
        _ -> 0
      end

    %{
      dispatched: dispatched,
      heuristic_hits: heuristic_hits,
      reprompts: reprompts,
      tokens: usage,
      events: collected,
      result: result
    }
  end

  @doc """
  Detect which `:structured`-reasoner heuristic recovery paths would fire
  for the given LLM text. Returns a list of atoms:

    * `:bare_array` — top-level JSON array → `detect_implicit_tool`
    * `:string_action_input` — `action_input` was a string → `_raw` wrapper
    * `:unknown_action` — action name not in tool_map (non-final)
    * `:code_block_fallback` — no JSON but a fenced code block → `lang_to_tool`
    * `:raw_response` — no JSON, no code block → treated as raw
    * `:malformed_json` — starts with `{` but fails to decode
  """
  def structured_heuristics(text, tool_map) do
    stripped = Rho.Parse.Lenient.strip_fences(text)

    case Jason.decode(stripped) do
      {:ok, list} when is_list(list) ->
        [:bare_array]

      {:ok, %{} = parsed} ->
        detect_map_heuristics(parsed, tool_map)

      {:ok, _other} ->
        [:raw_response]

      {:error, _} ->
        trimmed = String.trim_leading(text)

        cond do
          Regex.match?(~r/```(\w+)\s*\n/s, text) -> [:code_block_fallback]
          String.starts_with?(trimmed, "{") -> [:malformed_json, :raw_response]
          true -> [:raw_response]
        end
    end
  end

  defp detect_map_heuristics(parsed, tool_map) do
    action = parsed["action"] || parsed["tool"] || parsed["tool_name"] || parsed["name"]

    args_raw =
      parsed["action_input"] || parsed["tool_input"] || parsed["parameters"] ||
        parsed["args"] || parsed["input"]

    hits = []

    hits =
      case args_raw do
        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, m} when is_map(m) -> hits
            _ -> [:string_action_input | hits]
          end

        _ ->
          hits
      end

    hits =
      cond do
        not is_binary(action) -> [:raw_response | hits]
        action == "final_answer" -> hits
        Map.has_key?(tool_map, action) -> hits
        true -> [:unknown_action | hits]
      end

    hits
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

  defp classify({:final, _, _}), do: {:final, 0}

  defp classify(other), do: {{:unknown, other}, 0}
end
