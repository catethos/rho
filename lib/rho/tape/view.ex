defmodule Rho.Tape.View do
  @moduledoc """
  Task-oriented assembled context window. Derived from tape, never stored.

  A View selects entries from the tape based on the latest anchor and converts
  them to the ReqLLM message format the agent loop expects.
  """

  alias Rho.Tape.{Entry, Store}

  defstruct [:tape_name, :anchor_id, :anchor_summary, :entries, :policy]

  @type t :: %__MODULE__{
          tape_name: String.t(),
          anchor_id: integer() | nil,
          anchor_summary: String.t() | nil,
          entries: [Entry.t()],
          policy: atom()
        }

  @conversational_kinds [:message, :tool_call, :tool_result]
  @cache :rho_view_cache

  @doc """
  Assembles the default view: entries from the latest anchor forward,
  filtered to conversational kinds. Incrementally appends new entries
  when the anchor hasn't changed since the last call.
  """
  def default(tape_name) do
    ensure_cache()
    anchor = Store.last_anchor(tape_name)
    anchor_id = if anchor, do: anchor.id
    current_last = Store.last_id(tape_name)

    case :ets.lookup(@cache, tape_name) do
      [{_, ^anchor_id, prev_last, view}] when prev_last == current_last ->
        view

      [{_, ^anchor_id, prev_last, view}] ->
        new_entries =
          Store.read(tape_name, prev_last + 1)
          |> Enum.filter(&(&1.kind in @conversational_kinds))

        view = %{view | entries: view.entries ++ new_entries}
        :ets.insert(@cache, {tape_name, anchor_id, current_last, view})
        view

      _ ->
        view = build_default(tape_name, anchor)
        :ets.insert(@cache, {tape_name, anchor_id, current_last, view})
        view
    end
  end

  defp build_default(tape_name, anchor) do
    entries =
      case anchor do
        nil ->
          Store.read(tape_name)

        %Entry{id: anchor_id} ->
          Store.read(tape_name, anchor_id + 1)
      end

    entries = Enum.filter(entries, &(&1.kind in @conversational_kinds))

    anchor_summary =
      case anchor do
        %Entry{payload: %{"state" => %{"summary" => s}}} when s != "" -> s
        _ -> nil
      end

    %__MODULE__{
      tape_name: tape_name,
      anchor_id: anchor && anchor.id,
      anchor_summary: anchor_summary,
      entries: entries,
      policy: :default
    }
  end

  @doc "Invalidates the cached view for a tape, forcing a full rebuild on next access."
  def invalidate_cache(tape_name) do
    if :ets.whereis(@cache) != :undefined do
      :ets.delete(@cache, tape_name)
    end
  rescue
    ArgumentError -> :ok
  end

  defp ensure_cache do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Converts a View to a list of ReqLLM messages.

  If an anchor exists, its summary is prepended as a user context message.
  Consecutive tool_call entries are grouped into a single assistant message.
  """
  def to_messages(%__MODULE__{} = view) do
    anchor_msgs = anchor_context(view)
    entry_msgs = entries_to_messages(view.entries)
    anchor_msgs ++ entry_msgs
  end

  # -- Anchor context --

  defp anchor_context(%__MODULE__{anchor_summary: nil}), do: []

  defp anchor_context(%__MODULE__{anchor_summary: summary}) do
    [ReqLLM.Context.user("Context from previous conversation:\n#{summary}")]
  end

  # -- Entry-to-message conversion --

  defp entries_to_messages(entries) do
    entries
    |> drop_orphaned_tool_results()
    |> group_tool_calls()
    |> Enum.flat_map(&convert_group/1)
  end

  # Remove tool_result entries whose call_id has no matching tool_call in the
  # current view.  This prevents invalid messages when an anchor or compaction
  # boundary splits a tool_call/tool_result pair.
  defp drop_orphaned_tool_results(entries) do
    known_call_ids =
      entries
      |> Enum.filter(&(&1.kind == :tool_call))
      |> MapSet.new(& &1.payload["call_id"])

    Enum.filter(entries, fn
      %Entry{kind: :tool_result, payload: %{"call_id" => cid}} ->
        MapSet.member?(known_call_ids, cid)

      %Entry{kind: :tool_result} ->
        false

      _ ->
        true
    end)
  end

  # Groups consecutive tool_call entries together, leaves other entries as singletons.
  defp group_tool_calls(entries) do
    entries
    |> Enum.chunk_while(
      [],
      fn entry, acc ->
        case {entry.kind, acc} do
          {:tool_call, [%Entry{kind: :tool_call} | _]} ->
            {:cont, acc ++ [entry]}

          {:tool_call, [single]} ->
            {:cont, {:single, single}, [entry]}

          {:tool_call, []} ->
            {:cont, [entry]}

          {_, [%Entry{kind: :tool_call} | _] = tool_calls} ->
            {:cont, {:tool_calls, tool_calls}, [entry]}

          {_, []} ->
            {:cont, [entry]}

          {_, [single]} ->
            {:cont, {:single, single}, [entry]}
        end
      end,
      fn
        [] -> {:cont, []}
        [%Entry{kind: :tool_call} | _] = tool_calls -> {:cont, {:tool_calls, tool_calls}, []}
        [single] -> {:cont, {:single, single}, []}
      end
    )
  end

  defp convert_group(
         {:single, %Entry{kind: :message, payload: %{"role" => "user", "content" => content}}}
       ) do
    [ReqLLM.Context.user(content)]
  end

  defp convert_group(
         {:single,
          %Entry{kind: :message, payload: %{"role" => "assistant", "content" => content}}}
       ) do
    [ReqLLM.Context.assistant(content)]
  end

  defp convert_group({:single, %Entry{kind: :tool_result, payload: payload}}) do
    call_id = payload["call_id"] || "unknown"
    output = payload["output"] || ""
    [ReqLLM.Context.tool_result(call_id, output)]
  end

  defp convert_group({:single, _entry}), do: []

  defp convert_group({:tool_calls, tool_call_entries}) do
    tool_calls =
      Enum.map(tool_call_entries, fn entry ->
        args_json =
          case entry.payload["args"] do
            nil -> "{}"
            args when is_map(args) -> Jason.encode!(args)
            args when is_binary(args) -> args
          end

        ReqLLM.ToolCall.new(
          entry.payload["call_id"] || "tc_#{entry.id}",
          entry.payload["name"],
          args_json
        )
      end)

    [ReqLLM.Context.assistant("", tool_calls: tool_calls)]
  end
end
