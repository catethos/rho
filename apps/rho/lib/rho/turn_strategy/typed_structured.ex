defmodule Rho.TurnStrategy.TypedStructured do
  @moduledoc """
  Typed structured-output strategy using `Rho.ActionSchema`.

  Structured-output strategy using `Rho.ActionSchema` for typed dispatch.

  Describes tools in the prompt and asks the LLM to produce a flat JSON
  response with `"tool"` as discriminant. Parsing is handled by
  `ActionSchema.parse_and_dispatch/3` — a tagged union dispatcher with
  schema-guided coercion.

  Parse errors are returned as `{:parse_error, reason, text}` for the
  Runner to handle via correction-prompt retry.

  ## Configuration

      turn_strategy: :typed_structured
  """

  @behaviour Rho.TurnStrategy

  require Logger

  alias Rho.ActionSchema
  alias Rho.LLM.Admission
  alias Rho.PromptSection
  alias Rho.StructuredOutput
  alias Rho.TurnStrategy.Shared

  # --- Prompt sections ---

  @impl Rho.TurnStrategy
  def prompt_sections(tool_defs, _context) do
    [build_prompt_section(tool_defs)]
  end

  # --- Run ---

  @impl Rho.TurnStrategy
  def run(projection, runtime) do
    %{context: messages} = projection
    model = runtime.model
    emit = runtime.emit
    stream_opts = Keyword.drop(runtime.gen_opts, [:tools])

    schema = ActionSchema.build(runtime.tool_defs)

    case stream_with_retry(model, messages, stream_opts, emit, 1) do
      {:ok, text, usage} ->
        step = Map.get(projection, :step)
        emit.(%{type: :llm_usage, step: step, usage: usage, model: model})

        case ActionSchema.parse_and_dispatch(text, schema, runtime.tool_map) do
          {:respond, message, opts} ->
            if thinking = opts[:thinking] do
              emit.(%{type: :llm_text, text: thinking})
            end

            {:done, %{type: :response, text: message}}

          {:think, thought} ->
            emit.(%{type: :llm_text, text: thought})
            {:continue, build_think_step(thought)}

          {:tool, name, args, _tool_def, opts} ->
            if thinking = opts[:thinking] do
              emit.(%{type: :llm_text, text: thinking})
            end

            execute_tool(name, args, runtime.tool_map, runtime)

          {:unknown, name, _args} ->
            available = Map.keys(runtime.tool_map) |> Enum.join(", ")
            error = "Error: unknown tool '#{name}'. Available: respond, think, #{available}"
            {:continue, build_error_step(text, error)}

          {:parse_error, reason} ->
            {:parse_error, reason, text}
        end

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  # --- Tool execution ---

  defp execute_tool(name, args, tool_map, runtime) do
    tool_def = Map.fetch!(tool_map, name)
    call_id = "typed_structured_#{System.unique_integer([:positive])}"
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
        # ActionSchema already ran coercion via SchemaCoerce, so we pass
        # the args straight to the tool callback. The PluginRegistry
        # :tool_args_out stage may have mutated them, though, so we use
        # new_args from that stage.
        task =
          Task.async(fn ->
            t0 = System.monotonic_time(:millisecond)
            result = tool_def.execute.(new_args, ctx)
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

  # --- Streaming ---

  defp stream_with_retry(model, context, stream_opts, emit, attempt) do
    stream_opts = Keyword.put_new(stream_opts, :receive_timeout, 120_000)

    case Admission.with_slot(fn -> do_stream(model, context, stream_opts, emit) end) do
      {:ok, _accumulated, _usage} = ok ->
        ok

      {:error, :acquire_timeout} = err ->
        Logger.error("[typed_structured] admission timeout — no LLM slot available after 60s")

        err

      {:error, reason} ->
        maybe_retry(reason, model, context, stream_opts, emit, attempt)
    end
  end

  defp do_stream(model, context, stream_opts, emit) do
    with {:ok, stream_response} <- ReqLLM.stream_text(model, context, stream_opts),
         {:ok, accumulated} <- consume_stream(stream_response, emit),
         {:ok, usage} <- get_stream_metadata(stream_response) do
      {:ok, accumulated, usage}
    end
  end

  defp consume_stream(stream_response, emit) do
    iodata =
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce([], fn token, acc ->
        emit.(%{type: :text_delta, text: token})

        acc = [acc | token]
        text = IO.iodata_to_binary(acc)
        emit_partial(text, emit)

        acc
      end)

    {:ok, IO.iodata_to_binary(iodata)}
  rescue
    exception ->
      Logger.warning(
        "[typed_structured] stream consumption raised: #{Exception.message(exception)}"
      )

      {:error, exception}
  end

  defp emit_partial(text, emit) do
    case StructuredOutput.parse_partial(text) do
      {:ok, parsed} when is_map(parsed) ->
        emit.(%{type: :structured_partial, parsed: parsed})

      _ ->
        :ok
    end
  end

  defp maybe_retry(reason, model, context, stream_opts, emit, attempt) do
    if Shared.should_retry?(reason, attempt) do
      Logger.warning(
        "[typed_structured] stream failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
      )

      Shared.retry_backoff(attempt)
      stream_with_retry(model, context, stream_opts, emit, attempt + 1)
    else
      Logger.error(
        "[typed_structured] stream FAILED after #{attempt} attempts: #{inspect(reason)} model=#{model}"
      )

      {:error, reason}
    end
  end

  # --- Prompt section ---

  defp build_prompt_section(tool_defs) do
    schema = ActionSchema.build(tool_defs)
    schema_text = ActionSchema.render_prompt(schema)

    %PromptSection{
      key: :output_format,
      heading: "OUTPUT FORMAT — MANDATORY",
      body: """
      You MUST ALWAYS respond with a single JSON object. No exceptions, no plain text, no markdown fences.
      Your VERY FIRST character must be `{`.

      #{String.trim(schema_text)}

      Format: flat JSON with "tool" as the discriminant key.

      Examples:
        {"tool": "respond", "message": "Here is your answer."}
        {"tool": "think", "thought": "I need to reconsider..."}
        {"tool": "bash", "cmd": "ls -la", "thinking": "Check directory"}

      Rules:
      - EVERY response must be a JSON object with a "tool" field
      - The "tool" field must be exactly one of the ActionName variants above
      - Tool parameters go as top-level fields (NOT nested in "action_input")
      - "thinking" is an optional field on ANY action for brief reasoning (≤ 2 sentences)
      - Use "respond" to answer the user. Use "think" for standalone reasoning
      - String values must use valid JSON escaping: \\" for quotes, \\n for newlines
      - Never paste arrays, row data, or tool output into "thinking" — summarize instead\
      """,
      kind: :instructions,
      priority: :low
    }
  end

  # --- Step builders ---

  defp build_tool_step_from_result(name, args, result) do
    args_json = Jason.encode!(args)
    assistant_text = Jason.encode!(%{tool: name, args: args})
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

  defp build_think_step(thought) do
    %{
      type: :tool_step,
      assistant_msg: ReqLLM.Context.assistant(Jason.encode!(%{tool: "think", thought: thought})),
      tool_results: [
        ReqLLM.Context.user("[System] Thought noted. Continue with your next action.")
      ],
      tool_calls: [],
      structured_calls: [],
      response_text: nil
    }
  end

  defp build_error_step(raw_text, error_msg) do
    %{
      type: :tool_step,
      assistant_msg: ReqLLM.Context.assistant(raw_text),
      tool_results: [ReqLLM.Context.user(error_msg)],
      tool_calls: [],
      structured_calls: [],
      response_text: nil
    }
  end

  # --- Stream metadata ---

  defp get_stream_metadata(%ReqLLM.StreamResponse{metadata_handle: handle}) do
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(handle, :timer.seconds(30))

    case metadata do
      %{error: reason} -> {:error, reason}
      _ -> {:ok, metadata[:usage] || %{}}
    end
  rescue
    _ -> {:ok, %{}}
  end

  defp get_stream_metadata(stream_response) do
    usage = ReqLLM.StreamResponse.usage(stream_response) || %{}
    {:ok, usage}
  end
end
