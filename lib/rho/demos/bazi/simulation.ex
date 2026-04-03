defmodule Rho.Demos.Bazi.Simulation do
  @moduledoc """
  Coordinator GenServer for the BaZi multi-model debate simulation.
  Manages chart parsing, dimension proposals, scoring rounds, and agent spawning.
  Not an LLM — a plain Elixir GenServer.
  """

  use GenServer

  require Logger

  alias Rho.Agent.{Worker, Supervisor}
  alias Rho.Demos.Bazi.{Tools, ChartCalculator}
  alias Rho.Mount.Context
  alias Rho.Comms

  @advisor_roles [:bazi_advisor_qwen, :bazi_advisor_deepseek, :bazi_advisor_gpt]
  # @round_timeout_ms and @nudge_retry_ms will be added in Tasks 6/7

  defstruct [
    :session_id,
    status: :not_started,
    round: 0,
    max_rounds: 2,
    # Agent tracking
    chairman_agent_id: nil,
    chairman_tools: nil,
    advisors: %{},
    advisor_tools: %{},
    # BaZi-specific
    chart_data: nil,
    chart_image_b64: nil,
    birth_info: nil,
    user_options: [],
    user_question: nil,
    dimensions: [],
    dimension_proposals: %{},
    # Scoring
    scores: %{},
    # Timeout / chairman
    round_started_at: nil,
    round_timer_ref: nil,
    chairman_task: nil,
    pending_replies: 0,
    summary_delivered: false,
    summary_pending: false,
    deferred_closing_prompt: nil,
    # User info requests
    pending_user_info: nil,
    # Q&A
    last_question: nil,
    retry_count: 0
  ]

  # --- Public API ---

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {Rho.AgentRegistry, "bazi_sim_#{session_id}"}}

  @doc """
  Begin the simulation.

  Params:
    - `image_b64` (optional) — base64-encoded chart image
    - `birth_info` (optional) — %{year, month, day, hour, minute, gender}
    - `options` — list of options/choices to evaluate
    - `question` — the user's question
  """
  def begin_simulation(session_id, params) do
    GenServer.call(via(session_id), {:begin, params}, 30_000)
  end

  def approve_dimensions(session_id, dimensions) do
    GenServer.call(via(session_id), {:approve_dimensions, dimensions})
  end

  def reply_to_advisor(session_id, answer) do
    GenServer.cast(via(session_id), {:reply_to_advisor, answer})
  end

  def ask(session_id, question) do
    GenServer.cast(via(session_id), {:ask, question})
  end

  def status(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(session_id) do
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.chart.parsed")
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.dimensions.proposed")
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.scores.submitted")
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.user_info.requested")
    {:ok, _} = Comms.subscribe("rho.task.#{session_id}.completed")

    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # Mode 1: Image only — spawn chairman, send image for parsing
  @impl true
  def handle_call({:begin, %{image_b64: b64} = params}, _from, %{status: :not_started} = state)
      when is_binary(b64) and not is_map_key(params, :birth_info) do
    state = %{state |
      chart_image_b64: b64,
      user_options: params[:options] || [],
      user_question: params[:question]
    }

    Comms.publish("rho.bazi.#{state.session_id}.simulation.started", %{
      session_id: state.session_id,
      mode: :image_only
    }, source: "/session/#{state.session_id}")

    state = spawn_chairman(state)
    state = send_chart_to_chairman(state)

    {:reply, :ok, %{state | status: :parsing_chart}}
  end

  # Mode 2: Birth info only — calculate directly, skip image parsing
  @impl true
  def handle_call({:begin, %{birth_info: info} = params}, _from, %{status: :not_started} = state)
      when is_map(info) and not is_map_key(params, :image_b64) do
    state = %{state |
      birth_info: info,
      user_options: params[:options] || [],
      user_question: params[:question]
    }

    Comms.publish("rho.bazi.#{state.session_id}.simulation.started", %{
      session_id: state.session_id,
      mode: :birth_info_only
    }, source: "/session/#{state.session_id}")

    case calculate_chart(info) do
      {:ok, chart_data} ->
        state = %{state | chart_data: chart_data}
        state = spawn_chairman(state)
        state = spawn_advisors(state)
        state = start_dimension_proposal(state)
        {:reply, :ok, %{state | status: :proposing_dimensions}}

      {:error, reason} ->
        Logger.error("[Bazi] Chart calculation failed: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  # Mode 3: Both image and birth info — calculate first, also parse image for cross-validation
  @impl true
  def handle_call({:begin, %{image_b64: b64, birth_info: info} = params}, _from, %{status: :not_started} = state)
      when is_binary(b64) and is_map(info) do
    state = %{state |
      chart_image_b64: b64,
      birth_info: info,
      user_options: params[:options] || [],
      user_question: params[:question]
    }

    Comms.publish("rho.bazi.#{state.session_id}.simulation.started", %{
      session_id: state.session_id,
      mode: :both
    }, source: "/session/#{state.session_id}")

    case calculate_chart(info) do
      {:ok, chart_data} ->
        state = %{state | chart_data: chart_data}
        state = spawn_chairman(state)
        # Also send image to chairman for cross-validation
        state = send_chart_to_chairman(state)
        {:reply, :ok, %{state | status: :parsing_chart}}

      {:error, reason} ->
        Logger.error("[Bazi] Chart calculation failed: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:begin, _}, _from, %{status: :not_started} = state) do
    {:reply, {:error, :missing_input}, state}
  end

  def handle_call({:begin, _}, _from, state) do
    {:reply, {:error, :already_started}, state}
  end

  # Placeholder for dimension approval (Task 6)
  @impl true
  def handle_call({:approve_dimensions, _dims}, _from, state) do
    {:reply, {:error, :not_implemented}, state}
  end

  # Placeholder for user reply to advisor (Task 7)
  @impl true
  def handle_cast({:reply_to_advisor, _answer}, state) do
    {:noreply, state}
  end

  # Placeholder for ask (Task 7)
  @impl true
  def handle_cast({:ask, _question}, state) do
    {:noreply, state}
  end

  # --- Signal handlers (placeholders for Tasks 6 & 7) ---

  @impl true
  def handle_info({:signal, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # --- Private: Agent Spawning ---

  defp spawn_chairman(state) do
    agent_id = Rho.Session.new_agent_id()
    config = Rho.Config.agent(:bazi_chairman)

    tool_context = %Context{
      model: config.model,
      tape_name: "agent_#{agent_id}",
      memory_mod: Rho.Config.memory_module(),
      input_messages: [],
      opts: [],
      workspace: File.cwd!(),
      agent_name: :bazi_chairman,
      agent_id: agent_id,
      session_id: state.session_id,
      depth: 1,
      subagent: false
    }

    allowed_tools = ~w(send_message)

    mount_tools =
      Rho.MountRegistry.collect_tools(tool_context)
      |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

    chart_tool = Tools.submit_chart_data_tool(state.session_id, agent_id)
    finish_tool = Rho.Tools.Finish.tool_def()
    all_tools = mount_tools ++ [chart_tool, finish_tool]

    memory_mod = Rho.Config.memory_module()
    tape = "agent_#{agent_id}"
    memory_mod.bootstrap(tape)

    {:ok, _pid} =
      Supervisor.start_worker(
        agent_id: agent_id,
        session_id: state.session_id,
        workspace: File.cwd!(),
        agent_name: :bazi_chairman,
        role: :bazi_chairman,
        depth: 1,
        memory_ref: tape,
        max_steps: config.max_steps,
        system_prompt: config.system_prompt,
        tools: all_tools,
        model: config.model
      )

    Logger.info("[Bazi] Spawned chairman as #{agent_id}")
    %{state | chairman_agent_id: agent_id, chairman_tools: all_tools}
  end

  defp spawn_advisors(state) do
    advisors =
      @advisor_roles
      |> Enum.with_index()
      |> Enum.map(fn {role, idx} ->
        if idx > 0, do: Process.sleep(1_000)

        agent_id = Rho.Session.new_agent_id()
        config = Rho.Config.agent(role)

        tool_context = %Context{
          model: config.model,
          tape_name: "agent_#{agent_id}",
          memory_mod: Rho.Config.memory_module(),
          input_messages: [],
          opts: [],
          workspace: File.cwd!(),
          agent_name: role,
          agent_id: agent_id,
          session_id: state.session_id,
          depth: 1,
          subagent: false
        }

        allowed_tools = ~w(send_message list_agents)

        mount_tools =
          Rho.MountRegistry.collect_tools(tool_context)
          |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

        dimensions_tool = Tools.submit_dimensions_tool(state.session_id, agent_id, role)
        scores_tool = Tools.submit_scores_tool(state.session_id, agent_id, role)
        user_info_tool = Tools.request_user_info_tool(state.session_id, agent_id, role)
        finish_tool = Rho.Tools.Finish.tool_def()
        all_tools = mount_tools ++ [dimensions_tool, scores_tool, user_info_tool, finish_tool]

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

        Logger.info("[Bazi] Spawned #{role} as #{agent_id}")
        {role, %{agent_id: agent_id, tools: all_tools, config: config}}
      end)

    advisor_map = Map.new(advisors, fn {role, info} -> {role, info.agent_id} end)
    tools_map = Map.new(advisors, fn {role, info} -> {role, %{tools: info.tools, config: info.config}} end)

    %{state | advisors: advisor_map, advisor_tools: tools_map}
  end

  # --- Private: Chart Parsing ---

  defp send_chart_to_chairman(state) do
    alias ReqLLM.Message.ContentPart

    chairman_pid = Worker.whereis(state.chairman_agent_id)
    config = Rho.Config.agent(:bazi_chairman)

    image_binary = Base.decode64!(state.chart_image_b64)

    content = [
      ContentPart.text("""
      请仔细分析以下八字命盘图片，提取结构化数据。

      请提取以下信息并以JSON格式通过 submit_chart_data 工具提交：
      - day_master: 日主（如"乙木"）
      - pillars: 四柱信息，包含 year/month/day/hour，每柱含 stem（天干）、branch（地支）、hidden_stems（藏干）、ten_god（十神）
      - notes: 其他相关信息

      提取完成后调用 submit_chart_data 提交数据，然后调用 finish。
      """),
      ContentPart.image(image_binary, "image/png")
    ]

    Worker.submit(chairman_pid, content, tools: state.chairman_tools, model: config.model)

    %{state | chairman_task: :parse}
  end

  defp calculate_chart(%{year: y, month: m, day: d, hour: h} = info) do
    minute = Map.get(info, :minute, 0)
    gender = Map.get(info, :gender, :male)
    ChartCalculator.calculate(y, m, d, h, minute, gender)
  end

  defp start_dimension_proposal(state) do
    chart_text = format_chart_data(state.chart_data)
    options_text = Enum.map_join(state.user_options, "\n", fn opt -> "- #{opt}" end)

    prompt = """
    八字命盘数据：
    #{chart_text}

    用户选项：
    #{options_text}

    用户问题：#{state.user_question}

    请根据以上八字命盘和用户问题，提出3-5个你认为最相关的评分维度（如"财运"、"事业运"、"健康"等）。
    通过 submit_dimensions 工具提交你的维度建议，然后调用 finish。
    """

    state.advisors
    |> Enum.with_index()
    |> Enum.each(fn {{role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)

      if pid do
        role_info = Map.get(state.advisor_tools, role, %{})

        Worker.submit(pid, prompt,
          tools: role_info[:tools],
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end)

    state
  end

  @doc false
  def format_chart_data(nil), do: "（命盘数据尚未解析）"

  def format_chart_data(chart_data) when is_map(chart_data) do
    day_master = chart_data["day_master"] || "未知"

    pillars_text =
      ["year", "month", "day", "hour"]
      |> Enum.map(fn key ->
        label =
          case key do
            "year" -> "年柱"
            "month" -> "月柱"
            "day" -> "日柱"
            "hour" -> "时柱"
          end

        pillar = get_in(chart_data, ["pillars", key]) || %{}
        stem = pillar["stem"] || "?"
        branch = pillar["branch"] || "?"
        hidden = pillar["hidden_stems"] || []
        ten_god = pillar["ten_god"] || ""

        hidden_str = if hidden != [], do: "（藏干：#{Enum.join(hidden, "、")}）", else: ""
        god_str = if ten_god != "", do: " [#{ten_god}]", else: ""

        "  #{label}：#{stem}#{branch}#{hidden_str}#{god_str}"
      end)
      |> Enum.join("\n")

    da_yun_text =
      case chart_data["da_yun"] do
        list when is_list(list) and list != [] ->
          entries =
            Enum.map_join(list, "、", fn dy ->
              "#{dy["start_age"]}岁起 #{dy["gan_zhi"]}"
            end)

          "\n大运：#{entries}"

        _ ->
          ""
      end

    liu_nian_text =
      case chart_data["liu_nian"] do
        %{"year" => year, "gan_zhi" => gz} when gz != "" ->
          "\n流年：#{year}年 #{gz}"

        _ ->
          ""
      end

    notes_text =
      case chart_data["notes"] do
        notes when is_binary(notes) and notes != "" -> "\n备注：#{notes}"
        _ -> ""
      end

    """
    日主：#{day_master}
    四柱：
    #{pillars_text}#{da_yun_text}#{liu_nian_text}#{notes_text}
    """
  end
end
