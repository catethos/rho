defmodule Rho.Stdlib.Plugins.DataTable do
  @moduledoc """
  Plugin that provides generic tools for reading and editing a LiveView-managed data table.

  Write operations (add_rows, replace_all, update_cells, delete_rows) stream
  progressively via the signal bus. Read operations (get_table, get_table_summary)
  use direct pid messaging for synchronous request-response.

  Column-specific behaviour (normalization, summaries) is driven by a
  `RhoWeb.DataTable.Schema` when available, with sensible defaults otherwise.
  """

  @behaviour Rho.Plugin

  alias Rho.Comms

  @registry :rho_data_table_registry
  @stream_batch_size 5

  @doc "Register a LiveView pid for a session. Called by SessionCore on connect."
  def register(session_id, pid) do
    ensure_table()
    :ets.insert(@registry, {session_id, pid})
  end

  @doc "Unregister a LiveView pid for a session."
  def unregister(session_id) do
    ensure_table()
    :ets.delete(@registry, session_id)
  end

  @doc "Read rows from the data table for a given session."
  def read_rows(session_id) do
    case with_pid(session_id, fn pid ->
           ref = make_ref()
           send(pid, {:data_table_get_table, {self(), ref}, nil})

           receive do
             {^ref, {:ok, rows}} -> rows
           after
             5_000 -> []
           end
         end) do
      {:error, _} -> []
      nil -> []
      rows -> rows
    end
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
      delete_rows_tool(context),
      replace_all_tool(context)
    ]
  end

  def tools(_mount_opts, _context), do: []

  # --- Tool definitions ---

  defp get_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_table",
          description:
            "Get the current data table contents. Optionally filter by a field name and value. Returns JSON array of rows.",
          parameter_schema: [
            filter_field: [
              type: :string,
              required: false,
              doc: "Field name to filter by"
            ],
            filter_value: [
              type: :string,
              required: false,
              doc: "Value to match"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        with_pid(session_id, fn pid ->
          filter =
            case {args[:filter_field], args[:filter_value]} do
              {f, v} when is_binary(f) and is_binary(v) -> %{f => v}
              _ -> nil
            end

          ref = make_ref()
          send(pid, {:data_table_get_table, {self(), ref}, filter})

          receive do
            {^ref, {:ok, rows}} -> {:ok, Jason.encode!(rows)}
          after
            5_000 -> {:error, "Data table did not respond in time"}
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
            "Get a summary of the data table: row count and field value distributions. Use this before get_table to understand the data without loading all rows.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args, _ctx ->
        with_pid(session_id, fn pid ->
          ref = make_ref()
          send(pid, {:data_table_get_table, {self(), ref}, nil})

          receive do
            {^ref, {:ok, rows}} -> {:ok, Jason.encode!(build_summary(rows))}
          after
            5_000 -> {:error, "Data table did not respond in time"}
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
            "Update specific cells in existing rows. Pass a JSON string of changes array: [{\"id\": 1, \"field\": \"field_name\", \"value\": \"New Value\"}, ...]",
          parameter_schema: [
            changes_json: [
              type: :string,
              required: true,
              doc:
                "JSON string of changes array: [{\"id\": 1, \"field\": \"field_name\", \"value\": \"New Value\"}]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        changes_raw = args[:changes_json] || "[]"

        changes =
          case Jason.decode(changes_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_event(session_id, agent_id, :update_cells, %{changes: changes})
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
            "Add new rows to the data table. Pass a JSON string of row objects. Do NOT include 'id' — it is assigned automatically.",
          parameter_schema: [
            rows_json: [
              type: :string,
              required: true,
              doc: "JSON string of row array"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        rows_raw = args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> list
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
              doc: "JSON string of ID array, e.g. [1, 2, 3]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        ids_raw = args[:ids_json] || "[]"

        ids =
          case Jason.decode(ids_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_event(session_id, agent_id, :delete_rows, %{ids: ids})
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
            "Replace the entire data table with new data. Use for full regeneration. Do NOT include 'id'. Pass a JSON string of row objects.",
          parameter_schema: [
            rows_json: [
              type: :string,
              required: true,
              doc: "JSON string of the complete new dataset array"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        rows_raw = args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        publish_event(session_id, agent_id, :replace_all, %{})
        stream_rows_progressive(rows, :add, session_id, agent_id)
        {:ok, "Replaced table with #{length(rows)} row(s)"}
      end
    }
  end

  # --- Signal bus publishing (progressive streaming) ---

  @doc "Stream rows progressively to the data table via the signal bus."
  def stream_rows_progressive(rows, op, session_id, agent_id) do
    rows = Enum.map(rows, fn row -> Map.put_new(row, :row_id, generate_row_id()) end)
    batches = Enum.chunk_every(rows, @stream_batch_size)

    batches
    |> Enum.with_index()
    |> Enum.each(fn {batch, idx} ->
      if idx > 0, do: Process.sleep(30)

      publish_event(session_id, agent_id, :rows_delta, %{
        rows: batch,
        op: op
      })
    end)
  end

  @doc "Publish a data table event to the signal bus."
  def publish_event(session_id, agent_id, event_type, payload) do
    topic = "rho.session.#{session_id}.events.data_table_#{event_type}"
    source = "/session/#{session_id}/agent/#{agent_id}"

    Comms.publish(
      topic,
      Map.merge(payload, %{session_id: session_id, agent_id: agent_id}),
      source: source
    )
  end

  defp generate_row_id do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>> |> Base.encode16(case: :lower)
  end

  # --- Helpers ---

  @doc false
  def with_pid(session_id, fun) do
    ensure_table()

    case :ets.lookup(@registry, session_id) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: fun.(pid), else: {:error, "Data table not connected"}

      _ ->
        {:error, "Data table not connected"}
    end
  end

  defp build_summary(rows) do
    fields =
      case rows do
        [first | _] ->
          first
          |> Map.keys()
          |> Enum.reject(&(&1 in [:id, :sort_order, "id", "sort_order"]))

        _ ->
          []
      end

    field_stats =
      Enum.map(fields, fn field ->
        values = Enum.map(rows, &Map.get(&1, field))
        unique = Enum.uniq(values)
        %{field: field, unique_count: length(unique), sample: Enum.take(unique, 10)}
      end)

    %{
      total_rows: length(rows),
      fields: field_stats
    }
  end
end
