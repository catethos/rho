defmodule Rho.Agent.Registry do
  @moduledoc """
  ETS-based registry for agent discovery by role, capability, or session.

  The signal bus routes messages; the registry answers queries about
  the agent population within a session.
  """

  @table :rho_agent_registry

  @doc "Create the ETS table. Call once at application startup."
  def init_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Register an agent with its attributes."
  def register(agent_id, attrs) do
    entry = %{
      agent_id: agent_id,
      session_id: attrs[:session_id],
      role: attrs[:role],
      capabilities: attrs[:capabilities] || [],
      pid: attrs[:pid],
      status: attrs[:status] || :idle,
      depth: attrs[:depth] || 0,
      description: attrs[:description],
      skills: attrs[:skills] || [],
      tape_ref: attrs[:tape_ref],
      last_result: nil,
      reported_at: nil
    }

    :ets.insert(@table, {agent_id, entry})
    :ok
  end

  @doc """
  Record the terminal result for an agent. Used by completion-notice
  readers (e.g. the Subagent `:tool_result_in` transformer) to fetch
  the preview text without querying a possibly-dead worker.
  """
  @spec record_result(String.t(), term()) :: :ok | {:error, :not_found}
  def record_result(agent_id, result) do
    update(agent_id, %{last_result: result})
  end

  @doc """
  Mark a completed agent as having had its result reported to the
  parent (dedupe source for completion notices). Idempotent — the
  first call sets `reported_at`; subsequent calls overwrite with the
  newer timestamp.
  """
  @spec mark_reported(String.t(), integer() | nil) :: :ok | {:error, :not_found}
  def mark_reported(agent_id, at \\ nil) do
    timestamp = at || System.system_time(:millisecond)
    update(agent_id, %{reported_at: timestamp})
  end

  @doc "Update an agent's status."
  def update_status(agent_id, status) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, entry}] ->
        :ets.insert(@table, {agent_id, %{entry | status: status}})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Update arbitrary fields on an agent entry."
  def update(agent_id, attrs) when is_map(attrs) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, entry}] ->
        :ets.insert(@table, {agent_id, Map.merge(entry, attrs)})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Unregister an agent."
  def unregister(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  end

  # Guard clause fragment: filter out stopped agents
  defp live_guard, do: {:"=/=", {:map_get, :status, :"$2"}, :stopped}

  defp session_guard(session_id), do: {:==, {:map_get, :session_id, :"$2"}, session_id}

  @doc "Find live agents by role within a session."
  def find_by_role(session_id, role) do
    spec = [
      {{:"$1", :"$2"},
       [
         {:andalso, {:andalso, session_guard(session_id), {:==, {:map_get, :role, :"$2"}, role}},
          live_guard()}
       ], [:"$2"]}
    ]

    :ets.select(@table, spec)
  end

  @doc "Find agents by capability within a session."
  def find_by_capability(session_id, capability) do
    list(session_id)
    |> Enum.filter(fn agent ->
      capability in (agent.capabilities || [])
    end)
  end

  @doc """
  Return `[{agent_id, pid}]` for all live agents in the given session.

  Matches `session_id` exactly. Use `find_by_session_prefix/1` for
  prefix queries.
  """
  @spec find_by_session(String.t()) :: [{String.t(), pid()}]
  def find_by_session(session_id) do
    spec = [
      {{:"$1", :"$2"}, [{:andalso, session_guard(session_id), live_guard()}],
       [{{:"$1", {:map_get, :pid, :"$2"}}}]}
    ]

    :ets.select(@table, spec)
  end

  @doc """
  List all live agent entries whose `session_id` starts with `prefix`.

  ETS match-specs cannot express string prefix comparison on a set
  table, so this scans all live entries and post-filters in Elixir.
  Intended for low-cardinality admin queries (session listing).
  """
  @spec find_by_session_prefix(String.t()) :: [map()]
  def find_by_session_prefix(prefix) do
    spec = [
      {{:"$1", :"$2"}, [live_guard()], [:"$2"]}
    ]

    @table
    |> :ets.select(spec)
    |> Enum.filter(fn entry ->
      sid = entry[:session_id]
      is_binary(sid) and String.starts_with?(sid, prefix)
    end)
  end

  @doc "List all live agents in a session."
  def list(session_id) do
    spec = [
      {{:"$1", :"$2"}, [{:andalso, session_guard(session_id), live_guard()}], [:"$2"]}
    ]

    :ets.select(@table, spec)
  end

  @doc "List all agents in a session (including stopped)."
  def list_all(session_id) do
    spec = [
      {{:"$1", :"$2"}, [session_guard(session_id)], [:"$2"]}
    ]

    :ets.select(@table, spec)
  end

  @doc "List all live agents in a session except the given agent_id."
  def list_except(session_id, exclude_agent_id) do
    spec = [
      {{:"$1", :"$2"},
       [
         {:andalso, {:andalso, session_guard(session_id), {:"=/=", :"$1", exclude_agent_id}},
          live_guard()}
       ], [:"$2"]}
    ]

    :ets.select(@table, spec)
  end

  @doc """
  Return the direct children of `parent_id` — live agents whose ids
  are of the form `"<parent_id>/<name>"` with exactly one additional
  path segment.
  """
  @spec children_of(String.t()) :: [map()]
  def children_of(parent_id) do
    prefix = parent_id <> "/"

    spec = [
      {{:"$1", :"$2"}, [live_guard()], [:"$2"]}
    ]

    @table
    |> :ets.select(spec)
    |> Enum.filter(fn entry ->
      id = entry[:agent_id]

      is_binary(id) and String.starts_with?(id, prefix) and
        not String.contains?(
          binary_part(id, byte_size(prefix), byte_size(id) - byte_size(prefix)),
          "/"
        )
    end)
  end

  @doc """
  Return all descendants of `parent_id` — live agents whose ids start
  with `"<parent_id>/"`. Includes grandchildren and deeper.
  """
  @spec descendants_of(String.t()) :: [map()]
  def descendants_of(parent_id) do
    prefix = parent_id <> "/"

    spec = [
      {{:"$1", :"$2"}, [live_guard()], [:"$2"]}
    ]

    @table
    |> :ets.select(spec)
    |> Enum.filter(fn entry ->
      id = entry[:agent_id]
      is_binary(id) and String.starts_with?(id, prefix)
    end)
  end

  @doc "Get a specific agent's info."
  def get(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Count live agents in a session."
  def count(session_id) do
    spec = [
      {{:"$1", :"$2"}, [{:andalso, session_guard(session_id), live_guard()}], [true]}
    ]

    :ets.select_count(@table, spec)
  end
end
