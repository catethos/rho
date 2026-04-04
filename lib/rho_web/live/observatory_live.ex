defmodule RhoWeb.ObservatoryLive do
  use Phoenix.LiveView

  import RhoWeb.ObservatoryComponents

  alias Rho.Agent.Worker
  alias Rho.Demos.Hiring.{Candidates, Simulation}

  # --- Mount ---

  # Landing page — no session yet
  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    {:ok,
     assign(socket,
       session_id: nil,
       simulation_status: :not_started,
       agents: %{},
       timeline: [],
       scores: %{},
       round: 0,
       convergence_history: [],
       insights: [],
       activity: %{},
       selected_agent: nil,
       chairman_ready: false,
       bus_subs: []
     ), layout: {RhoWeb.Layouts, :app}}
  end

  # Observatory with session — subscribe first, then hydrate
  def mount(%{"session_id" => sid}, _session, socket) do
    socket =
      assign(socket,
        session_id: sid,
        simulation_status: :not_started,
        agents: %{},
        timeline: [],
        scores: seed_scoreboard(),
        round: 0,
        convergence_history: [],
        insights: [],
        activity: %{},
        selected_agent: nil,
        chairman_ready: false,
        bus_subs: []
      )

    if connected?(socket) do
      # Subscribe to all relevant event channels BEFORE starting
      subs =
        [
          "rho.agent.#{sid}.*",
          "rho.session.#{sid}.events.*",
          "rho.task.#{sid}.*",
          "rho.hiring.#{sid}.**"
        ]
        |> Enum.flat_map(fn pattern ->
          case Rho.Comms.subscribe(pattern) do
            {:ok, sub_id} -> [sub_id]
            {:error, _} -> []
          end
        end)

      Process.send_after(self(), :tick, 500)

      socket =
        socket
        |> assign(:bus_subs, subs)
        |> hydrate_from_registry(sid)
        |> hydrate_from_simulation(sid)
        |> replay_signals(sid)

      {:ok, socket, layout: {RhoWeb.Layouts, :app}}
    else
      {:ok, socket, layout: {RhoWeb.Layouts, :app}}
    end
  end

  # --- Events ---

  @impl true
  def handle_event("start_simulation", _params, socket) do
    session_id = "hiring_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Simulation.start(session_id: session_id)
    {:noreply, push_navigate(socket, to: "/observatory/#{session_id}")}
  end

  def handle_event("begin_simulation", _params, socket) do
    sid = socket.assigns.session_id

    # Ensure simulation process exists (may have been lost on server restart)
    case Simulation.start(session_id: sid) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Simulation.begin_simulation(sid) do
      :ok ->
        {:noreply, assign(socket, simulation_status: :running)}

      {:error, reason} ->
        require Logger
        Logger.error("[Observatory] begin_simulation failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, selected_agent: agent_id)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_agent: nil)}
  end

  def handle_event("ask_chairman", %{"question" => question}, socket) do
    question = String.trim(question)

    if question == "" do
      {:noreply, socket}
    else
      sid = socket.assigns.session_id

      case GenServer.whereis(Simulation.via(sid)) do
        nil ->
          notice = %{
            type: :system_notice, agent_role: nil, agent_id: nil, target: nil,
            text: "Session expired. Please start a new simulation.",
            candidate_id: nil, candidate_name: nil, score: nil, delta: nil,
            round: socket.assigns.round, timestamp: System.monotonic_time(:millisecond)
          }
          {:noreply, assign(socket, timeline: socket.assigns.timeline ++ [notice])}

        _pid ->
          Rho.Comms.publish("rho.hiring.#{sid}.user.question", %{
            session_id: sid,
            text: question,
            round: socket.assigns.round
          }, source: "/observatory/#{sid}")

          Simulation.ask(sid, question)
          {:noreply, socket}
      end
    end
  end

  # --- Tick: poll BEAM process internals ---

  @impl true
  def handle_info(:tick, socket) do
    agents = poll_process_stats(socket.assigns.agents)
    insights = generate_insights(agents)
    Process.send_after(self(), :tick, 500)
    {:noreply, assign(socket, agents: agents, insights: insights)}
  end

  # --- Signal handling ---

  def handle_info({:signal, %Jido.Signal{type: type, data: data}}, socket) do
    require Logger
    # Debug: log events to see what's arriving
    cond do
      String.contains?(type, "error") ->
        Logger.error("[Observatory] ERROR from #{data[:agent_id]}: #{inspect(data[:reason])}")
      String.contains?(type, "scores.submitted") ->
        Logger.info("[Observatory] SCORES from #{inspect(data[:role])}: #{inspect(data[:scores])}")
      String.contains?(type, "text_delta") ->
        :ok
      true ->
        Logger.debug("[Observatory] signal: #{type}")
    end

    socket = RhoWeb.ObservatoryProjection.project(socket, type, data)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  # Landing page
  @impl true
  def render(%{session_id: nil} = assigns) do
    candidates = Candidates.all()
    assigns = Phoenix.Component.assign(assigns, :candidates, candidates)

    ~H"""
    <div class="obs-landing">
      <div class="obs-landing-header">
        <div class="obs-mission-eyebrow">// multi-agent simulation</div>
        <h1>Hiring Committee</h1>
        <p>You're the hiring manager. 5 candidates, 3 offer slots, and a panel of AI evaluators who don't always agree.</p>
      </div>

      <div class="obs-constraints">
        <div class="obs-constraint">
          <div class="obs-constraint-value">$160K–190K</div>
          <div class="obs-constraint-label">Budget Band</div>
        </div>
        <div class="obs-constraint">
          <div class="obs-constraint-value">3</div>
          <div class="obs-constraint-label">Max Offers</div>
        </div>
        <div class="obs-constraint">
          <div class="obs-constraint-value">5</div>
          <div class="obs-constraint-label">Candidates</div>
        </div>
      </div>

      <div class="obs-landing-section">
        <div class="obs-section-header">
          <span class="obs-section-num">01</span>
          <span class="obs-landing-section-title" style="margin-bottom:0">The Candidates</span>
          <span class="obs-section-aside">Senior Backend Engineer</span>
        </div>
        <.candidate_cards candidates={@candidates} />
      </div>

      <div class="obs-landing-panel-row">
        <div class="obs-landing-panel-left">
          <div class="obs-section-header">
            <span class="obs-section-num">02</span>
            <span class="obs-landing-section-title" style="margin-bottom:0">The Panel</span>
          </div>
          <.panel_formation />
        </div>
        <div class="obs-landing-panel-right">
          <.why_multi_agent />
        </div>
      </div>

      <div class="obs-landing-section">
        <div class="obs-section-header">
          <span class="obs-section-num">03</span>
          <span class="obs-landing-section-title" style="margin-bottom:0">How It Plays Out</span>
        </div>
        <.how_it_works />
      </div>

      <button class="obs-start-btn-large" phx-click="start_simulation">
        Start Simulation
      </button>
      <div class="obs-start-meta">~2–3 min · 3 agents × 2 rounds · DeepSeek v3</div>
    </div>
    """
  end

  # Active observatory
  def render(assigns) do
    candidates = Candidates.all()
    assigns = Phoenix.Component.assign(assigns, :candidates, candidates)

    ~H"""
    <div class="obs-layout">
      <header class="obs-header">
        <h1 class="obs-title">Hiring Committee Observatory</h1>
        <div class="obs-header-stats">
          <span>Round <%= @round %></span>
          <span><%= map_size(@agents) %> agents</span>
          <span><%= length(@timeline) %> events</span>
          <span class={"obs-status-badge obs-status-#{@simulation_status}"}>
            <%= @simulation_status %>
          </span>
          <button :if={@simulation_status == :not_started}
            class="obs-start-btn" phx-click="begin_simulation">
            Begin
          </button>
        </div>
      </header>

      <.insights_bar insights={@insights} />

      <div class="obs-main">
        <div class="obs-left">
          <div class="obs-agents-grid">
            <.agent_card :for={{_id, agent} <- @agents} agent={agent} />
          </div>
          <.unified_timeline timeline={@timeline} />
          <form :if={@chairman_ready} phx-submit="ask_chairman" class="obs-chat-input">
            <input type="text" name="question" placeholder="Ask the Chairman anything about the simulation..."
                   autocomplete="off" />
            <button type="submit">Ask</button>
          </form>
        </div>

        <div class="obs-right">
          <.scoreboard scores={@scores} candidates={@candidates} />
          <.convergence_chart convergence_history={@convergence_history} />
        </div>

        <.agent_drawer
          :if={@selected_agent && @agents[@selected_agent]}
          agent={@agents[@selected_agent]}
          activity={Map.get(@activity, @selected_agent, %{text: "", entries: []})}
        />
      </div>
    </div>
    """
  end

  # --- Private ---

  defp hydrate_from_registry(socket, session_id) do
    agents =
      Rho.Agent.Registry.list(session_id)
      |> Enum.reduce(socket.assigns.agents, fn agent, acc ->
        Map.put_new(acc, agent.agent_id, %{
          agent_id: agent.agent_id,
          role: agent.role,
          agent_name: agent[:agent_name] || agent.role,
          status: agent.status,
          depth: agent.depth,
          pid: agent.pid,
          current_tool: nil,
          current_step: nil,
          message_queue_len: 0,
          heap_size: 0,
          reductions: 0,
          prev_reductions: 0,
          reductions_per_sec: 0,
          alive: is_pid(agent.pid) and Process.alive?(agent.pid)
        })
      end)

    assign(socket, :agents, agents)
  end

  defp hydrate_from_simulation(socket, session_id) do
    case GenServer.whereis(Simulation.via(session_id)) do
      nil -> socket
      _pid ->
        try do
          sim = Simulation.get_state(session_id)

          # Rebuild scoreboard from simulation's scores (latest round only)
          latest_round =
            sim.scores
            |> Map.keys()
            |> Enum.map(fn {_role, round} -> round end)
            |> Enum.max(fn -> 0 end)

          scores =
            sim.scores
            |> Enum.filter(fn {{_role, round}, _} -> round == latest_round end)
            |> Enum.reduce(seed_scoreboard(), fn {{role, _round}, entries}, acc ->
              role_key = score_column_for(role)

              Enum.reduce(entries, acc, fn entry, inner ->
                id = entry["id"]
                score = entry["score"]

                Map.update(inner, id, %{}, fn row ->
                  row
                  |> Map.put(role_key, score)
                  |> recompute_avg()
                end)
              end)
            end)

          # Rebuild agents from evaluators map (even if processes are dead)
          agents =
            Enum.reduce(sim.evaluators, socket.assigns.agents, fn {role, agent_id}, acc ->
              Map.put_new(acc, agent_id, %{
                agent_id: agent_id,
                role: role,
                agent_name: role,
                status: :stopped,
                depth: 1,
                pid: Worker.whereis(agent_id),
                current_tool: nil,
                current_step: nil,
                message_queue_len: 0,
                heap_size: 0,
                reductions: 0,
                prev_reductions: 0,
                reductions_per_sec: 0,
                alive: false
              })
            end)

          socket
          |> assign(:scores, scores)
          |> assign(:round, sim.round)
          |> assign(:simulation_status, sim.status)
          |> assign(:agents, agents)
          |> assign(:chairman_ready, sim.status == :completed and sim.summary_delivered)
        catch
          :exit, _ -> socket
        end
    end
  end

  defp score_column_for(:technical_evaluator), do: :technical
  defp score_column_for(:culture_evaluator), do: :culture
  defp score_column_for(:compensation_evaluator), do: :compensation
  defp score_column_for(_), do: :other

  defp recompute_avg(row) do
    values =
      [row[:technical], row[:culture], row[:compensation]]
      |> Enum.reject(&is_nil/1)

    avg = if values == [], do: nil, else: Enum.sum(values) / length(values)
    Map.put(row, :avg, avg)
  end

  defp replay_signals(socket, session_id) do
    # Replay signals from the in-memory bus journal to restore state after reconnect.
    # Skip rho.session.** (flooded with text_delta/llm_usage noise hitting 1000 batch limit).
    # Debate signals (message_sent/broadcast) are published via multi_agent mount directly
    # to the bus, so we replay them with a specific pattern.
    patterns = [
      "rho.agent.#{session_id}.**",
      "rho.hiring.#{session_id}.**",
      "rho.session.#{session_id}.events.message_sent",
      "rho.session.#{session_id}.events.broadcast"
    ]

    signals =
      patterns
      |> Enum.flat_map(fn pattern ->
        case Rho.Comms.replay(pattern) do
          {:ok, sigs} when is_list(sigs) -> sigs
          sigs when is_list(sigs) -> sigs
          _ -> []
        end
      end)
      |> Enum.sort_by(fn recorded -> recorded.signal.time || "" end)

    # During replay, temporarily mark as :replaying so projection doesn't
    # filter out debates that happened before completion
    socket = assign(socket, :replaying, true)

    socket =
      Enum.reduce(signals, socket, fn recorded, acc ->
        sig = recorded.signal
        RhoWeb.ObservatoryProjection.project(acc, sig.type, sig.data)
      end)

    assign(socket, :replaying, false)
  end

  defp seed_scoreboard do
    Map.new(Candidates.all(), fn c ->
      {c.id, %{name: c.name, technical: nil, culture: nil, compensation: nil, avg: nil,
               prev_technical: nil, prev_culture: nil, prev_compensation: nil}}
    end)
  end

  defp poll_process_stats(agents) do
    Map.new(agents, fn {id, agent} ->
      pid = agent[:pid]

      if pid && Process.alive?(pid) do
        proc_info =
          Process.info(pid, [:message_queue_len, :heap_size, :reductions]) || []

        stats = Enum.into(proc_info, %{})

        worker_meta =
          try do
            Worker.info(pid)
          catch
            :exit, _ -> %{}
          end

        prev = agent[:prev_reductions] || Map.get(stats, :reductions, 0)
        delta = Map.get(stats, :reductions, 0) - prev

        {id,
         agent
         |> Map.merge(stats)
         |> Map.put(:current_tool, worker_meta[:current_tool])
         |> Map.put(:current_step, worker_meta[:current_step])
         |> Map.put(:status, worker_meta[:status] || agent.status)
         |> Map.put(:prev_reductions, Map.get(stats, :reductions, 0))
         |> Map.put(:reductions_per_sec, delta * 2)
         |> Map.put(:alive, true)}
      else
        {id, %{agent | alive: false}}
      end
    end)
  end

  defp generate_insights(agents) do
    busy_count = agents |> Map.values() |> Enum.count(&(&1.status == :busy))

    dead_agents =
      agents
      |> Map.values()
      |> Enum.filter(&(&1[:alive] == false))
      |> Enum.map(&format_name(&1.agent_name))

    dead_insight =
      if dead_agents != [] do
        [%{text: "#{Enum.join(dead_agents, ", ")} #{if length(dead_agents) == 1, do: "process is", else: "processes are"} down", severity: :highlight}]
      else
        []
      end

    agent_insights =
      agents
      |> Map.values()
      |> Enum.flat_map(fn agent ->
        cond do
          agent[:message_queue_len] && agent.message_queue_len > 5 ->
            [
              %{
                text:
                  "#{format_name(agent.agent_name)} has #{agent.message_queue_len} queued messages — BEAM mailbox backpressure, zero infrastructure",
                severity: :highlight
              }
            ]

          agent[:heap_size] && agent.heap_size > 100_000 && agent[:alive] != false ->
            [
              %{
                text:
                  "#{format_name(agent.agent_name)} heap at #{div(agent.heap_size * 8, 1024)}KB — BEAM tracks per-process, not per-thread",
                severity: :info
              }
            ]

          true ->
            []
        end
      end)

    global_insights =
      cond do
        busy_count >= 3 ->
          [
            %{
              text:
                "#{busy_count} concurrent LLM calls — each in an isolated BEAM process, not OS threads",
              severity: :highlight
            }
          ]

        map_size(agents) >= 3 ->
          [
            %{
              text:
                "#{map_size(agents)} agents, 1 Elixir process each. No Redis, no Celery, no external queue.",
              severity: :info
            }
          ]

        true ->
          []
      end

    (global_insights ++ dead_insight ++ agent_insights) |> Enum.take(4)
  end

  defp format_name(name) when is_atom(name) do
    name |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_name(name), do: to_string(name)
end
