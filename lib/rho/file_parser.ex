defmodule Rho.FileParser do
  @moduledoc """
  Parses uploaded files by MIME type. Routes to Python scripts via Pythonx
  for binary formats (Excel, PDF). Handles images natively.

  This is a backend module — it runs in Tasks spawned by SpreadsheetLive,
  not inside the agent loop. The agent never calls this directly.
  """

  require Logger

  @excel_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @csv_mimes ["text/csv", "application/csv"]
  @pdf_mime "application/pdf"

  @spec parse(String.t(), String.t()) ::
          {:structured,
           %{
             sheets: [
               %{name: String.t(), columns: [String.t()], rows: [map()], row_count: integer()}
             ]
           }}
          | {:text, String.t()}
          | {:image, binary(), String.t()}
          | {:error, String.t()}

  def parse(path, mime_type) do
    ext = Path.extname(path) |> String.downcase()

    cond do
      mime_type == @excel_mime or ext == ".xlsx" ->
        parse_with_python(:excel, path, mime_type)

      mime_type in @csv_mimes or ext == ".csv" ->
        parse_with_python(:csv, path, mime_type)

      mime_type == @pdf_mime or ext == ".pdf" ->
        parse_with_python(:pdf, path, mime_type)

      String.starts_with?(mime_type, "image/") ->
        parse_image(path, mime_type)

      true ->
        {:error, "Unsupported file type: #{ext}. Supported: .xlsx, .csv, .pdf, .jpg, .png, .webp"}
    end
  end

  defp parse_image(path, media_type) do
    case File.read(path) do
      {:ok, binary} -> {:image, Base.encode64(binary), media_type}
      {:error, reason} -> {:error, "Failed to read image: #{inspect(reason)}"}
    end
  end

  defp parse_with_python(type, path, mime_type) do
    script = script_for(type)

    call_args =
      case type do
        :pdf -> inspect(path)
        _ -> "#{inspect(path)}, #{inspect(mime_type)}"
      end

    python_code = """
    __name__ = '__rho_fileparser__'
    exec(open(#{inspect(script)}).read())
    import json as _json
    _r = parse(#{call_args})
    _json.dumps(_r, default=str)
    """

    try do
      {result, _globals} = Pythonx.eval(python_code, %{})
      json_string = Pythonx.decode(result)

      case Jason.decode(json_string) do
        {:ok, %{"type" => "structured", "sheets" => sheets}} ->
          parsed_sheets =
            Enum.map(sheets, fn s ->
              %{
                name: s["name"],
                columns: s["columns"],
                rows: s["rows"],
                row_count: s["row_count"]
              }
            end)

          {:structured, %{sheets: parsed_sheets}}

        {:ok, %{"type" => "text", "content" => content}} ->
          {:text, content}

        {:ok, %{"type" => "error", "message" => message}} ->
          {:error, message}

        {:error, _} ->
          {:error, "Failed to parse Python output"}
      end
    rescue
      e ->
        Logger.error("[FileParser] Python error: #{Exception.message(e)}")
        {:error, "Failed to parse file: #{Exception.message(e)}"}
    end
  end

  defp script_for(:excel), do: script_path("parse_excel.py")
  defp script_for(:csv), do: script_path("parse_excel.py")
  defp script_for(:pdf), do: script_path("parse_pdf.py")

  defp script_path(name) do
    Application.app_dir(:rho, Path.join(["priv", "python", "file_parser", name]))
  end
end
