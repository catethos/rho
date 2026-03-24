defmodule Rho.Tape.Fork do
  @moduledoc """
  Fork/Merge operations for parallel exploration with controlled convergence.

  Fork creates an isolated tape starting at a specific entry ID from a source tape.
  Merge appends the fork's new entries (delta only) back to the main tape.
  The main tape is never rewritten — only new entries are appended.
  """

  alias Rho.Tape.{Service, Store}

  @doc """
  Creates a fork: a new tape that starts with a `fork_origin` anchor
  referencing the source tape and entry ID.

  Returns `{:ok, fork_tape_name}`.

  ## Options
    * `:at` - entry ID to fork from (default: latest entry ID)
    * `:name` - custom fork tape name (default: auto-generated)
  """
  def fork(source_tape, opts \\ []) do
    at_id = opts[:at] || Store.last_id(source_tape)

    fork_name = opts[:name] || "#{source_tape}_fork_#{:erlang.unique_integer([:positive])}"

    # Write fork_origin anchor to the new tape
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
    case Store.get(tape_name, 1) do
      %{kind: :anchor, payload: %{"name" => "fork_origin", "fork" => fork_data}} ->
        count = max(Store.last_id(tape_name) - 1, 0)

        %{
          source_tape: fork_data["source_tape"],
          at_id: fork_data["at_id"],
          entries_since_fork: count
        }

      _ ->
        nil
    end
  end
end
