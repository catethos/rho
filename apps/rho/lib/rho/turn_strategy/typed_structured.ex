defmodule Rho.TurnStrategy.TypedStructured do
  @moduledoc """
  Typed structured-output strategy using BAML for parsing.

  Generates a dynamic `.baml` schema from tool_defs via
  `RhoBaml.SchemaWriter`, then calls `BamlElixir.Client.sync_stream`
  to get a parsed map. Dispatch is handled by
  `ActionSchema.dispatch_parsed/3` — a tagged union dispatcher with
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
  alias Rho.TurnStrategy.Shared

  # --- Prompt sections ---

  # No prompt_sections needed — BAML's {{ ctx.output_format }} handles
  # format injection, and SchemaWriter includes tool descriptions in
  # the Action class @description. Returning [] avoids duplicating the
  # format spec in both the system prompt and the BAML template.
  @impl Rho.TurnStrategy
  def prompt_sections(_tool_defs, _context), do: []

  # --- Run: call LLM via BAML and classify response as intent ---

  @impl Rho.TurnStrategy
  def run(projection, runtime) do
    %{context: messages} = projection
    emit = runtime.emit
    step = Map.get(projection, :step)

    schema = ActionSchema.build(runtime.tool_defs)
    baml_path = RhoBaml.baml_path(:rho)

    # Write dynamic action schema + client config to disk
    write_opts = [model: runtime.model]
    RhoBaml.SchemaWriter.write!(baml_path, runtime.tool_defs, write_opts)

    # Serialize conversation messages for BAML prompt
    messages_text = serialize_messages(messages)

    collector = BamlElixir.Collector.new("turn_#{step || 0}")

    case call_with_retry(baml_path, messages_text, emit, collector, 1) do
      {:ok, parsed} ->
        usage = extract_usage(collector)
        emit.(%{type: :llm_usage, step: step, usage: usage, model: runtime.model})
        classify_action(parsed, schema, runtime)

      {:error, reason} ->
        emit.(%{type: :error, reason: reason})
        {:error, inspect(reason)}
    end
  end

  defp classify_action(parsed, schema, runtime) do
    emit = runtime.emit

    case ActionSchema.dispatch_parsed(parsed, schema, runtime.tool_map) do
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
        {:parse_error, reason, Jason.encode!(parsed)}

      {:parse_error, _reason} ->
        # Treat unparseable response as a plain respond — avoids costly
        # correction-prompt retries.
        message = parsed[:message] || parsed["message"] || inspect(parsed)
        {:respond, String.trim(to_string(message))}
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

  # --- BAML streaming ---

  defp call_with_retry(baml_path, messages_text, emit, collector, attempt) do
    case Admission.with_slot(fn -> do_baml_call(baml_path, messages_text, emit, collector) end) do
      {:ok, _parsed} = ok ->
        ok

      {:error, :acquire_timeout} = err ->
        Logger.error("[typed_structured] admission timeout — no LLM slot available after 60s")
        err

      {:error, reason} ->
        maybe_retry_baml(reason, baml_path, messages_text, emit, collector, attempt)
    end
  end

  defp do_baml_call(baml_path, messages_text, emit, collector) do
    Logger.info("[typed_structured] starting BAML stream")
    t0 = System.monotonic_time(:millisecond)

    callback = fn partial ->
      cleaned = clean_baml_result(partial)
      text = Jason.encode!(cleaned)
      emit.(%{type: :structured_partial, parsed: cleaned, text: text})
    end

    call_opts = %{path: baml_path, parse: false, collectors: [collector]}

    case BamlElixir.Client.sync_stream(
           "AgentTurn",
           %{messages: messages_text},
           callback,
           call_opts
         ) do
      {:ok, result} ->
        Logger.info(
          "[typed_structured] BAML stream complete in #{System.monotonic_time(:millisecond) - t0}ms"
        )

        {:ok, clean_baml_result(result)}

      {:error, reason} ->
        Logger.warning(
          "[typed_structured] BAML stream failed in #{System.monotonic_time(:millisecond) - t0}ms: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_retry_baml(reason, baml_path, messages_text, emit, collector, attempt) do
    if Shared.should_retry?(reason, attempt) do
      Logger.warning(
        "[typed_structured] BAML call failed (attempt #{attempt}): #{inspect(reason)}, retrying..."
      )

      Shared.retry_backoff(attempt)
      call_with_retry(baml_path, messages_text, emit, collector, attempt + 1)
    else
      Logger.error(
        "[typed_structured] BAML call FAILED after #{attempt} attempts: #{inspect(reason)}"
      )

      {:error, reason}
    end
  end

  # --- Message serialization ---

  defp serialize_messages(messages) do
    Enum.map_join(messages, "\n\n", &serialize_message/1)
  end

  defp serialize_message(%{role: role, content: content}) when is_list(content) do
    text =
      content
      |> Enum.filter(fn part -> part.type == :text end)
      |> Enum.map_join("\n", fn part -> part.text end)

    role_label = role |> to_string() |> String.capitalize()
    "#{role_label}: #{text}"
  end

  defp serialize_message(%{role: role, content: content}) when is_binary(content) do
    role_label = role |> to_string() |> String.capitalize()
    "#{role_label}: #{content}"
  end

  # --- BAML result cleanup ---

  defp clean_baml_result(result) when is_map(result) do
    result
    |> Map.drop([:__baml_class__])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> normalize_keys()
  end

  defp clean_baml_result(other), do: other

  # BAML returns atom keys — ActionSchema.dispatch expects string keys
  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # --- Usage extraction ---

  defp extract_usage(collector) do
    case BamlElixir.Collector.usage(collector) do
      %{} = usage -> usage
      {input, output} -> %{input_tokens: input, output_tokens: output}
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp maybe_emit_thinking(opts, emit) do
    if thinking = opts[:thinking] do
      emit.(%{type: :llm_text, text: thinking})
    end
  end
end
