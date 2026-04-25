defmodule Rho.TurnStrategy.TypedStructured do
  @moduledoc """
  Typed structured-output strategy using `Rho.ActionSchema`.

  Describes tools in the prompt and asks the LLM to produce a flat JSON
  response with `"tool"` as discriminant. Parsing is handled by
  `ActionSchema.parse_and_dispatch/3` — a tagged union dispatcher with
  schema-guided coercion.

  Returns intent tuples — the Runner handles tool execution via
  `Rho.ToolExecutor` and step recording.

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
    visible = Enum.reject(tool_defs, & &1[:deferred])
    [build_prompt_section(visible)]
  end

  # --- Run: call LLM and classify response as intent ---

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

        classify_action(text, schema, runtime)

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  defp classify_action(text, schema, runtime) do
    emit = runtime.emit

    case ActionSchema.parse_and_dispatch(text, schema, runtime.tool_map) do
      {:respond, message, opts} ->
        maybe_emit_thinking(opts, emit)
        {:respond, message}

      {:think, thought} ->
        {:think, thought}

      {:tool, name, args, _tool_def, opts} ->
        maybe_emit_thinking(opts, emit)
        call_id = "typed_structured_#{System.unique_integer([:positive])}"

        {:call_tools, [%{name: name, args: args, call_id: call_id}], nil}

      {:unknown, name, _args} ->
        available = Map.keys(runtime.tool_map) |> Enum.join(", ")
        reason = "unknown tool '#{name}'. Available: respond, think, #{available}"
        {:parse_error, reason, text}

      {:parse_error, _reason} ->
        # Treat unparseable text as a plain respond — avoids costly
        # correction-prompt retries. The LLM was trying to talk to
        # the user, just not in JSON format.
        {:respond, String.trim(text)}
    end
  end

  # --- Build step entries from tool results ---

  @impl Rho.TurnStrategy
  def build_tool_step(tool_calls, results, _response_text) do
    [tc] = tool_calls
    [r] = results

    args_json = Jason.encode!(tc.args)
    assistant_text = Jason.encode!(%{tool: tc.name, args: tc.args})
    result_text = "[Tool Result: #{tc.name}]\n#{r.result}"

    %{
      type: :tool_step,
      assistant_msg: ReqLLM.Context.assistant(assistant_text),
      tool_results: [ReqLLM.Context.user(result_text)],
      tool_calls: [],
      structured_calls: [{tc.name, args_json}],
      response_text: nil
    }
  end

  @impl Rho.TurnStrategy
  def build_think_step(thought) do
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
    Logger.info("[typed_structured] starting stream model=#{model}")
    t0 = System.monotonic_time(:millisecond)

    with {:ok, stream_response} <- ReqLLM.stream_text(model, context, stream_opts),
         _ =
           Logger.info(
             "[typed_structured] stream opened in #{System.monotonic_time(:millisecond) - t0}ms"
           ),
         {:ok, accumulated} <- consume_stream(stream_response, emit),
         _ =
           Logger.info(
             "[typed_structured] stream consumed in #{System.monotonic_time(:millisecond) - t0}ms (#{byte_size(accumulated)} bytes)"
           ),
         {:ok, usage} <- get_stream_metadata(stream_response) do
      Logger.info(
        "[typed_structured] stream complete in #{System.monotonic_time(:millisecond) - t0}ms"
      )

      {:ok, accumulated, usage}
    else
      error ->
        Logger.warning(
          "[typed_structured] stream failed in #{System.monotonic_time(:millisecond) - t0}ms: #{inspect(error)}"
        )

        error
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
      heading: "OUTPUT FORMAT",
      body: """
      Always respond with a single JSON object. First character must be `{`.

      #{String.trim(schema_text)}

      Example: {"tool": "respond", "message": "Hello!"}\
      """,
      kind: :instructions,
      priority: :low
    }
  end

  defp maybe_emit_thinking(opts, emit) do
    if thinking = opts[:thinking] do
      emit.(%{type: :llm_text, text: thinking})
    end
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
