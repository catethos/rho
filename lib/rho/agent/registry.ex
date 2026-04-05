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
      parent_agent_id: attrs[:parent_agent_id],
      depth: attrs[:depth] || 0,
      description: attrs[:description],
      skills: attrs[:skills] || [],
      memory_ref: attrs[:memory_ref]
    }

    :ets.insert(@table, {agent_id, entry})
    :ok
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
