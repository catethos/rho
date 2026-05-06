defmodule Rho.Stdlib.Uploads.Observer.Csv do
  @moduledoc "CSV parser using NimbleCSV. Single sheet (named after file)."

  alias NimbleCSV.RFC4180, as: NCSV

  @sample_rows 3

  def parse(path) when is_binary(path) do
    name = Path.basename(path, Path.extname(path))

    case parse_rows(path) do
      {:ok, []} -> {:ok, [%{name: name, columns: [], row_count: 0, sample_rows: []}]}
      {:ok, [header | data]} -> {:ok, [build_summary(name, header, data)]}
      {:error, reason} -> {:error, {:csv, reason}}
    end
  end

  def read_sheet(path, _sheet_ignored, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 200) |> min(1000)

    with {:ok, [header | data]} <- parse_rows(path) do
      sliced = data |> Enum.drop(offset) |> Enum.take(limit) |> rows_as_maps(header)
      {:ok, %{columns: header, rows: sliced, total: length(data)}}
    end
  end

  defp parse_rows(path) do
    rows = path |> File.stream!() |> NCSV.parse_stream(skip_headers: false) |> Enum.to_list()
    {:ok, rows}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_summary(name, header, data) do
    %{
      name: name,
      columns: header,
      row_count: length(data),
      sample_rows: data |> Enum.take(@sample_rows) |> rows_as_maps(header)
    }
  end

  defp rows_as_maps(rows, columns) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end
end
