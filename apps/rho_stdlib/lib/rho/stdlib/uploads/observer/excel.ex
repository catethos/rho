defmodule Rho.Stdlib.Uploads.Observer.Excel do
  @moduledoc "Xlsxir-based Excel parser. Returns sheet summaries with columns + sample rows."

  @sample_rows 3

  @doc "Parse a `.xlsx` file. Returns `{:ok, [sheet_summary]}` or `{:error, reason}`."
  def parse(path) when is_binary(path) do
    case Xlsxir.multi_extract(path) do
      results when is_list(results) -> {:ok, build_sheets(results)}
      {:error, reason} -> {:error, {:xlsxir, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc "Read a single sheet's full row data (no caching). Used by `read_upload`."
  def read_sheet(path, sheet_name, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 200) |> min(1000)

    case Xlsxir.multi_extract(path) do
      results when is_list(results) ->
        {matched, others} = partition_by_name(results, sheet_name)
        # Close every non-matched table to avoid an ETS-table leak per call.
        Enum.each(others, fn {:ok, t} -> Xlsxir.close(t) end)

        case matched do
          {:ok, table} ->
            rows = Xlsxir.get_list(table)
            Xlsxir.close(table)
            {columns, data_rows} = split_header_data(rows)
            total = length(data_rows)
            sliced = data_rows |> Enum.drop(offset) |> Enum.take(limit) |> rows_as_maps(columns)
            {:ok, %{columns: columns, rows: sliced, total: total}}

          :not_found ->
            {:error, :sheet_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp partition_by_name(results, sheet_name) do
    {matched, others} =
      Enum.reduce(results, {:not_found, []}, fn
        {:ok, table} = result, {:not_found, acc} ->
          if sheet_matches?(table, sheet_name) do
            {result, acc}
          else
            {:not_found, [result | acc]}
          end

        result, {found, acc} ->
          {found, [result | acc]}
      end)

    {matched, Enum.reverse(others)}
  end

  defp sheet_matches?(_table, nil), do: true

  defp sheet_matches?(table, name) do
    info = Xlsxir.get_info(table)
    extract_sheet_name(info) == name
  end

  defp build_sheets(results) do
    results
    |> Enum.map(fn
      {:ok, table} -> table_to_summary(table)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp table_to_summary(table) do
    rows = Xlsxir.get_list(table)
    info = Xlsxir.get_info(table)
    Xlsxir.close(table)

    {columns, data_rows} = split_header_data(rows)

    %{
      name: extract_sheet_name(info),
      columns: columns,
      row_count: length(data_rows),
      sample_rows: data_rows |> Enum.take(@sample_rows) |> rows_as_maps(columns)
    }
  end

  defp split_header_data([]), do: {[], []}
  defp split_header_data([header | rest]), do: {Enum.map(header, &to_str/1), rest}

  defp rows_as_maps(rows, columns) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, to_str(val)} end)
    end)
  end

  defp to_str(nil), do: ""
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: to_string(v)

  defp extract_sheet_name(info) when is_map(info), do: Map.get(info, :name) || "Sheet1"
  defp extract_sheet_name(info) when is_list(info), do: Keyword.get(info, :name, "Sheet1")
  defp extract_sheet_name(_), do: "Sheet1"
end
