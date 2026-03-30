defmodule Rho.Demos.Hiring.Simulation do
  @moduledoc """
  Deterministic coordinator for the hiring committee simulation.
  Manages rounds, spawns evaluators, and publishes domain events.
  Not an LLM — a plain Elixir GenServer.
  """

  use GenServer

  require Logger

  alias Rho.Demos.Hiring.{Candidates, Tools}
  alias Rho.Agent.{Worker, Supervisor}
  alias Rho.Comms

  defstruct [
    :session_id,
    round: 0,
    evaluators: %{},
    evaluator_tools: %{},
    scores: %{},
    status: :not_started,
    max_rounds: 2,
    chairman_agent_id: nil,
    chairman_tools: nil,
    round_started_at: nil,
    round_timer_ref: nil,
    summary_delivered: false,
    pending_replies: 0,
    last_question: nil,
    retry_count: 0
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

  def ask(session_id, question) do
    GenServer.cast(via(session_id), {:ask, question})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(session_id) do
    {:ok, _sub} = Comms.subscribe("rho.hiring.scores.submitted")
    {:ok, _sub2} = Comms.subscribe("rho.task.completed")
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:begin, _from, %{status: :not_started} = state) do
    Comms.publish("rho.hiring.simulation.started", %{
      session_id: state.session_id
    }, source: "/session/#{state.session_id}")

    state = spawn_chairman(state)

    # Publish hardcoded opening message (no LLM call)
    Comms.publish("rho.hiring.chairman.message", %{
      session_id: state.session_id,
      agent_id: state.chairman_agent_id,
      agent_role: :chairman,
      text: "I've convened this committee to evaluate 5 candidates for Senior Backend Engineer. Budget: $160K–$190K. Maximum 3 offers. Let's begin with Round 1 — evaluators, please score all candidates."
    }, source: "/session/#{state.session_id}")

    state = spawn_evaluators(state)
    state = start_round(state, 1)
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:begin, _from, state), do: {:reply, {:error, :already_started}, state}

  @impl true
  @chat_model "openrouter:anthropic/claude-sonnet-4.6"

  def handle_cast({:ask, question}, %{status: :completed} = state) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)

    if chairman_pid do
      prompt = build_chat_prompt(state, question)
      Worker.submit(chairman_pid, prompt, tools: state.chairman_tools, model: @chat_model)
      {:noreply, %{state | pending_replies: state.pending_replies + 1, last_question: question, retry_count: 0}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:ask, _question}, state), do: {:noreply, state}

  @impl true
  def handle_info({:retry_ask, question}, %{status: :completed} = state) when is_binary(question) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)

    if chairman_pid do
      Logger.info("[Hiring] Retrying question for chairman.")
      prompt = build_chat_prompt(state, question)
      Worker.submit(chairman_pid, prompt, tools: state.chairman_tools, model: @chat_model)
    end

    {:noreply, state}
  end

  def handle_info({:retry_ask, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:signal, %Jido.Signal{type: "rho.hiring.scores.submitted", data: data}}, %{status: :running} = state) do
    if data.session_id == state.session_id do
      # Use the coordinator's current round, not the LLM's claimed round
      state = record_scores(state, data.role, state.round, data.scores)
      state = maybe_advance_round(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Ignore late scores after simulation is completed
  def handle_info({:signal, %Jido.Signal{type: "rho.hiring.scores.submitted"}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{type: "rho.task.completed", data: data}}, %{status: :completed} = state) do
    if data.agent_id == state.chairman_agent_id do
      cond do
        # First completion = the closing summary
        not state.summary_delivered ->
          Logger.info("[Hiring] Chairman produced summary. Publishing to timeline.")

          Comms.publish("rho.hiring.chairman.summary", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :chairman,
            text: data.result
          }, source: "/session/#{state.session_id}")

          {:noreply, %{state | summary_delivered: true}}

        # User asked a question but chairman errored — retry up to 3 times
        state.pending_replies > 0 and String.starts_with?(data.result, "error:") and state.retry_count < 3 ->
          Logger.warning("[Hiring] Chairman failed (attempt #{state.retry_count + 1}/3), retrying: #{String.slice(data.result, 0, 100)}")
          Process.send_after(self(), {:retry_ask, state.last_question}, 2_000)
          {:noreply, %{state | retry_count: state.retry_count + 1}}

        # Max retries exhausted — show user-friendly error
        state.pending_replies > 0 and String.starts_with?(data.result, "error:") ->
          Logger.error("[Hiring] Chairman failed after 3 retries. Giving up.")

          Comms.publish("rho.hiring.chairman.reply", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :chairman,
            text: "I'm having trouble responding right now. Please wait a moment and try again."
          }, source: "/session/#{state.session_id}")

          {:noreply, %{state | pending_replies: state.pending_replies - 1, retry_count: 0}}

        # Successful reply
        state.pending_replies > 0 ->
          Logger.info("[Hiring] Chairman replied to user question. Publishing to timeline.")

          Comms.publish("rho.hiring.chairman.reply", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :chairman,
            text: data.result
          }, source: "/session/#{state.session_id}")

          {:noreply, %{state | pending_replies: state.pending_replies - 1}}

        # Stale completion from mailbox signals — ignore
        true ->
          Logger.debug("[Hiring] Ignoring stale chairman task completion (no pending replies)")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Ignore task completions from other agents or states
  def handle_info({:signal, %Jido.Signal{type: "rho.task.completed", data: _data}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:check_round_timeout, round_num}, %{status: :running, round: current_round} = state)
      when round_num == current_round do
    submitted_roles =
      state.scores
      |> Map.keys()
      |> Enum.filter(fn {_role, r} -> r == state.round end)
      |> Enum.map(fn {role, _r} -> role end)

    missing = Map.keys(state.evaluators) -- submitted_roles

    if missing != [] do
      Logger.warning("[Hiring] Round #{state.round} timeout — nudging #{length(missing)} evaluators: #{inspect(missing)}")

      chairman_pid = Worker.whereis(state.chairman_agent_id)
      config = Rho.Config.agent(:chairman)

      if chairman_pid do
        missing_names = Enum.map_join(missing, ", ", &Atom.to_string/1)
        Worker.submit(chairman_pid,
          "Send a message to each of these evaluators asking them to submit their round #{state.round} scores immediately: #{missing_names}. After sending the messages, call `finish`. Do not do anything else.",
          tools: state.chairman_tools,
          model: config.model
        )
      end

      ref = Process.send_after(self(), {:check_round_timeout, round_num}, 60_000)
      {:noreply, %{state | round_timer_ref: ref}}
    else
      {:noreply, state}
    end
  end

  # Stale timer from previous round or non-running state — ignore
  def handle_info({:check_round_timeout, _}, state), do: {:noreply, state}

  def handle_info(:stop_chairman, state) do
    pid = Worker.whereis(state.chairman_agent_id)
    if pid do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
      Logger.info("[Hiring] Chairman agent stopped.")
    end
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp spawn_evaluators(state) do
    roles = [:technical_evaluator, :culture_evaluator, :compensation_evaluator]

    evaluators =
      Map.new(roles, fn role ->
        agent_id = Rho.Session.new_agent_id()
        config = Rho.Config.agent(role)

        # Build tools: multi-agent tools + submit_scores
        tool_context = %{
          tape_name: "agent_#{agent_id}",
          workspace: File.cwd!(),
          agent_name: role,
          agent_id: agent_id,
          session_id: state.session_id,
          depth: 1,
          sandbox: nil
        }

        # Only include multi-agent tools (send_message, broadcast, list_agents)
        # Filter out unrelated tools like present_ui, bash, file tools, etc.
        allowed_tools = ~w(send_message list_agents)
        mount_tools =
          Rho.MountRegistry.collect_tools(tool_context)
          |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

        score_tool = Tools.submit_scores_tool(state.session_id, agent_id, role)
        finish_tool = Rho.Tools.Finish.tool_def()
        all_tools = mount_tools ++ [score_tool, finish_tool]

        # Bootstrap memory
        memory_mod = Rho.Config.memory_module()
        tape = "agent_#{agent_id}"
        memory_mod.bootstrap(tape)

        {:ok, _pid} =
          Supervisor.start_worker(
            agent_id: agent_id,
            session_id: state.session_id,
            workspace: File.cwd!(),
            agent_name: role,
            role: role,
            depth: 1,
            memory_ref: tape,
            max_steps: config.max_steps,
            system_prompt: config.system_prompt,
            tools: all_tools,
            model: config.model
          )

        Logger.info("[Hiring] Spawned #{role} as #{agent_id}")
        {role, %{agent_id: agent_id, tools: all_tools, config: config}}
      end)

    evaluator_map = Map.new(evaluators, fn {role, info} -> {role, info.agent_id} end)
    tools_map = Map.new(evaluators, fn {role, info} -> {role, %{tools: info.tools, config: info.config}} end)

    %{state | evaluators: evaluator_map, evaluator_tools: tools_map}
  end

  defp spawn_chairman(state) do
    agent_id = Rho.Session.new_agent_id()
    config = Rho.Config.agent(:chairman)

    tool_context = %{
      tape_name: "agent_#{agent_id}",
      workspace: File.cwd!(),
      agent_name: :chairman,
      agent_id: agent_id,
      session_id: state.session_id,
      depth: 1,
      sandbox: nil
    }

    allowed_tools = ~w(send_message)
    mount_tools =
      Rho.MountRegistry.collect_tools(tool_context)
      |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

    finish_tool = Rho.Tools.Finish.tool_def()
    all_tools = mount_tools ++ [finish_tool]

    memory_mod = Rho.Config.memory_module()
    tape = "agent_#{agent_id}"
    memory_mod.bootstrap(tape)

    {:ok, _pid} =
      Supervisor.start_worker(
        agent_id: agent_id,
        session_id: state.session_id,
        workspace: File.cwd!(),
        agent_name: :chairman,
        role: :chairman,
        depth: 1,
        memory_ref: tape,
        max_steps: config.max_steps,
        system_prompt: config.system_prompt,
        tools: all_tools,
        model: config.model
      )

    Logger.info("[Hiring] Spawned chairman as #{agent_id}")
    %{state | chairman_agent_id: agent_id, chairman_tools: all_tools}
  end

  defp start_round(state, round_num) do
    prompt = round_prompt(round_num, state)

    # Cancel previous round timer if exists
    if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

    Comms.publish("rho.hiring.round.started", %{
      session_id: state.session_id,
      round: round_num
    }, source: "/session/#{state.session_id}")

    Logger.info("[Hiring] Starting round #{round_num}")

    # Submit prompt to each evaluator with their custom tools
    # Stagger starts by 1s to avoid Finch connection pool exhaustion
    state.evaluators
    |> Enum.with_index()
    |> Enum.each(fn {{role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)
      if pid do
        role_info = Map.get(state.evaluator_tools, role, %{})
        Worker.submit(pid, prompt,
          tools: role_info[:tools],
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end)

    # Schedule round timeout check (with round number to prevent stale timer issues)
    ref = Process.send_after(self(), {:check_round_timeout, round_num}, 90_000)

    %{state | round: round_num, round_started_at: System.monotonic_time(:millisecond), round_timer_ref: ref}
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
        # Cancel round timer
        if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

        final = compute_final_shortlist(state)

        # Stop all evaluator agents to prevent further debate
        for {_role, agent_id} <- state.evaluators do
          pid = Worker.whereis(agent_id)
          if pid do
            try do
              GenServer.stop(pid, :normal, 5_000)
            catch
              :exit, _ -> :ok
            end
          end
        end

        Logger.info("[Hiring] Evaluators stopped. Sending closing prompt to chairman.")

        # Build and send closing prompt to chairman
        closing_prompt = build_closing_prompt(state, final)
        chairman_pid = Worker.whereis(state.chairman_agent_id)
        config = Rho.Config.agent(:chairman)

        if chairman_pid do
          Worker.submit(chairman_pid, closing_prompt,
            tools: state.chairman_tools,
            model: config.model
          )
        else
          Logger.warning("[Hiring] Chairman agent not available for closing summary")
        end

        # Chairman summary will be published when chairman finishes (via rho.task.completed handler)

        Comms.publish("rho.hiring.simulation.completed", %{
          session_id: state.session_id,
          shortlist: final
        }, source: "/session/#{state.session_id}")

        Logger.info("[Hiring] Simulation complete. Shortlist: #{inspect(final)}")
        %{state | status: :completed, round_timer_ref: nil}
      else
        start_round(state, state.round + 1)
      end
    else
      Logger.info("[Hiring] Waiting for scores: #{submitted}/#{expected} for round #{state.round}")
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
        |> Enum.map(fn {_id, role, score} -> "#{role}: #{score}" end)
        |> Enum.join(", ")

      {id, spread, role_scores}
    end)
    |> Enum.sort_by(fn {_id, spread, _} -> -spread end)
    |> Enum.map(fn {id, spread, role_scores} ->
      candidate = Enum.find(Candidates.all(), &(&1.id == id))
      name = if candidate, do: candidate.name, else: id
      "- #{id} (#{name}): spread #{spread} points — #{role_scores}"
    end)
    |> Enum.join("\n")
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

  defp build_closing_prompt(state, shortlist) do
    score_table =
      state.scores
      |> Enum.filter(fn {{_role, round}, _} -> round == state.max_rounds end)
      |> Enum.flat_map(fn {{role, _round}, scores} ->
        Enum.map(scores, fn entry ->
          candidate = Enum.find(Candidates.all(), &(&1.id == entry["id"]))
          name = if candidate, do: candidate.name, else: entry["id"]
          "#{name}: #{role} scored #{entry["score"]} — #{entry["rationale"] || ""}"
        end)
      end)
      |> Enum.join("\n")

    shortlist_text =
      shortlist
      |> Enum.map_join("\n", fn s ->
        candidate = Enum.find(Candidates.all(), &(&1.id == s.id))
        salary = if candidate, do: "$#{candidate.salary_expectation}", else: "N/A"
        "- #{s.name} (avg: #{s.avg_score}, salary: #{salary})"
      end)

    disagreement = build_disagreement_summary(state)

    """
    The committee has completed #{state.max_rounds} rounds of evaluation. Here are the final scores:

    #{score_table}

    Shortlist (top 3 by average):
    #{shortlist_text}

    Key disagreements from the debate:
    #{disagreement}

    Please produce the committee's final recommendation report. Use the `finish` tool with your summary when done.
    """
  end

  defp build_chat_prompt(state, question) do
    memory_mod = Rho.Config.memory_module()

    # Gather evaluator tape histories (tapes persist after process death)
    evaluator_context =
      state.evaluators
      |> Enum.map(fn {role, agent_id} ->
        history = memory_mod.history("agent_#{agent_id}")
        {role, summarize_evaluator_history(history)}
      end)
      |> Enum.map_join("\n\n", fn {role, summary} ->
        "## #{format_role(role)}\n#{summary}"
      end)

    score_summary = format_all_scores(state)

    """
    You are the Chairman answering a follow-up question from a user who watched the hiring simulation.

    Here is the full context from the simulation:

    ### Final Scores
    #{score_summary}

    ### Evaluator Activity
    #{evaluator_context}

    ### User Question
    #{question}

    Answer conversationally and concisely. Reference specific evaluator opinions and scores when relevant.
    When done, call `finish` with your complete response written directly to the user. The finish argument IS what the user will read — write it as a direct conversation, not a summary or description of what you said.
    """
  end

  defp summarize_evaluator_history(history) do
    history
    |> Enum.map(fn entry ->
      case entry do
        %{type: "message", role: "assistant", content: content} ->
          "Assistant: #{String.slice(to_string(content), 0, 300)}"

        %{type: "tool_call", name: "submit_scores", args: args} ->
          args = parse_args(args)
          scores = parse_args(args["scores"] || [])
          scores = if is_list(scores), do: scores, else: []
          formatted = Enum.map_join(scores, ", ", fn s ->
            "#{s["id"]}: #{s["score"]}"
          end)
          "Submitted scores: #{formatted} (at #{entry[:ts] || "?"})"

        %{type: "tool_call", name: "send_message", args: args} ->
          args = parse_args(args)
          "Sent message to #{parse_args(args["to"])}: #{String.slice(to_string(args["message"]), 0, 200)}"

        %{type: "tool_call", name: name} ->
          "Called #{name}"

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Tape stores tool args as raw JSON strings; parse if needed
  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> args
    end
  end

  defp parse_args(args), do: args

  defp format_all_scores(state) do
    latest_round = state.max_rounds

    state.scores
    |> Enum.filter(fn {{_role, round}, _} -> round == latest_round end)
    |> Enum.flat_map(fn {{role, _round}, scores} ->
      Enum.map(scores, fn entry ->
        candidate = Enum.find(Candidates.all(), &(&1.id == entry["id"]))
        name = if candidate, do: candidate.name, else: entry["id"]
        "#{name}: #{format_role(role)} scored #{entry["score"]}"
      end)
    end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp format_role(role) when is_atom(role) do
    role |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_role(role), do: to_string(role)

  def via(session_id), do: {:via, Registry, {Rho.AgentRegistry, "sim_#{session_id}"}}
end
