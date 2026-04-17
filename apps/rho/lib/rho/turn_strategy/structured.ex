defmodule Rho.TurnStrategy.Structured do
  @moduledoc """
  Structured-output strategy: instead of relying on the LLM's native
  tool_use protocol, this strategy describes tools in the prompt and
  asks the LLM to produce a structured JSON response parsed by
  `Rho.StructuredOutput`.

  Tool arguments appear as visible streaming text — renderable
  progressively in a CLI or web UI.

  ## Configuration

      turn_strategy: :structured
      # or legacy:
      reasoner: :structured
  """

  @behaviour Rho.TurnStrategy

  require Logger

  alias Rho.LLM.Admission
  alias Rho.PromptSection
  alias Rho.StructuredOutput
  alias Rho.TurnStrategy.Shared

  @prefill "JSON:\n"

  @impl Rho.TurnStrategy
  def prompt_sections(tool_defs, _context), do: [build_prompt_section(tool_defs)]

  @impl Rho.TurnStrategy
  def run(projection, runtime) do
    %{context: messages} = projection
    model = runtime.model
    emit = runtime.emit
    stream_opts = Keyword.drop(runtime.gen_opts, [:tools])

    messages = messages ++ [ReqLLM.Context.assistant(@prefill)]

    Logger.debug("[structured] starting LLM stream")
    t_llm_start = System.monotonic_time(:millisecond)

    case stream_with_retry(model, messages, stream_opts, emit, 1) do
      {:ok, text, usage} ->
        Logger.debug(
          "[structured] LLM stream completed in #{System.monotonic_time(:millisecond) - t_llm_start}ms"
        )

        step = Map.get(projection, :step)
        emit.(%{type: :llm_usage, step: step, usage: usage, model: model})

        text = strip_prefill(text)
        action = parse_action(text, runtime.tool_map)
        detect_format_waste(text, action, model, runtime)
        execute_action(action, text, runtime.tool_map, runtime)

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  # -- Parse --

  defp parse_action(text, tool_map) do
    case parse_json_action(text) do
      {:ok, action} -> resolve_action(action, tool_map)
      :miss -> parse_fallback(text, tool_map)
    end
  end

  defp parse_json_action(text) do
    case StructuredOutput.parse(text) do
      {:ok, parsed} when is_map(parsed) ->
        case extract_action_fields(parsed) do
          {:ok, action, args, thinking} -> {:ok, {action, args, thinking}}
          :miss -> :miss
        end

      {:ok, _non_map} ->
        :miss

      {:error, _} ->
        :miss
    end
  end

  @action_keys ~w(action tool tool_name name)
  @thinking_keys ~w(thinking thought reasoning)
  @args_keys ~w(action_input tool_input parameters args input)

  defp extract_action_fields(parsed) do
    action = first_string_value(parsed, @action_keys)
    thinking = first_string_value(parsed, @thinking_keys)

    if is_binary(action) do
      args_raw = first_value(parsed, @args_keys)
      args = normalize_args(args_raw)
      {:ok, action, args, thinking}
    else
      :miss
    end
  end

  defp first_string_value(map, keys) do
    Enum.find_value(keys, fn k -> map[k] end)
  end

  defp first_value(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.get(map, k) do
        nil -> nil
        v -> v
      end
    end)
  end

  defp resolve_action({"final_answer", args, thinking}, _tool_map) do
    answer = args["answer"] || args["_raw"] || inspect(args)
    {:final, answer, thinking}
  end

  defp resolve_action({name, args, thinking}, tool_map) do
    args = resolve_tool_args(name, args, tool_map)

    if Map.has_key?(tool_map, name) do
      {:tool, name, args, thinking}
    else
      Logger.warning("[turn_strategy.structured] unknown action: #{inspect(name)}")
      {:unknown_tool, name, args, thinking}
    end
  end

  defp resolve_tool_args(name, %{"_raw" => raw}, tool_map) do
    case Map.get(tool_map, name) do
      %{tool: tool} ->
        case tool.parameter_schema do
          [{param_name, _opts} | _] -> %{to_string(param_name) => raw}
          _ -> %{"input" => raw}
        end

      nil ->
        %{"input" => raw}
    end
  end

  defp resolve_tool_args(_name, args, _tool_map), do: args

  defp parse_fallback(text, tool_map) do
    case extract_code_block(text) do
      {lang, code} when is_binary(lang) ->
        tool_name = lang_to_tool(lang)
        args = code_tool_args(tool_name, code)

        if Map.has_key?(tool_map, tool_name) do
          Logger.info(
            "[turn_strategy.structured] detected #{lang} code block, executing via #{tool_name}"
          )

          {:tool, tool_name, args, nil}
        else
          Logger.warning(
            "[turn_strategy.structured] detected #{lang} code block but no #{tool_name} tool available"
          )

          {:raw_response, text}
        end

      nil ->
        trimmed = String.trim_leading(text)

        if String.starts_with?(trimmed, "{") do
          Logger.warning(
            "[turn_strategy.structured] malformed JSON, raw text: #{String.slice(text, 0..200)}"
          )
        else
          Logger.debug("[turn_strategy.structured] plain text response (no JSON attempted)")
        end

        Logger.debug("[turn_strategy.structured] raw LLM text: #{String.slice(text, 0..500)}")
        {:raw_response, text}
    end
  end

  # -- Execute --

  defp execute_action({:final, answer, thinking}, _raw_text, _tool_map, runtime) do
    emit_thinking(thinking, runtime.emit)
    {:done, %{type: :response, text: answer}}
  end

  defp execute_action({:tool, name, args, thinking}, _raw_text, tool_map, runtime) do
    emit_thinking(thinking, runtime.emit)
    execute_tool(name, args, tool_map, runtime)
  end

  defp execute_action({:unknown_tool, name, _args, thinking}, raw_text, tool_map, runtime) do
    emit_thinking(thinking, runtime.emit)
    available = Map.keys(tool_map) |> Enum.join(", ")
    error_msg = "Error: unknown tool '#{name}'. Available tools: #{available}"
    {:continue, build_tool_step(raw_text, error_msg)}
  end

  defp execute_action({:raw_response, text}, _raw_text, tool_map, _runtime) do
    if map_size(tool_map) > 0 do
      Logger.info("[turn_strategy.structured] re-prompting: LLM did not use required JSON format")

      correction = """
      [System] Your response was not in the required JSON format. You MUST respond with a JSON object like:
      {"thinking": "your reasoning", "action": "tool_name_or_final_answer", "action_input": {...}}

      If you want to respond to the user, use: {"thinking": "...", "action": "final_answer", "action_input": {"answer": "your response"}}
      """

      {:continue, build_tool_step(text, correction)}
    else
      {:done, %{type: :response, text: text}}
    end
  end

  # -- Tool execution --

  defp execute_tool(name, args, tool_map, runtime) do
    tool_def = Map.fetch!(tool_map, name)
    call_id = "structured_#{System.unique_integer([:positive])}"
    emit = runtime.emit
    ctx = runtime.context

    emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})

    args_data = %{tool_name: name, args: args}

    case Rho.PluginRegistry.apply_stage(:tool_args_out, args_data, ctx) do
      {:deny, reason} ->
        result = "Denied: #{reason}"

        emit.(%{
          type: :tool_result,
          name: name,
          status: :error,
          output: result,
          call_id: call_id,
          latency_ms: 0,
          error_type: :denied
        })

        {:continue, build_tool_step_from_result(name, args, result)}

      {:halt, reason} ->
        emit.(%{type: :error, reason: {:halt, reason}})
        {:error, {:halt, reason}}

      {:cont, %{args: new_args}} ->
        cast_args = Rho.ToolArgs.cast(new_args, tool_def.tool.parameter_schema)

        task =
          Task.async(fn ->
            t0 = System.monotonic_time(:millisecond)
            result = tool_def.execute.(cast_args, ctx)
            latency_ms = System.monotonic_time(:millisecond) - t0
            {result, latency_ms}
          end)

        timeout = Shared.tool_inactivity_timeout()

        case Shared.await_tool_with_inactivity(task, timeout) do
          {result, latency_ms} ->
            call = %{name: name, args: new_args, call_id: call_id}
            handle_tool_result(result, call, latency_ms, runtime)

          :timeout ->
            emit.(%{
              type: :tool_result,
              name: name,
              status: :error,
              output: "tool execution inactive",
              call_id: call_id,
              latency_ms: timeout,
              error_type: :timeout
            })

            {:continue,
             build_tool_step_from_result(
               name,
               new_args,
               "Error: tool execution inactive for #{div(timeout, 1000)}s"
             )}
        end
    end
  end

  defp handle_tool_result(%Rho.ToolResponse{} = resp, call, latency_ms, runtime) do
    output_str = resp.text || ""
    result = apply_tool_result_in(call.name, output_str, runtime.context)

    runtime.emit.(%{
      type: :tool_result,
      name: call.name,
      status: :ok,
      output: result,
      call_id: call.call_id,
      latency_ms: latency_ms,
      effects: resp.effects
    })

    {:continue, build_tool_step_from_result(call.name, call.args, result)}
  end

  defp handle_tool_result({:final, output}, call, latency_ms, runtime) do
    output_str = to_string(output)
    result = apply_tool_result_in(call.name, output_str, runtime.context)

    runtime.emit.(%{
      type: :tool_result,
      name: call.name,
      status: :ok,
      output: result,
      call_id: call.call_id,
      latency_ms: latency_ms
    })

    {:done, %{type: :response, text: result}}
  end

  defp handle_tool_result({:ok, output}, call, latency_ms, runtime) do
    output_str = to_string(output)
    result = apply_tool_result_in(call.name, output_str, runtime.context)

    runtime.emit.(%{
      type: :tool_result,
      name: call.name,
      status: :ok,
      output: result,
      call_id: call.call_id,
      latency_ms: latency_ms
    })

    {:continue, build_tool_step_from_result(call.name, call.args, result)}
  end

  defp handle_tool_result({:error, reason}, call, latency_ms, runtime) do
    error_str = "Error: #{reason}"

    runtime.emit.(%{
      type: :tool_result,
      name: call.name,
      status: :error,
      output: to_string(reason),
      call_id: call.call_id,
      latency_ms: latency_ms,
      error_type: :runtime_error
    })

    {:continue, build_tool_step_from_result(call.name, call.args, error_str)}
  end

  defp apply_tool_result_in(name, result, ctx) do
    case Rho.PluginRegistry.apply_stage(:tool_result_in, %{tool_name: name, result: result}, ctx) do
      {:cont, %{result: new}} -> to_string(new)
      {:halt, _reason} -> to_string(result)
    end
  end

  # -- Streaming --

  defp stream_with_retry(model, context, stream_opts, emit, attempt) do
    stream_opts = Keyword.put_new(stream_opts, :receive_timeout, 120_000)

    # One admission slot per attempt — the slot represents an active
    # HTTP connection to the provider. Released on success OR failure
    # so retries re-queue fairly behind new work. Acquire timeout is
    # terminal (retrying won't help on the same timescale).
    case Admission.with_slot(fn -> do_stream(model, context, stream_opts, emit) end) do
      {:ok, _accumulated, _usage} = ok ->
        ok

      {:error, :acquire_timeout} = err ->
        Logger.error(
          "[turn_strategy.structured] admission timeout — no LLM slot available after 60s"
        )

        err

      {:error, reason} ->
        maybe_retry_structured(reason, model, context, stream_opts, emit, attempt)
    end
  end

  defp do_stream(model, context, stream_opts, emit) do
    with {:ok, stream_response} <- ReqLLM.stream_text(model, context, stream_opts),
         {:ok, accumulated} <- consume_stream(stream_response, emit),
         {:ok, usage} <- get_stream_metadata(stream_response) do
      {:ok, accumulated, usage}
    end
  end

  # Consumes the streaming response, accumulating text deltas and emitting
  # partial parse events. Wrapped in try/rescue so that a transport-level
  # failure raised from the underlying Finch/Req stream (e.g. pool
  # exhaustion, mid-stream disconnect) becomes `{:error, reason}` and
  # flows through `maybe_retry_structured/6` instead of crashing the
  # agent loop.
  defp consume_stream(stream_response, emit) do
    {iodata, _stripped?} =
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce({[], false}, fn token, {acc, stripped?} ->
        emit.(%{type: :text_delta, text: token})

        acc = [acc | token]
        new_acc = IO.iodata_to_binary(acc)

        {clean, stripped?} =
          if stripped?, do: {new_acc, true}, else: strip_prefill_once(new_acc)

        emit_partial(clean, emit)

        {acc, stripped?}
      end)

    {:ok, iodata |> IO.iodata_to_binary() |> strip_prefill()}
  rescue
    exception ->
      Logger.warning(
        "[turn_strategy.structured] stream consumption raised: #{Exception.message(exception)}"
      )

      {:error, exception}
  end

  defp emit_partial(clean, emit) do
    case StructuredOutput.parse_partial(clean) do
      {:ok, parsed} when is_map(parsed) ->
        emit.(%{type: :structured_partial, parsed: parsed})

      _ ->
        :ok
    end
  end

  defp maybe_retry_structured(reason, model, context, stream_opts, emit, attempt) do
    if Shared.should_retry?(reason, attempt) do
      Logger.warning(
        "[turn_strategy.structured] stream failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
      )

      Shared.retry_backoff(attempt)
      stream_with_retry(model, context, stream_opts, emit, attempt + 1)
    else
      Logger.error(
        "[turn_strategy.structured] stream FAILED after #{attempt} attempts: #{inspect(reason)} model=#{model}"
      )

      {:error, reason}
    end
  end

  # -- Prompt section (strategy-owned) --

  @doc """
  Returns a `%PromptSection{}` with the structured-output format instructions.

  Kept public for legacy callers that previously called
  `Rho.Reasoner.Structured.prompt_section/1`.
  """
  def build_prompt_section(tool_defs) do
    tool_variants =
      Enum.map_join(tool_defs, "\n", fn tool_def ->
        tool = tool_def.tool
        desc = tool.description || ""
        params = render_variant_params(tool)
        "- #{tool.name}: #{desc} #{params}"
      end)

    %PromptSection{
      key: :output_format,
      heading: "OUTPUT FORMAT — MANDATORY",
      body: """
      You MUST ALWAYS respond with a single JSON object. No exceptions, no plain text, no markdown fences.
      This applies to EVERY response, whether you are using a tool OR just answering the user.
      Your VERY FIRST character must be `{`. Do not write any prose before the opening brace.

      Schema:
      {
        thinking: string,
        action: Action,
        action_input: { ... },
      }

      Action variants (set "action" to one of these):
      - final_answer: { answer: string }
      #{tool_variants}

      Rules:
      - EVERY response must be a JSON object with "thinking", "action", and "action_input" fields
      - The "action" field must be exactly one of the variant names above
      - String values must use valid JSON escaping: \\" for quotes, \\n for newlines
      - `thinking` is a SHORT private scratchpad (≤ 2 sentences). Never paste JSON,
        arrays, row data, or tool output into `thinking` — it wastes tokens and
        the content will be hallucinated since you cannot see data the tool
        returned in its side-effects.
      - If you catch yourself about to emit `[{` or a long enumeration inside
        `thinking` or `answer`, STOP: summarize the shape instead (e.g.
        "13 skills across 4 categories") and continue.\
      """,
      kind: :instructions,
      priority: :low,
      examples: [
        ~s({"thinking": "The user is asking who I am.", "action": "final_answer", "action_input": {"answer": "I am your AI assistant."}}),
        ~s({"thinking": "I need to list files.", "action": "bash", "action_input": {"cmd": "ls -la"}})
      ]
    }
  end

  # Legacy single-arg entrypoint retained for backward compatibility.
  @doc false
  def prompt_section(tool_defs), do: build_prompt_section(tool_defs)

  # -- Step builders --

  defp build_tool_step_from_result(name, args, result) do
    args_json = Jason.encode!(args)
    assistant_text = Jason.encode!(%{action: name, action_input: args})
    result_text = "[Tool Result: #{name}]\n#{result}"

    %{
      type: :tool_step,
      assistant_msg: ReqLLM.Context.assistant(assistant_text),
      tool_results: [ReqLLM.Context.user(result_text)],
      tool_calls: [],
      structured_calls: [{name, args_json}],
      response_text: nil
    }
  end

  defp build_tool_step(raw_text, result_text) do
    %{
      type: :tool_step,
      assistant_msg: ReqLLM.Context.assistant(raw_text),
      tool_results: [ReqLLM.Context.user(result_text)],
      tool_calls: [],
      structured_calls: [],
      response_text: nil
    }
  end

  # -- Helpers --

  # Flag two failure modes that waste output tokens:
  #
  #   1. `:trailing_garbage` — the LLM produced a valid action envelope but
  #      kept emitting content after the closing `}` (e.g. duplicated prose,
  #      closing markdown fence). Only reported when `parse_action` actually
  #      returned a usable action; otherwise the trailing bytes aren't
  #      "trailing" at all, they're the response itself.
  #
  #   2. `:no_envelope` — the LLM didn't produce any recognizable action
  #      envelope, forcing the expensive re-prompt path in
  #      `execute_action({:raw_response, _}, ...)`. Records the full
  #      output byte count so operators can size the waste.
  defp detect_format_waste(text, action, model, runtime) do
    agent = runtime.context && runtime.context.agent_name
    step = runtime.context && runtime.context.depth
    trimmed = String.trim(text)

    case action do
      {:raw_response, _} ->
        total_bytes = byte_size(trimmed)

        Logger.warning(
          "[turn_strategy.structured] LLM produced no valid action envelope " <>
            "(#{total_bytes} bytes will trigger re-prompt). " <>
            "agent=#{inspect(agent)} model=#{model}. " <>
            "Preview: #{String.slice(trimmed, 0, 160)}"
        )

        :telemetry.execute(
          [:rho, :structured, :no_envelope],
          %{wasted_bytes: total_bytes},
          %{model: model, agent_name: agent, step: step}
        )

      _valid_action ->
        case find_balanced_envelope(trimmed) do
          {:ok, envelope_end} ->
            trailing = binary_part(trimmed, envelope_end, byte_size(trimmed) - envelope_end)
            trailing_trimmed = String.trim(trailing)
            trailing_bytes = byte_size(trailing_trimmed)

            # Ignore tiny trailers (closing markdown fence, stray whitespace)
            # — they cost ~1 token and are uninteresting noise.
            if trailing_bytes > 8 do
              Logger.warning(
                "[turn_strategy.structured] LLM emitted #{trailing_bytes} bytes after valid envelope " <>
                  "(agent=#{inspect(agent)} model=#{model}). " <>
                  "Preview: #{String.slice(trailing_trimmed, 0, 120)}"
              )

              :telemetry.execute(
                [:rho, :structured, :trailing_garbage],
                %{trailing_bytes: trailing_bytes, total_bytes: byte_size(trimmed)},
                %{model: model, agent_name: agent, step: step}
              )
            end

          :error ->
            :ok
        end
    end
  end

  # Find the byte offset right after the matching `}` that closes the first
  # top-level `{`, honoring string quoting. Returns `{:ok, end_offset}` or
  # `:error` if no balanced envelope exists.
  defp find_balanced_envelope(text) do
    case :binary.match(text, "{") do
      {start, _} -> scan_balanced(text, start + 1, 1, false, false)
      :nomatch -> :error
    end
  end

  defp scan_balanced(_text, pos, 0, _in_str, _esc), do: {:ok, pos}

  defp scan_balanced(text, pos, _depth, _in_str, _esc) when pos >= byte_size(text),
    do: :error

  defp scan_balanced(text, pos, depth, in_str, true),
    do: scan_balanced(text, pos + 1, depth, in_str, false)

  defp scan_balanced(text, pos, depth, true, false) do
    case binary_part(text, pos, 1) do
      "\\" -> scan_balanced(text, pos + 1, depth, true, true)
      "\"" -> scan_balanced(text, pos + 1, depth, false, false)
      _ -> scan_balanced(text, pos + 1, depth, true, false)
    end
  end

  defp scan_balanced(text, pos, depth, false, false) do
    case binary_part(text, pos, 1) do
      "\"" -> scan_balanced(text, pos + 1, depth, true, false)
      "{" -> scan_balanced(text, pos + 1, depth + 1, false, false)
      "}" -> scan_balanced(text, pos + 1, depth - 1, false, false)
      _ -> scan_balanced(text, pos + 1, depth, false, false)
    end
  end

  defp strip_prefill(text) do
    case String.split(text, @prefill, parts: 2) do
      [_, rest] -> rest
      _ -> text
    end
  end

  defp strip_prefill_once(text) do
    case String.split(text, @prefill, parts: 2) do
      [_, rest] -> {rest, true}
      _ -> {text, false}
    end
  end

  defp emit_thinking(nil, _emit), do: :ok

  defp emit_thinking(thinking, emit) when is_binary(thinking) do
    if String.trim(thinking) != "", do: emit.(%{type: :llm_text, text: thinking})
  end

  defp normalize_args(nil), do: %{}

  defp normalize_args(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"_raw" => s}
    end
  end

  defp normalize_args(map) when is_map(map), do: map
  defp normalize_args(_), do: %{}

  @lang_tool_map %{
    "python" => "python",
    "py" => "python",
    "bash" => "bash",
    "sh" => "bash",
    "shell" => "bash",
    "zsh" => "bash"
  }

  defp lang_to_tool(lang),
    do: Map.get(@lang_tool_map, String.downcase(lang), String.downcase(lang))

  defp code_tool_args("python", code), do: %{"code" => code}
  defp code_tool_args("bash", code), do: %{"command" => code}
  defp code_tool_args(_tool, code), do: %{"code" => code}

  defp extract_code_block(text) do
    case Regex.run(~r/```(\w+)\s*\n(.*?)(?:```|$)/s, text) do
      [_, lang, code] when byte_size(code) > 0 -> {lang, String.trim(code)}
      _ -> nil
    end
  end

  defp render_variant_params(tool) do
    case tool.parameter_schema do
      [] -> "{}"
      schema when is_list(schema) -> "{ #{render_schema_fields(schema)} }"
      _ -> "{}"
    end
  end

  defp render_schema_fields(schema) do
    Enum.map_join(schema, ", ", fn {name, opts} ->
      type = Keyword.get(opts, :type, :string) |> render_type()
      optional = if Keyword.get(opts, :required, false), do: "", else: "?"
      doc = Keyword.get(opts, :doc)
      desc_comment = if doc && doc != "", do: " // #{doc}", else: ""
      "#{name}#{optional}: #{type}#{desc_comment}"
    end)
  end

  defp render_type({:list, inner}), do: "#{render_type(inner)}[]"
  defp render_type({:map, k, v}), do: "map<#{render_type(k)}, #{render_type(v)}>"
  defp render_type(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp render_type(other), do: inspect(other)

  defp get_stream_metadata(%ReqLLM.StreamResponse{metadata_handle: handle}) do
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(handle, :timer.seconds(30))

    case metadata do
      %{error: reason} -> {:error, reason}
      _ -> {:ok, metadata[:usage] || %{}}
    end
  rescue
    # GenServer.call raises on timeout
    _ -> {:ok, %{}}
  end

  defp get_stream_metadata(stream_response) do
    usage = ReqLLM.StreamResponse.usage(stream_response) || %{}
    {:ok, usage}
  end
end
