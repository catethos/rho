defmodule Rho.Trace.Bundle do
  @moduledoc """
  Writes portable debug bundles for conversation tapes.
  """

  alias Rho.Tape.Entry
  alias Rho.Trace.Projection

  @doc "Resolve `ref` and write a debug bundle directory."
  @spec write(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(ref, opts \\ []) when is_binary(ref) do
    with {:ok, resolved} <- Rho.Conversation.Ref.resolve(ref) do
      write_resolved(resolved, opts)
    end
  end

  @doc "Write a debug bundle from an already resolved reference map."
  @spec write_resolved(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write_resolved(%{tape_name: tape_name} = resolved, opts \\ []) when is_binary(tape_name) do
    out_dir = Keyword.get(opts, :out) || default_out_dir()
    last = Keyword.get(opts, :last)
    File.mkdir_p!(out_dir)

    entries = Projection.entries(tape_name, last: last)
    context = Projection.context(tape_name)
    chat = Projection.chat(tape_name, last: last)
    debug = Projection.debug(tape_name, last: last)
    failures = Rho.Trace.Analyzer.findings(entries)
    costs = Projection.costs(tape_name, last: last)
    summary = summary(resolved, entries, failures, costs)

    write_json(Path.join(out_dir, "summary.json"), summary)
    write_tape(Path.join(out_dir, "tape.jsonl"), entries)
    write_events(Path.join(out_dir, "events.jsonl"), resolved[:event_log_path])
    File.write!(Path.join(out_dir, "chat.md"), render_chat(chat))
    File.write!(Path.join(out_dir, "context.md"), render_context(context))
    File.write!(Path.join(out_dir, "debug-timeline.md"), render_debug(debug))
    File.write!(Path.join(out_dir, "failures.md"), render_failures(failures))
    File.write!(Path.join(out_dir, "costs.md"), render_costs(costs))
    File.write!(Path.join(out_dir, "README.md"), readme(resolved))

    {:ok, Map.put(summary, "out_dir", out_dir)}
  rescue
    error -> {:error, error}
  end

  defp summary(resolved, entries, failures, costs) do
    anchors = Enum.filter(entries, &(&1.kind == :anchor))
    latest_anchor = List.last(anchors)

    %{
      "conversation_id" => resolved[:conversation_id],
      "session_id" => resolved[:session_id],
      "thread_id" => resolved[:thread_id],
      "tape_name" => resolved[:tape_name],
      "event_log_path" => resolved[:event_log_path],
      "entry_count" => length(entries),
      "anchor_count" => length(anchors),
      "latest_anchor" => anchor_summary(latest_anchor),
      "model_names_seen" => model_names(entries),
      "tool_names_seen" => tool_names(entries),
      "total_cost" => get_in(costs, [:totals, :total_cost]) || 0.0,
      "failure_count" => length(failures)
    }
  end

  defp anchor_summary(nil), do: nil

  defp anchor_summary(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "name" => entry.payload["name"],
      "summary" => get_in(entry.payload, ["state", "summary"])
    }
  end

  defp model_names(entries) do
    entries
    |> Enum.flat_map(fn entry -> [entry.payload["model"], entry.meta["model"]] end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp tool_names(entries) do
    entries
    |> Enum.filter(&(&1.kind in [:tool_call, :tool_result]))
    |> Enum.map(& &1.payload["name"])
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp write_json(path, data), do: File.write!(path, Jason.encode!(data, pretty: true))

  defp write_tape(path, entries) do
    lines = Enum.map_join(entries, "\n", &Entry.to_json/1)
    File.write!(path, if(lines == "", do: "", else: lines <> "\n"))
  end

  defp write_events(path, nil), do: File.write!(path, "")

  defp write_events(path, events_path) do
    if File.exists?(events_path), do: File.cp!(events_path, path), else: File.write!(path, "")
  end

  defp render_chat(messages) do
    ["# Chat", "" | Enum.map(messages, &chat_line/1)]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp chat_line(msg) do
    role = msg[:role] || msg.role
    content = msg[:content] || msg.content || ""
    entry_id = msg[:tape_entry_id] || msg.tape_entry_id
    "## #{role} (entry #{entry_id})\n\n#{content}\n"
  end

  defp render_context(context) do
    [
      "# LLM Context",
      ""
      | Enum.with_index(context, 1)
        |> Enum.map(fn {msg, idx} ->
          role = Map.get(msg, :role) || Map.get(msg, "role") || "unknown"
          content = Map.get(msg, :content) || Map.get(msg, "content") || ""
          "## #{idx}. #{role}\n\n#{render_content(content)}\n"
        end)
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_content(content) when is_binary(content), do: content
  defp render_content(content), do: inspect(content, limit: :infinity, printable_limit: :infinity)

  defp render_debug(rows) do
    lines =
      Enum.map(rows, fn row ->
        "- #{row.id} #{row.date} #{row.label}\n  #{row.payload_preview}"
      end)

    ["# Debug Timeline", "" | lines]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_failures([]), do: "# Failures\n\nNo findings.\n"

  defp render_failures(findings) do
    lines =
      Enum.map(findings, fn f ->
        "- [#{f.severity}] #{f.code} at entry #{f.entry_id}: #{f.message}\n  #{Jason.encode!(f.details)}"
      end)

    ["# Failures", "" | lines]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_costs(%{turns: turns, totals: totals}) do
    turn_lines =
      Enum.map(turns, fn turn ->
        "- entry #{turn.entry_id}: #{turn.total_tokens} tokens, #{format_cost(turn.total_cost)}"
      end)

    [
      "# Costs",
      "",
      "Total cost: #{format_cost(totals.total_cost)}",
      "Input tokens: #{totals.input_tokens}",
      "Output tokens: #{totals.output_tokens}",
      "",
      "## Turns",
      "" | turn_lines
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp readme(resolved) do
    """
    # Rho Debug Bundle

    Tape: `#{resolved[:tape_name]}`
    Conversation: `#{resolved[:conversation_id] || "n/a"}`
    Thread: `#{resolved[:thread_id] || "n/a"}`

    `context.md` is generated by the same tape projection path used by the runner.
    `failures.md` contains deterministic analyzer findings.
    """
  end

  defp default_out_dir do
    ts = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(":", "")
    Path.join(System.tmp_dir!(), "rho-debug-#{ts}")
  end

  defp format_cost(n) when is_number(n), do: "$#{Float.round(n / 1, 6)}"
  defp format_cost(_), do: "$0.0"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
