defmodule Rho.Tape.Service do
  @moduledoc "Stateless high-level API for tape operations."

  alias Rho.Tape.{Entry, Store}

  @doc "Derives a deterministic tape name from session ID and workspace path."
  def session_tape(session_id, workspace) do
    sid = hash8(to_string(session_id))
    wid = hash8(to_string(workspace))
    "session_#{sid}_#{wid}"
  end

  @doc "Creates an initial session/start anchor if none exists."
  def ensure_bootstrap_anchor(tape_name) do
    case Store.last_anchor(tape_name) do
      nil ->
        append(tape_name, :anchor, %{
          "name" => "session/start",
          "state" => %{
            "phase" => "start",
            "summary" => "Session started.",
            "next_steps" => [],
            "source_ids" => [],
            "owner" => "human"
          }
        })

      _anchor ->
        :ok
    end
  end

  @doc "Appends an entry to the tape."
  def append(tape_name, kind, payload, meta \\ %{}) do
    entry = Entry.new(kind, payload, meta)
    Store.append(tape_name, entry)
  end

  @doc "Translates an AgentLoop event into a tape entry and appends it."
  def append_from_event(tape_name, event) do
    case event_to_entry(event) do
      nil -> :ok
      {kind, payload} -> append(tape_name, kind, payload)
    end
  end

  @doc "Convenience for appending an :event entry."
  def append_event(tape_name, name, payload \\ %{}) do
    append(tape_name, :event, Map.put(payload, "name", name))
  end

  @doc "Returns info about a tape: entry/anchor counts, last anchor, entries since anchor."
  def info(tape_name) do
    entries = Store.read(tape_name)
    anchors = Enum.filter(entries, &(&1.kind == :anchor))
    last_anchor = List.last(anchors)

    since_anchor =
      case last_anchor do
        nil -> length(entries)
        a -> entries |> Enum.count(&(&1.id > a.id))
      end

    %{
      entry_count: length(entries),
      anchor_count: length(anchors),
      last_anchor_name: last_anchor && last_anchor.payload["name"],
      entries_since_anchor: since_anchor
    }
  end

  @doc "Substring search on :message entries. When a matching entry is a user message, the next assistant message is included as well."
  def search(tape_name, query, limit \\ 10) do
    matching_ids = Store.search_ids(tape_name, query)

    if matching_ids == [] do
      []
    else
      id_set = MapSet.new(matching_ids)
      all_entries = Store.read(tape_name)

      # Build a map: user_entry_id -> next assistant entry (single pass)
      next_assistant =
        all_entries
        |> Enum.reverse()
        |> Enum.reduce({%{}, nil}, fn entry, {map, last_assistant} ->
          cond do
            entry.kind == :message and entry.payload["role"] == "assistant" ->
              {map, entry}

            entry.kind == :message and entry.payload["role"] == "user" and last_assistant != nil ->
              {Map.put(map, entry.id, last_assistant), last_assistant}

            true ->
              {map, last_assistant}
          end
        end)
        |> elem(0)

      all_entries
      |> Enum.filter(&(MapSet.member?(id_set, &1.id)))
      |> Enum.take(-limit)
      |> Enum.flat_map(fn entry ->
        if entry.payload["role"] == "user" do
          case Map.get(next_assistant, entry.id) do
            nil -> [entry]
            assistant_entry -> [entry, assistant_entry]
          end
        else
          [entry]
        end
      end)
    end
  end

  @doc """
  Performs a handoff: writes a new anchor with structured state, shifting the
  execution origin. The default view will start from this anchor forward.

  ## Options
    * `:source_ids` - entry IDs that informed this anchor (default: last 20 non-anchor IDs)
    * `:owner` - "human" | "agent" (default: "agent")
  """
  def handoff(tape_name, phase, summary, opts \\ []) do
    next_steps = opts[:next_steps] || []
    owner = opts[:owner] || "agent"

    source_ids =
      opts[:source_ids] ||
        (tape_name
         |> Store.read()
         |> Enum.filter(&(&1.kind != :anchor))
         |> Enum.map(& &1.id)
         |> Enum.take(-20))

    payload = %{
      "name" => phase,
      "state" => %{
        "phase" => phase,
        "summary" => summary,
        "next_steps" => next_steps,
        "source_ids" => source_ids,
        "owner" => owner
      }
    }

    append(tape_name, :anchor, payload)
  end

  @doc "Clears tape with optional JSONL backup, then re-bootstraps."
  def reset(tape_name, archive \\ false) do
    if archive do
      src = Path.expand("~/.rho/tapes/#{tape_name}.jsonl")

      if File.exists?(src) do
        ts = DateTime.utc_now() |> DateTime.to_unix()
        dest = Path.expand("~/.rho/tapes/#{tape_name}.#{ts}.jsonl")
        File.cp!(src, dest)
      end
    end

    Store.clear(tape_name)
    Rho.Tape.View.invalidate_cache(tape_name)
    ensure_bootstrap_anchor(tape_name)
  end

  @doc "Returns all tape entries as a UI-friendly history list."
  def history(tape_name) do
    Store.read(tape_name)
    |> Enum.filter(&(&1.kind in [:message, :tool_call, :tool_result, :anchor]))
    |> Enum.map(&entry_to_history/1)
  end

  defp entry_to_history(%{kind: :message} = e) do
    %{type: "message", role: e.payload["role"], content: e.payload["content"], id: e.id, ts: e.date}
  end

  defp entry_to_history(%{kind: :tool_call} = e) do
    %{type: "tool_call", name: e.payload["name"], args: e.payload["args"], id: e.id, ts: e.date}
  end

  defp entry_to_history(%{kind: :tool_result} = e) do
    %{type: "tool_result", name: e.payload["name"], output: e.payload["output"],
      status: e.payload["status"], id: e.id, ts: e.date}
  end

  defp entry_to_history(%{kind: :anchor} = e) do
    %{type: "anchor", name: e.payload["name"], id: e.id, ts: e.date}
  end

  # -- Event-to-entry mapping --

  defp event_to_entry(%{type: :llm_text, text: text}) do
    {:message, %{"role" => "assistant", "content" => text}}
  end

  defp event_to_entry(%{type: :tool_start, name: name, args: args} = event) do
    payload = %{"name" => name, "args" => args} |> maybe_put_call_id(event)
    {:tool_call, payload}
  end

  defp event_to_entry(%{type: :tool_result, name: name} = event) do
    payload =
      %{"name" => name, "status" => to_string(event[:status] || :ok), "output" => event[:output] || ""}
      |> maybe_put_call_id(event)
      |> maybe_put("latency_ms", event[:latency_ms])
      |> maybe_put("error_type", if(event[:error_type], do: to_string(event[:error_type])))

    {:tool_result, payload}
  end

  defp event_to_entry(%{type: :llm_usage} = event) do
    usage = event[:usage] || %{}

    payload =
      %{
        "name" => "llm_usage",
        "step" => event[:step],
        "model" => to_string(event[:model] || ""),
        "input_tokens" => get_usage(usage, :input_tokens),
        "output_tokens" => get_usage(usage, :output_tokens),
        "reasoning_tokens" => get_usage(usage, :reasoning_tokens),
        "cached_tokens" => get_usage(usage, :cached_tokens),
        "cache_creation_tokens" => get_usage(usage, :cache_creation_tokens),
        "total_tokens" => get_usage(usage, :total_tokens),
        "total_cost" => get_usage(usage, :total_cost),
        "input_cost" => get_usage(usage, :input_cost),
        "output_cost" => get_usage(usage, :output_cost),
        "reasoning_cost" => get_usage(usage, :reasoning_cost)
      }

    {:event, payload}
  end

  defp event_to_entry(%{type: :error, reason: reason}) do
    {:event, %{"name" => "error", "reason" => inspect(reason)}}
  end

  defp event_to_entry(_), do: nil

  defp get_usage(usage, key) do
    case Map.get(usage, key) do
      nil -> Map.get(usage, to_string(key), 0)
      val -> val
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_call_id(payload, event) do
    case event[:call_id] do
      nil -> payload
      call_id -> Map.put(payload, "call_id", call_id)
    end
  end

  defp hash8(str) do
    :crypto.hash(:md5, str)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end
end
