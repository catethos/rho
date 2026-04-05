defmodule Mix.Tasks.Rho.ReasonerReport do
  use Mix.Task

  @shortdoc "Compute reasoner metrics from a session's events.jsonl"

  @moduledoc """
  Ingests a session's `events.jsonl` and emits reasoner comparison
  metrics. Originally built for the Phase 1 tagged-vs-structured
  comparison; `:tagged` was removed post-live-eval, but the post-hoc
  metrics remain useful for any reasoner.

  ## Usage

      mix rho.reasoner_report <session_id>
      mix rho.reasoner_report --file <path/to/events.jsonl>
      mix rho.reasoner_report --attach <session_id>     # live telemetry capture

  ## Post-hoc metrics (extracted from events.jsonl)

    * Assistant turns + total output tokens (avg tokens/turn)
    * Outer-envelope double-escape count — assistant messages where the
      top-level JSON has an `action_input` string containing `\\"`
    * Heuristic hits — count of messages that would trigger a
      structured-reasoner recovery heuristic (`detect_implicit_tool`, `_raw`
      wrapper, `lang_to_tool`, markdown fallback, etc.)
    * Reprompt count — assistant turns that produced no tool call / no
      structured call (approximated by absence of a `tool_start` immediately
      following an `llm_text`)
    * Task completion — whether the session called `finish` or `end_turn`

  ## Live-only metrics (require --attach during the live run)

    * `[:rho, :parse, :lenient, :parse]` — partial-parse CPU overhead

  In `--attach` mode this task stays in the foreground aggregating that
  telemetry event and appending each occurrence to
  `_rho/sessions/<session_id>/reasoner_telemetry.jsonl`. Press Ctrl-C to
  stop and print the aggregate. Note: `:telemetry.attach` is node-local,
  so this captures nothing when the live run is in a separate BEAM
  (e.g. `mix phx.server` in another terminal).
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [file: :string, attach: :boolean, workspace: :string]
      )

    cond do
      opts[:attach] ->
        session_id = List.first(rest) || Mix.raise("--attach requires a session_id")
        attach_loop(session_id, workspace(opts))

      opts[:file] ->
        analyze_file(opts[:file])

      session_id = List.first(rest) ->
        path = Path.join([workspace(opts), "_rho", "sessions", session_id, "events.jsonl"])
        analyze_file(path)

      true ->
        Mix.shell().error("Usage: mix rho.reasoner_report <session_id> [--file path]")
        exit({:shutdown, 1})
    end
  end

  defp workspace(opts), do: opts[:workspace] || File.cwd!()

  # ---- post-hoc analysis ----

  defp analyze_file(path) do
    unless File.exists?(path) do
      Mix.shell().error("No events file at #{path}")
      exit({:shutdown, 1})
    end

    events =
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Enum.to_list()

    metrics = compute_metrics(events)
    print_report(path, metrics)
  end

  defp compute_metrics(events) do
    # Each event has an inner `data.type` that identifies the canonical event;
    # the outer `type` is the fully-qualified bus topic. Dispatch on data.type.
    assistant_texts =
      for e <- events, (e["data"] || %{})["type"] == "llm_text", do: e["data"]["text"] || ""

    usage_events =
      for e <- events, (e["data"] || %{})["type"] == "llm_usage", do: e["data"]

    tool_starts =
      for e <- events, (e["data"] || %{})["type"] == "tool_start", do: e["data"]

    turn_starts = Enum.count(events, fn e -> (e["data"] || %{})["type"] == "turn_started" end)

    output_tokens =
      usage_events
      |> Enum.map(fn d ->
        get_in(d, ["usage", "output_tokens"]) || get_in(d, ["usage", "output"]) || 0
      end)
      |> Enum.sum()

    assistant_turns = length(assistant_texts)

    double_escape_count =
      assistant_texts
      |> Enum.map(&count_outer_envelope_escapes/1)
      |> Enum.sum()

    heuristic_hits_list =
      Enum.map(assistant_texts, &count_heuristic_hits/1)

    heuristic_hits_total = Enum.sum(heuristic_hits_list)

    # reprompt count: assistant turns that produced no subsequent tool_start
    # in the same turn (rough approximation, good enough for a one-shot report)
    reprompt_count = count_reprompts(events)

    tool_names = Enum.map(tool_starts, & &1["name"])
    finished? = "finish" in tool_names or "end_turn" in tool_names

    %{
      assistant_turns: assistant_turns,
      output_tokens: output_tokens,
      tokens_per_turn:
        if(assistant_turns > 0, do: Float.round(output_tokens / assistant_turns, 2), else: 0.0),
      double_escape_count: double_escape_count,
      heuristic_hits: heuristic_hits_total,
      reprompt_count: reprompt_count,
      turn_starts: turn_starts,
      tool_calls: length(tool_starts),
      completed?: finished?,
      completion_tool: Enum.find(tool_names, &(&1 in ["finish", "end_turn"]))
    }
  end

  # counts `\"` within a string action_input of the top-level JSON envelope
  defp count_outer_envelope_escapes(text) do
    case Rho.Parse.Lenient.parse(text) do
      {:ok, %{} = parsed} ->
        case parsed["action_input"] || parsed["tool_input"] || parsed["parameters"] do
          s when is_binary(s) ->
            # `\"` in the decoded string corresponds to `\\"` in the raw JSON
            count = s |> String.graphemes() |> Enum.count(&(&1 == "\""))
            count

          _ ->
            0
        end

      _ ->
        0
    end
  end

  # mirrors Rho.Test.ReasonerHarness.structured_heuristics/2 (tool_map-free
  # — we can't know the real tool list post-hoc, so we count hits that don't
  # depend on tool names)
  defp count_heuristic_hits(text) do
    # Skip plain-prose assistant messages (sessions using the :direct reasoner
    # emit free text alongside native tool_calls — those aren't envelopes and
    # shouldn't be counted as recovery hits).
    if not envelope_candidate?(text) do
      0
    else
      do_count_heuristic_hits(text)
    end
  end

  defp envelope_candidate?(text) do
    trimmed = text |> Rho.Parse.Lenient.strip_fences() |> String.trim_leading()
    String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")
  end

  defp do_count_heuristic_hits(text) do
    stripped = Rho.Parse.Lenient.strip_fences(text)

    case Jason.decode(stripped) do
      {:ok, list} when is_list(list) ->
        1

      {:ok, %{} = parsed} ->
        args_raw =
          parsed["action_input"] || parsed["tool_input"] || parsed["parameters"] ||
            parsed["args"] || parsed["input"]

        hits = 0

        hits =
          case args_raw do
            s when is_binary(s) ->
              case Jason.decode(s) do
                {:ok, m} when is_map(m) -> hits
                _ -> hits + 1
              end

            _ ->
              hits
          end

        action = parsed["action"] || parsed["tool"] || parsed["tool_name"] || parsed["name"]
        if is_binary(action), do: hits, else: hits + 1

      {:ok, _} ->
        1

      {:error, _} ->
        trimmed = String.trim_leading(text)

        cond do
          Regex.match?(~r/```(\w+)\s*\n/s, text) -> 1
          String.starts_with?(trimmed, "{") -> 2
          true -> 1
        end
    end
  end

  # Count assistant turns with no following tool_start before the next
  # before_llm / turn boundary.
  defp count_reprompts(events) do
    events
    |> Enum.reduce({0, :idle}, fn e, {count, state} ->
      case {(e["data"] || %{})["type"], state} do
        {"llm_text", _} -> {count, :expecting_tool}
        {"tool_start", :expecting_tool} -> {count, :idle}
        {"turn_started", :expecting_tool} -> {count + 1, :idle}
        {"before_llm", :expecting_tool} -> {count + 1, :idle}
        _ -> {count, state}
      end
    end)
    |> elem(0)
  end

  defp print_report(path, m) do
    Mix.shell().info("""

    Reasoner report — #{path}

      Assistant turns          : #{m.assistant_turns}
      Turn starts              : #{m.turn_starts}
      Tool calls               : #{m.tool_calls}
      Total output tokens      : #{m.output_tokens}
      Avg tokens/assistant turn: #{m.tokens_per_turn}

      Double-escaped \\" in outer action_input: #{m.double_escape_count}
      Heuristic hits (structured-style)       : #{m.heuristic_hits}
      Reprompt count (approx)                 : #{m.reprompt_count}

      Completion               : #{if m.completed?, do: "YES (#{m.completion_tool})", else: "no"}

    Live-only metrics (re-run with --attach to capture):
      [:rho, :parse, :lenient, :parse]        : partial-parse CPU overhead
    """)
  end

  # ---- --attach mode ----

  defp attach_loop(session_id, workspace) do
    out_dir = Path.join([workspace, "_rho", "sessions", session_id])
    File.mkdir_p!(out_dir)
    out_path = Path.join(out_dir, "reasoner_telemetry.jsonl")

    table = :ets.new(:reasoner_report_acc, [:set, :public])
    :ets.insert(table, {:parse_duration_us, 0})
    :ets.insert(table, {:parse_bytes, 0})
    :ets.insert(table, {:parse_calls, 0})

    {:ok, file} = File.open(out_path, [:append, :utf8])

    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      [
        [:rho, :parse, :lenient, :parse]
      ],
      &handle_event/4,
      %{table: table, file: file}
    )

    Mix.shell().info("""
    Attached telemetry handlers. Writing to #{out_path}
    Start your live run now in another terminal. Press Ctrl-C twice to stop.
    """)

    Process.flag(:trap_exit, true)
    wait_loop(table, file, handler_id)
  end

  defp wait_loop(table, file, handler_id) do
    receive do
      _ -> wait_loop(table, file, handler_id)
    after
      5_000 ->
        print_attach_snapshot(table)
        wait_loop(table, file, handler_id)
    end
  end

  defp handle_event([:rho, :parse, :lenient, :parse], measurements, _meta, %{
         table: table,
         file: file
       }) do
    dur = Map.get(measurements, :duration_us, 0)
    bytes = Map.get(measurements, :bytes, 0)
    :ets.update_counter(table, :parse_duration_us, dur)
    :ets.update_counter(table, :parse_bytes, bytes)
    :ets.update_counter(table, :parse_calls, 1)

    IO.write(
      file,
      Jason.encode!(%{event: "parse", duration_us: dur, bytes: bytes, ts: timestamp()}) <> "\n"
    )
  end

  defp print_attach_snapshot(table) do
    [{:parse_duration_us, dur}] = :ets.lookup(table, :parse_duration_us)
    [{:parse_calls, calls}] = :ets.lookup(table, :parse_calls)

    Mix.shell().info("[reasoner_report] parse calls=#{calls} total_us=#{dur}")
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
