defmodule Rho.Stdlib.Plugins.Uploads do
  @moduledoc """
  Plugin exposing per-session uploaded files to the agent: list, observe,
  and paginated read. No domain logic here — that's
  `RhoFrameworks.Tools.WorkflowTools.import_library_from_upload`.

  See spec §6.1.
  """

  @behaviour Rho.Plugin

  alias Rho.Stdlib.Uploads
  alias Rho.Stdlib.Uploads.Observer

  @impl Rho.Plugin
  def tools(_opts, ctx) do
    sid = ctx[:session_id]

    [
      list_uploads_tool(sid),
      observe_upload_tool(sid),
      read_upload_tool(sid)
    ]
  end

  defp list_uploads_tool(sid) do
    %{
      tool:
        ReqLLM.tool(
          name: "list_uploads",
          description: "List files uploaded by the user in this session.",
          parameter_schema: [],
          callback: fn _ -> :ok end
        ),
      execute: fn _args, _ctx ->
        case Uploads.list(sid) do
          [] -> {:ok, "No uploads in this session."}
          handles -> {:ok, render_list(handles)}
        end
      end
    }
  end

  defp observe_upload_tool(sid) do
    %{
      tool:
        ReqLLM.tool(
          name: "observe_upload",
          description:
            "Get a structured summary of an uploaded file: sheets, columns, sample rows, detected hints.",
          parameter_schema: [
            upload_id: [type: :string, required: true, doc: "Upload handle id (upl_...)"]
          ],
          callback: fn _ -> :ok end
        ),
      execute: fn args, _ctx ->
        id = args[:upload_id] || args["upload_id"]

        case Observer.observe(sid, id) do
          {:ok, obs} -> {:ok, render_observation(obs)}
          {:error, reason} -> {:error, "observe_upload failed: #{inspect(reason)}"}
        end
      end
    }
  end

  defp read_upload_tool(sid) do
    %{
      tool:
        ReqLLM.tool(
          name: "read_upload",
          description:
            "Read rows from an uploaded structured file (Excel/CSV). Defaults: first 200 rows of first sheet.",
          parameter_schema: [
            upload_id: [type: :string, required: true],
            sheet: [type: :string, doc: "Sheet name (Excel only). Defaults to first sheet."],
            offset: [type: :integer, doc: "0-based row offset. Default 0."],
            limit: [type: :integer, doc: "Max rows. Default 200, max 1000."]
          ],
          callback: fn _ -> :ok end
        ),
      execute: fn args, _ctx ->
        id = args[:upload_id] || args["upload_id"]
        sheet = args[:sheet] || args["sheet"]

        opts = [
          offset: args[:offset] || args["offset"] || 0,
          limit: args[:limit] || args["limit"] || 200
        ]

        case Observer.read_sheet(sid, id, sheet, opts) do
          {:ok, page} -> {:ok, Jason.encode!(page)}
          {:error, reason} -> {:error, "read_upload failed: #{inspect(reason)}"}
        end
      end
    }
  end

  # --- Renderers ---

  defp render_list(handles) do
    handles
    |> Enum.map(fn h ->
      "- #{h.filename} (#{h.id}, #{format_bytes(h.size)})"
    end)
    |> Enum.join("\n")
  end

  defp render_observation(obs) do
    """
    #{obs.summary_text}

    kind: #{obs.kind}
    sheet_strategy: #{obs.hints[:sheet_strategy]}
    warnings: #{Enum.join(obs.warnings, "; ")}
    """
  end

  defp format_bytes(n) when n < 1024, do: "#{n}B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{div(n, 1024)}KB"
  defp format_bytes(n), do: "#{div(n, 1024 * 1024)}MB"
end
