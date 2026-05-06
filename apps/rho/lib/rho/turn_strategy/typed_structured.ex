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

    # Serialize conversation messages for BAML prompt. The volatile
    # portion of the system prompt is hoisted to the end of the text so
    # the stable preamble + conversation tail can be a long byte-identical
    # prefix across user turns — required for upstream automatic prefix
    # caching (OpenAI / Anthropic-via-OpenRouter).
    messages_text = serialize_messages(messages, runtime)

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

        # If the LLM emitted free-text that BAML couldn't fit into any
        # action variant, recover the raw text from the collector and
        # surface it as a `:respond` so the user sees the message instead
        # of a parse-error stack trace.
        recover_parse_failure(reason, collector)
    end
  end

  defp recover_parse_failure(reason, collector) do
    if parse_failure?(reason) do
      case extract_llm_text(collector) do
        text when is_binary(text) and byte_size(text) > 0 ->
          Logger.info(
            "[typed_structured] BAML parse failed; recovering as :respond (#{byte_size(text)} chars)"
          )

          {:ok, %{"tool" => "respond", "message" => text}}

        _ ->
          {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp parse_failure?(reason) when is_binary(reason) do
    String.contains?(reason, "Failed to find any") or
      String.contains?(reason, "Missing required field") or
      String.contains?(reason, "Failed to coerce")
  end

  defp parse_failure?(_), do: false

  # `BamlElixir.Collector.last_function_log/1` returns the raw LLM stream
  # log. The exact shape is NIF-controlled and may vary by version, so
  # walk the structure, skip known meta fields (function_name, model id,
  # etc. — short identifiers we'd never want as the user-visible message),
  # and pick the longest remaining string. LLM prose is long; identifiers
  # are short, so longest-wins is a reliable heuristic across log shapes.
  @meta_keys ~w(function_name name model client_name client_id provider tag id)a
  @meta_key_strings Enum.map(@meta_keys, &Atom.to_string/1)

  defp extract_llm_text(collector) do
    log = BamlElixir.Collector.last_function_log(collector)

    Logger.debug(fn ->
      "[typed_structured] last_function_log shape=#{inspect(log, limit: 5, printable_limit: 200)}"
    end)

    case longest_string(log) do
      text when is_binary(text) and byte_size(text) > 0 -> text
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("[typed_structured] extract_llm_text raised: #{inspect(e)}")
      nil
  end

  defp longest_string(value), do: collect_strings(value, []) |> pick_longest()

  defp collect_strings(value, acc) when is_binary(value) do
    if value == "", do: acc, else: [value | acc]
  end

  defp collect_strings(%_{} = struct, acc) do
    struct |> Map.from_struct() |> collect_strings(acc)
  end

  defp collect_strings(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, acc ->
      if meta_key?(k), do: acc, else: collect_strings(v, acc)
    end)
  end

  defp collect_strings(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_strings/2)
  end

  defp collect_strings({_, v}, acc), do: collect_strings(v, acc)
  defp collect_strings(_, acc), do: acc

  defp meta_key?(k) when is_atom(k), do: k in @meta_keys
  defp meta_key?(k) when is_binary(k), do: k in @meta_key_strings
  defp meta_key?(_), do: false

  defp pick_longest([]), do: nil

  defp pick_longest(strings) do
    Enum.max_by(strings, &byte_size/1)
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

  # Public for testing — see Rho.TurnStrategy.TypedStructuredTest.
  @doc false
  def serialize_messages(messages, runtime) do
    {system_msgs, tail} = Enum.split_with(messages, &system_role?/1)

    stable_text = runtime.system_prompt_stable || ""
    volatile_text = runtime.system_prompt_volatile || ""

    # When the runtime didn't pre-split the prompt (e.g. test harness),
    # fall back to whatever the system message carried so we don't lose
    # context. In that case there's no volatile tail to hoist.
    stable_text =
      if stable_text == "",
        do: extract_system_text(system_msgs),
        else: stable_text

    parts = [
      prepend_role("system", stable_text),
      Enum.map_join(tail, "\n\n", &serialize_message/1),
      prepend_role("system", volatile_text)
    ]

    parts
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp system_role?(%{role: :system}), do: true
  defp system_role?(%{role: "system"}), do: true
  defp system_role?(_), do: false

  defp extract_system_text(system_msgs) do
    system_msgs
    |> Enum.map_join("\n\n", fn %{content: content} -> content_text(content) end)
  end

  defp content_text(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> part.type == :text end)
    |> Enum.map_join("\n", fn part -> part.text end)
  end

  defp content_text(content) when is_binary(content), do: content

  defp prepend_role(_role, ""), do: ""
  defp prepend_role(role, text), do: "#{String.capitalize(role)}: #{text}"

  defp serialize_message(%{role: role, content: content}) when is_list(content) do
    role_label = role |> to_string() |> String.capitalize()
    "#{role_label}: #{content_text(content)}"
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
