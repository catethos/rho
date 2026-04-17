defmodule Mix.Tasks.Rho.Trace do
  @moduledoc false

  use Mix.Task

  @shortdoc "Analyze tape traces for sessions"

  @tapes_dir Path.expand("~/.rho/tapes")

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [all: :boolean, recent: :integer, after: :string],
        aliases: [a: :all, n: :recent]
      )

    case rest do
      ["summary" | tape_args] -> summary(tape_args, opts)
      ["tools" | tape_args] -> tools(tape_args, opts)
      ["costs" | tape_args] -> costs(tape_args, opts)
      ["failures" | tape_args] -> failures(tape_args, opts)
      ["cache" | tape_args] -> cache(tape_args, opts)
      _ -> usage()
    end
  end

  # -- Subcommands --

  defp summary(tape_args, opts) do
    tapes = resolve_tapes(tape_args, opts)

    header =
      String.pad_trailing("Session", 48) <>
        String.pad_leading("Turns", 6) <>
        String.pad_leading("Steps", 6) <>
        String.pad_leading("Tools", 6) <>
        String.pad_leading("Errors", 7) <>
        String.pad_leading("In", 9) <>
        String.pad_leading("Out", 9) <>
        String.pad_leading("Cache%", 7) <>
        String.pad_leading("Cost", 10)

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    Enum.each(tapes, fn {name, entries} ->
      stats = compute_stats(entries)

      cache_pct =
        if stats.input_tokens > 0,
          do: Float.round(stats.cached_tokens / stats.input_tokens * 100, 0),
          else: 0.0

      line =
        String.pad_trailing(truncate(name, 47), 48) <>
          String.pad_leading("#{stats.turns}", 6) <>
          String.pad_leading("#{stats.steps}", 6) <>
          String.pad_leading("#{stats.tool_calls}", 6) <>
          String.pad_leading("#{stats.tool_errors}", 7) <>
          String.pad_leading("#{stats.input_tokens}", 9) <>
          String.pad_leading("#{stats.output_tokens}", 9) <>
          String.pad_leading("#{trunc(cache_pct)}%", 7) <>
          String.pad_leading(format_cost(stats.total_cost), 10)

      IO.puts(line)
    end)
  end

  defp tools(tape_args, opts) do
    tapes = resolve_tapes(tape_args, opts)

    tool_stats =
      tapes
      |> Enum.flat_map(fn {_name, entries} -> entries end)
      |> Enum.filter(&(&1["kind"] == "tool_result"))
      |> Enum.group_by(& &1["payload"]["name"])
      |> Enum.map(fn {name, results} ->
        calls = length(results)
        errors = Enum.count(results, &(&1["payload"]["status"] == "error"))
        avg_latency = avg_field(results, ["payload", "latency_ms"])

        error_types =
          results
          |> Enum.map(&get_in(&1, ["payload", "error_type"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()

        %{
          name: name,
          calls: calls,
          errors: errors,
          avg_latency_ms: avg_latency,
          error_types: error_types
        }
      end)
      |> Enum.sort_by(& &1.calls, :desc)

    header =
      String.pad_trailing("Tool", 24) <>
        String.pad_leading("Calls", 7) <>
        String.pad_leading("Errors", 7) <>
        String.pad_leading("Error%", 8) <>
        String.pad_leading("Avg ms", 8) <>
        "  Error Types"

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header) + 20))

    Enum.each(tool_stats, fn t ->
      error_pct = if t.calls > 0, do: Float.round(t.errors / t.calls * 100, 1), else: 0.0

      types_str =
        Enum.map_join(t.error_types, ", ", fn {type, count} -> "#{type}(#{count})" end)

      line =
        String.pad_trailing(t.name, 24) <>
          String.pad_leading("#{t.calls}", 7) <>
          String.pad_leading("#{t.errors}", 7) <>
          String.pad_leading("#{error_pct}%", 8) <>
          String.pad_leading("#{t.avg_latency_ms}", 8) <>
          "  #{types_str}"

      IO.puts(line)
    end)
  end

  defp costs(tape_args, opts) do
    tapes = resolve_tapes(tape_args, opts)

    rows =
      tapes
      |> Enum.map(fn {name, entries} ->
        stats = compute_stats(entries)
        date = first_date(entries)

        %{
          name: name,
          date: date,
          total_cost: stats.total_cost,
          input_cost: stats.input_cost,
          output_cost: stats.output_cost,
          reasoning_cost: stats.reasoning_cost,
          turns: stats.turns
        }
      end)
      |> Enum.sort_by(& &1.date)

    header =
      String.pad_trailing("Session", 48) <>
        String.pad_leading("Turns", 6) <>
        String.pad_leading("Input$", 9) <>
        String.pad_leading("Output$", 9) <>
        String.pad_leading("Reason$", 9) <>
        String.pad_leading("Total$", 9) <>
        String.pad_leading("$/Turn", 9)

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    total_cost = 0.0

    total_cost =
      Enum.reduce(rows, total_cost, fn r, acc ->
        cost_per_turn = if r.turns > 0, do: Float.round(r.total_cost / r.turns, 4), else: 0.0

        line =
          String.pad_trailing(truncate(r.name, 47), 48) <>
            String.pad_leading("#{r.turns}", 6) <>
            String.pad_leading(format_cost(r.input_cost), 9) <>
            String.pad_leading(format_cost(r.output_cost), 9) <>
            String.pad_leading(format_cost(r.reasoning_cost), 9) <>
            String.pad_leading(format_cost(r.total_cost), 9) <>
            String.pad_leading(format_cost(cost_per_turn), 9)

        IO.puts(line)
        acc + r.total_cost
      end)

    IO.puts(String.duplicate("-", 99))
    IO.puts(String.pad_trailing("TOTAL", 48) <> String.pad_leading(format_cost(total_cost), 42))
  end

  defp failures(tape_args, opts) do
    tapes = resolve_tapes(tape_args, opts)
    Enum.each(tapes, &print_failures/1)
  end

  defp print_failures({name, entries}) do
    tool_errors =
      Enum.filter(entries, &(&1["kind"] == "tool_result" && &1["payload"]["status"] == "error"))

    max_steps = Enum.filter(entries, &max_steps_error?/1)
    retries = detect_retries(entries)

    if tool_errors != [] or max_steps != [] or retries != [] do
      IO.puts("\n#{IO.ANSI.yellow()}#{name}#{IO.ANSI.reset()}")
      Enum.each(tool_errors, &print_tool_error/1)
      Enum.each(max_steps, &print_max_steps/1)
      Enum.each(retries, &print_retry/1)
    end
  end

  defp max_steps_error?(e) do
    e["kind"] == "event" && e["payload"]["name"] == "error" &&
      is_binary(e["payload"]["reason"]) &&
      String.contains?(e["payload"]["reason"], "max steps")
  end

  defp print_tool_error(e) do
    p = e["payload"]
    error_type = p["error_type"] || "unknown"

    IO.puts(
      "  #{IO.ANSI.red()}[tool_error]#{IO.ANSI.reset()} #{p["name"]} (#{error_type}): #{truncate(p["output"] || "", 80)}"
    )
  end

  defp print_max_steps(e) do
    IO.puts(
      "  #{IO.ANSI.red()}[max_steps]#{IO.ANSI.reset()} #{truncate(e["payload"]["reason"], 80)}"
    )
  end

  defp print_retry({tool_name, count}) do
    IO.puts(
      "  #{IO.ANSI.yellow()}[retry]#{IO.ANSI.reset()} #{tool_name} called #{count}x consecutively"
    )
  end

  defp cache(tape_args, opts) do
    tapes = resolve_tapes(tape_args, opts)
    Enum.each(tapes, &print_cache_report/1)
  end

  defp print_cache_report({name, entries}) do
    usage_events =
      Enum.filter(entries, fn e ->
        e["kind"] == "event" && e["payload"]["name"] == "llm_usage"
      end)

    if usage_events != [], do: print_cache_details(name, usage_events)
  end

  defp print_cache_details(name, usage_events) do
    IO.puts("\n#{name}")

    header =
      String.pad_leading("Turn", 5) <>
        String.pad_leading("Input", 8) <>
        String.pad_leading("Cached", 8) <>
        String.pad_leading("Cache%", 8) <>
        String.pad_leading("CacheWr", 8) <>
        String.pad_leading("Output", 8) <>
        String.pad_leading("Cost", 11) <>
        String.pad_leading("NoCacheCst", 11)

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    {total_cost, total_no_cache, total_input, total_cached, total_output} =
      usage_events
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, 0.0, 0, 0, 0}, &cache_turn_reducer/2)

    IO.puts(String.duplicate("-", String.length(header)))

    total_cache_pct =
      if total_input > 0,
        do: Float.round(total_cached / total_input * 100, 1),
        else: 0.0

    total_line =
      String.pad_leading("Total", 5) <>
        String.pad_leading("#{total_input}", 8) <>
        String.pad_leading("#{total_cached}", 8) <>
        String.pad_leading("#{total_cache_pct}%", 8) <>
        String.pad_leading("", 8) <>
        String.pad_leading("#{total_output}", 8) <>
        String.pad_leading(format_cost(total_cost), 11) <>
        String.pad_leading(format_cost(total_no_cache), 11)

    IO.puts(total_line)

    savings = total_no_cache - total_cost

    savings_pct =
      if total_no_cache > 0, do: Float.round(savings / total_no_cache * 100, 1), else: 0.0

    IO.puts("")
    IO.puts("  Actual cost:          #{format_cost(total_cost)}")
    IO.puts("  Cost without caching: #{format_cost(total_no_cache)}")
    IO.puts("  Savings:              #{format_cost(savings)} (#{savings_pct}%)")
  end

  defp cache_turn_reducer({e, i}, {tc, tnc, ti, tca, to}) do
    p = e["payload"]
    inp = safe_int(p["input_tokens"])
    cached = safe_int(p["cached_tokens"])
    cache_wr = safe_int(p["cache_creation_tokens"])
    out = safe_int(p["output_tokens"])
    cost = safe_float(p["total_cost"])

    cost_no_cache = estimate_uncached_cost(inp, out, p["model"])
    cache_pct = if inp > 0, do: Float.round(cached / inp * 100, 1), else: 0.0

    line =
      String.pad_leading("#{i}", 5) <>
        String.pad_leading("#{inp}", 8) <>
        String.pad_leading("#{cached}", 8) <>
        String.pad_leading("#{cache_pct}%", 8) <>
        String.pad_leading("#{cache_wr}", 8) <>
        String.pad_leading("#{out}", 8) <>
        String.pad_leading(format_cost(cost), 11) <>
        String.pad_leading(format_cost(cost_no_cache), 11)

    IO.puts(line)
    {tc + cost, tnc + cost_no_cache, ti + inp, tca + cached, to + out}
  end

  defp estimate_uncached_cost(input_tokens, output_tokens, model_spec) do
    case LLMDB.model(model_spec) do
      {:ok, model} ->
        input_rate = (model.cost[:input] || 1.0) / 1_000_000
        output_rate = (model.cost[:output] || 5.0) / 1_000_000
        input_tokens * input_rate + output_tokens * output_rate

      {:error, _} ->
        # Fallback if model not found in LLMDB
        input_tokens * 1.0e-6 + output_tokens * 5.0e-6
    end
  end

  # -- Tape loading --

  defp resolve_tapes(tape_args, opts) do
    cond do
      tape_args != [] ->
        Enum.map(tape_args, fn name -> {name, load_tape(name)} end)

      opts[:all] ->
        list_all_tapes()
        |> Enum.map(fn name -> {name, load_tape(name)} end)

      true ->
        n = opts[:recent] || 10

        list_all_tapes()
        |> Enum.map(fn name -> {name, tape_mtime(name)} end)
        |> Enum.sort_by(fn {_, mtime} -> mtime end, :desc)
        |> Enum.take(n)
        |> Enum.map(fn {name, _mtime} -> {name, load_tape(name)} end)
    end
  end

  defp tape_mtime(name) do
    path = Rho.Tape.Store.path_for(name)

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end

  defp list_all_tapes do
    case File.ls(@tapes_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn f ->
          f
          |> String.trim_trailing(".jsonl")
          |> String.replace("%2F", "/")
          |> String.replace("%25", "%")
        end)

      {:error, _} ->
        []
    end
  end

  defp load_tape(name) do
    path = Rho.Tape.Store.path_for(name)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.flat_map(&decode_tape_line/1)
    else
      []
    end
  end

  defp decode_tape_line(line) do
    case Jason.decode(line) do
      {:ok, entry} -> [entry]
      {:error, _} -> []
    end
  end

  # -- Stats computation --

  defp compute_stats(entries) do
    turns =
      Enum.count(entries, fn e ->
        e["kind"] == "message" && e["payload"]["role"] == "user"
      end)

    usage_events =
      Enum.filter(entries, fn e ->
        e["kind"] == "event" && e["payload"]["name"] == "llm_usage"
      end)

    steps = length(usage_events)

    tool_results = Enum.filter(entries, &(&1["kind"] == "tool_result"))
    tool_calls = length(tool_results)
    tool_errors = Enum.count(tool_results, &(&1["payload"]["status"] == "error"))

    compactions =
      Enum.count(entries, fn e ->
        e["kind"] == "event" && e["payload"]["name"] == "compact"
      end)

    # Aggregate token/cost from usage events
    token_init = %{
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      cached_tokens: 0,
      cache_creation_tokens: 0,
      total_cost: 0.0,
      input_cost: 0.0,
      output_cost: 0.0,
      reasoning_cost: 0.0
    }

    token_stats =
      Enum.reduce(usage_events, token_init, fn e, acc ->
        p = e["payload"]

        %{
          acc
          | input_tokens: acc.input_tokens + safe_int(p["input_tokens"]),
            output_tokens: acc.output_tokens + safe_int(p["output_tokens"]),
            reasoning_tokens: acc.reasoning_tokens + safe_int(p["reasoning_tokens"]),
            cached_tokens: acc.cached_tokens + safe_int(p["cached_tokens"]),
            cache_creation_tokens:
              acc.cache_creation_tokens + safe_int(p["cache_creation_tokens"]),
            total_cost: acc.total_cost + safe_float(p["total_cost"]),
            input_cost: acc.input_cost + safe_float(p["input_cost"]),
            output_cost: acc.output_cost + safe_float(p["output_cost"]),
            reasoning_cost: acc.reasoning_cost + safe_float(p["reasoning_cost"])
        }
      end)

    Map.merge(token_stats, %{
      turns: turns,
      steps: steps,
      tool_calls: tool_calls,
      tool_errors: tool_errors,
      compactions: compactions
    })
  end

  # -- Retry detection --

  defp detect_retries(entries) do
    entries
    |> Enum.filter(&(&1["kind"] == "tool_call"))
    |> Enum.chunk_by(& &1["payload"]["name"])
    |> Enum.filter(&(length(&1) >= 3))
    |> Enum.map(fn chunk ->
      {hd(chunk)["payload"]["name"], length(chunk)}
    end)
  end

  # -- Helpers --

  defp first_date([]), do: ""
  defp first_date([first | _]), do: first["date"] || ""

  defp avg_field(entries, path) do
    values = Enum.map(entries, &get_in(&1, path)) |> Enum.reject(&is_nil/1)
    if values == [], do: 0, else: trunc(Enum.sum(values) / length(values))
  end

  defp safe_int(nil), do: 0
  defp safe_int(n) when is_number(n), do: trunc(n)
  defp safe_int(_), do: 0

  defp safe_float(nil), do: 0.0
  defp safe_float(n) when is_number(n), do: n / 1
  defp safe_float(_), do: 0.0

  defp format_cost(n) when is_number(n), do: "$#{Float.round(n / 1, 4)}"
  defp format_cost(_), do: "$0.0"

  defp truncate(str, max) do
    if String.length(str) > max, do: String.slice(str, 0, max - 2) <> "..", else: str
  end

  defp usage do
    IO.puts("""
    Usage: mix rho.trace <command> [tape_name] [options]

    Commands:
      summary   Session overview: turns, steps, tools, tokens, cost
      tools     Per-tool breakdown: call count, errors, latency
      costs     Cost reporting per session with totals
      failures  Tool errors, max-steps hits, retry patterns
      cache     Per-turn cache analysis with cost savings

    Options:
      --all, -a        Analyze all tapes
      --recent N, -n N Show N most recent tapes (default: 10)

    Examples:
      mix rho.trace summary --recent 5
      mix rho.trace tools --all
      mix rho.trace costs session_abc123_def456
      mix rho.trace failures --recent 20
    """)
  end
end
