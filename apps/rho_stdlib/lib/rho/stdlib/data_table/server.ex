defmodule Rho.Stdlib.DataTable.Server do
  @moduledoc """
  Per-session GenServer that owns all tables for a single session.

  Tools and the LiveView call into this server synchronously via
  `GenServer.call`. After each mutation the server publishes a coarse
  invalidation event to `Rho.Comms`; subscribers respond by re-fetching
  snapshots.

  The server uses `restart: :temporary` — if it crashes it stays down
  with a clear `{:error, :not_running}` rather than silently restarting
  with empty state.
  """

  use GenServer, restart: :temporary

  alias Rho.Comms
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

  @doc "Topic used for coarse invalidation events via `Rho.Comms`."
  def topic(session_id) when is_binary(session_id) do
    "rho.session.#{session_id}.events.data_table"
  end

  # --- Init ---

  @impl true
  def init(session_id) do
    main = Table.new("main", Schema.dynamic("main"))

    state = %{
      session_id: session_id,
      tables: %{"main" => main},
      table_order: ["main"]
    }

    # Announce that "main" exists so subscribers hitting ensure_started
    # slightly after us still see a fresh state.
    {:ok, state}
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

  def handle_call({:create_table, name, schema}, _from, state) do
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

        publish(state.session_id, %{
          event: :table_created,
          table_name: name,
          version: table.version
        })

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:ensure_table, name, schema}, _from, state) do
    case Map.fetch(state.tables, name) do
      {:ok, %Table{schema: existing}} ->
        if schemas_compatible?(existing, schema) do
          {:reply, :ok, state}
        else
          {:reply, {:error, :schema_mismatch}, state}
        end

      :error ->
        table = Table.new(name, schema)

        new_state = %{
          state
          | tables: Map.put(state.tables, name, table),
            table_order: state.table_order ++ [name]
        }

        publish(state.session_id, %{
          event: :table_created,
          table_name: name,
          version: table.version
        })

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:drop_table, name}, _from, state) do
    case Map.fetch(state.tables, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, _} ->
        new_state = %{
          state
          | tables: Map.delete(state.tables, name),
            table_order: List.delete(state.table_order, name)
        }

        publish(state.session_id, %{event: :table_removed, table_name: name})
        {:reply, :ok, new_state}
    end
  end

  # --- Row operations ---

  def handle_call({:add_rows, name, rows}, _from, state) do
    with_table(state, name, fn table ->
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

  def handle_call({:update_cells, name, changes}, _from, state) do
    with_table(state, name, fn table ->
      case Table.update_cells(table, changes) do
        {:ok, updated} -> {:ok, updated, :ok}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def handle_call({:delete_rows, name, ids}, _from, state) do
    with_table(state, name, fn table ->
      {:ok, updated} = Table.delete_rows(table, ids)
      {:ok, updated, :ok}
    end)
  end

  def handle_call({:delete_by_filter, name, filter}, _from, state) do
    with_table(state, name, fn table ->
      {:ok, updated, deleted_count} = Table.delete_by_filter(table, filter)
      {:ok, updated, {:ok, deleted_count}}
    end)
  end

  def handle_call({:replace_all, name, rows}, _from, state) do
    with_table(state, name, fn table ->
      case Table.replace_all(table, rows, &generate_row_id/0) do
        {:ok, updated, inserted} -> {:ok, updated, {:ok, inserted}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # --- Internal ---

  defp with_table(state, name, fun) do
    case Map.fetch(state.tables, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, table} ->
        case fun.(table) do
          {:ok, updated_table, reply} ->
            new_tables = Map.put(state.tables, name, updated_table)
            new_state = %{state | tables: new_tables}

            publish(state.session_id, %{
              event: :table_changed,
              table_name: name,
              version: updated_table.version
            })

            {:reply, reply, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp publish(session_id, payload) do
    Comms.publish(topic(session_id), payload, source: "/session/#{session_id}/data_table")
  end

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
