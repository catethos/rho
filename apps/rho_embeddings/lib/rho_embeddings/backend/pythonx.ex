defmodule RhoEmbeddings.Backend.Pythonx do
  @moduledoc """
  Production embedding backend backed by `Pythonx` + `fastembed`.

  Holds the loaded `TextEmbedding` model in pythonx globals under the
  name `__rho_embed_model__`. All eval calls run on dirty schedulers via
  the pythonx NIF, so they don't block the BEAM.
  """

  @behaviour RhoEmbeddings.Backend

  @await_ready_timeout 30_000

  @impl true
  def load(model_name) when is_binary(model_name) do
    case RhoPython.await_ready(@await_ready_timeout) do
      :ok ->
        do_load(model_name)

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def embed(texts) when is_list(texts) do
    code = """
    __vecs = list(__rho_embed_model__.embed(__batch))
    [v.tolist() for v in __vecs]
    """

    try do
      {result, _globals} = Pythonx.eval(code, %{"__batch" => texts})
      decoded = Pythonx.decode(result)

      if is_list(decoded) and Enum.all?(decoded, &is_list/1) do
        {:ok, Enum.map(decoded, &Enum.map(&1, fn v -> v / 1 end))}
      else
        {:error, {:decode_failed, decoded}}
      end
    rescue
      e in Pythonx.Error -> {:error, {:eval_failed, Exception.message(e)}}
      e -> {:error, {:eval_failed, Exception.message(e)}}
    end
  end

  defp do_load(model_name) do
    code = """
    from fastembed import TextEmbedding
    __rho_embed_model__ = TextEmbedding(model_name=#{python_string_literal(model_name)})
    list(__rho_embed_model__.embed(["warmup"]))
    """

    try do
      Pythonx.eval(code, %{})
      :ok
    rescue
      e in Pythonx.Error -> {:error, {:load_failed, Exception.message(e)}}
      e -> {:error, {:load_failed, Exception.message(e)}}
    end
  end

  defp python_string_literal(s) when is_binary(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end
end
