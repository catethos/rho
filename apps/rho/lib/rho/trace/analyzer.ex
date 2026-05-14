defmodule Rho.Trace.Analyzer do
  @moduledoc """
  Deterministic trace findings for agent debugging.
  """

  alias Rho.Tape.{Entry, Store}

  @default_large_context_threshold 200
  @default_high_token_threshold 100_000
  @default_high_cost_threshold 1.0

  @doc "Analyze a tape by name."
  @spec analyze(String.t(), keyword()) :: [map()]
  def analyze(tape_name, opts \\ []) when is_binary(tape_name) do
    tape_name
    |> Store.read()
    |> findings(opts)
  end

  @doc "Return deterministic findings for a list of entries."
  @spec findings([Entry.t()], keyword()) :: [map()]
  def findings(entries, opts \\ []) when is_list(entries) do
    trace = entries |> Enum.sort_by(&(&1.id || 0)) |> index_entries()

    []
    |> Kernel.++(orphan_tool_results(trace))
    |> Kernel.++(tool_calls_without_results(trace))
    |> Kernel.++(repeated_tool_calls(trace))
    |> Kernel.++(max_steps_exceeded(trace))
    |> Kernel.++(parse_error_loop(trace))
    |> Kernel.++(missing_final_assistant_message(trace))
    |> Kernel.++(fork_without_context(trace))
    |> Kernel.++(large_context_after_anchor(trace, opts))
    |> Kernel.++(tool_error_without_type(trace))
    |> Kernel.++(high_cost_turn(trace, opts))
    |> Enum.sort_by(fn finding ->
      {severity_rank(finding.severity), finding.entry_id || 0, finding.code}
    end)
  end

  defp index_entries(entries) do
    initial = %{
      tool_calls: [],
      tool_results: [],
      messages: [],
      anchors: [],
      max_step_errors: [],
      parse_errors: [],
      llm_usage_events: [],
      tool_error_results: [],
      tool_call_ids: MapSet.new(),
      tool_result_ids: MapSet.new(),
      copied_conversational_count: 0,
      conversational_after_anchor_count: 0,
      last_anchor_id: nil,
      turn_started?: false,
      turn_finished?: false
    }

    entries
    |> Enum.reduce(initial, &index_entry/2)
    |> reverse_index_lists()
  end

  defp index_entry(%Entry{kind: :tool_call} = entry, acc) do
    acc
    |> add_conversational_entry(entry)
    |> Map.update!(:tool_calls, &[entry | &1])
    |> Map.update!(:tool_call_ids, &MapSet.put(&1, entry.payload["call_id"]))
  end

  defp index_entry(%Entry{kind: :tool_result} = entry, acc) do
    acc
    |> add_conversational_entry(entry)
    |> Map.update!(:tool_results, &[entry | &1])
    |> Map.update!(:tool_result_ids, &MapSet.put(&1, entry.payload["call_id"]))
    |> maybe_add_tool_error(entry)
  end

  defp index_entry(%Entry{kind: :message} = entry, acc) do
    acc
    |> add_conversational_entry(entry)
    |> Map.update!(:messages, &[entry | &1])
  end

  defp index_entry(%Entry{kind: :anchor} = entry, acc) do
    %{
      acc
      | anchors: [entry | acc.anchors],
        last_anchor_id: entry.id,
        conversational_after_anchor_count: 0
    }
  end

  defp index_entry(%Entry{kind: :event} = entry, acc) do
    acc
    |> index_event(entry)
    |> maybe_add_max_step_error(entry)
    |> maybe_add_parse_error(entry)
    |> maybe_add_llm_usage(entry)
  end

  defp index_entry(_entry, acc), do: acc

  defp add_conversational_entry(acc, entry) do
    copied? = entry.meta["copied_from_tape"] || entry.meta["copied_from_entry_id"]

    %{
      acc
      | copied_conversational_count:
          acc.copied_conversational_count + if(copied?, do: 1, else: 0),
        conversational_after_anchor_count: acc.conversational_after_anchor_count + 1
    }
  end

  defp index_event(acc, entry) do
    case entry.payload["name"] do
      "turn_started" -> %{acc | turn_started?: true}
      "turn_finished" -> %{acc | turn_finished?: true}
      _ -> acc
    end
  end

  defp maybe_add_max_step_error(acc, entry) do
    if entry.payload["name"] == "error" and string_contains?(entry.payload["reason"], "max steps") do
      Map.update!(acc, :max_step_errors, &[entry | &1])
    else
      acc
    end
  end

  defp maybe_add_parse_error(acc, entry) do
    if string_contains?(entry.payload["name"], "parse") or
         string_contains?(entry.payload["reason"], "parse") do
      Map.update!(acc, :parse_errors, &[entry | &1])
    else
      acc
    end
  end

  defp maybe_add_llm_usage(acc, entry) do
    if entry.payload["name"] == "llm_usage" do
      Map.update!(acc, :llm_usage_events, &[entry | &1])
    else
      acc
    end
  end

  defp maybe_add_tool_error(acc, entry) do
    if entry.payload["status"] == "error" and blank?(entry.payload["error_type"]) do
      Map.update!(acc, :tool_error_results, &[entry | &1])
    else
      acc
    end
  end

  defp reverse_index_lists(trace) do
    %{
      trace
      | tool_calls: Enum.reverse(trace.tool_calls),
        tool_results: Enum.reverse(trace.tool_results),
        messages: Enum.reverse(trace.messages),
        anchors: Enum.reverse(trace.anchors),
        max_step_errors: Enum.reverse(trace.max_step_errors),
        parse_errors: Enum.reverse(trace.parse_errors),
        llm_usage_events: Enum.reverse(trace.llm_usage_events),
        tool_error_results: Enum.reverse(trace.tool_error_results)
    }
  end

  defp orphan_tool_results(trace) do
    call_ids = trace.tool_call_ids

    trace.tool_results
    |> Enum.reject(fn entry -> MapSet.member?(call_ids, entry.payload["call_id"]) end)
    |> Enum.map(fn entry ->
      finding(:error, :orphan_tool_result, entry.id, "Tool result has no matching tool call.", %{
        call_id: entry.payload["call_id"],
        name: entry.payload["name"]
      })
    end)
  end

  defp tool_calls_without_results(trace) do
    result_ids = trace.tool_result_ids

    trace.tool_calls
    |> Enum.reject(fn entry -> MapSet.member?(result_ids, entry.payload["call_id"]) end)
    |> Enum.map(fn entry ->
      finding(
        :warning,
        :tool_call_without_result,
        entry.id,
        "Tool call has no matching result.",
        %{
          call_id: entry.payload["call_id"],
          name: entry.payload["name"]
        }
      )
    end)
  end

  defp repeated_tool_calls(trace) do
    trace.tool_calls
    |> Enum.chunk_by(& &1.payload["name"])
    |> Enum.filter(&(length(&1) >= 3))
    |> Enum.map(fn chunk ->
      first = hd(chunk)

      finding(
        :warning,
        :repeated_tool_call,
        first.id,
        "Tool called #{length(chunk)} times consecutively.",
        %{name: first.payload["name"], count: length(chunk)}
      )
    end)
  end

  defp max_steps_exceeded(trace) do
    trace.max_step_errors
    |> Enum.map(fn entry ->
      finding(:error, :max_steps_exceeded, entry.id, "Run exceeded the maximum step budget.", %{
        reason: entry.payload["reason"]
      })
    end)
  end

  defp parse_error_loop(trace) do
    if match?([_, _ | _], trace.parse_errors) do
      first = hd(trace.parse_errors)

      [
        finding(
          :warning,
          :parse_error_loop,
          first.id,
          "Multiple parse errors occurred in one trace.",
          %{
            count: length(trace.parse_errors),
            entry_ids: Enum.map(trace.parse_errors, & &1.id)
          }
        )
      ]
    else
      []
    end
  end

  defp missing_final_assistant_message(trace) do
    last_message = List.last(trace.messages)

    case last_message do
      %Entry{payload: %{"role" => "user"}} ->
        if trace.turn_started? and not trace.turn_finished? do
          []
        else
          [
            finding(
              :warning,
              :missing_final_assistant_message,
              last_message.id,
              "Last user message has no assistant response.",
              %{}
            )
          ]
        end

      _ ->
        []
    end
  end

  defp fork_without_context(trace) do
    origin =
      Enum.find(trace.anchors, fn entry ->
        entry.payload["name"] == "fork_origin"
      end)

    if origin && trace.copied_conversational_count == 0 do
      [
        finding(
          :error,
          :fork_without_context,
          origin.id,
          "Fork tape has a fork origin but no inherited conversational entries.",
          origin.payload["fork"] || %{}
        )
      ]
    else
      []
    end
  end

  defp large_context_after_anchor(trace, opts) do
    threshold = Keyword.get(opts, :large_context_threshold, @default_large_context_threshold)
    count = trace.conversational_after_anchor_count

    if count > threshold do
      [
        finding(
          :info,
          :large_context_after_anchor,
          trace.last_anchor_id,
          "Context after latest anchor has #{count} conversational entries.",
          %{count: count, threshold: threshold}
        )
      ]
    else
      []
    end
  end

  defp tool_error_without_type(trace) do
    trace.tool_error_results
    |> Enum.map(fn entry ->
      finding(:warning, :tool_error_without_type, entry.id, "Tool error lacks error_type.", %{
        name: entry.payload["name"],
        call_id: entry.payload["call_id"]
      })
    end)
  end

  defp high_cost_turn(trace, opts) do
    token_threshold = Keyword.get(opts, :high_token_threshold, @default_high_token_threshold)
    cost_threshold = Keyword.get(opts, :high_cost_threshold, @default_high_cost_threshold)

    trace.llm_usage_events
    |> Enum.flat_map(fn entry ->
      tokens = safe_int(entry.payload["total_tokens"])
      cost = safe_float(entry.payload["total_cost"])

      if tokens > token_threshold or cost > cost_threshold do
        [
          finding(
            :warning,
            :high_cost_turn,
            entry.id,
            "LLM usage exceeds configured threshold.",
            %{
              total_tokens: tokens,
              total_cost: cost,
              token_threshold: token_threshold,
              cost_threshold: cost_threshold
            }
          )
        ]
      else
        []
      end
    end)
  end

  defp finding(severity, code, entry_id, message, details) do
    %{
      severity: severity,
      code: code,
      entry_id: entry_id,
      message: message,
      details: details || %{}
    }
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2
  defp severity_rank(_), do: 3

  defp string_contains?(value, needle) when is_binary(value) do
    value |> String.downcase() |> String.contains?(needle)
  end

  defp string_contains?(_value, _needle), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp safe_int(n) when is_integer(n), do: n
  defp safe_int(n) when is_float(n), do: trunc(n)

  defp safe_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp safe_int(_), do: 0

  defp safe_float(n) when is_number(n), do: n / 1

  defp safe_float(n) when is_binary(n) do
    case Float.parse(n) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp safe_float(_), do: 0.0
end
