defmodule Rho.Stdlib.Plugins.Spreadsheet do
  @moduledoc """
  Mount that provides tools for reading and editing a LiveView-managed spreadsheet.

  Write operations (add_rows, replace_all, update_cells, delete_rows) stream
  progressively via the signal bus — the same pattern as LiveRender's `present_ui`.
  Read operations (get_table, get_table_summary) use direct pid messaging for
  synchronous request-response.
  """

  @behaviour Rho.Plugin

  alias Rho.Comms

  @registry :rho_spreadsheet_registry
  @stream_batch_size 5

  @doc "Register a LiveView pid for a session. Called by SpreadsheetLive on connect."
  def register(session_id, pid) do
    ensure_table()
    :ets.insert(@registry, {session_id, pid})
  end

  @doc "Unregister a LiveView pid for a session."
  def unregister(session_id) do
    ensure_table()
    :ets.delete(@registry, session_id)
  end

  defp ensure_table do
    if :ets.whereis(@registry) == :undefined do
      :ets.new(@registry, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  @impl Rho.Plugin
  def tools(_mount_opts, %{session_id: session_id} = context) do
    [
      get_table_tool(session_id),
      get_table_summary_tool(session_id),
      update_cells_tool(context),
      add_rows_tool(context),
      add_proficiency_levels_tool(session_id, context),
      delete_rows_tool(context),
      replace_all_tool(context)
    ]
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Plugin
  def prompt_sections(_mount_opts, _context) do
    [
      """
      # Spreadsheet Editor Context

      You have a spreadsheet with columns:
      id, category, cluster, skill_name, skill_description, level, level_name, level_description.

      Each row represents one proficiency level for one skill. A skill with 5 proficiency levels
      has 5 rows (sharing the same category, cluster, skill_name, skill_description).

      ## Tool Reference
      - `get_table_summary`: Check current state before any changes
      - `get_table`: Read rows, optionally filtered by field/value
      - `add_rows`: Add new rows (pass rows_json — do NOT include "id")
      - `update_cells`: Edit specific cells by row ID
      - `delete_rows`: Remove rows by ID array
      - `replace_all`: Replace the entire table

      ## Row Format
      When adding skeleton rows (Phase 2), use level=0 and level_description="⏳ Pending...":
      {"category": "...", "cluster": "...", "skill_name": "...", "skill_description": "...", "level": 0, "level_name": "", "level_description": "⏳ Pending..."}

      When adding proficiency level rows (Phase 3), use level=1-5 with full descriptions.
      """
    ]
  end

  # --- Tool definitions ---

  defp get_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_table",
          description:
            "Get the current spreadsheet data. Optionally filter by a field name and value. Returns JSON array of rows.",
          parameter_schema: [
            filter_field: [
              type: :string,
              required: false,
              doc: "Field name to filter by, e.g. \"category\""
            ],
            filter_value: [
              type: :string,
              required: false,
              doc: "Value to match, e.g. \"Leadership\""
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        with_pid(session_id, fn pid ->
          filter =
            case {args["filter_field"], args["filter_value"]} do
              {f, v} when is_binary(f) and is_binary(v) -> %{f => v}
              _ -> nil
            end

          ref = make_ref()
          send(pid, {:spreadsheet_get_table, {self(), ref}, filter})

          receive do
            {^ref, {:ok, rows}} -> {:ok, Jason.encode!(rows)}
          after
            5_000 -> {:error, "Spreadsheet did not respond in time"}
          end
        end)
      end
    }
  end

  defp get_table_summary_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_table_summary",
          description:
            "Get a summary of the spreadsheet: row count, categories, clusters, and skill counts. Use this before get_table to understand the data without loading all rows.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        with_pid(session_id, fn pid ->
          ref = make_ref()
          send(pid, {:spreadsheet_get_table, {self(), ref}, nil})

          receive do
            {^ref, {:ok, rows}} -> {:ok, Jason.encode!(build_summary(rows))}
          after
            5_000 -> {:error, "Spreadsheet did not respond in time"}
          end
        end)
      end
    }
  end

  defp update_cells_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "update_cells",
          description:
            "Update specific cells in existing rows. Pass a JSON string of changes array: [{\"id\": 1, \"field\": \"skill_name\", \"value\": \"New Name\"}, ...]",
          parameter_schema: [
            changes_json: [
              type: :string,
              required: true,
              doc:
                "JSON string of changes array: [{\"id\": 1, \"field\": \"skill_name\", \"value\": \"New Name\"}]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        changes_raw = args["changes_json"] || args[:changes_json] || "[]"

        changes =
          case Jason.decode(changes_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_spreadsheet_event(session_id, agent_id, :update_cells, %{changes: changes})
        {:ok, "Updated #{length(changes)} cell(s)"}
      end
    }
  end

  defp add_rows_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "add_rows",
          description:
            "Add new rows to the spreadsheet. Pass a JSON string of row objects. Do NOT include 'id' — it is assigned automatically. Fields: category, cluster, skill_name, skill_description, level (integer), level_name, level_description.",
          parameter_schema: [
            rows_json: [
              type: :string,
              required: true,
              doc:
                "JSON string of row array, e.g. [{\"category\":\"Leadership\",\"cluster\":\"Strategy\",\"skill_name\":\"Vision\",\"skill_description\":\"...\",\"level\":1,\"level_name\":\"Foundational\",\"level_description\":\"...\"}]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        rows_raw = args["rows_json"] || args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> Enum.map(list, &normalize_row/1)
            _ -> []
          end

        if rows == [] do
          {:error, "No valid rows to add. Ensure rows_json is a valid JSON array."}
        else
          stream_rows_progressive(rows, :add, session_id, agent_id)
          {:ok, "Added #{length(rows)} row(s)"}
        end
      end
    }
  end

  defp add_proficiency_levels_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "add_proficiency_levels",
          description:
            "Add proficiency levels for skills. Each entry needs skill_name, category, cluster, skill_description, and a levels array. More token-efficient than add_rows when generating proficiency levels.",
          parameter_schema: [
            levels_json: [
              type: :string,
              required: true,
              doc:
                ~s(JSON string: [{"skill_name":"SQL","category":"Data","cluster":"Wrangling","skill_description":"...","levels":[{"level":1,"level_name":"Novice","level_description":"..."},...]},...]  )
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["levels_json"] || args[:levels_json] || "[]"

        skills =
          case Jason.decode(raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        if skills == [] do
          {:error, "No valid data. Ensure levels_json is a valid JSON array."}
        else
          rows =
            Enum.flat_map(skills, fn skill_entry ->
              skill_name = skill_entry["skill_name"] || ""
              category = skill_entry["category"] || ""
              cluster = skill_entry["cluster"] || ""
              skill_desc = skill_entry["skill_description"] || ""
              levels = skill_entry["levels"] || []

              Enum.map(levels, fn lvl ->
                %{
                  category: category,
                  cluster: cluster,
                  skill_name: skill_name,
                  skill_description: skill_desc,
                  level: lvl["level"] || 1,
                  level_name: lvl["level_name"] || "",
                  level_description: lvl["level_description"] || ""
                }
              end)
            end)

          if rows == [] do
            {:error, "No levels to add."}
          else
            stream_rows_progressive(rows, :add, session_id, agent_id)
            {:ok, "Added #{length(rows)} proficiency level(s) for #{length(skills)} skill(s)"}
          end
        end
      end
    }
  end

  defp delete_rows_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "delete_rows",
          description: "Delete rows by their IDs.",
          parameter_schema: [
            ids_json: [
              type: :string,
              required: true,
              doc: "JSON string of integer ID array, e.g. [1, 2, 3]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        ids_raw = args["ids_json"] || args[:ids_json] || "[]"

        ids =
          case Jason.decode(ids_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_spreadsheet_event(session_id, agent_id, :delete_rows, %{ids: ids})
        {:ok, "Deleted #{length(ids)} row(s)"}
      end
    }
  end

  defp replace_all_tool(context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "replace_all",
          description:
            "Replace the entire spreadsheet with new data. Use for full regeneration. Do NOT include 'id'. Pass a JSON string of row objects.",
          parameter_schema: [
            rows_json: [
              type: :string,
              required: true,
              doc: "JSON string of the complete new dataset array"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        rows_raw = args["rows_json"] || args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> Enum.map(list, &normalize_row/1)
            _ -> []
          end

        # Clear table first, then stream rows progressively
        publish_spreadsheet_event(session_id, agent_id, :replace_all, %{})
        stream_rows_progressive(rows, :add, session_id, agent_id)
        {:ok, "Replaced table with #{length(rows)} row(s)"}
      end
    }
  end

  # --- Signal bus publishing (progressive streaming) ---

  defp stream_rows_progressive(rows, op, session_id, agent_id) do
    batches = Enum.chunk_every(rows, @stream_batch_size)

    batches
    |> Enum.with_index()
    |> Enum.each(fn {batch, idx} ->
      if idx > 0, do: Process.sleep(30)

      publish_spreadsheet_event(session_id, agent_id, :rows_delta, %{
        rows: batch,
        op: op
      })
    end)
  end

  defp publish_spreadsheet_event(session_id, agent_id, event_type, payload) do
    topic = "rho.session.#{session_id}.events.spreadsheet_#{event_type}"
    source = "/session/#{session_id}/agent/#{agent_id}"

    Comms.publish(
      topic,
      Map.merge(payload, %{session_id: session_id, agent_id: agent_id}),
      source: source
    )
  end

  # --- Helpers ---

  defp with_pid(session_id, fun) do
    ensure_table()

    case :ets.lookup(@registry, session_id) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: fun.(pid), else: {:error, "Spreadsheet not connected"}

      _ ->
        {:error, "Spreadsheet not connected"}
    end
  end

  defp normalize_row(row) when is_map(row) do
    %{
      category: row["category"] || row[:category] || "",
      cluster: row["cluster"] || row[:cluster] || "",
      skill_name: row["skill_name"] || row[:skill_name] || "",
      skill_description: row["skill_description"] || row[:skill_description] || "",
      level: row["level"] || row[:level] || 1,
      level_name: row["level_name"] || row[:level_name] || "",
      level_description: row["level_description"] || row[:level_description] || ""
    }
  end

  defp build_summary(rows) do
    categories =
      rows
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, cat_rows} ->
        clusters =
          cat_rows
          |> Enum.group_by(& &1.cluster)
          |> Enum.map(fn {cluster, cluster_rows} ->
            skills = cluster_rows |> Enum.map(& &1.skill_name) |> Enum.uniq()
            %{cluster: cluster, skill_count: length(skills), skills: skills}
          end)

        %{category: cat, cluster_count: length(clusters), clusters: clusters}
      end)

    %{
      total_rows: length(rows),
      total_categories: length(categories),
      total_skills: rows |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length(),
      categories: categories
    }
  end
end
