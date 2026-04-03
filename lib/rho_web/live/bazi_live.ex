defmodule RhoWeb.BaziLive do
  use Phoenix.LiveView

  import RhoWeb.BaziComponents

  alias Rho.Demos.Bazi.Simulation
  alias RhoWeb.BaziProjection

  # --- Mount ---

  # Landing page — no session yet, redirect to a new one
  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    session_id = "bazi_#{System.unique_integer([:positive])}"
    {:ok, push_navigate(socket, to: "/bazi/#{session_id}"), layout: {RhoWeb.Layouts, :app}}
  end

  # Active session
  def mount(%{"session_id" => sid}, _session, socket) do
    socket =
      assign(socket,
        session_id: sid,
        simulation_status: :not_started,
        phase: :not_started,
        round: 0,
        timeline: [],
        scores: %{},
        agents: %{},
        chart_data: nil,
        dimensions: [],
        proposed_dimensions: [],
        user_options: [],
        user_question: "",
        chairman_ready: false,
        pending_user_question: nil,
        birth_input_mode: "image",
        bus_subs: []
      )

    socket =
      if connected?(socket) do
        # Subscribe to all relevant event channels BEFORE starting
        subs =
          [
            "rho.agent.#{sid}.*",
            "rho.bazi.#{sid}.**",
            "rho.task.#{sid}.*"
          ]
          |> Enum.flat_map(fn pattern ->
            case Rho.Comms.subscribe(pattern) do
              {:ok, sub_id} -> [sub_id]
              {:error, _} -> []
            end
          end)

        Process.send_after(self(), :tick, 500)

        socket
        |> assign(:bus_subs, subs)
        |> hydrate_from_simulation(sid)
      else
        socket
      end

    {:ok,
     socket
     |> allow_upload(:chart_image,
       accept: ~w(.png .jpg .jpeg),
       max_entries: 1,
       max_file_size: 10_000_000
     ), layout: {RhoWeb.Layouts, :app}}
  end

  # --- Events ---

  @impl true
  def handle_event("begin_simulation", params, socket) do
    sid = socket.assigns.session_id

    # Ensure coordinator process exists
    case Simulation.start_link(sid) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Build simulation params from form data
    sim_params = build_sim_params(socket, params)

    case Simulation.begin_simulation(sid, sim_params) do
      :ok ->
        {:noreply,
         socket
         |> assign(:simulation_status, :running)
         |> assign(:user_options, sim_params[:options] || [])
         |> assign(:user_question, sim_params[:question] || "")}

      {:error, reason} ->
        require Logger
        Logger.error("[BaziLive] begin_simulation failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("approve_dimensions", params, socket) do
    sid = socket.assigns.session_id

    # Use the possibly-edited textarea version, falling back to the hidden input
    raw = params["dimensions_edit"] || params["dimensions"] || "[]"

    case Jason.decode(raw) do
      {:ok, dims} when is_list(dims) ->
        case Simulation.approve_dimensions(sid, dims) do
          :ok ->
            {:noreply,
             socket
             |> assign(:dimensions, dims)
             |> assign(:phase, :round_1)}

          {:error, reason} ->
            require Logger
            Logger.error("[BaziLive] approve_dimensions failed: #{inspect(reason)}")
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reply_to_advisor", %{"answer" => answer}, socket) do
    answer = String.trim(answer)

    if answer == "" do
      {:noreply, socket}
    else
      Simulation.reply_to_advisor(socket.assigns.session_id, answer)
      {:noreply, assign(socket, :pending_user_question, nil)}
    end
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
            type: :chairman,
            agent_id: nil,
            text: "Session expired. Please start a new simulation.",
            round: socket.assigns.round,
            timestamp: System.monotonic_time(:millisecond)
          }

          {:noreply, assign(socket, timeline: socket.assigns.timeline ++ [notice])}

        _pid ->
          Simulation.ask(sid, question)

          # Add user question to timeline
          entry = %{
            type: :user_reply,
            text: question,
            original_question: "",
            round: socket.assigns.round,
            timestamp: System.monotonic_time(:millisecond)
          }

          {:noreply, assign(socket, timeline: socket.assigns.timeline ++ [entry])}
      end
    end
  end

  def handle_event("toggle_input_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :birth_input_mode, mode)}
  end

  # --- Tick: poll BEAM process internals ---

  @impl true
  def handle_info(:tick, socket) do
    agents = poll_process_stats(socket.assigns.agents)
    Process.send_after(self(), :tick, 500)
    {:noreply, assign(socket, agents: agents)}
  end

  # --- Signal handling ---

  def handle_info({:signal, %Jido.Signal{type: type, data: data}}, socket) do
    socket = BaziProjection.project(socket, type, data)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(%{simulation_status: :not_started} = assigns) do
    ~H"""
    <.setup_form birth_input_mode={@birth_input_mode} uploads={@uploads} />
    """
  end

  def render(assigns) do
    ~H"""
    <div class="bazi-observatory">
      <.top_bar phase={@phase} round={@round} simulation_status={@simulation_status} />

      <div class="bazi-body">
        <.agent_panel agents={@agents} />
        <.timeline
          timeline={@timeline}
          phase={@phase}
          proposed_dimensions={@proposed_dimensions}
          pending_user_question={@pending_user_question}
          chairman_ready={@chairman_ready}
        />
        <.scoreboard scores={@scores} dimensions={@dimensions} />
      </div>
    </div>
    """
  end

  # --- Private ---

  defp build_sim_params(socket, params) do
    mode = socket.assigns.birth_input_mode
    options = parse_options(params["options"] || "")
    question = String.trim(params["question"] || "")

    base = %{options: options, question: question}

    # Add image if available
    base =
      if mode in ["image", "both"] do
        case consume_uploaded_entries(socket, :chart_image, fn %{path: path}, _entry ->
               {:ok, File.read!(path) |> Base.encode64()}
             end) do
          [b64 | _] -> Map.put(base, :image_b64, b64)
          _ -> base
        end
      else
        base
      end

    # Add birth info if available
    if mode in ["birth", "both"] do
      birth_info = %{
        year: parse_int(params["birth_year"]),
        month: parse_int(params["birth_month"]),
        day: parse_int(params["birth_day"]),
        hour: parse_int(params["birth_hour"]),
        minute: parse_int(params["birth_minute"] || "0"),
        gender: parse_gender(params["birth_gender"])
      }

      if birth_info.year && birth_info.month && birth_info.day && birth_info.hour do
        Map.put(base, :birth_info, birth_info)
      else
        base
      end
    else
      base
    end
  end

  defp parse_options(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp parse_gender("female"), do: :female
  defp parse_gender(_), do: :male

  defp hydrate_from_simulation(socket, session_id) do
    case GenServer.whereis(Simulation.via(session_id)) do
      nil ->
        socket

      _pid ->
        try do
          sim = Simulation.status(session_id)

          socket
          |> assign(:round, sim.round)
          |> assign(:simulation_status, sim.status)
          |> assign(:dimensions, sim.dimensions)
          |> assign(:user_options, sim.user_options)
          |> assign(:user_question, sim.user_question || "")
          |> assign(:chart_data, sim.chart_data)
          |> assign(:chairman_ready, sim.status == :completed and sim.summary_delivered)
          |> assign(:phase, status_to_phase(sim.status))
          |> hydrate_agents(sim)
        catch
          :exit, _ -> socket
        end
    end
  end

  defp status_to_phase(:not_started), do: :not_started
  defp status_to_phase(:parsing_chart), do: :not_started
  defp status_to_phase(:proposing_dimensions), do: :proposing_dimensions
  defp status_to_phase(:awaiting_dimension_approval), do: :awaiting_dimension_approval
  defp status_to_phase(:round_1), do: :round_1
  defp status_to_phase(:round_2), do: :round_2
  defp status_to_phase(:completed), do: :completed
  defp status_to_phase(_), do: :not_started

  defp hydrate_agents(socket, sim) do
    agents =
      Enum.reduce(sim.advisors, socket.assigns.agents, fn {role, agent_id}, acc ->
        Map.put_new(acc, agent_id, %{
          agent_id: agent_id,
          role: role,
          agent_name: role,
          status: :stopped,
          depth: 1,
          pid: Rho.Agent.Worker.whereis(agent_id),
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

    # Add chairman
    agents =
      if sim.chairman_agent_id do
        Map.put_new(agents, sim.chairman_agent_id, %{
          agent_id: sim.chairman_agent_id,
          role: :bazi_chairman,
          agent_name: :bazi_chairman,
          status: :stopped,
          depth: 1,
          pid: Rho.Agent.Worker.whereis(sim.chairman_agent_id),
          current_tool: nil,
          current_step: nil,
          message_queue_len: 0,
          heap_size: 0,
          reductions: 0,
          prev_reductions: 0,
          reductions_per_sec: 0,
          alive: false
        })
      else
        agents
      end

    assign(socket, :agents, agents)
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
            Rho.Agent.Worker.info(pid)
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
end
