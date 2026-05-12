defmodule RhoEmbeddings.Backend.Fake do
  @moduledoc """
  Test backend. Returns deterministic 384-dim vectors derived from a
  hash of the input text — no model download, no network.

  Tests can also pre-stash specific vectors for specific texts via
  `put_vector/2`, in which case those texts get the supplied vector
  instead of the hash-derived default.
  """

  @behaviour RhoEmbeddings.Backend

  @dim 384
  @table :rho_embeddings_fake_overrides

  @impl true
  def load(_model_name) do
    ensure_table()
    :ok
  end

  @impl true
  def embed(texts) when is_list(texts) do
    ensure_table()
    {:ok, Enum.map(texts, &vector_for/1)}
  end

  @doc "Stash a canned vector to be returned for `text`."
  def put_vector(text, vector) when is_binary(text) and is_list(vector) do
    ensure_table()
    :ets.insert(@table, {text, vector})
    :ok
  end

  @doc "Clear all stashed overrides."
  def reset() do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp vector_for(text) do
    case :ets.lookup(@table, text) do
      [{^text, vector}] -> vector
      [] -> hash_vector(text)
    end
  end

  defp hash_vector(text) do
    seed = :erlang.phash2(text)

    for i <- 0..(@dim - 1) do
      :math.sin(seed + i) * 0.5 + 0.5
    end
  end

  defp ensure_table() do
    case :ets.info(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> @table
    end
  end
end
