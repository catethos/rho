defmodule Rho.Trace.Projection do
  @moduledoc """
  Pure projections over tape entries.

  The LLM context projection delegates to the canonical tape projection path;
  chat, debug, failures, and costs are alternate views over the same facts.
  """

  alias Rho.Tape.{Entry, Store}

  @doc "Build UI-friendly chat messages from a tape."
  @spec chat(String.t(), keyword()) :: [map()]
  def chat(tape_name, opts \\ []) when is_binary(tape_name) do
    tape_name
    |> entries(opts)
    |> chat_entries()
  end

  @doc "Build exactly the LLM-visible context for a tape."
  @spec context(String.t(), keyword()) :: [map()]
  def context(tape_name, _opts \\ []) when is_binary(tape_name) do
    Rho.Tape.Projection.JSONL.build_context(tape_name)
  end

  @doc "Build a chronological developer timeline."
  @spec debug(String.t(), keyword()) :: [map()]
  def debug(tape_name, opts \\ []) when is_binary(tape_name) do
    tape_name
    |> entries(opts)
    |> Enum.map(fn entry ->
      %{
        id: entry.id,
        kind: entry.kind,
        label: label(entry),
        payload_preview: preview(entry.payload),
        meta: entry.meta || %{},
        date: entry.date
      }
    end)
  end

  @doc "Run deterministic failure checks for a tape."
  @spec failures(String.t(), keyword()) :: [map()]
  def failures(tape_name, opts \\ []) when is_binary(tape_name) do
    tape_name
    |> entries([])
    |> Rho.Trace.Analyzer.findings(opts)
  end

  @doc "Aggregate usage and cost data from `llm_usage` tape events."
  @spec costs(String.t(), keyword()) :: map()
  def costs(tape_name, opts \\ []) when is_binary(tape_name) do
    turns =
      tape_name
      |> entries(opts)
      |> Enum.filter(&usage_event?/1)
      |> Enum.map(&usage_turn/1)

    totals =
      Enum.reduce(turns, empty_costs(), fn turn, acc ->
        %{
          input_tokens: acc.input_tokens + turn.input_tokens,
          output_tokens: acc.output_tokens + turn.output_tokens,
          reasoning_tokens: acc.reasoning_tokens + turn.reasoning_tokens,
          cached_tokens: acc.cached_tokens + turn.cached_tokens,
          cache_creation_tokens: acc.cache_creation_tokens + turn.cache_creation_tokens,
          total_tokens: acc.total_tokens + turn.total_tokens,
          total_cost: acc.total_cost + turn.total_cost,
          input_cost: acc.input_cost + turn.input_cost,
          output_cost: acc.output_cost + turn.output_cost,
          reasoning_cost: acc.reasoning_cost + turn.reasoning_cost
        }
      end)

    %{turns: turns, totals: totals}
  end

  @doc false
  def entries(tape_name, opts \\ []) do
    read_entries(tape_name)
    |> maybe_last(opts[:last])
  end

  defp read_entries(tape_name) do
    case Store.read(tape_name) do
      [] -> read_entries_from_file(tape_name)
      entries -> entries
    end
  rescue
    _ -> read_entries_from_file(tape_name)
  end

  defp read_entries_from_file(tape_name) do
    path = Store.path_for(tape_name)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Entry.from_json(line) do
          {:ok, entry} -> [entry]
          {:error, _} -> []
        end
      end)
    else
      []
    end
  end

  defp maybe_last(entries, nil), do: entries
  defp maybe_last(entries, n) when is_integer(n) and n > 0, do: Enum.take(entries, -n)
  defp maybe_last(entries, _), do: entries

  defp chat_entries(entries), do: do_chat_entries(entries, [])

  defp do_chat_entries([], acc), do: Enum.reverse(acc)

  defp do_chat_entries([%Entry{kind: :message, payload: payload} = entry, next | rest], acc) do
    with "assistant" <- payload["role"],
         {:ok, %{} = action} <- structured_action(payload["content"]),
         tool when is_binary(tool) and tool not in ["respond", "think"] <- action_tool(action),
         {:ok, result_name, output} <- tool_result_message(next),
         true <- result_name == tool do
      do_chat_entries(rest, [structured_tool_message(entry, next, action, output) | acc])
    else
      _ -> do_chat_entries([entry], acc, [next | rest])
    end
  end

  defp do_chat_entries([entry | rest], acc), do: do_chat_entries(rest, chat_entry_acc(entry, acc))

  defp do_chat_entries([entry], acc, rest), do: do_chat_entries(rest, chat_entry_acc(entry, acc))

  defp chat_entry_acc(%Entry{kind: :message, payload: payload} = entry, acc) do
    cond do
      payload["role"] == "assistant" ->
        case structured_action(payload["content"]) do
          {:ok, %{} = action} -> structured_action_acc(entry, action, acc)
          _ -> append_chat_entry(entry, acc)
        end

      synthetic_tool_result?(payload["content"]) ->
        {:ok, name, output} = parse_tool_result(payload["content"])
        [synthetic_tool_result_message(entry, name, output) | acc]

      thought_noted?(payload["content"]) ->
        acc

      true ->
        append_chat_entry(entry, acc)
    end
  end

  defp chat_entry_acc(entry, acc), do: append_chat_entry(entry, acc)

  defp append_chat_entry(entry, acc) do
    case chat_entry(entry) do
      nil -> acc
      msg -> [msg | acc]
    end
  end

  defp structured_action_acc(entry, action, acc) do
    case action_tool(action) do
      "respond" ->
        message = action["message"] || action["answer"] || ""

        if String.trim(to_string(message)) == "" do
          acc
        else
          [assistant_text_message(entry, message) | acc]
        end

      "think" ->
        acc

      tool when is_binary(tool) ->
        [structured_tool_message(entry, nil, action, nil) | acc]

      _ ->
        append_chat_entry(entry, acc)
    end
  end

  defp structured_action(content) when is_binary(content) do
    case Rho.StructuredOutput.parse(content) do
      {:ok, %{} = map} ->
        if action_tool(map), do: {:ok, map}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp structured_action(_), do: :error

  defp action_tool(map), do: map["tool"] || map["action"] || map["tool_name"] || map["name"]

  defp structured_tool_message(entry, result_entry, action, output) do
    name = action_tool(action)

    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      result_tape_entry_id: result_entry && result_entry.id,
      role: :assistant,
      type: :tool_call,
      name: name,
      args: action["args"] || action["action_input"] || %{},
      call_id: "structured-#{entry.id}",
      status: if(is_nil(output), do: :pending, else: :ok),
      output: output,
      content: "Tool: #{name || "unknown"}",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp synthetic_tool_result_message(entry, name, output) do
    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: :assistant,
      type: :tool_call,
      name: name,
      args: %{},
      call_id: "synthetic-result-#{entry.id}",
      status: :ok,
      output: output,
      content: "Tool result: #{name || "unknown"}",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp assistant_text_message(entry, content) do
    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: :assistant,
      type: :text,
      content: to_string(content),
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp tool_result_message(%Entry{
         kind: :message,
         payload: %{"role" => "user", "content" => content}
       }),
       do: parse_tool_result(content)

  defp tool_result_message(_), do: :error

  @tool_result_prefix ~r/^\[Tool Result: ([^\]]+)\]\n?(.*)$/s

  defp synthetic_tool_result?(content), do: match?({:ok, _, _}, parse_tool_result(content))

  defp parse_tool_result(content) when is_binary(content) do
    case Regex.run(@tool_result_prefix, content) do
      [_, name, output] -> {:ok, name, output}
      _ -> :error
    end
  end

  defp parse_tool_result(_), do: :error

  defp thought_noted?(content) when is_binary(content),
    do: String.starts_with?(content, "[System] Thought noted.")

  defp thought_noted?(_), do: false

  defp chat_entry(%Entry{kind: :message, payload: payload} = entry) do
    role = role_atom(payload["role"])

    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: role,
      type: :text,
      content: payload["content"] || "",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp chat_entry(%Entry{kind: :tool_call, payload: payload} = entry) do
    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: :assistant,
      type: :tool_call,
      name: payload["name"],
      args: payload["args"] || %{},
      call_id: payload["call_id"],
      status: :pending,
      content: "Tool: #{payload["name"] || "unknown"}",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp chat_entry(%Entry{kind: :tool_result, payload: payload} = entry) do
    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: :assistant,
      type: :tool_call,
      name: payload["name"],
      output: payload["output"] || "",
      call_id: payload["call_id"],
      status: status_atom(payload["status"]),
      content: "Tool result: #{payload["name"] || "unknown"}",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp chat_entry(%Entry{kind: :anchor, payload: payload} = entry) do
    state = payload["state"] || %{}

    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: :system,
      type: :anchor,
      content: state["summary"] || payload["name"] || "anchor",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp chat_entry(%Entry{kind: :event, payload: %{"name" => "error"} = payload} = entry) do
    %{
      id: "tape-#{entry.id}",
      tape_entry_id: entry.id,
      role: :system,
      type: :error,
      content: payload["reason"] || "Error",
      agent_id: entry.meta["agent_id"],
      ts: entry.date
    }
  end

  defp chat_entry(_entry), do: nil

  defp label(%Entry{kind: :message, payload: payload}) do
    "message #{payload["role"] || "unknown"}"
  end

  defp label(%Entry{kind: :tool_call, payload: payload}) do
    "tool_call #{payload["name"] || "unknown"}"
  end

  defp label(%Entry{kind: :tool_result, payload: payload}) do
    "tool_result #{payload["name"] || "unknown"} #{payload["status"] || "unknown"}"
  end

  defp label(%Entry{kind: :anchor, payload: payload}) do
    "anchor #{payload["name"] || "unknown"}"
  end

  defp label(%Entry{kind: :event, payload: payload}) do
    "event #{payload["name"] || "unknown"}"
  end

  defp preview(payload) do
    payload
    |> Jason.encode!()
    |> truncate(500)
  rescue
    _ -> inspect(payload, limit: 50, printable_limit: 500)
  end

  defp usage_event?(%Entry{kind: :event, payload: %{"name" => "llm_usage"}}), do: true
  defp usage_event?(_entry), do: false

  defp usage_turn(%Entry{id: id, date: date, payload: payload, meta: meta}) do
    %{
      entry_id: id,
      date: date,
      model: payload["model"] || meta["model"],
      step: payload["step"] || meta["step"],
      input_tokens: safe_int(payload["input_tokens"]),
      output_tokens: safe_int(payload["output_tokens"]),
      reasoning_tokens: safe_int(payload["reasoning_tokens"]),
      cached_tokens: safe_int(payload["cached_tokens"]),
      cache_creation_tokens: safe_int(payload["cache_creation_tokens"]),
      total_tokens: safe_int(payload["total_tokens"]),
      total_cost: safe_float(payload["total_cost"]),
      input_cost: safe_float(payload["input_cost"]),
      output_cost: safe_float(payload["output_cost"]),
      reasoning_cost: safe_float(payload["reasoning_cost"])
    }
  end

  defp empty_costs do
    %{
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      cached_tokens: 0,
      cache_creation_tokens: 0,
      total_tokens: 0,
      total_cost: 0.0,
      input_cost: 0.0,
      output_cost: 0.0,
      reasoning_cost: 0.0
    }
  end

  defp role_atom("user"), do: :user
  defp role_atom("assistant"), do: :assistant
  defp role_atom("system"), do: :system
  defp role_atom(role) when is_atom(role), do: role
  defp role_atom(_), do: :system

  defp status_atom("error"), do: :error
  defp status_atom(:error), do: :error
  defp status_atom(_), do: :ok

  defp safe_int(n) when is_integer(n), do: n
  defp safe_int(n) when is_float(n), do: trunc(n)
  defp safe_int(n) when is_binary(n), do: n |> Integer.parse() |> elem_or_zero()
  defp safe_int(_), do: 0

  defp safe_float(n) when is_number(n), do: n / 1
  defp safe_float(n) when is_binary(n), do: n |> Float.parse() |> elem_or_zero_float()
  defp safe_float(_), do: 0.0

  defp elem_or_zero({n, _}), do: n
  defp elem_or_zero(:error), do: 0

  defp elem_or_zero_float({n, _}), do: n
  defp elem_or_zero_float(:error), do: 0.0

  defp truncate(str, max_value) do
    if String.length(str) > max_value, do: String.slice(str, 0, max_value - 3) <> "...", else: str
  end
end