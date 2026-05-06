defmodule Rho.Stdlib.Plugins.DocIngest do
  @moduledoc """
  **DEPRECATED.** Prefer `Rho.Stdlib.Plugins.Uploads` for new code.

  `ingest_document` is kept for path-based callers (e.g. the `data_extractor`
  sub-agent) and now delegates to the unified Observer pipeline at
  `Rho.Stdlib.Uploads.parse_one_off/1`. The format-string parameter is
  ignored — file format is detected from the path's extension.

  Plugin that provides a tool for extracting text/data from external
  documents (Excel, PDF, Word) so the agent can create skill frameworks
  from them.
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
            format: [
              type: :string,
              required: false,
              doc: "DEPRECATED — ignored. Format is detected from file extension."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        path = args[:file_path] || args["file_path"]

        cond do
          is_nil(path) or path == "" ->
            {:error, "file_path is required"}

          true ->
            path = Path.expand(path)

            if File.exists?(path) do
              case Rho.Stdlib.Uploads.parse_one_off(path) do
                {:ok, %Rho.Stdlib.Uploads.Observation{} = obs} ->
                  {:ok, format_observation_as_text(obs)}

                {:error, reason} ->
                  {:error, "Ingest failed: #{inspect(reason)}"}
              end
            else
              {:error, "File not found: #{path}"}
            end
        end
      end
    }
  end

  defp format_observation_as_text(%Rho.Stdlib.Uploads.Observation{kind: :structured_table} = obs) do
    sheets_text =
      obs.sheets
      |> Enum.map(fn s ->
        rows_text =
          s.sample_rows
          |> Enum.map(fn r ->
            r
            |> Enum.map_join(" | ", fn {k, v} -> "#{k}: #{v}" end)
          end)
          |> Enum.join("\n")

        "Sheet: #{s.name} (#{s.row_count} rows)\nHeaders: #{Enum.join(s.columns, " | ")}\n#{rows_text}"
      end)
      |> Enum.join("\n\n--- Sheet Break ---\n\n")

    obs.summary_text <> "\n\n" <> sheets_text
  end

  defp format_observation_as_text(%Rho.Stdlib.Uploads.Observation{summary_text: t}), do: t
end
