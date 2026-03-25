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
        bus_subs: []
      )

    if connected?(socket) do
      # Subscribe to all relevant event channels BEFORE starting
      subs =
        [
          "rho.agent.*",
          "rho.session.#{sid}.events.*",
          "rho.task.*",
          "rho.hiring.scores.*",
          "rho.hiring.round.*",
          "rho.hiring.simulation.*",
          "rho.hiring.chairman.*"
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
        <h1>Hiring Committee Observatory</h1>
        <p>Watch 3 AI agents evaluate candidates, debate each other, and converge on a hiring decision — in real-time. Every agent is a BEAM process.</p>
      </div>

      <div class="obs-landing-section">
        <div class="obs-landing-section-title">The Evaluators</div>
        <.evaluator_cards />
      </div>

      <div class="obs-landing-section">
        <div class="obs-landing-section-title">The Candidates — Senior Backend Engineer · $160K–$190K · Max 3 offers</div>
        <.candidate_cards candidates={@candidates} />
      </div>

      <div class="obs-landing-section">
        <div class="obs-landing-section-title">How It Works</div>
        <.how_it_works />
      </div>

      <button class="obs-start-btn-large" phx-click="start_simulation">
        Start Simulation
      </button>
      <div class="obs-start-meta">~2–3 min · 3 agents × 2 rounds · 5 candidates · Uses Claude Haiku</div>
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

          agent[:alive] == false ->
            [%{text: "#{format_name(agent.agent_name)} process is down", severity: :highlight}]

          agent[:heap_size] && agent.heap_size > 100_000 ->
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

    (global_insights ++ agent_insights) |> Enum.take(3)
  end

  defp format_name(name) when is_atom(name) do
    name |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_name(name), do: to_string(name)
end
