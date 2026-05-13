defmodule Rho.Stdlib.Uploads.Observer do
  @moduledoc """
  Layer 2 — opens a `Handle{}` and returns a uniform `%Observation{}`.
  Caches the result on the handle via `Server.put_observation/3` so
  subsequent calls return the cached value without re-parsing.

  Per-extension routing in `parse_path/1` (used by `Uploads.parse_one_off/1`).
  Session-aware routing in `observe/2` (used by `Uploads.Plugin` tools).

  See `docs/superpowers/specs/2026-05-06-file-upload-design.md` §5.2.

  ## Concurrency

  `observe/2` runs the parse in the calling process. The first successful
  parse is cached on the handle via `Server.put_observation/3`; subsequent
  calls short-circuit to the cached observation. Concurrent first-time
  callers may parse in parallel — acceptable for v1 (cache hits within ms
  collapse the second through Nth caller). If duplicate parses appear in
  telemetry, move the parse inside `Server.handle_call/3` for strict
  serialization. See spec §5.2.
  """

  alias Rho.Stdlib.Uploads
  alias Rho.Stdlib.Uploads.Handle
  alias Rho.Stdlib.Uploads.Observation
  alias Rho.Stdlib.Uploads.Observer.{Csv, Excel, Hints, Image, Prose}
  alias Rho.Stdlib.Uploads.Server

  @parse_timeout_ms 15_000

  # --- Public API ---

  @spec observe(String.t(), String.t()) :: {:ok, Observation.t()} | {:error, term()}
  def observe(session_id, upload_id) do
    case Uploads.get(session_id, upload_id) do
      {:ok, %Handle{observation: %Observation{} = cached}} ->
        {:ok, cached}

      {:ok, %Handle{} = h} ->
        case run_with_timeout(fn -> parse_path(h.path, filename: h.filename) end) do
          {:ok, obs} ->
            :ok = Server.put_observation(session_id, upload_id, obs)
            {:ok, obs}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @spec read_sheet(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, %{columns: [String.t()], rows: [map()], total: non_neg_integer()}}
          | {:error, term()}
  def read_sheet(session_id, upload_id, sheet, opts \\ []) do
    case Uploads.get(session_id, upload_id) do
      {:ok, %Handle{} = h} -> dispatch_read(h, sheet, opts)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Parse a path directly (no session). Used by `Uploads.parse_one_off/1`
  and `DocIngest`. Caller owns the file — we only read.
  """
  @spec parse_path(String.t(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def parse_path(path, opts \\ []) do
    filename = Keyword.get(opts, :filename, Path.basename(path))
    do_parse(path, filename, kind_for_path(path))
  end

  # --- Routing ---

  @type upload_kind ::
          :structured_table
          | :pdf
          | :prose_text
          | :docx
          | :image
          | :unsupported

  @doc """
  Classify an upload path by extension using the product-level upload kinds.
  """
  @spec kind_for_path(String.t()) :: upload_kind()
  def kind_for_path(path) do
    case Path.extname(path) |> String.downcase() do
      ".xlsx" -> :structured_table
      ".csv" -> :structured_table
      ".pdf" -> :pdf
      ext when ext in [".txt", ".md", ".markdown", ".html", ".htm"] -> :prose_text
      ".docx" -> :docx
      ext when ext in [".jpg", ".jpeg", ".png", ".webp"] -> :image
      _ -> :unsupported
    end
  end

  @doc """
  Returns true when the LiveView send path should parse an upload before
  submitting the chat message.
  """
  @spec parse_now?(String.t()) :: boolean()
  def parse_now?(path) do
    kind_for_path(path) in [:structured_table, :prose_text]
  end

  defp parser_for_table(path) do
    case Path.extname(path) |> String.downcase() do
      ".xlsx" -> :excel
      ".csv" -> :csv
      _ -> :unsupported
    end
  end

  defp do_parse(_path, filename, :unsupported) do
    {:ok,
     %Observation{
       kind: :unsupported,
       summary_text: "[Uploaded: #{filename}] Unsupported file type."
     }}
  end

  defp do_parse(_path, filename, :pdf) do
    {:ok,
     %Observation{
       kind: :pdf,
       summary_text:
         "[Uploaded: #{filename}]\nPDF uploaded. Use upload_id with extract_role_from_jd for JD extraction."
     }}
  end

  defp do_parse(_path, filename, :docx) do
    {:ok,
     %Observation{
       kind: :docx,
       summary_text: "[Uploaded: #{filename}]\nDOCX uploaded. Text preview is not extracted yet."
     }}
  end

  defp do_parse(path, filename, :prose_text) do
    case Path.extname(path) |> String.downcase() do
      ext when ext in [".html", ".htm"] -> Prose.parse_html(path, filename)
      _ -> Prose.parse_text(path, filename)
    end
  end

  defp do_parse(path, filename, :image) do
    case Image.parse(path) do
      {:ok, sheets} ->
        {:ok,
         %Observation{
           kind: :image,
           sheets: sheets,
           summary_text: "[Uploaded: #{filename}] Image — passthrough only in v1."
         }}

      err ->
        err
    end
  end

  defp do_parse(path, filename, :structured_table) do
    case parser_for_table(path) do
      :excel -> tabular_observation(filename, Excel.parse(path))
      :csv -> tabular_observation(filename, Csv.parse(path))
      :unsupported -> do_parse(path, filename, :unsupported)
    end
  end

  defp tabular_observation(_filename, {:error, _} = err), do: err

  defp tabular_observation(filename, {:ok, sheets}) do
    hints = Hints.from_sheets(sheets)
    warnings = warnings_for(sheets, hints)

    {:ok,
     %Observation{
       kind: :structured_table,
       sheets: sheets,
       hints: hints,
       warnings: warnings,
       summary_text: build_summary(filename, sheets, hints)
     }}
  end

  defp dispatch_read(%Handle{path: path}, sheet, opts) do
    case kind_for_path(path) do
      :structured_table ->
        case parser_for_table(path) do
          :excel -> Excel.read_sheet(path, sheet, opts)
          :csv -> Csv.read_sheet(path, sheet, opts)
          :unsupported -> {:error, :unsupported}
        end

      :pdf ->
        {:error, :not_a_table}

      :prose_text ->
        {:error, :not_a_table}

      :docx ->
        {:error, :not_a_table}

      :image ->
        {:error, :not_a_table}

      :unsupported ->
        {:error, :unsupported}
    end
  end

  # --- Warnings + summary text ---

  defp warnings_for(sheets, hints) do
    []
    |> maybe_warn(hints.skill_name_column == nil, "No skill name column found — required.")
    |> append_empty_sheet_warnings(sheets)
    |> maybe_warn(
      hints.sheet_strategy == :roles_per_sheet,
      "Multi-sheet file with no library name column — sheet names look like roles. v1 imports one library per file (see import error for next steps)."
    )
    |> maybe_warn(
      hints.sheet_strategy == :ambiguous,
      "Sheet structures are inconsistent — explicit library_name and role_strategy required."
    )
  end

  defp maybe_warn(list, true, msg), do: list ++ [msg]
  defp maybe_warn(list, false, _msg), do: list

  defp append_empty_sheet_warnings(list, sheets) do
    sheets
    |> Enum.filter(&(&1.row_count == 0))
    |> Enum.reduce(list, fn s, acc -> acc ++ ["Sheet '#{s.name}' has no rows."] end)
  end

  defp build_summary(filename, sheets, hints) do
    sheet_phrase =
      case sheets do
        [s] ->
          "1 sheet \"#{s.name}\", #{s.row_count} rows"

        many ->
          "#{length(many)} sheets (#{Enum.map_join(many, ", ", & &1.name)}), ~#{avg_rows(many)} rows each"
      end

    cols_phrase =
      sheets
      |> List.first()
      |> case do
        nil -> ""
        %{columns: cols} -> "Columns: #{Enum.join(cols, ", ")}."
      end

    detected =
      case hints.sheet_strategy do
        :single_library when hints.library_name_column != nil ->
          "Detected: single library (from #{hints.library_name_column} column)."

        :single_library ->
          "Detected: single library (no library-name column — will use filename as default)."

        :roles_per_sheet ->
          "Detected: roles per sheet (sheet name = role). v1 supports one library per file — see import error for next steps."

        :ambiguous ->
          "Detected: ambiguous shape — caller must supply library_name and role_strategy explicitly."
      end

    "[Uploaded: #{filename}]\n#{sheet_phrase}. #{cols_phrase}\n#{detected}"
  end

  defp avg_rows(sheets) do
    sum = Enum.reduce(sheets, 0, fn s, acc -> acc + s.row_count end)
    div(sum, length(sheets))
  end

  # --- Timeout wrapper ---

  defp run_with_timeout(fun) do
    task = Task.async(fun)

    case Task.yield(task, @parse_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :parse_timeout}
      {:exit, reason} -> {:error, {:parse_crashed, reason}}
    end
  end
end
