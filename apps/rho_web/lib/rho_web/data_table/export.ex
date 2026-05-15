defmodule RhoWeb.DataTable.Export do
  @moduledoc """
  Pure CSV/XLSX export builders for data-table rows.

  The LiveComponent owns interaction and download events; this module owns the
  serialization contract so export behavior can be tested without rendering or
  LiveView state.
  """

  alias RhoWeb.DataTable.Schema

  @doc "Build a CSV document from ordered data-table rows and a display schema."
  def build_csv(export_rows, %Schema{} = schema) when is_list(export_rows) do
    csv_columns = Enum.reject(schema.columns, fn col -> col.type == :action end)
    csv_child_columns = schema.child_columns || []
    children_key = schema.children_key

    has_children = children_key != nil and csv_child_columns != []

    all_headers = csv_headers(csv_columns, csv_child_columns, has_children)

    header = Enum.map_join(all_headers, ",", &csv_escape/1)

    data_lines =
      Enum.flat_map(export_rows, fn row ->
        parent_cells = csv_parent_cells(row, csv_columns)

        if has_children do
          csv_child_lines(row, children_key, csv_child_columns, parent_cells)
        else
          [Enum.join(parent_cells, ",")]
        end
      end)

    header <> "\n" <> Enum.join(data_lines, "\n")
  end

  @doc "Build an XLSX binary from ordered data-table rows and a display schema."
  def build_xlsx(export_rows, %Schema{} = schema) when is_list(export_rows) do
    xlsx_columns = Enum.reject(schema.columns, fn col -> col.type == :action end)
    xlsx_child_columns = schema.child_columns || []
    children_key = schema.children_key

    has_children = children_key != nil and xlsx_child_columns != []

    all_cols =
      if has_children, do: xlsx_columns ++ xlsx_child_columns, else: xlsx_columns

    header_style = [bold: true, bg_color: "#2B579A", color: "#FFFFFF", size: 11]
    header_row = Enum.map(all_cols, fn col -> [col.label | header_style] end)

    stripe_color = "#F2F6FC"
    separator = [bottom: [style: :thin, color: "#C0C0C0"]]

    {data_rows, _group_idx} =
      Enum.flat_map_reduce(export_rows, 0, fn row, group_idx ->
        raw_rows =
          xlsx_raw_rows(row, xlsx_columns, children_key, xlsx_child_columns, has_children)

        striped? = rem(group_idx, 2) == 1
        styled_rows = style_xlsx_rows(raw_rows, striped?, stripe_color, separator)

        {styled_rows, group_idx + 1}
      end)

    all_rows = [xlsx_header_labels(all_cols) | data_rows]
    col_widths = xlsx_column_widths(all_rows)

    sheet =
      %Elixlsx.Sheet{
        name: schema.title || "Data",
        rows: [header_row | data_rows],
        col_widths: col_widths,
        show_grid_lines: false
      }
      |> Elixlsx.Sheet.set_row_height(1, 22)

    {:ok, {_filename, binary}} =
      %Elixlsx.Workbook{sheets: [sheet]}
      |> Elixlsx.write_to_memory("export.xlsx")

    binary
  end

  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp csv_parent_cells(row, parent_columns) do
    Enum.map(parent_columns, fn col ->
      val = Map.get(row, col.key) || Map.get(row, Atom.to_string(col.key)) || ""
      csv_escape(to_string(val))
    end)
  end

  defp csv_headers(header_parent_columns, header_child_columns, has_children) do
    parent_labels = Enum.map(header_parent_columns, & &1.label)

    if has_children do
      parent_labels ++ Enum.map(header_child_columns, & &1.label)
    else
      parent_labels
    end
  end

  defp csv_child_lines(row, children_key, csv_child_columns, parent_cells) do
    children = Map.get(row, children_key) || Map.get(row, Atom.to_string(children_key)) || []

    case children do
      [] ->
        blank_children = List.duplicate("", length(csv_child_columns))
        [Enum.join(parent_cells ++ blank_children, ",")]

      children_entries when is_list(children_entries) ->
        Enum.map(children_entries, fn child ->
          child_cells = csv_child_cells(child, csv_child_columns)
          Enum.join(parent_cells ++ child_cells, ",")
        end)
    end
  end

  defp csv_child_cells(child, csv_children_columns) do
    Enum.map(csv_children_columns, fn col ->
      val = Map.get(child, col.key) || Map.get(child, Atom.to_string(col.key)) || ""
      csv_escape(to_string(val))
    end)
  end

  defp xlsx_raw_rows(row, xlsx_columns, children_key, xlsx_child_columns, has_children) do
    parent_cells = xlsx_parent_cells(row, xlsx_columns)

    if has_children do
      xlsx_child_rows(row, children_key, xlsx_child_columns, parent_cells)
    else
      [parent_cells]
    end
  end

  defp xlsx_parent_cells(row, xlsx_columns) do
    Enum.map(xlsx_columns, fn col ->
      val = Map.get(row, col.key) || Map.get(row, Atom.to_string(col.key)) || ""
      xlsx_cell_value(val, col.type)
    end)
  end

  defp xlsx_child_rows(row, children_key, xlsx_child_columns, parent_cells) do
    children = Map.get(row, children_key) || Map.get(row, Atom.to_string(children_key)) || []

    case children do
      [] ->
        blank_children = List.duplicate("", length(xlsx_child_columns))
        [parent_cells ++ blank_children]

      xlsx_children when is_list(xlsx_children) ->
        Enum.map(xlsx_children, fn child ->
          parent_cells ++ xlsx_child_cells(child, xlsx_child_columns)
        end)
    end
  end

  defp xlsx_header_labels(header_columns) do
    Enum.map(header_columns, & &1.label)
  end

  defp xlsx_child_cells(child, xlsx_child_columns) do
    Enum.map(xlsx_child_columns, fn col ->
      val = Map.get(child, col.key) || Map.get(child, Atom.to_string(col.key)) || ""
      xlsx_cell_value(val, col.type)
    end)
  end

  defp style_xlsx_rows(raw_rows, striped?, stripe_color, separator) do
    last_idx = length(raw_rows) - 1

    raw_rows
    |> Enum.with_index()
    |> Enum.map(fn {cells, row_idx} ->
      last_in_group? = row_idx == last_idx

      Enum.map(cells, fn cell ->
        style =
          if(striped?, do: [bg_color: stripe_color], else: []) ++
            if(last_in_group?, do: [border: separator], else: [])

        case {cell, style} do
          {_, []} -> cell
          {val, props} when is_binary(val) -> [val | props]
          {val, props} when is_number(val) -> [val | props]
          _ -> cell
        end
      end)
    end)
  end

  defp xlsx_column_widths(all_rows) do
    all_rows
    |> Enum.reduce(%{}, fn row, acc ->
      row
      |> Stream.with_index(1)
      |> Enum.reduce(acc, fn {cell, idx}, width_acc ->
        Map.update(width_acc, idx, cell_width(cell), &max(&1, cell_width(cell)))
      end)
    end)
    |> Map.new(fn {idx, max_len} -> {idx, min(max_len + 3, 60)} end)
  end

  defp cell_width([val | _]) when is_binary(val), do: String.length(val)
  defp cell_width(val) when is_binary(val), do: String.length(val)
  defp cell_width(val) when is_number(val), do: val |> to_string() |> String.length()
  defp cell_width(_), do: 0

  defp xlsx_cell_value(val, :number) when is_binary(val) do
    case Float.parse(val) do
      {n, ""} -> n
      _ -> val
    end
  end

  defp xlsx_cell_value(val, :number) when is_number(val), do: val
  defp xlsx_cell_value(val, _type), do: to_string(val)
end
