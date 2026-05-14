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
    entries = Enum.sort_by(entries, &(&1.id || 0))

    []
    |> Kernel.++(orphan_tool_results(entries))
    |> Kernel.++(tool_calls_without_results(entries))
    |> Kernel.++(repeated_tool_calls(entries))
    |> Kernel.++(max_steps_exceeded(entries))
    |> Kernel.++(parse_error_loop(entries))
    |> Kernel.++(missing_final_assistant_message(entries))
    |> Kernel.++(fork_without_context(entries))
    |> Kernel.++(large_context_after_anchor(entries, opts))
    |> Kernel.++(tool_error_without_type(entries))
    |> Kernel.++(high_cost_turn(entries, opts))
    |> Enum.sort_by(fn finding ->
      {severity_rank(finding.severity), finding.entry_id || 0, finding.code}
    end)
  end

  defp orphan_tool_results(entries) do
    call_ids =
      entries
      |> Enum.filter(&(&1.kind == :tool_call))
      |> MapSet.new(& &1.payload["call_id"])

    entries
    |> Enum.filter(&(&1.kind == :tool_result))
    |> Enum.reject(fn entry -> MapSet.member?(call_ids, entry.payload["call_id"]) end)
    |> Enum.map(fn entry ->
      finding(:error, :orphan_tool_result, entry.id, "Tool result has no matching tool call.", %{
        call_id: entry.payload["call_id"],
        name: entry.payload["name"]
      })
    end)
  end

  defp tool_calls_without_results(entries) do
    result_ids =
      entries
      |> Enum.filter(&(&1.kind == :tool_result))
      |> MapSet.new(& &1.payload["call_id"])

    entries
    |> Enum.filter(&(&1.kind == :tool_call))
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

  defp repeated_tool_calls(entries) do
    entries
    |> Enum.filter(&(&1.kind == :tool_call))
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

  defp max_steps_exceeded(entries) do
    entries
    |> Enum.filter(fn entry ->
      entry.kind == :event and entry.payload["name"] == "error" and
        string_contains?(entry.payload["reason"], "max steps")
    end)
    |> Enum.map(fn entry ->
      finding(:error, :max_steps_exceeded, entry.id, "Run exceeded the maximum step budget.", %{
        reason: entry.payload["reason"]
      })
    end)
  end

  defp parse_error_loop(entries) do
    parse_errors =
      Enum.filter(entries, fn entry ->
        entry.kind == :event and
          (string_contains?(entry.payload["name"], "parse") or
             string_contains?(entry.payload["reason"], "parse"))
      end)

    if length(parse_errors) >= 2 do
      first = hd(parse_errors)

      [
        finding(
          :warning,
          :parse_error_loop,
          first.id,
          "Multiple parse errors occurred in one trace.",
          %{
            count: length(parse_errors),
            entry_ids: Enum.map(parse_errors, & &1.id)
          }
        )
      ]
    else
      []
    end
  end

  defp missing_final_assistant_message(entries) do
    last_message =
      entries
      |> Enum.filter(&(&1.kind == :message))
      |> List.last()

    case last_message do
      %Entry{payload: %{"role" => "user"}} ->
        active_turn? =
          Enum.any?(entries, fn entry ->
            entry.kind == :event and entry.payload["name"] == "turn_started"
          end) and
            not Enum.any?(entries, fn entry ->
              entry.kind == :event and entry.payload["name"] == "turn_finished"
            end)

        if active_turn? do
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

  defp fork_without_context(entries) do
    origin =
      Enum.find(entries, fn entry ->
        entry.kind == :anchor and entry.payload["name"] == "fork_origin"
      end)

    inherited_count =
      entries
      |> Enum.filter(&(&1.kind in [:message, :tool_call, :tool_result]))
      |> Enum.count(&(&1.meta["copied_from_tape"] || &1.meta["copied_from_entry_id"]))

    if origin && inherited_count == 0 do
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

  defp large_context_after_anchor(entries, opts) do
    threshold = Keyword.get(opts, :large_context_threshold, @default_large_context_threshold)

    last_anchor_id =
      case entries |> Enum.filter(&(&1.kind == :anchor)) |> List.last() do
        nil -> nil
        entry -> entry.id
      end

    count =
      entries
      |> Enum.filter(&(&1.kind in [:message, :tool_call, :tool_result]))
      |> Enum.count(fn entry -> is_nil(last_anchor_id) or entry.id > last_anchor_id end)

    if count > threshold do
      [
        finding(
          :info,
          :large_context_after_anchor,
          last_anchor_id,
          "Context after latest anchor has #{count} conversational entries.",
          %{count: count, threshold: threshold}
        )
      ]
    else
      []
    end
  end

  defp tool_error_without_type(entries) do
    entries
    |> Enum.filter(fn entry ->
      entry.kind == :tool_result and entry.payload["status"] == "error" and
        blank?(entry.payload["error_type"])
    end)
    |> Enum.map(fn entry ->
      finding(:warning, :tool_error_without_type, entry.id, "Tool error lacks error_type.", %{
        name: entry.payload["name"],
        call_id: entry.payload["call_id"]
      })
    end)
  end

  defp high_cost_turn(entries, opts) do
    token_threshold = Keyword.get(opts, :high_token_threshold, @default_high_token_threshold)
    cost_threshold = Keyword.get(opts, :high_cost_threshold, @default_high_cost_threshold)

    entries
    |> Enum.filter(fn entry -> entry.kind == :event and entry.payload["name"] == "llm_usage" end)
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
