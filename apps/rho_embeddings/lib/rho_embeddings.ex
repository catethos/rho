defmodule RhoEmbeddings do
  @moduledoc """
  Sentence-embedding service.

  Wraps a singleton `RhoEmbeddings.Server` that delegates to the
  configured backend (OpenAI HTTP in prod, Fake in tests). All
  `embed_many/1` calls serialize through the server.

  Initialization is lazy: the server spawns an async `Task` in
  `init/1` to load the backend. While the load is in flight,
  `embed_many/1` returns `{:error, :not_ready}` and `ready?/0`
  returns `false`.
  """

  alias RhoEmbeddings.Server

  @doc """
  Embed a list of strings. Serializes through the server process.

  Returns `{:ok, vectors}` on success or `{:error, term}` if the model
  is not yet loaded or the underlying eval fails.
  """
  @spec embed_many([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed_many(texts) when is_list(texts), do: Server.embed_many(texts)

  @doc "Returns true once the embedding model has finished loading."
  @spec ready?() :: boolean()
  def ready?(), do: Server.ready?()

  @doc "Returns the configured model name."
  @spec model_name() :: String.t()
  def model_name(), do: Server.model_name()
end
