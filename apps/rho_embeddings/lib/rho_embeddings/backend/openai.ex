defmodule RhoEmbeddings.Backend.OpenAI do
  @moduledoc """
  Embedding backend that calls OpenAI's `text-embedding-3-small` API,
  requesting `dimensions: 384` to match the existing pgvector schema.

  text-embedding-3-* models support Matryoshka truncation — any prefix
  of the full 1536-dim vector is itself a valid (cosine-comparable)
  embedding. The 384-dim prefix preserves most of the quality while
  keeping the schema unchanged from the fastembed/MiniLM era.

  Requires `OPENAI_API_KEY` in env.

  Selected via:

      config :rho_embeddings, backend: RhoEmbeddings.Backend.OpenAI
  """

  @behaviour RhoEmbeddings.Backend

  require Logger

  @endpoint "https://api.openai.com/v1/embeddings"
  @model "text-embedding-3-small"
  @dimensions 384

  # Single-batch cap from OpenAI's API. Stay well under it so we don't
  # hit token-per-request limits with verbose skill descriptions.
  @max_batch 256

  @impl true
  def load(_model_name) do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        Logger.error("RhoEmbeddings.Backend.OpenAI requires OPENAI_API_KEY")
        {:error, :missing_api_key}

      _ ->
        :ok
    end
  end

  @impl true
  def embed([]), do: {:ok, []}

  def embed(texts) when is_list(texts) do
    texts
    |> Enum.chunk_every(@max_batch)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case post_batch(batch) do
        {:ok, vecs} -> {:cont, {:ok, acc ++ vecs}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp post_batch(texts) do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    body = %{
      model: @model,
      input: texts,
      dimensions: @dimensions
    }

    case Req.post(@endpoint,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           json: body,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        # OpenAI returns objects with `index` and `embedding`; sort by
        # `index` so output order matches input order.
        vecs =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vecs}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
