defmodule Rho.Stdlib.Plugins.DataTable do
  @moduledoc """
  Agent-facing data table tools.

  Row state is owned by `Rho.Stdlib.DataTable.Server` — a per-session
  GenServer. Tools in this plugin are thin wrappers around the
  `Rho.Stdlib.DataTable` client API. They do not publish any legacy UI
  signals: the server publishes its own coarse invalidation events
  via `Rho.Events` as `:data_table` events, which the LiveView
  consumes by refetching snapshots.
  """

  @behaviour Rho.Plugin

  alias Rho.Stdlib.DataTable

  @default_table "main"

  # --- Plugin callbacks ---

  @impl Rho.Plugin
  def tools(mount_opts, %{session_id: session_id}) when is_binary(session_id) do
    # Ensure the server exists so tools that read before any write succeed.
    _ = DataTable.ensure_started(session_id)

    all = [
      describe_table_tool(session_id),
      query_table_tool(session_id),
      list_tables_tool(session_id),
      update_cells_tool(session_id),
      add_rows_tool(session_id),
      delete_rows_tool(session_id),
      replace_all_tool(session_id)
    ]

    mark_deferred(all, mount_opts)
  end

  def tools(_mount_opts, _context), do: []

  defp mark_deferred(tools, mount_opts) do
    case Keyword.get(mount_opts, :deferred) do
      nil ->
        tools

      names when is_list(names) ->
        deferred = MapSet.new(names, &to_string/1)

        Enum.map(tools, fn tool_def ->
          if MapSet.member?(deferred, tool_def.tool.name),
            do: Map.put(tool_def, :deferred, true),
            else: tool_def
        end)
    end
  end

  # --- Tool definitions ---

  defp describe_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "describe_table",
          description: "Data table shape: row count, columns, samples.",
          parameter_schema: [
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table

        case DataTable.summarize_table(session_id, table: table) do
          {:ok, summary} -> {:ok, Jason.encode!(summary)}
          {:error, reason} -> {:error, "describe_table failed: #{inspect(reason)}"}
        end
      end
    }
  end

  defp query_table_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "query_table",
          description: "Read data table rows with filtering.",
          parameter_schema: [
            table: [type: :string, required: false, doc: "default: main"],
            columns: [type: :string, required: false, doc: "comma-separated names"],
            filter_field: [type: :string, required: false],
            filter_value: [type: :string, required: false],
            limit: [type: :string, required: false, doc: "default: 50"],
            offset: [type: :string, required: false, doc: "default: 0"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_query_table(args, session_id)
      end
    }
  end

  defp execute_query_table(args, session_id) do
    table = args[:table] || @default_table
    filter = parse_filter(args)
    columns = parse_columns(args)
    limit = parse_positive_int(args[:limit], 50)
    offset = parse_non_neg_int(args[:offset], 0)

    case DataTable.query_rows(session_id,
           table: table,
           filter: filter,
           columns: columns,
           limit: limit,
           offset: offset
         ) do
      {:ok, result} ->
        result = maybe_elide_complex_columns(result, columns)
        {:ok, Jason.encode!(result)}

      {:error, reason} ->
        {:error, "query_table failed: #{inspect(reason)}"}
    end
  end

  # When no explicit column projection is requested, replace complex (list/map)
  # cell values with a compact type descriptor like "<list<5>>". Callers that
  # genuinely want those fields must ask for them in `columns`.
  defp maybe_elide_complex_columns(%{rows: rows} = result, nil) do
    %{result | rows: Enum.map(rows, &elide_complex_values/1)}
  end

  defp maybe_elide_complex_columns(result, _columns), do: result

  defp elide_complex_values(row) when is_map(row) do
    Map.new(row, fn
      {k, v} when is_list(v) -> {k, "<list<#{length(v)}>>"}
      {k, v} when is_map(v) -> {k, "<map<#{map_size(v)}>>"}
      pair -> pair
    end)
  end

  defp parse_filter(args) do
    case {args[:filter_field], args[:filter_value]} do
      {f, v} when is_binary(f) and is_binary(v) -> %{f => v}
      _ -> nil
    end
  end

  defp parse_columns(args) do
    case args[:columns] do
      s when is_binary(s) and s != "" ->
        s |> String.split(",") |> Enum.map(&String.trim/1)

      _ ->
        nil
    end
  end

  defp parse_positive_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp parse_non_neg_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_non_neg_int(_, default), do: default

  defp list_tables_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "list_tables",
          description: "List data tables with row counts.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args, _ctx ->
        case DataTable.list_tables(session_id) do
          list when is_list(list) ->
            result =
              Enum.map(list, fn entry ->
                %{
                  name: entry.name,
                  row_count: entry.row_count,
                  version: entry.version
                }
              end)

            {:ok, Jason.encode!(result)}

          {:error, reason} ->
            {:error, "list_tables failed: #{inspect(reason)}"}
        end
      end
    }
  end

  defp update_cells_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "update_cells",
          description: "Update data table cells.",
          parameter_schema: [
            changes_json: [type: :string, required: true, doc: "JSON array of {id, field, value}"],
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table
        changes_raw = args[:changes_json] || "[]"

        changes =
          case Jason.decode(changes_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        case DataTable.update_cells(session_id, changes, table: table) do
          :ok ->
            {:ok, "Updated #{length(changes)} cell(s)"}

          {:error, reason} ->
            {:error, "update_cells failed: #{inspect(reason)}"}
        end
      end
    }
  end

  defp add_rows_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "add_rows",
          description: "Add rows to data table.",
          parameter_schema: [
            rows_json: [type: :string, required: true, doc: "JSON row array"],
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table
        rows_raw = args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        if rows == [] do
          {:error, "No valid rows to add. Ensure rows_json is a valid JSON array."}
        else
          case DataTable.add_rows(session_id, rows, table: table) do
            {:ok, inserted} ->
              {:ok, "Added #{length(inserted)} row(s)"}

            {:error, reason} ->
              {:error, "add_rows failed: #{inspect(reason)}"}
          end
        end
      end
    }
  end

  defp delete_rows_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "delete_rows",
          description: "Delete data table rows by ID or filter.",
          parameter_schema: [
            ids_json: [type: :string, doc: "JSON array of row IDs"],
            filter_json: [type: :string, doc: "JSON filter object"],
            table: [type: :string, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_delete_rows(args, session_id)
      end
    }
  end

  defp execute_delete_rows(args, session_id) do
    table = args[:table] || @default_table

    cond do
      args[:ids_json] ->
        delete_by_ids(session_id, args[:ids_json], table)

      args[:filter_json] ->
        delete_by_filter(session_id, args[:filter_json], table)

      true ->
        {:error, "Provide ids_json or filter_json"}
    end
  end

  defp delete_by_ids(session_id, ids_json, table) do
    case Jason.decode(ids_json) do
      {:ok, ids} when is_list(ids) ->
        ids = Enum.map(ids, &to_string/1)

        case DataTable.delete_rows(session_id, ids, table: table) do
          :ok -> {:ok, "Deleted #{length(ids)} row(s)"}
          {:error, reason} -> {:error, "delete_rows failed: #{inspect(reason)}"}
        end

      _ ->
        {:error, "ids_json must be a JSON array"}
    end
  end

  defp delete_by_filter(session_id, filter_json, table) do
    case Jason.decode(filter_json) do
      {:ok, filter} when is_map(filter) and filter != %{} ->
        case DataTable.delete_by_filter(session_id, filter, table: table) do
          {:ok, count} -> {:ok, "Deleted #{count} row(s) by filter"}
          {:error, reason} -> {:error, "delete_by_filter failed: #{inspect(reason)}"}
        end

      _ ->
        {:error, "filter_json must be a non-empty JSON object"}
    end
  end

  defp replace_all_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "replace_all",
          description: "Replace all data table rows.",
          parameter_schema: [
            rows_json: [type: :string, required: true, doc: "JSON row array"],
            table: [type: :string, required: false, doc: "default: main"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        table = args[:table] || @default_table
        rows_raw = args[:rows_json] || "[]"

        rows =
          case Jason.decode(rows_raw) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        case DataTable.replace_all(session_id, rows, table: table) do
          {:ok, inserted} ->
            {:ok, "Replaced table with #{length(inserted)} row(s)"}

          {:error, reason} ->
            {:error, "replace_all failed: #{inspect(reason)}"}
        end
      end
    }
  end
end
