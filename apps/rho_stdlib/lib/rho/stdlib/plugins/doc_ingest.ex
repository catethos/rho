defmodule Rho.Stdlib.Plugins.DocIngest do
  @moduledoc """
  Plugin that provides a tool for extracting text/data from external documents
  (Excel, PDF, Word) so the agent can create skill frameworks from them.

  Returns raw extracted content — the agent interprets and structures it
  into skill framework rows using existing spreadsheet tools.
  """

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_mount_opts, _context) do
    [ingest_document_tool()]
  end

  defp ingest_document_tool do
    %{
      tool:
        ReqLLM.tool(
          name: "ingest_document",
          description:
            "Extract text or table data from an external file (Excel .xlsx, PDF .pdf, Word .docx). " <>
              "Returns the extracted content as text or structured table data. " <>
              "Use the extracted content to populate the spreadsheet with add_rows.",
          parameter_schema: [
            file_path: [type: :string, required: true, doc: "absolute path"],
            format: [type: :string, required: false, doc: "excel|pdf|word, auto-detected"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        path = args[:file_path]

        if is_nil(path) or path == "" do
          {:error, "file_path is required"}
        else
          path = Path.expand(path)

          if File.exists?(path) do
            format = detect_format(args[:format], path)
            extract(format, path)
          else
            {:error, "File not found: #{path}"}
          end
        end
      end
    }
  end

  # --- Format detection ---

  defp detect_format(nil, path), do: detect_format_from_ext(path)
  defp detect_format("", path), do: detect_format_from_ext(path)
  defp detect_format("excel", _path), do: :excel
  defp detect_format("pdf", _path), do: :pdf
  defp detect_format("word", _path), do: :word
  defp detect_format(other, _path), do: {:unknown, other}

  defp detect_format_from_ext(path) do
    case Path.extname(path) |> String.downcase() do
      ".xlsx" -> :excel
      ".xls" -> :excel
      ".pdf" -> :pdf
      ".docx" -> :word
      ".doc" -> :word
      ext -> {:unknown, ext}
    end
  end

  # --- Extraction ---

  defp extract(:excel, path) do
    case extract_excel(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "Excel extraction failed: #{inspect(reason)}"}
    end
  end

  defp extract(:pdf, path) do
    case extract_pdf(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "PDF extraction failed: #{inspect(reason)}"}
    end
  end

  defp extract(:word, path) do
    case extract_docx(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "Word extraction failed: #{inspect(reason)}"}
    end
  end

  defp extract({:unknown, fmt}, _path) do
    {:error, "Unsupported format: #{fmt}. Supported: .xlsx (Excel), .pdf (PDF), .docx (Word)"}
  end

  # --- Excel (.xlsx) via Xlsxir ---

  defp extract_excel(path) do
    case Xlsxir.multi_extract(path) do
      results when is_list(results) ->
        tables = for {:ok, table} <- results, do: table

        sheets = Enum.map(tables, &format_sheet/1)

        {:ok, Enum.join(sheets, "\n\n--- Sheet Break ---\n\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_sheet(table) do
    rows = Xlsxir.get_list(table)
    Xlsxir.close(table)

    case rows do
      [headers | data_rows] ->
        header_strs = Enum.map(headers, &to_string_safe/1)
        data = Enum.map(data_rows, &format_data_row(&1, header_strs))

        "Headers: #{Enum.join(header_strs, " | ")}\n" <>
          Enum.join(data, "\n")

      _ ->
        "(empty sheet)"
    end
  end

  defp format_data_row(row, header_strs) do
    row
    |> Enum.zip(header_strs)
    |> Enum.map_join(" | ", fn {val, hdr} -> "#{hdr}: #{to_string_safe(val)}" end)
  end

  # --- PDF via liteparse (preferred) or pdftotext (fallback) ---

  defp extract_pdf(path) do
    case System.find_executable("lit") do
      nil -> extract_pdf_pdftotext(path)
      lit -> extract_pdf_liteparse(lit, path)
    end
  end

  defp extract_pdf_liteparse(lit, path) do
    case System.cmd(lit, ["parse", path, "--output", "text"], stderr_to_stdout: true) do
      {text, 0} ->
        {:ok, String.trim(text)}

      {err, _code} ->
        # Fall back to pdftotext if liteparse fails
        case extract_pdf_pdftotext(path) do
          {:ok, _} = ok -> ok
          {:error, _} -> {:error, "liteparse failed: #{String.slice(err, 0, 500)}"}
        end
    end
  end

  defp extract_pdf_pdftotext(path) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error,
         "No PDF parser found. Install liteparse (npm install -g @llamaindex/liteparse) " <>
           "or poppler-utils (brew install poppler / apt install poppler-utils)."}

      pdftotext ->
        case System.cmd(pdftotext, ["-layout", path, "-"], stderr_to_stdout: true) do
          {text, 0} -> {:ok, String.trim(text)}
          {err, _code} -> {:error, "pdftotext failed: #{String.slice(err, 0, 500)}"}
        end
    end
  end

  # --- Word (.docx) via liteparse (preferred) or ZIP + XML (fallback) ---

  defp extract_docx(path) do
    case System.find_executable("lit") do
      nil -> extract_docx_zip(path)
      lit -> extract_docx_liteparse(lit, path)
    end
  end

  defp extract_docx_liteparse(lit, path) do
    case System.cmd(lit, ["parse", path, "--output", "text"], stderr_to_stdout: true) do
      {text, 0} ->
        {:ok, String.trim(text)}

      {_err, _code} ->
        extract_docx_zip(path)
    end
  end

  defp extract_docx_zip(path) do
    charlist_path = String.to_charlist(path)

    case :zip.unzip(charlist_path, [:memory]) do
      {:ok, files} ->
        case List.keyfind(files, ~c"word/document.xml", 0) do
          {_, xml_binary} ->
            text = extract_text_from_docx_xml(xml_binary)
            {:ok, text}

          nil ->
            {:error, "No word/document.xml found in .docx archive"}
        end

      {:error, reason} ->
        {:error, "Failed to unzip .docx: #{inspect(reason)}"}
    end
  end

  defp extract_text_from_docx_xml(xml) do
    # Simple regex-based extraction of text from Word XML
    # Extracts content between <w:t> tags and joins paragraphs
    text = to_string(xml)

    text
    |> Regex.scan(~r/<w:p[ >].*?<\/w:p>/s)
    |> Enum.map(&extract_paragraph_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_paragraph_text([para]) do
    Regex.scan(~r/<w:t[^>]*>([^<]*)<\/w:t>/, para)
    |> Enum.map_join("", fn [_, content] -> content end)
  end

  # --- Helpers ---

  defp to_string_safe(nil), do: ""
  defp to_string_safe(val) when is_binary(val), do: val
  defp to_string_safe(val), do: inspect(val)
end
