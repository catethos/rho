defmodule Rho.Tape.Store do
  @moduledoc """
  Append-only tape storage. Single writer (GenServer serializes appends),
  concurrent readers (ETS with read_concurrency).

  Persists to JSONL files under ~/.rho/tapes/.
  """

  use GenServer

  alias Rho.Tape.Entry

  @table :rho_tape_store
  @index_table :rho_tape_index
  @tapes_dir Path.expand("~/.rho/tapes")

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Appends an entry to the tape. Assigns monotonic ID. Returns {:ok, entry_with_id}."
  def append(tape_name, %Entry{} = entry) do
    GenServer.call(__MODULE__, {:append, tape_name, entry})
  end

  @doc "Reads all entries for a tape, sorted by ID. Direct ETS read (no GenServer)."
  def read(tape_name) do
    match_spec = [{{{tape_name, :"$1"}, :"$2"}, [{:is_integer, :"$1"}], [{{:"$1", :"$2"}}]}]

    @table
    |> :ets.select(match_spec)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Reads entries with id >= from_id."
  def read(tape_name, from_id) do
    spec = [
      {{{tape_name, :"$1"}, :"$2"}, [{:is_integer, :"$1"}, {:>=, :"$1", from_id}],
       [{{:"$1", :"$2"}}]}
    ]

    @table
    |> :ets.select(spec)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Returns the last entry ID for a tape, or 0 if empty."
  def last_id(tape_name) do
    case :ets.lookup(@table, {tape_name, :meta}) do
      [{{_, :meta}, %{next_id: n}}] -> n - 1
      [] -> 0
    end
  end

  @doc "Returns a single entry by tape name and ID, or nil."
  def get(tape_name, id) do
    case :ets.lookup(@table, {tape_name, id}) do
      [{{_, _}, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Clears all entries for a tape and removes the JSONL file."
  def clear(tape_name) do
    GenServer.call(__MODULE__, {:clear, tape_name})
  end

  @doc """
  Full-text search: returns entry IDs matching all tokens in the query.
  Direct ETS read (no GenServer).
  """
  def search_ids(tape_name, query) do
    tokens = tokenize(query)

    case tokens do
      [] ->
        []

      [first | rest] ->
        initial = lookup_token_ids(tape_name, first)

        Enum.reduce(rest, initial, fn token, acc ->
          token_ids = lookup_token_ids(tape_name, token)
          MapSet.intersection(acc, token_ids)
        end)
        |> MapSet.to_list()
        |> Enum.sort()
    end
  end

  @doc "Returns the latest anchor entry for a tape, or nil."
  def last_anchor(tape_name) do
    case :ets.lookup(@table, {tape_name, :meta}) do
      [{{_, :meta}, %{last_anchor_id: anchor_id}}] when is_integer(anchor_id) ->
        get(tape_name, anchor_id)

      _ ->
        nil
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@index_table, [:named_table, :bag, :public, read_concurrency: true])
    File.mkdir_p!(@tapes_dir)
    load_all_tapes()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:append, tape_name, entry}, _from, state) do
    next_id = get_next_id(tape_name)
    entry = %{entry | id: next_id}

    :ets.insert(@table, {{tape_name, next_id}, entry})

    meta = get_meta(tape_name)
    meta = %{meta | next_id: next_id + 1}
    meta = if entry.kind == :anchor, do: Map.put(meta, :last_anchor_id, next_id), else: meta
    :ets.insert(@table, {{tape_name, :meta}, meta})

    index_entry(tape_name, entry)
    append_to_file(tape_name, entry)

    {:reply, {:ok, entry}, state}
  end

  def handle_call({:clear, tape_name}, _from, state) do
    # Delete all entries for this tape from ETS
    match_spec = [{{{tape_name, :_}, :_}, [], [true]}]
    :ets.select_delete(@table, match_spec)

    # Delete index entries for this tape
    index_spec = [{{{tape_name, :_}, :_}, [], [true]}]
    :ets.select_delete(@index_table, index_spec)

    # Delete JSONL file
    path = tape_path(tape_name)
    File.rm(path)

    {:reply, :ok, state}
  end

  # -- Private --

  defp get_meta(tape_name) do
    case :ets.lookup(@table, {tape_name, :meta}) do
      [{{_, :meta}, meta}] -> meta
      [] -> %{next_id: 1, last_anchor_id: nil}
    end
  end

  defp get_next_id(tape_name) do
    get_meta(tape_name).next_id
  end

  defp tape_path(tape_name) do
    Path.join(@tapes_dir, "#{tape_name}.jsonl")
  end

  defp append_to_file(tape_name, %Entry{} = entry) do
    path = tape_path(tape_name)
    line = Entry.to_json(entry) <> "\n"
    File.write!(path, line, [:append])
  end

  defp load_all_tapes do
    case File.ls(@tapes_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.each(&load_tape_file/1)

      {:error, _} ->
        :ok
    end
  end

  defp load_tape_file(filename) do
    tape_name = String.trim_trailing(filename, ".jsonl")
    path = Path.join(@tapes_dir, filename)

    {max_id, last_anchor_id} =
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce({0, nil}, fn line, {max, anchor_id} ->
        case Entry.from_json(line) do
          {:ok, entry} ->
            :ets.insert(@table, {{tape_name, entry.id}, entry})
            index_entry(tape_name, entry)
            new_anchor = if entry.kind == :anchor, do: entry.id, else: anchor_id
            {Kernel.max(max, entry.id), new_anchor}

          {:error, _} ->
            {max, anchor_id}
        end
      end)

    if max_id > 0 do
      :ets.insert(
        @table,
        {{tape_name, :meta}, %{next_id: max_id + 1, last_anchor_id: last_anchor_id}}
      )
    end
  end

  defp index_entry(tape_name, %Entry{id: id, kind: :message, payload: %{"content" => content}})
       when is_binary(content) do
    tokens = tokenize(content)

    Enum.each(tokens, fn token ->
      :ets.insert(@index_table, {{tape_name, token}, id})
    end)
  end

  defp index_entry(_tape_name, _entry), do: :ok

  defp lookup_token_ids(tape_name, token) do
    @index_table
    |> :ets.lookup({tape_name, token})
    |> Enum.map(&elem(&1, 1))
    |> MapSet.new()
  end

  @doc false
  def tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end
end
