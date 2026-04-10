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

  alias Rho.StructuredOutput
  alias Rho.PromptSection

  @max_stream_retries 2

  @impl Rho.TurnStrategy
  def prompt_sections(tool_defs, _context), do: [build_prompt_section(tool_defs)]

  @impl Rho.TurnStrategy
  def run(projection, runtime) do
    %{context: messages} = projection
    model = runtime.model
    emit = runtime.emit
    stream_opts = Keyword.drop(runtime.gen_opts, [:tools])

    case stream_with_retry(model, messages, stream_opts, emit, 1) do
      {:ok, text, usage} ->
        step = Map.get(projection, :step)
        emit.(%{type: :llm_usage, step: step, usage: usage, model: model})

        action = parse_action(text, runtime.tool_map)
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

      {:ok, [%{} | _] = list} ->
        {tool, param} = detect_implicit_tool(list)

        case Jason.encode(list) do
          {:ok, json} -> {:ok, {tool, %{param => json}, nil}}
          _ -> :miss
        end

      {:ok, _non_map} ->
        :miss

      {:error, _} ->
        :miss
    end
  end

  defp extract_action_fields(parsed) do
    action = parsed["action"] || parsed["tool"] || parsed["tool_name"] || parsed["name"]
    thinking = parsed["thinking"] || parsed["thought"] || parsed["reasoning"]

    if is_binary(action) do
      args_raw =
        parsed["action_input"] || parsed["tool_input"] || parsed["parameters"] ||
          parsed["args"] || parsed["input"]

      args = normalize_args(args_raw)
      {:ok, action, args, thinking}
    else
      :miss
    end
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
        t0 = System.monotonic_time(:millisecond)
        result = tool_def.execute.(cast_args, ctx)
        latency_ms = System.monotonic_time(:millisecond) - t0

        call = %{name: name, args: new_args, call_id: call_id}
        handle_tool_result(result, call, latency_ms, runtime)
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
    case ReqLLM.stream_text(model, context, stream_opts) do
      {:ok, stream_response} ->
        accumulated =
          stream_response
          |> ReqLLM.StreamResponse.tokens()
          |> Enum.reduce("", fn token, acc ->
            emit.(%{type: :text_delta, text: token})

            new_acc = acc <> token

            case StructuredOutput.parse_partial(new_acc) do
              {:ok, parsed} when is_map(parsed) ->
                emit.(%{type: :structured_partial, parsed: parsed})

              _ ->
                :ok
            end

            new_acc
          end)

        case get_stream_metadata(stream_response) do
          {:error, reason} ->
            if attempt <= @max_stream_retries and retryable?(reason) do
              Logger.warning(
                "[turn_strategy.structured] stream failed mid-stream (attempt #{attempt}): #{inspect(reason)}, retrying..."
              )

              Process.sleep(1_000 * attempt)
              stream_with_retry(model, context, stream_opts, emit, attempt + 1)
            else
              {:error, reason}
            end

          {:ok, usage} ->
            {:ok, accumulated, usage}
        end

      {:error, reason} ->
        if attempt <= @max_stream_retries and retryable?(reason) do
          Logger.warning(
            "[turn_strategy.structured] stream failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
          )

          Process.sleep(1_000 * attempt)
          stream_with_retry(model, context, stream_opts, emit, attempt + 1)
        else
          {:error, reason}
        end
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
      tool_defs
      |> Enum.map(fn tool_def ->
        "- #{tool_def.tool.name}: #{render_variant_params(tool_def.tool)}"
      end)
      |> Enum.join("\n")

    tool_descriptions =
      tool_defs
      |> Enum.map(fn tool_def ->
        tool = tool_def.tool
        "- #{tool.name}: #{tool.description || "No description."}"
      end)
      |> Enum.join("\n")

    %PromptSection{
      key: :output_format,
      heading: "OUTPUT FORMAT — MANDATORY",
      body: """
      You MUST ALWAYS respond with a single JSON object. No exceptions, no plain text, no markdown fences.
      This applies to EVERY response, whether you are using a tool OR just answering the user.

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
      - String values must use valid JSON escaping: \\" for quotes, \\n for newlines\
      """,
      kind: :instructions,
      priority: :low,
      subsections: [
        %PromptSection{
          key: :tool_reference,
          heading: "Tool Reference",
          body: tool_descriptions
        }
      ],
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
    assistant_text = Jason.encode!(%{action: name, action_input: args})
    result_text = "[Tool Result: #{name}]\n#{result}"

    %{
      type: :tool_step,
      assistant_msg: ReqLLM.Context.assistant(assistant_text),
      tool_results: [ReqLLM.Context.user(result_text)],
      tool_calls: [],
      structured_calls: [{name, Jason.encode!(args)}],
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

  defp detect_implicit_tool([first | _]) do
    if Map.has_key?(first, "levels") do
      {"add_proficiency_levels", "levels_json"}
    else
      {"add_rows", "rows_json"}
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
      [] ->
        "{}"

      schema when is_list(schema) ->
        fields =
          schema
          |> Enum.map(fn {name, opts} ->
            type = Keyword.get(opts, :type, :string) |> render_type()
            optional = if Keyword.get(opts, :required, false), do: "", else: "?"
            doc = Keyword.get(opts, :doc)
            desc_comment = if doc && doc != "", do: " // #{doc}", else: ""
            "#{name}#{optional}: #{type}#{desc_comment}"
          end)
          |> Enum.join(", ")

        "{ #{fields} }"

      _ ->
        "{}"
    end
  end

  defp render_type({:list, inner}), do: "#{render_type(inner)}[]"
  defp render_type({:map, k, v}), do: "map<#{render_type(k)}, #{render_type(v)}>"
  defp render_type(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp render_type(other), do: inspect(other)

  defp get_stream_metadata(%ReqLLM.StreamResponse{metadata_handle: handle}) do
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(handle)

    case metadata do
      %{error: reason} -> {:error, reason}
      _ -> {:ok, metadata[:usage] || %{}}
    end
  end

  defp get_stream_metadata(stream_response) do
    usage = ReqLLM.StreamResponse.usage(stream_response) || %{}
    {:ok, usage}
  end

  defp retryable?(%Mint.TransportError{reason: reason}), do: retryable?(reason)
  defp retryable?({:timeout, _}), do: true
  defp retryable?({:closed, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(:closed), do: true
  defp retryable?({:http_task_failed, inner}), do: retryable?(inner)
  defp retryable?({:http_streaming_failed, inner}), do: retryable?(inner)
  defp retryable?({:provider_build_failed, inner}), do: retryable?(inner)
  defp retryable?(:econnrefused), do: true
  defp retryable?(:econnreset), do: true
  defp retryable?(_), do: false
end
