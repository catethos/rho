defmodule Rho.Stdlib.DataTable do
  @moduledoc """
  Client API for the per-session data table server.

  Every operation takes a `session_id` (string) and an optional `opts`
  keyword list whose `:table` key selects the named table. The default
  table is `"main"`, which is eagerly created with a dynamic schema on
  server init and accepts arbitrary LLM-generated fields.

  ## Example

      Rho.Stdlib.DataTable.ensure_started("sess_1")
      Rho.Stdlib.DataTable.add_rows("sess_1", [%{name: "foo"}])
      Rho.Stdlib.DataTable.get_rows("sess_1")

  ## Lifecycle and crash semantics

  The server uses `restart: :temporary`. A crashed server does NOT
  silently restart with empty state — callers get `{:error, :not_running}`
  from any read/write after a crash. Only explicit callers should
  `ensure_started/1` the server:

    * the DataTable plugin's `tools/2` callback, at agent boot
    * the LiveView on mount (via `SessionCore`/`SkillLibraryLive`)
    * `EffectDispatcher` before writing an effect

  After every mutation the server publishes a coarse invalidation event on
  the session topic `"rho.session.<id>.events.data_table"` via
  `Rho.Comms`. Subscribers re-fetch snapshots.
  """

  alias Rho.Stdlib.DataTable.Schema
  alias Rho.Stdlib.DataTable.Server

  @type session_id :: String.t()
  @type table_name :: String.t()
  @type row :: map()
  @type opts :: keyword()

  @default_table "main"

  # --- Lifecycle ---

  @doc """
  Ensure a server is running for the given session. Idempotent.

  Safe to call from multiple processes concurrently — the underlying
  DynamicSupervisor + Registry via-tuple rendezvous converges to a
  single process.
  """
  @spec ensure_started(session_id()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id) when is_binary(session_id) do
    case Server.whereis(session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               Rho.Stdlib.DataTable.Supervisor,
               {Server, session_id: session_id}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Stop the data table server for a session, if running."
  @spec stop(session_id()) :: :ok
  def stop(session_id) when is_binary(session_id) do
    case Server.whereis(session_id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(Rho.Stdlib.DataTable.Supervisor, pid)
        :ok
    end
  end

  @doc "Return the pid for a session's server, or `nil` if not running."
  @spec whereis(session_id()) :: pid() | nil
  def whereis(session_id), do: Server.whereis(session_id)

  @doc "Topic for data table invalidation events for a session."
  @spec topic(session_id()) :: String.t()
  def topic(session_id), do: Server.topic(session_id)

  # --- Table management ---

  @doc """
  Create a new named table with the given schema. Errors if it already
  exists. Prefer `ensure_table/4` from tools to handle concurrent
  creation races.
  """
  @spec create_table(session_id(), table_name(), Schema.t(), opts()) ::
          :ok | {:error, term()}
  def create_table(session_id, name, %Schema{} = schema, _opts \\ [])
      when is_binary(name) do
    call(session_id, {:create_table, name, schema})
  end

  @doc """
  Idempotent create-if-missing for a named table.

  Returns `:ok` if created or if an existing table has a compatible
  schema. Returns `{:error, :schema_mismatch}` if an existing table
  has different columns/mode.

  Starts the server if not already running — one of the few client APIs
  that does so, so effect dispatchers and tools can opportunistically
  bring up the server on first write.
  """
  @spec ensure_table(session_id(), table_name(), Schema.t(), opts()) ::
          :ok | {:error, term()}
  def ensure_table(session_id, name, %Schema{} = schema, _opts \\ [])
      when is_binary(name) do
    with {:ok, _pid} <- ensure_started(session_id) do
      GenServer.call(Server.via(session_id), {:ensure_table, name, schema})
    end
  end

  @doc "List the tables known to this session."
  @spec list_tables(session_id()) :: [map()] | {:error, :not_running}
  def list_tables(session_id) do
    call(session_id, {:list_tables})
  end

  @doc "Fetch the schema for a named table."
  @spec get_schema(session_id(), table_name()) :: {:ok, Schema.t()} | {:error, term()}
  def get_schema(session_id, name) do
    call(session_id, {:get_schema, name})
  end

  @doc "Drop a named table."
  @spec drop_table(session_id(), table_name()) :: :ok | {:error, term()}
  def drop_table(session_id, name) do
    call(session_id, {:drop_table, name})
  end

  # --- Snapshots ---

  @doc "Return a session-wide snapshot: list of tables plus their order."
  @spec get_session_snapshot(session_id()) :: map() | {:error, :not_running}
  def get_session_snapshot(session_id) do
    call(session_id, {:session_snapshot})
  end

  @doc "Return a full snapshot of one table (rows + schema + version)."
  @spec get_table_snapshot(session_id(), table_name()) :: {:ok, map()} | {:error, term()}
  def get_table_snapshot(session_id, name \\ @default_table) do
    call(session_id, {:table_snapshot, name})
  end

  @doc "Return a summary of a table: row count + per-field unique value samples."
  @spec summarize_table(session_id(), opts()) :: {:ok, map()} | {:error, term()}
  def summarize_table(session_id, opts \\ []) do
    name = Keyword.get(opts, :table, @default_table)
    call(session_id, {:summarize, name})
  end

  # --- Row operations ---

  @doc "Append rows to a table. Returns `{:ok, inserted_rows}`."
  @spec add_rows(session_id(), [row()], opts()) ::
          {:ok, [row()]} | {:error, term()}
  def add_rows(session_id, rows, opts \\ []) when is_list(rows) do
    name = Keyword.get(opts, :table, @default_table)
    call(session_id, {:add_rows, name, rows})
  end

  @doc """
  Read rows from a table. Optional `:filter` opt is a map of
  `field => value` to match.

  Returns a list of rows on success, `[]` if the table does not exist,
  or `{:error, :not_running}` if the server has crashed. Callers that
  only care about data can pattern-match on the list; callers that need
  to distinguish "no data" from "crash" should match on the tuple.
  """
  @spec get_rows(session_id(), opts()) :: [row()] | {:error, :not_running}
  def get_rows(session_id, opts \\ []) do
    name = Keyword.get(opts, :table, @default_table)
    filter = Keyword.get(opts, :filter, nil)

    case call(session_id, {:get_rows, name, filter}) do
      {:ok, rows} -> rows
      {:error, :not_found} -> []
      {:error, :not_running} = err -> err
      other -> other
    end
  end

  @doc "Apply cell changes to a table."
  @spec update_cells(session_id(), [map()], opts()) :: :ok | {:error, term()}
  def update_cells(session_id, changes, opts \\ []) when is_list(changes) do
    name = Keyword.get(opts, :table, @default_table)
    call(session_id, {:update_cells, name, changes})
  end

  @doc "Delete rows by id."
  @spec delete_rows(session_id(), [String.t()], opts()) :: :ok | {:error, term()}
  def delete_rows(session_id, ids, opts \\ []) when is_list(ids) do
    name = Keyword.get(opts, :table, @default_table)
    call(session_id, {:delete_rows, name, ids})
  end

  @doc "Delete rows matching a filter map. Returns `{:ok, deleted_count}`."
  @spec delete_by_filter(session_id(), map(), opts()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_by_filter(session_id, filter, opts \\ []) when is_map(filter) do
    name = Keyword.get(opts, :table, @default_table)
    call(session_id, {:delete_by_filter, name, filter})
  end

  @doc """
  Query rows with filter, column projection, limit, and offset.

  Returns `%{rows: [...], total: n, offset: n, limit: n}` or `{:error, term}`.

  Options:
    * `:table` — table name (default: "main")
    * `:filter` — map of field/value equality filters
    * `:columns` — list of column name strings to project
    * `:limit` — max rows to return
    * `:offset` — rows to skip
  """
  @spec query_rows(session_id(), opts()) :: map() | {:error, term()}
  def query_rows(session_id, opts \\ []) do
    name = Keyword.get(opts, :table, @default_table)
    filter = Keyword.get(opts, :filter)
    columns = Keyword.get(opts, :columns)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    call(session_id, {:query_rows, name, filter, columns, limit, offset})
  end

  @doc "Replace all rows in a table. Returns `{:ok, inserted_rows}`."
  @spec replace_all(session_id(), [row()], opts()) ::
          {:ok, [row()]} | {:error, term()}
  def replace_all(session_id, rows, opts \\ []) when is_list(rows) do
    name = Keyword.get(opts, :table, @default_table)
    call(session_id, {:replace_all, name, rows})
  end

  # --- Internal ---

  # Look up the running server and dispatch the call. If the server is
  # not running (never started, or crashed with `restart: :temporary`),
  # return `{:error, :not_running}` rather than silently starting a
  # fresh empty server. Callers that need to start the server should
  # call `ensure_started/1` explicitly.
  defp call(session_id, message) when is_binary(session_id) do
    case Server.whereis(session_id) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(Server.via(session_id), message)
    end
  end
end
