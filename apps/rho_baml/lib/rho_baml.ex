defmodule RhoBaml do
  @moduledoc """
  Pure library for BAML-based structured LLM calls.

  Provides:
  - `RhoBaml.SchemaCompiler` — Zoi schema → BAML class string conversion
  - `RhoBaml.Function` — `use` hook for defining LLM function modules
  """

  @doc """
  Returns the `baml_src` directory path for the given OTP app.

  At runtime, resolves via `:code.priv_dir/1`.
  """
  def baml_path(app) do
    app |> :code.priv_dir() |> to_string() |> Path.join("baml_src")
  end
end
