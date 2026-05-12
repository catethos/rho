defmodule RhoEmbeddings.Backend do
  @moduledoc """
  Behaviour wrapping a model load + embed calls.

  Two implementations:

    * `RhoEmbeddings.Backend.OpenAI` — production. HTTP-backed; calls
      OpenAI's `/v1/embeddings` endpoint.
    * `RhoEmbeddings.Backend.Fake` — tests. Returns canned vectors so
      the suite runs without network access.

  Selected via `Application.get_env(:rho_embeddings, :backend, ...)`.
  """

  @callback load(model_name :: String.t()) :: :ok | {:error, term()}

  @callback embed(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
end
