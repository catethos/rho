defmodule RhoFrameworks.Roles.EmbeddingCache do
  @moduledoc """
  Process-wide cache of query string → embedding vector, shared across all
  LiveView sessions. Hot queries ("data scientist", "engineer") hit the
  embedding backend exactly once across the whole app until evicted.

  Bounded to ~1000 entries. On insert past the cap, the oldest 100 entries
  are dropped (FIFO — adequate at this size, no need for true LRU).
  """

  use GenServer

  @table __MODULE__
  @max_entries 1000
  @evict_batch 100

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @spec get(String.t()) :: {:ok, list(float())} | :miss
  def get(query) when is_binary(query) do
    case :ets.lookup(@table, query) do
      [{^query, vec, _seq}] -> {:ok, vec}
      [] -> :miss
    end
  end

  @spec put(String.t(), list(float())) :: :ok
  def put(query, vec) when is_binary(query) and is_list(vec) do
    GenServer.cast(__MODULE__, {:put, query, vec})
  end

  # --- GenServer ---

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{seq: 0}}
  end

  @impl true
  def handle_cast({:put, query, vec}, %{seq: seq} = state) do
    :ets.insert(@table, {query, vec, seq})
    state = %{state | seq: seq + 1}

    if :ets.info(@table, :size) > @max_entries do
      evict_oldest(@evict_batch)
    end

    {:noreply, state}
  end

  defp evict_oldest(n) do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_q, _v, seq} -> seq end)
    |> Enum.take(n)
    |> Enum.each(fn {q, _v, _seq} -> :ets.delete(@table, q) end)
  end
end
