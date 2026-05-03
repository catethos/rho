defmodule RhoEmbeddings.Backend do
  @moduledoc """
  Behaviour wrapping the pythonx model load + embed calls.

  Two implementations:

    * `RhoEmbeddings.Backend.Pythonx` — production. Calls
      `RhoPython.await_ready/1` then `Pythonx.eval/2` against the
      configured `fastembed.TextEmbedding` model.
    * `RhoEmbeddings.Backend.Fake` — tests. Returns canned vectors so
      the suite runs without downloading 210 MB of weights.

  Selected via `Application.get_env(:rho_embeddings, :backend, ...)`.
  """

  @callback load(model_name :: String.t()) :: :ok | {:error, term()}

  @callback embed(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
end
