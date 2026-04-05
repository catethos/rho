defmodule RhoWeb.ObservatoryLive do
  use Phoenix.LiveView

  import RhoWeb.ObservatoryComponents

  alias Rho.Agent.Worker
  alias Rho.Demos.Hiring.{Candidates, Simulation}

  # --- Mount ---

  # Landing page — no session yet
  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    sessions = list_known_sessions()

    {:ok,
     assign(socket,
       active_page: :observatory,
       session_id: nil,
       status: :not_started,
       agents: %{},
       discussion: [],
       discussion_counter: 0,
       scores: %{},
       round: 0,
       bus_subs: [],
       sessions: sessions
     ), layout: {RhoWeb.Layouts, :app}}
  end

  # Observatory with session
  def mount(%{"session_id" => sid}, _session, socket) do
    socket =
      assign(socket,
        active_page: :observatory,
        session_id: sid,
        status: :not_started,
        agents: %{},
        discussion: [],
        discussion_counter: 0,
        scores: seed_scoreboard(),
        round: 0,
        bus_subs: [],
        edges: %{},
        recent_edges: [],
        # Replay state
        replay_queue: :queue.new(),
        replay_speed: :normal,
        replay_active: false
      )

    if connected?(socket) do
      subs =
        [
          "rho.agent.*",
          "rho.session.#{sid}.events.*",
          "rho.task.*",
          "rho.hiring.scores.*",
          "rho.hiring.round.*",
          "rho.hiring.simulation.*"
        ]
        |> Enum.flat_map(fn pattern ->
          case Rho.Comms.subscribe(pattern) do
            {:ok, sub_id} -> [sub_id]
            {:error, _} -> []
          end
        end)

      Process.send_after(self(), :tick, 1000)

      socket =
        socket
        |> assign(:bus_subs, subs)
        |> hydrate_from_registry(sid)
        |> hydrate_from_event_log(sid)

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

    case Simulation.start(session_id: sid) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Simulation.begin_simulation(sid) do
      :ok ->
        {:noreply, assign(socket, status: :running)}

      {:error, reason} ->
        require Logger
        Logger.error("[Observatory] begin_simulation failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # --- Replay controls ---

  def handle_event("replay_speed", %{"speed" => speed}, socket) do
    speed = String.to_existing_atom(speed)
    {:noreply, assign(socket, :replay_speed, speed)}
  end

  def handle_event("replay_skip", _params, socket) do
    # Project all remaining queued events at once
    socket = drain_replay_queue(socket)
    {:noreply, socket}
  end

  def handle_event("replay_pause", _params, socket) do
    {:noreply, assign(socket, :replay_active, false)}
  end

  def handle_event("replay_resume", _params, socket) do
    Process.send_after(self(), :replay_tick, 10)
    {:noreply, assign(socket, :replay_active, true)}
  end

  # --- Replay tick: drip-feed events from queue ---

  @impl true
  def handle_info(:replay_tick, socket) do
    if not socket.assigns.replay_active or :queue.is_empty(socket.assigns.replay_queue) do
      # Replay finished
      socket = finish_replay(socket)
      {:noreply, socket}
    else
      # How many events to project per tick depends on speed
      batch_size = replay_batch_size(socket.assigns.replay_speed)
      {socket, remaining} = project_batch(socket, batch_size)

      if :queue.is_empty(remaining) do
        {:noreply, finish_replay(assign(socket, :replay_queue, remaining))}
      else
        interval = replay_interval(socket.assigns.replay_speed)
        Process.send_after(self(), :replay_tick, interval)
        {:noreply, assign(socket, :replay_queue, remaining)}
      end
    end
  end

  # --- Tick: poll BEAM process stats ---

  def handle_info(:tick, socket) do
    agents = poll_process_stats(socket.assigns.agents)
    Process.send_after(self(), :tick, 1000)
    {:noreply, assign(socket, agents: agents)}
  end

  # --- Signal handling ---

  def handle_info({:signal, %Jido.Signal{type: type, data: data} = _sig}, socket) do
    socket = RhoWeb.ObservatoryProjection.project(socket, type, data)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  # Landing page
  @impl true
  def render(%{session_id: nil} = assigns) do
    ~H"""
    <div class="obs-landing">
      <h1>Multi-Agent Observatory</h1>
      <p>Watch AI agents collaborate in real-time. See every message, tool call, and decision as it happens.</p>
      <button class="obs-btn obs-btn-lg" phx-click="start_simulation">
        Start Hiring Simulation
      </button>

      <div :if={@sessions != []} class="obs-session-list">
        <h2 class="obs-session-list-title">Existing Sessions</h2>
        <a :for={s <- @sessions} class="obs-session-link" href={"/observatory/#{s.id}"}>
          <span class="obs-session-link-id"><%= s.id %></span>
          <span class="obs-session-link-meta">
            <%= if s.live, do: "live", else: "log" %>
            · <%= s.agents %> agents
            <%= if s.events > 0, do: "· #{s.events} events" %>
          </span>
        </a>
      </div>
    </div>
    """
  end

  # Active observatory
  def render(assigns) do
    ~H"""
    <div class="obs-shell">
      <header class="obs-topbar">
        <div class="obs-topbar-left">
          <h1 class="obs-logo">Observatory</h1>
          <span class="obs-session-id"><%= @session_id %></span>
        </div>
        <div class="obs-topbar-right">
          <span class="obs-stat-pill">Round <%= @round %></span>
          <span class="obs-stat-pill"><%= map_size(@agents) %> agents</span>
          <span class="obs-stat-pill"><%= length(@discussion) %> events</span>

          <!-- Replay controls -->
          <div :if={@status == :replaying or @replay_active or not :queue.is_empty(@replay_queue)} class="obs-replay-controls">
            <button :if={@replay_active} class="obs-replay-btn" phx-click="replay_pause" title="Pause">&#9646;&#9646;</button>
            <button :if={not @replay_active and not :queue.is_empty(@replay_queue)} class="obs-replay-btn" phx-click="replay_resume" title="Resume">&#9654;</button>
            <button :for={speed <- ~w(slow normal fast turbo)a}
              class={"obs-replay-speed #{if @replay_speed == speed, do: "active"}"}
              phx-click="replay_speed" phx-value-speed={speed}>
              <%= speed %>
            </button>
            <button class="obs-replay-btn" phx-click="replay_skip" title="Skip to end">&#9197;</button>
            <span class="obs-replay-remaining"><%= :queue.len(@replay_queue) %> left</span>
          </div>

          <span class={"obs-status-pill obs-status-#{@status}"}><%= @status %></span>
          <button :if={@status == :not_started}
            class="obs-btn obs-btn-sm" phx-click="begin_simulation">Begin</button>
        </div>
      </header>

      <div class="obs-body">
        <main class="obs-timeline-pane" id="discussion-timeline" phx-hook="AutoScroll">
          <.discussion_timeline discussion={@discussion} agents={@agents} />
        </main>

        <aside class="obs-sidebar">
          <section :if={map_size(@agents) >= 2} class="obs-sidebar-section">
            <h2 class="obs-sidebar-title">Interactions</h2>
            <.interaction_graph agents={@agents} edges={@edges} recent_edges={@recent_edges} />
          </section>

          <section class="obs-sidebar-section">
            <h2 class="obs-sidebar-title">Agents</h2>
            <.agent_pill :for={{_id, agent} <- @agents} :if={agent[:agent_name]} agent={agent} />
            <p :if={@agents == %{}} class="obs-muted">No agents yet</p>
          </section>

          <section :if={has_scores?(@scores)} class="obs-sidebar-section">
            <h2 class="obs-sidebar-title">Scores</h2>
            <.score_table scores={@scores} />
          </section>

          <section class="obs-sidebar-section">
            <h2 class="obs-sidebar-title">Tokens</h2>
            <.token_summary agents={@agents} />
          </section>
        </aside>
      </div>
    </div>
    """
  end

  # --- Private ---

  defp hydrate_from_registry(socket, session_id) do
    agents =
      Rho.Agent.Registry.list_all(session_id)
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
          token_usage: %{input: 0, output: 0},
          alive: is_pid(agent.pid) and Process.alive?(agent.pid)
        })
      end)

    assign(socket, :agents, agents)
  end

  defp hydrate_from_event_log(socket, session_id) do
    require Logger
    jsonl = Path.join([File.cwd!(), "_rho", "sessions", session_id, "events.jsonl"])
    Logger.info("[Observatory] Attempting replay from #{jsonl}, exists=#{File.exists?(jsonl)}")

    if File.exists?(jsonl) do
      skip_types = ~w(llm_usage step_start llm_text text_delta ui_spec ui_spec_delta)

      events =
        jsonl
        |> File.stream!()
        |> Stream.map(fn line ->
          case Jason.decode(line) do
            {:ok, event} -> event
            _ -> nil
          end
        end)
        |> Stream.reject(&is_nil/1)
        |> Stream.reject(fn event ->
          type = event["type"] || ""
          short = type |> String.split(".") |> List.last()
          short in skip_types
        end)
        |> Enum.map(fn event ->
          type = event["type"] || ""
          data = atomize_keys(event["data"] || %{})
          {type, data}
        end)

      Logger.info("[Observatory] Queued #{length(events)} events for replay")

      queue = :queue.from_list(events)

      # Start the replay timer
      Process.send_after(self(), :replay_tick, 50)

      socket
      |> assign(:replay_queue, queue)
      |> assign(:replay_active, true)
      |> assign(:status, :replaying)
    else
      socket
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "[Observatory] Event log replay failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      socket
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end

        {atom_key, atomize_value(v)}

      {k, v} ->
        {k, atomize_value(v)}
    end)
  end

  defp atomize_keys(other), do: other

  # Recursively atomize nested maps; convert known enum strings to atoms
  defp atomize_value(v) when is_map(v), do: atomize_keys(v)
  defp atomize_value(v) when is_list(v), do: Enum.map(v, &atomize_value/1)
  defp atomize_value(v), do: v

  defp seed_scoreboard do
    Map.new(Candidates.all(), fn c ->
      {c.id, %{name: c.name, technical: nil, culture: nil, compensation: nil, avg: nil}}
    end)
  end

  defp has_scores?(scores) do
    Enum.any?(scores, fn {_id, s} -> s.technical || s.culture || s.compensation end)
  end

  defp poll_process_stats(agents) do
    Map.new(agents, fn {id, agent} ->
      pid = agent[:pid]

      if pid && Process.alive?(pid) do
        proc_info = Process.info(pid, [:message_queue_len, :heap_size, :reductions]) || []
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
         |> Map.put(
           :token_usage,
           worker_meta[:token_usage] || agent[:token_usage] || %{input: 0, output: 0}
         )
         |> Map.put(:prev_reductions, Map.get(stats, :reductions, 0))
         |> Map.put(:reductions_per_sec, delta)
         |> Map.put(:alive, true)}
      else
        {id, %{agent | alive: false}}
      end
    end)
  end

  defp list_known_sessions do
    # Combine live sessions + on-disk event logs
    live =
      Rho.Session.list()
      |> Enum.map(fn info ->
        %{
          id: info.session_id,
          live: true,
          agents: Rho.Agent.Registry.count(info.session_id),
          events: 0
        }
      end)

    live_ids = MapSet.new(live, & &1.id)

    # Scan _rho/sessions/ for event log directories
    sessions_dir = Path.join(File.cwd!(), "_rho/sessions")

    disk =
      case File.ls(sessions_dir) do
        {:ok, dirs} ->
          dirs
          |> Enum.reject(&MapSet.member?(live_ids, &1))
          |> Enum.map(fn dir ->
            jsonl = Path.join([sessions_dir, dir, "events.jsonl"])
            events = count_lines(jsonl)
            agents = Rho.Agent.Registry.count(dir)
            %{id: dir, live: false, agents: agents, events: events}
          end)
          |> Enum.filter(fn s -> s.events > 0 end)

        {:error, _} ->
          []
      end

    # Live first, then disk sorted by id descending
    live ++ Enum.sort_by(disk, & &1.id, :desc)
  end

  # --- Replay helpers ---

  # Batch size: how many events to project per tick
  defp replay_batch_size(:slow), do: 1
  defp replay_batch_size(:normal), do: 2
  defp replay_batch_size(:fast), do: 5
  defp replay_batch_size(:turbo), do: 20

  # Interval between ticks in ms
  defp replay_interval(:slow), do: 300
  defp replay_interval(:normal), do: 120
  defp replay_interval(:fast), do: 40
  defp replay_interval(:turbo), do: 10

  defp project_batch(socket, 0), do: {socket, socket.assigns.replay_queue}

  defp project_batch(socket, n) do
    queue = socket.assigns.replay_queue

    case :queue.out(queue) do
      {:empty, queue} ->
        {socket, queue}

      {{:value, {type, data}}, rest} ->
        socket =
          try do
            RhoWeb.ObservatoryProjection.project(socket, type, data)
          rescue
            _ -> socket
          end

        project_batch(assign(socket, :replay_queue, rest), n - 1)
    end
  end

  defp drain_replay_queue(socket) do
    queue = socket.assigns.replay_queue

    socket =
      :queue.to_list(queue)
      |> Enum.reduce(socket, fn {type, data}, sock ->
        try do
          RhoWeb.ObservatoryProjection.project(sock, type, data)
        rescue
          _ -> sock
        end
      end)

    finish_replay(assign(socket, :replay_queue, :queue.new()))
  end

  defp finish_replay(socket) do
    socket
    |> assign(:replay_active, false)
    |> assign(
      :status,
      if map_size(socket.assigns.agents) > 0 and
           not Enum.any?(socket.assigns.agents, fn {_id, a} -> a[:alive] == true end) do
        :completed
      else
        socket.assigns.status
      end
    )
  end

  defp count_lines(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} ->
        0

      {:ok, _} ->
        path
        |> File.stream!()
        |> Enum.count()

      {:error, _} ->
        0
    end
  rescue
    _ -> 0
  end
end
