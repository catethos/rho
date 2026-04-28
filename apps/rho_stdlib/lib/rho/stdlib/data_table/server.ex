defmodule Rho.Stdlib.DataTable.Server do
  @moduledoc """
  Per-session GenServer that owns all tables for a single session.

  Tools and the LiveView call into this server synchronously via
  `GenServer.call`. After each mutation the server publishes a coarse
  invalidation event via `Rho.Events`; subscribers respond by re-fetching
  snapshots.

  The server uses `restart: :temporary` — if it crashes it stays down
  with a clear `{:error, :not_running}` rather than silently restarting
  with empty state.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Rho.Stdlib.DataTable.Schema
  alias Rho.Stdlib.DataTable.Table

  # --- Child spec / start ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @doc "Registry-backed name for a server by session id."
  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {Rho.Stdlib.DataTable.Registry, session_id}}
  end

  @doc "Look up the pid for a session's server. Returns nil if not running."
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(Rho.Stdlib.DataTable.Registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Legacy topic string. DataTable events now flow via `Rho.Events`."
  def topic(session_id) when is_binary(session_id) do
    "rho.session.#{session_id}.events.data_table"
  end

  # --- Init ---

  @impl true
  def init(session_id) do
    Process.flag(:trap_exit, true)
    main = Table.new("main", Schema.dynamic("main"))

    state = %{
      session_id: session_id,
      tables: %{"main" => main},
      table_order: ["main"]
    }

    Logger.debug(fn -> "[DataTable.Server] init session=#{session_id}" end)

    # Announce that "main" exists so subscribers hitting ensure_started
    # slightly after us still see a fresh state.
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    sid = Map.get(state, :session_id, "?")
    tables = Map.keys(Map.get(state, :tables, %{}))

    Logger.warning(fn ->
      "[DataTable.Server] TERMINATE session=#{sid} reason=#{inspect(reason, limit: :infinity)} " <>
        "tables=#{inspect(tables)}"
    end)

    :ok
  end

  # --- Table management ---

  @impl true
  def handle_call({:list_tables}, _from, state) do
    list =
      Enum.map(state.table_order, fn name ->
        table = Map.fetch!(state.tables, name)

        %{
          name: table.name,
          schema: table.schema,
          row_count: Table.row_count(table),
          version: table.version
        }
      end)

    {:reply, list, state}
  end

  def handle_call({:session_snapshot}, _from, state) do
    tables =
      Enum.map(state.table_order, fn name ->
        table = Map.fetch!(state.tables, name)

        %{
          name: table.name,
          schema: table.schema,
          row_count: Table.row_count(table),
          version: table.version
        }
      end)

    {:reply, %{tables: tables, table_order: state.table_order}, state}
  end

  def handle_call({:table_snapshot, name}, _from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, table} -> {:reply, {:ok, Table.snapshot(table)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:summarize, name}, _from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, table} -> {:reply, {:ok, Table.summarize(table)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_schema, name}, _from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, table} -> {:reply, {:ok, table.schema}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:create_table, name, schema}, from, state) do
    cond do
      Map.has_key?(state.tables, name) ->
        {:reply, {:error, :already_exists}, state}

      not match?(%Schema{}, schema) ->
        {:reply, {:error, :invalid_schema}, state}

      true ->
        table = Table.new(name, schema)

        new_state = %{
          state
          | tables: Map.put(state.tables, name, table),
            table_order: state.table_order ++ [name]
        }

        publish(
          state.session_id,
          %{event: :table_created, table_name: name, version: table.version},
          caller_source(from)
        )

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:ensure_table, name, schema}, from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, %Table{schema: existing}} ->
        if schemas_compatible?(existing, schema) do
          Logger.debug(fn ->
            "[DataTable.Server] ensure_table session=#{state.session_id} " <>
              "table=#{inspect(name)} (already exists, compatible)"
          end)

          {:reply, :ok, state}
        else
          Logger.warning(fn ->
            "[DataTable.Server] ensure_table SCHEMA_MISMATCH session=#{state.session_id} " <>
              "table=#{inspect(name)} existing=#{inspect(existing.mode)}/#{inspect(Schema.column_names(existing))} " <>
              "incoming=#{inspect(schema.mode)}/#{inspect(Schema.column_names(schema))}"
          end)

          {:reply, {:error, :schema_mismatch}, state}
        end

      :error ->
        table = Table.new(name, schema)

        new_state = %{
          state
          | tables: Map.put(state.tables, name, table),
            table_order: state.table_order ++ [name]
        }

        Logger.debug(fn ->
          "[DataTable.Server] ensure_table session=#{state.session_id} " <>
            "table=#{inspect(name)} (created); existing_tables=#{inspect(state.table_order)}"
        end)

        publish(
          state.session_id,
          %{event: :table_created, table_name: name, version: table.version},
          caller_source(from)
        )

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:drop_table, name}, from, state) do
    case Map.fetch(state.tables, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, _} ->
        new_state = %{
          state
          | tables: Map.delete(state.tables, name),
            table_order: List.delete(state.table_order, name)
        }

        publish(
          state.session_id,
          %{event: :table_removed, table_name: name},
          caller_source(from)
        )

        {:reply, :ok, new_state}
    end
  end

  # --- Row operations ---

  def handle_call({:add_rows, name, rows}, from, state) do
    Logger.debug(fn ->
      "[DataTable.Server] add_rows session=#{state.session_id} table=#{inspect(name)} " <>
        "row_count=#{length(rows)} known_tables=#{inspect(Map.keys(state.tables))}"
    end)

    with_table(state, name, caller_source(from), fn table ->
      case Table.add_rows(table, rows, &generate_row_id/0) do
        {:ok, updated, inserted} -> {:ok, updated, {:ok, inserted}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def handle_call({:get_rows, name, filter}, _from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, table} -> {:reply, {:ok, Table.filter_rows(table, filter)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:query_rows, name, filter, columns, limit, offset}, _from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, table} ->
        result =
          Table.query_rows(table,
            filter: filter,
            columns: columns,
            limit: limit,
            offset: offset
          )

        {:reply, {:ok, result}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update_cells, name, changes}, from, state) do
    with_table(state, name, caller_source(from), fn table ->
      case Table.update_cells(table, changes) do
        {:ok, updated} -> {:ok, updated, :ok}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def handle_call({:delete_rows, name, ids}, from, state) do
    with_table(state, name, caller_source(from), fn table ->
      {:ok, updated} = Table.delete_rows(table, ids)
      {:ok, updated, :ok}
    end)
  end

  def handle_call({:delete_by_filter, name, filter}, from, state) do
    with_table(state, name, caller_source(from), fn table ->
      {:ok, updated, deleted_count} = Table.delete_by_filter(table, filter)
      {:ok, updated, {:ok, deleted_count}}
    end)
  end

  def handle_call({:replace_all, name, rows}, from, state) do
    with_table(state, name, caller_source(from), fn table ->
      case Table.replace_all(table, rows, &generate_row_id/0) do
        {:ok, updated, inserted} -> {:ok, updated, {:ok, inserted}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # --- Internal ---

  defp with_table(state, name, source, fun) do
    case Map.fetch(state.tables, name) do
      :error ->
        Logger.warning(fn ->
          "[DataTable.Server] with_table NOT_FOUND session=#{state.session_id} " <>
            "table=#{inspect(name)} known=#{inspect(Map.keys(state.tables))}"
        end)

        {:reply, {:error, :not_found}, state}

      {:ok, table} ->
        case fun.(table) do
          {:ok, updated_table, reply} ->
            new_tables = Map.put(state.tables, name, updated_table)
            new_state = %{state | tables: new_tables}

            publish(
              state.session_id,
              %{
                event: :table_changed,
                table_name: name,
                version: updated_table.version
              },
              source
            )

            {:reply, reply, new_state}

          {:error, reason} ->
            Logger.debug(fn ->
              "[DataTable.Server] with_table fun returned error session=#{state.session_id} " <>
                "table=#{inspect(name)} reason=#{inspect(reason)}"
            end)

            {:reply, {:error, reason}, state}
        end
    end
  end

  # Publish must never crash the server. A subscriber raising or a
  # malformed event would otherwise tear down all session table state
  # (we run :temporary), which previously surfaced as
  # `{:error, :not_running}` on the next call. Catch + log instead.
  defp publish(session_id, payload, source) do
    event = %Rho.Events.Event{
      kind: :data_table,
      session_id: session_id,
      agent_id: nil,
      timestamp: System.monotonic_time(:millisecond),
      data: payload,
      source: source
    }

    try do
      Rho.Events.broadcast(session_id, event)
    catch
      kind, reason ->
        Logger.error(fn ->
          "[DataTable.Server] publish RAISED session=#{session_id} " <>
            "kind=#{inspect(kind)} reason=#{inspect(reason, limit: 100)} " <>
            "payload=#{inspect(payload, limit: 100)}"
        end)

        :ok
    end
  end

  # Read the caller process's `:rho_source` from its process dictionary,
  # so framework mutations carry provenance (`:user | :flow | :agent`)
  # without changing the public DataTable API. Defaults to `nil` for
  # callers that haven't opted in (generic agents, tests, etc.).
  defp caller_source({pid, _ref}) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :rho_source)
      _ -> nil
    end
  end

  defp caller_source(_), do: nil

  defp schemas_compatible?(%Schema{} = a, %Schema{} = b) do
    a.mode == b.mode and Schema.column_names(a) == Schema.column_names(b) and
      a.children_key == b.children_key and
      Schema.child_column_names(a) == Schema.child_column_names(b)
  end

  defp schemas_compatible?(_, _), do: false

  @doc false
  def generate_row_id do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>> |> Base.encode16(case: :lower)
  end
end
