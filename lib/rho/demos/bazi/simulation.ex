defmodule Rho.Demos.Bazi.Simulation do
  @moduledoc """
  Coordinator GenServer for the BaZi multi-model debate simulation.
  Manages chart parsing, dimension proposals, scoring rounds, and agent spawning.
  Not an LLM — a plain Elixir GenServer.
  """

  use GenServer

  require Logger

  alias Rho.Agent.{Worker, Supervisor}
  alias Rho.Demos.Bazi.{Tools, Scoring, ChartCalculator}
  alias Rho.Mount.Context
  alias Rho.Comms

  @advisor_roles [:bazi_advisor_qwen, :bazi_advisor_deepseek, :bazi_advisor_gpt]
  @round_timeout_ms 90_000
  @nudge_retry_ms 60_000

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
    calculated_chart_data: nil,
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
        Logger.info("[BaZi] Chart calculated successfully, spawning agents...")
        state = %{state | chart_data: chart_data}
        state = spawn_chairman(state)
        Logger.info("[BaZi] Chairman spawned, now spawning advisors...")
        state = spawn_advisors(state)
        Logger.info("[BaZi] Advisors spawned: #{inspect(Map.keys(state.advisors))}, starting dimension proposal...")
        state = start_dimension_proposal(state)
        Logger.info("[BaZi] Dimension proposal started, transitioning to :proposing_dimensions")
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
        # Store calculated chart separately for cross-validation later
        state = %{state | chart_data: chart_data, calculated_chart_data: chart_data}
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

  # Dimension approval
  @impl true
  def handle_call({:approve_dimensions, dims}, _from, %{status: :awaiting_dimension_approval} = state) do
    Logger.info("[Bazi] Dimensions approved: #{inspect(dims)}")

    Comms.publish("rho.bazi.#{state.session_id}.dimensions.approved", %{
      session_id: state.session_id,
      dimensions: dims
    }, source: "/session/#{state.session_id}")

    state = %{state | dimensions: dims}
    state = start_round(state, 1)
    {:reply, :ok, %{state | status: :round_1}}
  end

  def handle_call({:approve_dimensions, _dims}, _from, state) do
    {:reply, {:error, :wrong_status}, state}
  end

  # --- Casts ---

  # User reply to advisor info request
  @impl true
  def handle_cast({:reply_to_advisor, answer}, %{pending_user_info: pending} = state)
      when not is_nil(pending) do
    Logger.info("[Bazi] User replied to advisor info request: #{String.slice(answer, 0, 100)}")

    # Broadcast answer to all advisors as a user message
    reply_text = "用户回复了你的提问「#{pending.question}」：\n#{answer}\n\n请继续你的分析。"

    for {role, agent_id} <- state.advisors do
      pid = Worker.whereis(agent_id)
      if pid do
        role_info = Map.get(state.advisor_tools, role, %{})
        Worker.submit(pid, reply_text,
          tools: role_info[:tools],
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end

    Comms.publish("rho.bazi.#{state.session_id}.user_info.replied", %{
      session_id: state.session_id,
      answer: answer,
      original_question: pending.question
    }, source: "/session/#{state.session_id}")

    {:noreply, %{state | pending_user_info: nil}}
  end

  def handle_cast({:reply_to_advisor, _answer}, state) do
    {:noreply, state}
  end

  # Post-simulation Q&A
  @impl true
  def handle_cast({:ask, question}, %{status: :completed} = state) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)

    if chairman_pid do
      prompt = build_chat_prompt(state, question)
      config = Rho.Config.agent(:bazi_chairman)
      chat_tools = state.chairman_tools ++ advisor_search_tools(state)
      Worker.submit(chairman_pid, prompt, tools: chat_tools, model: config.model)
      {:noreply, %{state | pending_replies: state.pending_replies + 1, last_question: question, retry_count: 0, chairman_task: :chat}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:ask, _question}, state), do: {:noreply, state}

  # --- Signal handlers ---

  # Chart parsed signal (status: :parsing_chart)
  @impl true
  def handle_info({:signal, %Jido.Signal{type: "rho.bazi." <> rest, data: data}}, %{status: :parsing_chart} = state) do
    if String.ends_with?(rest, ".chart.parsed") do
      Logger.info("[Bazi] Chart data received from chairman")
      parsed_chart_data = data.chart_data || data["chart_data"]

      # If we have calculated_chart_data (mode 3), compare and publish diffs
      state =
        if state.calculated_chart_data do
          diffs = ChartCalculator.compare_charts(state.calculated_chart_data, parsed_chart_data)

          if diffs != [] do
            diff_text = Enum.map_join(diffs, "\n", fn d -> "- #{d}" end)
            Logger.info("[Bazi] Chart cross-validation found diffs:\n#{diff_text}")

            Comms.publish("rho.bazi.#{state.session_id}.chart.diffs", %{
              session_id: state.session_id,
              diffs: diffs
            }, source: "/session/#{state.session_id}")
          end

          # Use calculated data as authoritative
          state
        else
          # Mode 1: image-only, use parsed data as chart_data
          %{state | chart_data: parsed_chart_data}
        end

      state = spawn_advisors(state)
      state = start_dimension_proposal(state)
      {:noreply, %{state | status: :proposing_dimensions}}
    else
      {:noreply, state}
    end
  end

  # Dimension proposal signal (status: :proposing_dimensions)
  def handle_info({:signal, %Jido.Signal{type: "rho.bazi." <> rest, data: data}}, %{status: :proposing_dimensions} = state) do
    if String.ends_with?(rest, ".dimensions.proposed") do
      role = data.role || data["role"]
      dims = data.dimensions || data["dimensions"]
      role_atom = if is_atom(role), do: role, else: String.to_existing_atom(role)

      Logger.info("[Bazi] #{role_atom} proposed dimensions: #{inspect(dims)}")

      proposals = Map.put(state.dimension_proposals, role_atom, dims)
      state = %{state | dimension_proposals: proposals}

      # Check if all advisors have proposed
      if map_size(proposals) >= length(@advisor_roles) do
        merged = Scoring.merge_dimensions(proposals)
        Logger.info("[Bazi] Merged dimensions: #{inspect(merged)}")

        Comms.publish("rho.bazi.#{state.session_id}.dimensions.merged", %{
          session_id: state.session_id,
          proposals: proposals,
          merged: merged
        }, source: "/session/#{state.session_id}")

        {:noreply, %{state | dimensions: merged, status: :awaiting_dimension_approval}}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Score submission signal (status: :round_1 or :round_2)
  def handle_info({:signal, %Jido.Signal{type: "rho.bazi." <> rest, data: data}}, %{status: status} = state)
      when status in [:round_1, :round_2] do
    cond do
      String.ends_with?(rest, ".scores.submitted") ->
        role = data.role || data["role"]
        scores = data.scores || data["scores"]
        role_atom = if is_atom(role), do: role, else: String.to_existing_atom(role)

        state = record_scores(state, role_atom, state.round, scores)
        state = maybe_advance_round(state)
        {:noreply, state}

      String.ends_with?(rest, ".user_info.requested") ->
        role = data[:from_advisor] || data["from_advisor"] || data[:role] || data["role"]
        question = data[:question] || data["question"]

        Logger.info("[Bazi] #{role} requested user info: #{String.slice(to_string(question), 0, 100)}")

        {:noreply, %{state | pending_user_info: %{role: role, question: question}}}

      true ->
        {:noreply, state}
    end
  end

  # Nudge completion while still running — clear the flag so maybe_advance_round won't defer
  def handle_info({:signal, %Jido.Signal{type: "rho.task." <> _rest, data: data}}, %{status: status} = state)
      when status in [:round_1, :round_2] do
    if data.agent_id == state.chairman_agent_id and state.chairman_task == :nudge do
      Logger.debug("[Bazi] Nudge completed (while running)")
      {:noreply, %{state | chairman_task: nil}}
    else
      {:noreply, state}
    end
  end

  # Chairman task completion (status: :completed)
  def handle_info({:signal, %Jido.Signal{type: "rho.task." <> _rest, data: data}}, %{status: :completed} = state) do
    if data.agent_id == state.chairman_agent_id do
      cond do
        # Nudge completion — if summary is pending, send it now
        state.chairman_task == :nudge ->
          Logger.debug("[Bazi] Nudge completed")
          if state.summary_pending do
            Logger.info("[Bazi] Nudge done, now sending deferred summary prompt to chairman")
            send(self(), :send_deferred_summary)
            {:noreply, %{state | chairman_task: :summary, summary_pending: false}}
          else
            {:noreply, %{state | chairman_task: nil}}
          end

        # Summary completion
        state.chairman_task == :summary and not state.summary_delivered ->
          Logger.info("[Bazi] Chairman produced summary. Publishing to timeline.")

          Comms.publish("rho.bazi.#{state.session_id}.chairman.summary", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :bazi_chairman,
            text: data.result
          }, source: "/session/#{state.session_id}")

          {:noreply, %{state | summary_delivered: true, chairman_task: nil}}

        # User asked a question but chairman errored — retry up to 3 times
        state.chairman_task == :chat and String.starts_with?(data.result, "error:") and state.retry_count < 3 ->
          Logger.warning("[Bazi] Chairman failed (attempt #{state.retry_count + 1}/3), retrying: #{String.slice(data.result, 0, 100)}")
          Process.send_after(self(), {:retry_ask, state.last_question}, 2_000)
          {:noreply, %{state | retry_count: state.retry_count + 1}}

        # Max retries exhausted — show user-friendly error
        state.chairman_task == :chat and String.starts_with?(data.result, "error:") ->
          Logger.error("[Bazi] Chairman failed after 3 retries. Giving up.")

          Comms.publish("rho.bazi.#{state.session_id}.chairman.reply", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :bazi_chairman,
            text: "抱歉，我暂时无法回答。请稍后再试。"
          }, source: "/session/#{state.session_id}")

          {:noreply, %{state | pending_replies: state.pending_replies - 1, retry_count: 0, chairman_task: nil}}

        # Successful chat reply
        state.chairman_task == :chat ->
          Logger.info("[Bazi] Chairman replied to user question. Publishing to timeline.")

          Comms.publish("rho.bazi.#{state.session_id}.chairman.reply", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :bazi_chairman,
            text: data.result
          }, source: "/session/#{state.session_id}")

          {:noreply, %{state | pending_replies: state.pending_replies - 1, chairman_task: nil}}

        # Stale completion — ignore
        true ->
          Logger.debug("[Bazi] Ignoring stale chairman task completion (task: #{inspect(state.chairman_task)})")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Ignore task completions from other agents or states
  def handle_info({:signal, %Jido.Signal{type: "rho.task." <> _rest}}, state) do
    {:noreply, state}
  end

  # Catch-all for other signals
  def handle_info({:signal, _}, state), do: {:noreply, state}

  # Retry ask after chairman error
  @impl true
  def handle_info({:retry_ask, question}, %{status: :completed} = state) when is_binary(question) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)

    if chairman_pid do
      Logger.info("[Bazi] Retrying question for chairman.")
      config = Rho.Config.agent(:bazi_chairman)
      prompt = build_chat_prompt(state, question)
      chat_tools = state.chairman_tools ++ advisor_search_tools(state)
      Worker.submit(chairman_pid, prompt, tools: chat_tools, model: config.model)
    end

    {:noreply, state}
  end

  def handle_info({:retry_ask, _}, state), do: {:noreply, state}

  # Round timeout check
  @impl true
  def handle_info({:check_round_timeout, round_num}, %{status: status, round: current_round} = state)
      when round_num == current_round and status in [:round_1, :round_2] do
    submitted_roles =
      state.scores
      |> Map.keys()
      |> Enum.filter(fn {_role, r} -> r == state.round end)
      |> Enum.map(fn {role, _r} -> role end)

    missing = Map.keys(state.advisors) -- submitted_roles

    if missing != [] do
      Logger.warning("[Bazi] Round #{state.round} timeout -- nudging #{length(missing)} advisors: #{inspect(missing)}")

      chairman_pid = Worker.whereis(state.chairman_agent_id)
      config = Rho.Config.agent(:bazi_chairman)

      if chairman_pid do
        missing_names = Enum.map_join(missing, ", ", &Atom.to_string/1)
        Worker.submit(chairman_pid,
          "请向以下顾问发消息，要求他们立即提交第#{state.round}轮评分：#{missing_names}。发送消息后调用 finish。不要做其他事情。",
          tools: state.chairman_tools,
          model: config.model
        )
      end

      ref = Process.send_after(self(), {:check_round_timeout, round_num}, @nudge_retry_ms)
      {:noreply, %{state | round_timer_ref: ref, chairman_task: :nudge}}
    else
      {:noreply, state}
    end
  end

  # Stale timer from previous round or non-running state — ignore
  def handle_info({:check_round_timeout, _}, state), do: {:noreply, state}

  # Deferred summary — nudge finished, now send the actual summary prompt
  def handle_info(:send_deferred_summary, state) do
    if state.deferred_closing_prompt do
      send_summary_to_chairman(state, state.deferred_closing_prompt)
      Logger.info("[Bazi] Deferred summary sent to chairman")
      {:noreply, %{state | deferred_closing_prompt: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

    Logger.info("[BaZi] Sending chart to chairman pid=#{inspect(chairman_pid)} agent_id=#{state.chairman_agent_id}")

    case Worker.submit(chairman_pid, content, tools: state.chairman_tools, model: config.model) do
      {:ok, turn_id} ->
        Logger.info("[BaZi] Chairman chart parse turn started: #{turn_id}")
      other ->
        Logger.error("[BaZi] Chairman submit failed: #{inspect(other)}")
    end

    %{state | chairman_task: :parse}
  end

  defp calculate_chart(%{year: y, month: m, day: d, hour: h} = info) do
    minute = Map.get(info, :minute, 0)
    gender = Map.get(info, :gender, :male)
    ChartCalculator.calculate(y, m, d, h, minute, gender)
  end

  # --- Private: Dimension Proposal ---

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
    注意：本轮只需要提交维度建议，不要评分，不要分析，不要发消息。
    """

    # Only give dimension + finish tools for this phase (prevent premature scoring)
    dim_only_tools = fn role_info ->
      Enum.filter(role_info[:tools] || [], fn tool_def ->
        tool_def.tool.name in ["submit_dimensions", "finish"]
      end)
    end

    state.advisors
    |> Enum.with_index()
    |> Enum.each(fn {{role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)

      if pid do
        role_info = Map.get(state.advisor_tools, role, %{})

        Worker.submit(pid, prompt,
          tools: dim_only_tools.(role_info),
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end)

    state
  end

  # --- Private: Round Orchestration ---

  defp start_round(state, round_num) do
    prompt = round_prompt(round_num, state)

    # Cancel previous round timer if exists
    if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

    Comms.publish("rho.bazi.#{state.session_id}.round.started", %{
      session_id: state.session_id,
      round: round_num
    }, source: "/session/#{state.session_id}")

    Logger.info("[Bazi] Starting round #{round_num}")

    # Submit prompt to each advisor with their custom tools (staggered 1s)
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

    # Schedule round timeout check
    ref = Process.send_after(self(), {:check_round_timeout, round_num}, @round_timeout_ms)

    status = :"round_#{round_num}"
    %{state | round: round_num, round_started_at: System.monotonic_time(:millisecond), round_timer_ref: ref, status: status}
  end

  defp round_prompt(1, state) do
    chart_text = format_chart_data(state.chart_data)
    options_text = Enum.map_join(state.user_options, "\n", fn opt -> "- #{opt}" end)
    dimensions_text = Enum.map_join(state.dimensions, "、", & &1)

    """
    八字命盘数据：
    #{chart_text}

    用户问题：#{state.user_question}

    评估选项：
    #{options_text}

    评分维度：#{dimensions_text}

    请独立分析每个选项，根据八字命盘和用户问题，对每个选项的每个维度进行0-100评分。
    第1轮请进行独立分析，不需要与其他顾问讨论。
    评分完成后通过 submit_scores 工具提交，round 参数设为 1。
    如果需要向用户确认某些信息，可以使用 request_user_info 工具。
    """
  end

  defp round_prompt(round_num, state) do
    prev_round = round_num - 1
    score_table = Scoring.format_score_table(state.scores, prev_round, state.dimensions)
    disagreement = Scoring.build_disagreement_summary(state.scores, prev_round)

    disagreement_section =
      if disagreement == "" do
        "上一轮评分基本一致。"
      else
        "主要分歧：\n#{disagreement}"
      end

    """
    第#{round_num}轮：委员会已审阅上一轮评分。

    上一轮评分汇总：
    #{score_table}

    #{disagreement_section}

    请根据其他顾问的观点重新考虑你的评分。
    你可以使用 send_message 与其他顾问就具体选项进行讨论。
    讨论后通过 submit_scores 工具提交修改后的评分，round 参数设为 #{round_num}。
    对于评分变化较大的维度，请说明理由。
    """
  end

  # --- Private: Score Collection ---

  defp record_scores(state, role, round, scores) do
    key = {role, round}
    Logger.info("[Bazi] #{role} submitted scores for round #{round}")
    %{state | scores: Map.put(state.scores, key, scores)}
  end

  defp maybe_advance_round(state) do
    expected = map_size(state.advisors)

    submitted =
      state.scores
      |> Map.keys()
      |> Enum.count(fn {_role, r} -> r == state.round end)

    if submitted >= expected do
      if state.round >= state.max_rounds do
        # Cancel round timer
        if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

        # Stop all advisor agents to prevent further debate
        for {_role, agent_id} <- state.advisors do
          pid = Worker.whereis(agent_id)
          if pid do
            try do
              GenServer.stop(pid, :normal, 5_000)
            catch
              :exit, _ -> :ok
            end
          end
        end

        Logger.info("[Bazi] Advisors stopped. Preparing closing prompt for chairman.")

        closing_prompt = build_closing_prompt(state)

        Comms.publish("rho.bazi.#{state.session_id}.simulation.completed", %{
          session_id: state.session_id,
          round: state.round
        }, source: "/session/#{state.session_id}")

        # If nudge is in-flight, defer the summary until nudge completes
        if state.chairman_task == :nudge do
          Logger.info("[Bazi] Nudge in-flight -- deferring summary until nudge completes")
          %{state | status: :completed, round_timer_ref: nil, summary_pending: true, deferred_closing_prompt: closing_prompt}
        else
          send_summary_to_chairman(state, closing_prompt)
          Logger.info("[Bazi] Simulation complete after #{state.round} rounds.")
          %{state | status: :completed, round_timer_ref: nil, chairman_task: :summary}
        end
      else
        start_round(state, state.round + 1)
      end
    else
      Logger.info("[Bazi] Waiting for scores: #{submitted}/#{expected} for round #{state.round}")
      state
    end
  end

  # --- Private: Chairman Summary ---

  defp send_summary_to_chairman(state, closing_prompt) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)
    config = Rho.Config.agent(:bazi_chairman)

    if chairman_pid do
      Worker.submit(chairman_pid, closing_prompt,
        tools: state.chairman_tools,
        model: config.model
      )
    else
      Logger.warning("[Bazi] Chairman agent not available for closing summary")
    end
  end

  defp build_closing_prompt(state) do
    score_table = Scoring.format_score_table(state.scores, state.round, state.dimensions)
    aggregated = Scoring.aggregate_scores(state.scores, state.round)
    disagreement = Scoring.build_disagreement_summary(state.scores, state.round)

    # Format aggregated scores
    aggregated_text =
      aggregated
      |> Enum.sort_by(fn {_opt, dim_map} -> -(Map.get(dim_map, "composite", 0)) end)
      |> Enum.map_join("\n", fn {option, dim_map} ->
        composite = Map.get(dim_map, "composite", 0)
        dims = dim_map |> Map.drop(["composite"]) |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)
        "  #{option}: 综合 #{composite} (#{dims})"
      end)

    disagreement_section =
      if disagreement == "" do
        "各顾问评分基本一致，无重大分歧。"
      else
        disagreement
      end

    """
    委员会已完成#{state.round}轮评估。以下是最终评分：

    #{score_table}

    综合评分（各顾问平均）：
    #{aggregated_text}

    主要分歧：
    #{disagreement_section}

    请根据以上数据，对用户的问题"#{state.user_question}"给出最终的综合分析和建议。
    使用 `finish` 工具提交你的总结。
    """
  end

  # --- Private: Post-Simulation Q&A ---

  defp build_chat_prompt(state, question) do
    memory_mod = Rho.Config.memory_module()

    score_table = Scoring.format_score_table(state.scores, state.round, state.dimensions)

    # Include chairman's prior Q&A for conversation context
    chairman_history = memory_mod.history("agent_#{state.chairman_agent_id}")
    prior_chat = summarize_chairman_chat(chairman_history)

    prior_chat_section =
      if prior_chat == "" do
        ""
      else
        """

        ### 之前的问答
        #{prior_chat}
        """
      end

    # List available advisor search tools
    search_tool_list =
      state.advisors
      |> Enum.map_join("\n", fn {role, _agent_id} ->
        "- `search_#{role}_history(query)` — 搜索#{Scoring.format_role(role)}顾问的完整对话历史"
      end)

    """
    你是主席，正在回答一位观看了八字分析辩论的用户的后续问题。

    ### 最终评分
    #{score_table}
    #{prior_chat_section}
    ### 顾问历史搜索工具
    你可以使用以下工具搜索各顾问的完整历史（推理过程、辩论、评分理由）：
    #{search_tool_list}

    当用户询问具体顾问的推理或辩论时，请使用这些工具。
    搜索提示：使用1-2个简短关键词（如"财运"、"评分"、"分歧"），不要用完整句子。
    多个关键词使用AND逻辑——"财运 评分"只返回同时包含两个词的消息。
    对于简单的评分问题，直接使用上面的评分数据即可。

    ### 用户当前问题
    #{question}

    请以对话方式简洁回答。引用具体顾问的观点和评分。如果这个问题之前已经回答过，请提示用户并简要引用之前的回答。

    完成后，调用 `finish` 工具提交你的完整回复。finish 的参数就是用户将看到的内容——请直接写给用户看的回复。
    """
  end

  defp summarize_chairman_chat(history) do
    history
    |> Enum.filter(fn entry ->
      case entry do
        %{type: "message", role: "user"} -> true
        %{type: "tool_call", name: "finish"} -> true
        _ -> false
      end
    end)
    |> Enum.map(fn entry ->
      case entry do
        %{type: "message", role: "user", content: content} ->
          question = extract_user_question(to_string(content))
          if question != "", do: "用户: #{question}", else: nil

        %{type: "tool_call", name: "finish", args: args} ->
          args = parse_args(args)
          reply = args["result"] || args["value"] || ""
          if reply != "", do: "主席: #{String.slice(reply, 0, 500)}", else: nil

        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp extract_user_question(content) do
    cond do
      String.contains?(content, "### 用户当前问题") ->
        content |> String.split("### 用户当前问题") |> List.last() |> String.split("\n\n") |> hd() |> String.trim()
      String.contains?(content, "### 用户问题") ->
        content |> String.split("### 用户问题") |> List.last() |> String.split("\n\n") |> hd() |> String.trim()
      true -> ""
    end
  end

  defp advisor_search_tools(state) do
    Enum.map(state.advisors, fn {role, agent_id} ->
      tape_name = "agent_#{agent_id}"
      tool_name = "search_#{role}_history"

      %{
        tool:
          ReqLLM.tool(
            name: tool_name,
            description:
              "搜索#{Scoring.format_role(role)}顾问的完整对话历史（推理、辩论、评分理由）。",
            parameter_schema: [
              query: [type: :string, required: true, doc: "搜索关键词"],
              limit: [type: :integer, doc: "最大返回数量（默认10）"]
            ],
            callback: fn _args -> :ok end
          ),
        execute: fn args ->
          query = args["query"] || args[:query] || ""
          limit = args["limit"] || args[:limit] || 10

          if String.trim(query) == "" do
            {:error, "query is required"}
          else
            results = Rho.Tape.Service.search(tape_name, query, limit)

            if results == [] do
              {:ok, "未找到与\"#{query}\"匹配的#{Scoring.format_role(role)}历史记录。"}
            else
              formatted =
                Enum.map_join(results, "\n---\n", fn entry ->
                  entry_role = entry.payload["role"] || "unknown"
                  content = entry.payload["content"] || ""
                  ts = entry.date || ""
                  "[#{ts}] [#{entry_role}] #{content}"
                end)

              {:ok, "找到#{length(results)}条#{Scoring.format_role(role)}的记录：\n#{formatted}"}
            end
          end
        end
      }
    end)
  end

  # --- Private: Helpers ---

  # Tape stores tool args as raw JSON strings; parse if needed
  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> args
    end
  end

  defp parse_args(args), do: args

  @doc false
  def format_chart_data(nil), do: "(命盘数据尚未解析)"

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

        hidden_str = if hidden != [], do: "(藏干：#{Enum.join(hidden, "、")})", else: ""
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
