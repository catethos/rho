defmodule Rho.Stdlib.Uploads.Observer.Image do
  @moduledoc "Image observer — passthrough metadata only (no OCR)."

  def parse(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok,
         [
           %{
             name: Path.basename(path),
             columns: [],
             row_count: 0,
             sample_rows: [],
             extra: %{size_bytes: size}
           }
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_sheet(_path, _sheet, _opts \\ []), do: {:error, :not_a_table}
end
