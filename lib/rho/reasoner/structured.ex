defmodule Rho.Reasoner.Structured do
  @moduledoc """
  Structured-output reasoner: instead of relying on the LLM's native tool_use
  protocol, this reasoner describes tools in the prompt and asks the LLM to
  produce a structured JSON response parsed by `Rho.StructuredOutput`.

  The key advantage is that tool call arguments appear as visible streaming
  text — they can be rendered progressively in a CLI or web UI, unlike native
  tool_use blocks which are opaque during streaming.

  ## Core structure

  Each step is: stream → parse → execute.

  `parse_action/2` classifies the LLM output into a tagged union:

  - `{:final, answer}`          — terminal, stop the loop
  - `{:tool, name, args}`       — invoke a tool, feed result back
  - `{:unknown_tool, name, args, raw}` — tool not found, feed error back
  - `{:raw_response, text}`     — unparseable, treat as final answer

  `execute_action/4` dispatches on that union and returns
  `{:done, ...}` or `{:continue, ...}` for the agent loop.

  ## Configuration

      reasoner: :structured
  """

  @behaviour Rho.Reasoner

  require Logger

  alias Rho.StructuredOutput

  @max_stream_retries 2

  # -- Entry point: stream → parse → execute --

  @impl Rho.Reasoner
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

  # -- Parse: LLM text → action union --

  defp parse_action(text, tool_map) do
    case parse_json_action(text) do
      {:ok, action} -> resolve_action(action, tool_map)
      :miss -> parse_fallback(text, tool_map)
    end
  end

  # Try to extract a structured JSON action from the text.
  defp parse_json_action(text) do
    case StructuredOutput.parse(text) do
      {:ok, %{"action" => action} = parsed} when is_binary(action) ->
        args = normalize_args(parsed["action_input"])
        thinking = parsed["thinking"]
        {:ok, {action, args, thinking}}

      {:ok, _non_action} ->
        :miss

      {:error, _} ->
        :miss
    end
  end

  # Classify a parsed {action, args, thinking} into the union type.
  defp resolve_action({"final_answer", args, thinking}, _tool_map) do
    answer = args["answer"] || inspect(args)
    {:final, answer, thinking}
  end

  defp resolve_action({name, args, thinking}, tool_map) do
    if Map.has_key?(tool_map, name) do
      {:tool, name, args, thinking}
    else
      Logger.warning("[reasoner.structured] unknown action: #{inspect(name)}")
      {:unknown_tool, name, args, thinking}
    end
  end

  # Fallback: check for fenced code blocks, otherwise treat as raw response.
  defp parse_fallback(text, tool_map) do
    case extract_code_block(text) do
      {lang, code} when is_binary(lang) ->
        tool_name = lang_to_tool(lang)
        args = code_tool_args(tool_name, code)

        if Map.has_key?(tool_map, tool_name) do
          Logger.info("[reasoner.structured] detected #{lang} code block, executing via #{tool_name}")
          {:tool, tool_name, args, nil}
        else
          Logger.warning("[reasoner.structured] detected #{lang} code block but no #{tool_name} tool available")
          {:raw_response, text}
        end

      nil ->
        trimmed = String.trim_leading(text)

        if String.starts_with?(trimmed, "{") do
          # Tried to produce JSON but failed — worth a warning
          Logger.warning("[reasoner.structured] malformed JSON, raw text: #{String.slice(text, 0..200)}")
        else
          # Plain text response — LLM answered directly without tools, this is normal
          Logger.debug("[reasoner.structured] plain text response (no JSON attempted)")
        end

        {:raw_response, text}
    end
  end

  # -- Execute: action union → loop result --

  defp execute_action({:final, answer, thinking}, _raw_text, _tool_map, runtime) do
    emit_thinking(thinking, runtime.emit)
    {:done, %{type: :response, text: answer}}
  end

  defp execute_action({:tool, name, args, thinking}, _raw_text, tool_map, runtime) do
    emit_thinking(thinking, runtime.emit)
    execute_tool(name, args, tool_map, runtime.emit, runtime.lifecycle)
  end

  defp execute_action({:unknown_tool, name, _args, thinking}, raw_text, tool_map, runtime) do
    emit_thinking(thinking, runtime.emit)
    available = Map.keys(tool_map) |> Enum.join(", ")
    error_msg = "Error: unknown tool '#{name}'. Available tools: #{available}"
    {:continue, build_tool_step(raw_text, error_msg)}
  end

  defp execute_action({:raw_response, text}, _raw_text, _tool_map, _runtime) do
    {:done, %{type: :response, text: text}}
  end

  # -- Tool execution --

  defp execute_tool(name, args, tool_map, emit, lifecycle) do
    tool_def = Map.fetch!(tool_map, name)
    call_id = "structured_#{System.unique_integer([:positive])}"
    call = %{name: name, args: args, call_id: call_id}

    emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})

    case lifecycle.before_tool.(call) do
      {:deny, reason} ->
        result = "Denied: #{reason}"
        emit.(%{type: :tool_result, name: name, status: :error, output: result,
                call_id: call_id, latency_ms: 0, error_type: :denied})

        {:continue, build_tool_step_from_result(name, args, result)}

      :ok ->
        t0 = System.monotonic_time(:millisecond)
        result = tool_def.execute.(args)
        latency_ms = System.monotonic_time(:millisecond) - t0

        handle_tool_result(result, call, latency_ms, emit, lifecycle)
    end
  end

  defp handle_tool_result({:final, output}, call, latency_ms, emit, lifecycle) do
    output_str = to_string(output)
    result = lifecycle.after_tool.(call, output_str)
    emit.(%{type: :tool_result, name: call.name, status: :ok, output: result,
            call_id: call.call_id, latency_ms: latency_ms})
    {:done, %{type: :response, text: result}}
  end

  defp handle_tool_result({:ok, output}, call, latency_ms, emit, lifecycle) do
    output_str = to_string(output)
    result = lifecycle.after_tool.(call, output_str)
    emit.(%{type: :tool_result, name: call.name, status: :ok, output: result,
            call_id: call.call_id, latency_ms: latency_ms})
    {:continue, build_tool_step_from_result(call.name, call.args, result)}
  end

  defp handle_tool_result({:error, reason}, call, latency_ms, emit, _lifecycle) do
    error_str = "Error: #{reason}"
    emit.(%{type: :tool_result, name: call.name, status: :error, output: to_string(reason),
            call_id: call.call_id, latency_ms: latency_ms, error_type: :runtime_error})
    {:continue, build_tool_step_from_result(call.name, call.args, error_str)}
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

        # Check metadata for stream errors (connection closed mid-stream)
        case get_stream_metadata(stream_response) do
          {:error, reason} ->
            if attempt <= @max_stream_retries and retryable?(reason) do
              Logger.warning("[reasoner.structured] stream failed mid-stream (attempt #{attempt}): #{inspect(reason)}, retrying...")
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
          Logger.warning("[reasoner.structured] stream failed (attempt #{attempt}): #{inspect(reason)}, retrying...")
          Process.sleep(1_000 * attempt)
          stream_with_retry(model, context, stream_opts, emit, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  # -- Tool prompt section (public, called by AgentLoop) --

  @doc """
  Returns a `%PromptSection{}` with the structured-output format instructions.

  Tools are rendered as a tagged enum (discriminated union) with inline
  parameter shapes and comments (BAML-style).
  """
  def prompt_section(tool_defs) do
    alias Rho.Mount.PromptSection

    # Compact variant list: just name + params, no descriptions
    tool_variants =
      tool_defs
      |> Enum.map(fn tool_def ->
        "- #{tool_def.tool.name}: #{render_variant_params(tool_def.tool)}"
      end)
      |> Enum.join("\n")

    # Tool descriptions as structured reference
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

  defp emit_thinking(nil, _emit), do: :ok
  defp emit_thinking(thinking, emit) when is_binary(thinking) do
    if String.trim(thinking) != "", do: emit.(%{type: :llm_text, text: thinking})
  end

  defp normalize_args(nil), do: %{}
  defp normalize_args(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"answer" => s}
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

  defp lang_to_tool(lang), do: Map.get(@lang_tool_map, String.downcase(lang), String.downcase(lang))

  defp code_tool_args("python", code), do: %{"code" => code}
  defp code_tool_args("bash", code), do: %{"command" => code}
  defp code_tool_args(_tool, code), do: %{"code" => code}

  defp extract_code_block(text) do
    case Regex.run(~r/```(\w+)\s*\n(.*?)(?:```|$)/s, text) do
      [_, lang, code] when byte_size(code) > 0 -> {lang, String.trim(code)}
      _ -> nil
    end
  end

  # Render a tool's parameters as BAML-style inline pseudo-JSON.
  # Example: { path: string, offset?: int // line offset }
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

  # Extract metadata from stream response, detecting mid-stream errors.
  # Returns {:ok, usage} or {:error, reason}.
  defp get_stream_metadata(%ReqLLM.StreamResponse{metadata_handle: handle}) do
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(handle)

    case metadata do
      %{error: reason} -> {:error, reason}
      _ -> {:ok, metadata[:usage] || %{}}
    end
  end

  defp get_stream_metadata(stream_response) do
    # Fallback for non-struct stream responses (e.g., test fakes)
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
