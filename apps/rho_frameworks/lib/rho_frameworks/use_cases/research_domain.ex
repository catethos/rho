defmodule RhoFrameworks.UseCases.ResearchDomain do
  @moduledoc """
  `:agent_loop` UseCase that pulls domain context into the session before
  structured generation runs (§4.4 of the swappable-decision-policy plan).

  Spawns a lightweight `RhoFrameworks.AgentJobs` worker armed with
  `web_fetch` + `save_finding` + `finish`. The worker streams discovered
  facts as rows into the session's `research_notes` named table; the
  research panel renders them live and lets the user pin/unpin or stop
  early. Pinned rows feed the downstream generation step (see
  `RhoFrameworks.Flows.CreateFramework.build_input(:generate, ...)`).

  The worker is kicked off and `run/2` returns immediately as
  `{:async, %{agent_id: id, table_name: "research_notes"}}` — the same
  shape `GenerateFrameworkSkeletons` uses today, so `FlowLive` reuses its
  existing async tracking.

  ## Test seam

  Override the spawn entry point via Application env to bypass the real
  worker (and its LLM call) in tests:

      Application.put_env(:rho_frameworks, :research_domain_spawn_fn,
                          fn opts -> {:ok, "fixture-agent-\#{...}"} end)

  Tests should `Application.delete_env/2` on `on_exit/1`.
  """

  @behaviour RhoFrameworks.UseCase

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{AgentJobs, DataTableSchemas, Scope}

  @table_name "research_notes"

  @impl true
  def describe do
    %{
      id: :research_domain,
      label: "Research the domain",
      cost_hint: :agent,
      doc: "Pull domain context (web search) into research_notes before generation."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    with :ok <- ensure_research_table(scope),
         {:ok, agent_id} <- spawn_worker(input, scope) do
      publish_started(scope, agent_id)
      {:async, %{agent_id: agent_id, table_name: @table_name}}
    end
  end

  @doc "Public for the research panel — emits the same row shape `save_finding` writes."
  @spec table_name() :: String.t()
  def table_name, do: @table_name

  # ──────────────────────────────────────────────────────────────────────
  # Setup
  # ──────────────────────────────────────────────────────────────────────

  defp ensure_research_table(%Scope{session_id: session_id}) when is_binary(session_id) do
    with {:ok, _pid} <- DataTable.ensure_started(session_id),
         :ok <-
           DataTable.ensure_table(
             session_id,
             @table_name,
             DataTableSchemas.research_notes_schema()
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:ensure_table_failed, reason}}
    end
  end

  defp ensure_research_table(_), do: {:error, :missing_session_id}

  # ──────────────────────────────────────────────────────────────────────
  # Worker spawn
  # ──────────────────────────────────────────────────────────────────────

  defp spawn_worker(input, %Scope{} = scope) do
    config = Rho.AgentConfig.agent(:default)

    spawn_args = [
      task: build_task_prompt(input),
      parent_agent_id: scope.session_id,
      tools: research_tools(scope),
      model: config.model,
      system_prompt: research_system_prompt(),
      max_steps: input[:max_steps] || 12,
      turn_strategy: Rho.TurnStrategy.Direct,
      provider: config.provider || %{},
      agent_name: :researcher,
      session_id: scope.session_id,
      organization_id: scope.organization_id
    ]

    case spawn_fn().(spawn_args) do
      {:ok, agent_id} when is_binary(agent_id) -> {:ok, agent_id}
      {:error, reason} -> {:error, {:spawn_failed, reason}}
      other -> {:error, {:unexpected_spawn_result, other}}
    end
  end

  defp spawn_fn do
    Application.get_env(:rho_frameworks, :research_domain_spawn_fn, &AgentJobs.start/1)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Prompts
  # ──────────────────────────────────────────────────────────────────────

  defp research_system_prompt do
    """
    You are a research worker for a skill-framework builder. Your job is to
    gather concrete, useful facts about a domain or set of roles so a
    downstream generator can produce a high-quality framework.

    Rules:
    - Each useful fact is a separate `save_finding` call. Keep facts atomic
      (one trend, one tool, one role characteristic per row).
    - Always include a `source`: a URL when you `web_fetch`-ed something,
      or a short label like "general-knowledge" when you're synthesising.
    - Tag findings: `trend`, `tooling`, `role`, `skill`, `process` — pick
      whichever fits, or omit `tag` if none does.
    - When you have ~6–10 strong findings call `finish` with a short summary.
    - Do not call save_finding speculatively. One fact per call.
    """
  end

  defp build_task_prompt(input) do
    name = input[:name] || ""
    description = input[:description] || ""
    domain = input[:domain] || ""
    target_roles = input[:target_roles] || ""

    """
    Research context for a new skill framework.

    Framework name: #{name}
    Description: #{description}
    Domain: #{domain}
    Target roles: #{target_roles}

    Plan:
    1. Identify 2–3 high-signal sources (job listings, established
       frameworks like SFIA, role guides) and `web_fetch` them.
    2. For each useful fact extracted, call `save_finding`.
    3. When you have enough, call `finish` with a one-line summary.
    """
  end

  # ──────────────────────────────────────────────────────────────────────
  # Tools
  # ──────────────────────────────────────────────────────────────────────

  defp research_tools(%Scope{} = _scope) do
    web_fetch = hd(Rho.Stdlib.Tools.WebFetch.tools(%{}, %Rho.Context{agent_name: :researcher}))

    [
      web_fetch,
      save_finding_tool_def(),
      Rho.Stdlib.Tools.Finish.tool_def()
    ]
  end

  defp save_finding_tool_def do
    %{
      tool:
        ReqLLM.tool(
          name: "save_finding",
          description:
            "Save one atomic research finding into the session's research_notes table. " <>
              "Each call writes one row; pinned defaults to false (the user pins via the panel).",
          parameter_schema: [
            source: [
              type: :string,
              required: true,
              doc: "URL of the source, or a short label like 'general-knowledge'"
            ],
            fact: [type: :string, required: true, doc: "The finding itself, one sentence"],
            tag: [
              type: :string,
              required: false,
              doc: "Optional category: trend / tooling / role / skill / process"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: &execute_save_finding/2
    }
  end

  defp execute_save_finding(_args, %Rho.Context{session_id: nil}),
    do: {:error, "save_finding requires a session_id on the agent context"}

  defp execute_save_finding(args, %Rho.Context{session_id: session_id}) do
    row = %{
      source: get(args, :source),
      fact: get(args, :fact),
      tag: get(args, :tag),
      pinned: false
    }

    if is_nil(row.source) or row.source == "" or is_nil(row.fact) or row.fact == "" do
      {:error, "save_finding requires non-empty `source` and `fact`"}
    else
      Process.put(:rho_source, :agent)

      case DataTable.add_rows(session_id, [row], table: @table_name) do
        {:ok, [_row]} ->
          {:ok, "Saved finding: #{String.slice(row.fact, 0, 80)}"}

        {:error, reason} ->
          {:error, "save_finding failed: #{inspect(reason)}"}
      end
    end
  end

  defp get(args, key) when is_map(args) do
    Map.get(args, key) || Map.get(args, Atom.to_string(key))
  end

  # ──────────────────────────────────────────────────────────────────────
  # Lifecycle event
  # ──────────────────────────────────────────────────────────────────────

  defp publish_started(%Scope{session_id: nil}, _agent_id), do: :ok

  defp publish_started(%Scope{} = scope, agent_id) do
    data = %{
      session_id: scope.session_id,
      agent_id: scope.session_id,
      worker_agent_id: agent_id,
      role: :researcher,
      task: "Researching domain"
    }

    Rho.Events.broadcast(
      scope.session_id,
      Rho.Events.event(:task_requested, scope.session_id, agent_id, data)
    )
  end
end
