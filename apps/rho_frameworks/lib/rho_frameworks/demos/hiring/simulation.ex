defmodule RhoFrameworks.Demos.Hiring.Simulation do
  @moduledoc """
  Deterministic coordinator for the hiring committee simulation.
  Manages rounds, spawns evaluators, and publishes domain events.
  Not an LLM — a plain Elixir GenServer.
  """

  use GenServer

  require Logger

  alias RhoFrameworks.Demos.Hiring.{Candidates, Tools}
  alias Rho.Agent.{Worker, Supervisor}
  alias Rho.Events.Event
  alias Rho.RunSpec

  defstruct [
    :session_id,
    round: 0,
    evaluators: %{},
    scores: %{},
    status: :not_started,
    max_rounds: 2
  ]

  # --- Public API ---

  def start(opts \\ []) do
    session_id = opts[:session_id] || "hiring_#{System.unique_integer([:positive])}"
    GenServer.start(__MODULE__, session_id, name: via(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  def begin_simulation(session_id) do
    GenServer.call(via(session_id), :begin, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(session_id) do
    Rho.Events.subscribe(session_id)
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:begin, _from, %{status: :not_started} = state) do
    Rho.Events.broadcast(
      state.session_id,
      Rho.Events.event(:hiring_simulation_started, state.session_id)
    )

    state = spawn_evaluators(state)
    state = start_round(state, 1)
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:begin, _from, state), do: {:reply, {:error, :already_started}, state}

  @impl true
  def handle_info(%Event{kind: :hiring_scores_submitted, data: data}, state) do
    # Use the coordinator's current round, not the LLM's claimed round
    state = record_scores(state, data.role, state.round, data.scores)
    state = maybe_advance_round(state)
    {:noreply, state}
  end

  def handle_info(%Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp spawn_evaluators(state) do
    roles = [:technical_evaluator, :culture_evaluator, :compensation_evaluator]

    evaluators =
      Map.new(roles, fn role ->
        agent_id = Rho.Agent.Primary.new_agent_id(Rho.Agent.Primary.agent_id(state.session_id))
        config = Rho.Config.agent_config(role)
        workspace = File.cwd!()

        # Build tools: multi-agent tools + submit_scores + finish
        tool_context = %{
          tape_name: agent_id,
          workspace: workspace,
          agent_name: role,
          agent_id: agent_id,
          session_id: state.session_id,
          depth: 1,
          sandbox: nil
        }

        # Only include multi-agent tools (send_message, broadcast, list_agents)
        # Filter out unrelated tools like present_ui, bash, file tools, etc.
        allowed_tools = ~w(send_message broadcast_message list_agents)

        mount_tools =
          Rho.PluginRegistry.collect_tools(tool_context)
          |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

        score_tool = Tools.submit_scores_tool(state.session_id, agent_id, role)
        finish_tool = Rho.Stdlib.Tools.Finish.tool_def()
        all_tools = mount_tools ++ [score_tool, finish_tool]

        # Bootstrap memory (one tape per evaluator, named by agent_id)
        memory_mod = Rho.Config.tape_module()
        memory_mod.bootstrap(agent_id)

        spec =
          RunSpec.build(
            model: config.model,
            system_prompt: config.system_prompt,
            max_steps: config.max_steps,
            max_tokens: config.max_tokens,
            plugins: config.plugins,
            turn_strategy: config.turn_strategy,
            prompt_format: config.prompt_format || :markdown,
            provider: config.provider,
            description: config.description,
            skills: config.skills || [],
            avatar: config.avatar,
            tools: all_tools,
            tape_module: memory_mod,
            agent_name: role,
            workspace: workspace,
            session_id: state.session_id
          )

        {:ok, _pid} =
          Supervisor.start_worker(
            agent_id: agent_id,
            session_id: state.session_id,
            workspace: workspace,
            agent_name: role,
            role: role,
            tape_ref: agent_id,
            run_spec: spec
          )

        Logger.info("[Hiring] Spawned #{role} as #{agent_id}")
        {role, agent_id}
      end)

    %{state | evaluators: evaluators}
  end

  defp start_round(state, round_num) do
    prompt = round_prompt(round_num, state)

    Rho.Events.broadcast(
      state.session_id,
      Rho.Events.event(:hiring_round_started, state.session_id, nil, %{round: round_num})
    )

    Logger.info("[Hiring] Starting round #{round_num}")

    # Submit prompt to each evaluator. Tools/system_prompt/model live in the
    # RunSpec set at start_worker time; no per-turn overrides needed.
    # Stagger starts by 1s to avoid Finch connection pool exhaustion.
    state.evaluators
    |> Enum.with_index()
    |> Enum.each(fn {{_role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)
      if pid, do: Worker.submit(pid, prompt)
    end)

    %{state | round: round_num}
  end

  defp round_prompt(1, _state) do
    """
    Evaluate the following candidates for Senior Backend Engineer.
    Salary band: $160,000 — $190,000. Maximum 3 offers.

    #{Candidates.format_all()}

    Score each candidate 0-100 based on your evaluation criteria.
    Use submit_scores with round: 1 when done.
    """
  end

  defp round_prompt(2, state) do
    summary = build_disagreement_summary(state)

    """
    Round 2: The committee has reviewed initial scores. Here are the key disagreements:

    #{summary}

    Reconsider your scores in light of other evaluators' perspectives.
    You may use send_message to debate specific candidates with other evaluators.
    Then use submit_scores with round: 2 for your revised ratings.
    """
  end

  defp record_scores(state, role, round, scores) do
    key = {role, round}
    Logger.info("[Hiring] #{role} submitted scores for round #{round}")
    %{state | scores: Map.put(state.scores, key, scores)}
  end

  defp maybe_advance_round(state) do
    expected = map_size(state.evaluators)

    submitted =
      state.scores
      |> Map.keys()
      |> Enum.count(fn {_role, r} -> r == state.round end)

    if submitted >= expected do
      if state.round >= state.max_rounds do
        final = compute_final_shortlist(state)

        Rho.Events.broadcast(
          state.session_id,
          Rho.Events.event(:hiring_simulation_completed, state.session_id, nil, %{
            shortlist: final
          })
        )

        Logger.info("[Hiring] Simulation complete. Shortlist: #{inspect(final)}")
        %{state | status: :completed}
      else
        start_round(state, state.round + 1)
      end
    else
      Logger.info(
        "[Hiring] Waiting for scores: #{submitted}/#{expected} for round #{state.round}"
      )

      state
    end
  end

  defp build_disagreement_summary(state) do
    # Collect round 1 scores by candidate
    round1_scores =
      state.scores
      |> Enum.filter(fn {{_role, round}, _scores} -> round == 1 end)
      |> Enum.flat_map(fn {{role, _round}, scores} ->
        Enum.map(scores, fn entry ->
          {entry["id"], role, entry["score"]}
        end)
      end)
      |> Enum.group_by(fn {id, _role, _score} -> id end)

    # Find candidates with high variance (>20 point spread)
    round1_scores
    |> Enum.map(fn {id, entries} ->
      scores = Enum.map(entries, fn {_id, _role, score} -> score end)
      min = Enum.min(scores, fn -> 0 end)
      max = Enum.max(scores, fn -> 0 end)
      spread = max - min

      role_scores =
        entries
        |> Enum.map_join(", ", fn {_id, role, score} -> "#{role}: #{score}" end)

      {id, spread, role_scores}
    end)
    |> Enum.sort_by(fn {_id, spread, _} -> -spread end)
    |> Enum.map_join("\n", fn {id, spread, role_scores} ->
      candidate = Enum.find(Candidates.all(), &(&1.id == id))
      name = if candidate, do: candidate.name, else: id
      "- #{id} (#{name}): spread #{spread} points — #{role_scores}"
    end)
  end

  defp compute_final_shortlist(state) do
    # Average round 2 scores (or round 1 if no round 2) across evaluators
    latest_round = state.max_rounds

    candidate_averages =
      state.scores
      |> Enum.filter(fn {{_role, round}, _scores} -> round == latest_round end)
      |> Enum.flat_map(fn {{_role, _round}, scores} ->
        Enum.map(scores, fn entry ->
          {entry["id"], entry["score"]}
        end)
      end)
      |> Enum.group_by(fn {id, _score} -> id end)
      |> Enum.map(fn {id, entries} ->
        scores = Enum.map(entries, fn {_id, score} -> score end)
        avg = Enum.sum(scores) / max(length(scores), 1)
        {id, Float.round(avg, 1)}
      end)
      |> Enum.sort_by(fn {_id, avg} -> -avg end)
      |> Enum.take(3)

    Enum.map(candidate_averages, fn {id, avg} ->
      candidate = Enum.find(Candidates.all(), &(&1.id == id))
      name = if candidate, do: candidate.name, else: id
      %{id: id, name: name, avg_score: avg}
    end)
  end

  defp via(session_id), do: {:via, Registry, {Rho.AgentRegistry, "sim_#{session_id}"}}
end
