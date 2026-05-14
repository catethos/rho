defmodule Rho.Tape.Fork do
  @moduledoc """
  Fork/Merge operations for parallel exploration with controlled convergence.

  Fork creates an isolated tape starting at a specific entry ID from a source tape.
  Merge appends the fork's new entries (delta only) back to the main tape.
  The main tape is never rewritten — only new entries are appended.
  """

  alias Rho.Tape.{Service, Store}

  @doc """
  Creates a fork: a new tape materialized with entries up to the fork point,
  followed by a `fork_origin` anchor referencing the source tape and entry ID.

  Returns `{:ok, fork_tape_name}`.

  ## Options
    * `:at` - entry ID to fork from (default: latest entry ID)
    * `:name` - custom fork tape name (default: auto-generated)
  """
  def fork(source_tape, opts \\ []) do
    at_id = opts[:at] || Store.last_id(source_tape)

    fork_name = opts[:name] || "#{source_tape}_fork_#{:erlang.unique_integer([:positive])}"

    source_entries =
      source_tape
      |> Store.read()
      |> Enum.filter(&(&1.id <= at_id))
      |> drop_incomplete_tool_calls()

    Enum.each(source_entries, fn entry ->
      meta =
        entry.meta
        |> Map.put("copied_from_tape", source_tape)
        |> Map.put("copied_from_entry_id", entry.id)

      Service.append(fork_name, entry.kind, entry.payload, meta)
    end)

    # Write fork_origin anchor to the new tape after the inherited entries.
    Service.append(fork_name, :anchor, %{
      "name" => "fork_origin",
      "state" => %{
        "phase" => "fork",
        "summary" => "Forked from #{source_tape} at entry #{at_id}.",
        "next_steps" => [],
        "source_ids" => [],
        "owner" => "system"
      },
      "fork" => %{
        "source_tape" => source_tape,
        "at_id" => at_id
      }
    })

    {:ok, fork_name}
  end

  @doc """
  Merges a fork back into the main tape. Appends only the delta entries
  (entries after the fork_origin anchor) to the main tape.

  Returns `{:ok, count}` where count is the number of entries merged.
  """
  def merge(fork_tape, main_tape) do
    fork_entries = Store.read(fork_tape)

    # Find the fork_origin anchor
    origin =
      Enum.find(fork_entries, fn e ->
        e.kind == :anchor and e.payload["name"] == "fork_origin"
      end)

    case origin do
      nil ->
        {:error, :no_fork_origin}

      %{id: origin_id} ->
        # Get entries after the fork_origin (the delta)
        delta =
          fork_entries
          |> Enum.filter(&(&1.id > origin_id))
          |> Enum.reject(&(&1.kind == :anchor and &1.payload["name"] == "fork_origin"))

        # Append delta entries to main tape
        Enum.each(delta, fn entry ->
          meta = Map.put(entry.meta || %{}, "from_fork", fork_tape)
          Service.append(main_tape, entry.kind, entry.payload, meta)
        end)

        {:ok, length(delta)}
    end
  end

  @doc """
  Returns fork metadata if the tape is a fork, nil otherwise.
  """
  def fork_info(tape_name) do
    case find_fork_origin(tape_name) do
      %{id: origin_id, payload: %{"fork" => fork_data}} ->
        count = max(Store.last_id(tape_name) - origin_id, 0)

        %{
          source_tape: fork_data["source_tape"],
          at_id: fork_data["at_id"],
          entries_since_fork: count
        }

      _ ->
        nil
    end
  end

  defp find_fork_origin(tape_name) do
    tape_name
    |> Store.read()
    |> Enum.find(fn entry -> entry.kind == :anchor and entry.payload["name"] == "fork_origin" end)
  end

  defp drop_incomplete_tool_calls(entries) do
    result_ids =
      entries
      |> Enum.filter(&(&1.kind == :tool_result))
      |> MapSet.new(& &1.payload["call_id"])

    Enum.reject(entries, fn
      %{kind: :tool_call, payload: %{"call_id" => call_id}} ->
        not MapSet.member?(result_ids, call_id)

      _ ->
        false
    end)
  end
end
