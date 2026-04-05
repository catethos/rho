defmodule Rho.Agent.Worker do
  @moduledoc """
  Unified agent process. Every agent — whether the primary chat agent,
  a delegated researcher, or a nested sub-task worker — is the same
  process shape.

  Replaces both Session.Worker and Subagent.Worker. Key differences:
  - Has an agent_id separate from session_id (multiple agents per session)
  - Has a role and capabilities for discovery
  - Has a mailbox queue of incoming signals
  - Publishes events to the signal bus
  - Full mount/lifecycle support regardless of depth
  """

  use GenServer, restart: :transient

  require Logger

  alias Rho.Agent.Registry, as: AgentRegistry
  alias Rho.Comms

  defstruct [
    :agent_id,
    :session_id,
    :role,
    :workspace,
    :real_workspace,
    :sandbox,
    :memory_mod,
    :memory_ref,
    :agent_name,
    :task_ref,
    :task_pid,
    :current_turn_id,
    :parent_agent_id,
    capabilities: [],
    status: :idle,
    depth: 0,
    queue: :queue.new(),
    mailbox: :queue.new(),
    waiters: [],
    subscribers: %{},
    bus_subscriptions: [],
    persistent_tools: nil,
    current_tool: nil,
    current_step: nil,
    token_usage: %{input: 0, output: 0},
    last_activity_at: nil,
    user_id: nil
  ]

  # --- Public API ---

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Rho.AgentRegistry, agent_id}})
  end

  @doc "Submit input asynchronously. Returns {:ok, turn_id} immediately."
  def submit(pid, content, opts \\ []) do
    GenServer.call(pid, {:submit, content, opts})
  end

  @doc "Subscribe to session events via direct pid broadcast (backward compat)."
  def subscribe(pid, subscriber_pid \\ self()) do
    GenServer.call(pid, {:subscribe, subscriber_pid})
  end

  @doc "Unsubscribe from session events."
  def unsubscribe(pid, subscriber_pid \\ self()) do
    GenServer.call(pid, {:unsubscribe, subscriber_pid})
  end

  @doc "Get agent info."
  def info(pid) do
    GenServer.call(pid, :info)
  end

  @doc "Get current status."
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc "Cancel the current agent loop turn."
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  @doc "Deliver a signal to this agent's mailbox (used by multi-agent tools)."
  def deliver_signal(pid, signal) do
    GenServer.cast(pid, {:deliver_signal, signal})
  end

  @doc "Block until agent finishes current task. Returns result."
  def collect(pid, timeout \\ 600_000) do
    GenServer.call(pid, :collect, timeout)
  end

  @doc "Look up a worker pid by agent_id."
  def whereis(agent_id) do
    case Registry.lookup(Rho.AgentRegistry, agent_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    agent_name = Keyword.get(opts, :agent_name, :default)
    role = Keyword.get(opts, :role, :primary)
    depth = Keyword.get(opts, :depth, 0)
    capabilities = Keyword.get(opts, :capabilities, [])
    parent_agent_id = Keyword.get(opts, :parent_agent_id)

    memory_mod = Rho.Config.memory_module()

    {memory_ref, effective_workspace, sandbox} =
      if opts[:memory_ref] do
        # Delegated agent with pre-configured memory
        {opts[:memory_ref], workspace, nil}
      else
        # Primary agent — bootstrap memory and maybe sandbox
        ref = memory_mod.memory_ref(session_id, workspace)
        memory_mod.bootstrap(ref)
        {eff_ws, sb} = maybe_start_sandbox(session_id, workspace)
        {ref, eff_ws, sb}
      end

    state = %__MODULE__{
      agent_id: agent_id,
      session_id: session_id,
      role: role,
      workspace: effective_workspace,
      real_workspace: workspace,
      sandbox: sandbox,
      memory_mod: memory_mod,
      memory_ref: memory_ref,
      agent_name: agent_name,
      depth: depth,
      capabilities: capabilities,
      parent_agent_id: parent_agent_id,
      user_id: Keyword.get(opts, :user_id)
    }

    # Pull id card from config
    config = Rho.Config.agent(agent_name)

    # Register in agent registry (with id card from config or opts)
    AgentRegistry.register(agent_id, %{
      session_id: session_id,
      role: role,
      capabilities: capabilities,
      pid: self(),
      status: :idle,
      parent_agent_id: parent_agent_id,
      depth: depth,
      description: Keyword.get(opts, :description) || config.description,
      skills: Keyword.get(opts, :skills) || config.skills,
      memory_ref: memory_ref
    })

    # Subscribe to inbox on the signal bus
    bus_subs = subscribe_to_bus(session_id, agent_id)

    # Publish agent started event
    Comms.publish(
      "rho.agent.started",
      %{
        agent_id: agent_id,
        session_id: session_id,
        role: role,
        capabilities: capabilities
      },
      source: "/session/#{session_id}/agent/#{agent_id}"
    )

    Logger.debug("Agent worker started: #{agent_id} (session: #{session_id}, role: #{role})")

    state = %{state | bus_subscriptions: bus_subs}

    # If there's an initial task, start it immediately
    case Keyword.get(opts, :initial_task) do
      nil ->
        {:ok, state}

      task ->
        {:ok, state, {:continue, {:initial_task, task, opts}}}
    end
  end

  @impl true
  def handle_continue({:initial_task, task, opts}, state) do
    max_steps = Keyword.get(opts, :max_steps, 30)
    system_prompt = Keyword.get(opts, :system_prompt)
    tools = Keyword.get(opts, :tools)
    model = Keyword.get(opts, :model)
    task_id = Keyword.get(opts, :task_id)

    state =
      start_turn(
        task,
        [
          max_steps: max_steps,
          system_prompt: system_prompt,
          tools: tools,
          model: model,
          task_id: task_id,
          delegated: true
        ],
        state
      )

    {:noreply, state}
  end

  # --- Submit ---

  @impl true
  def handle_call({:submit, "," <> command, _opts}, _from, %{status: :idle} = state) do
    turn_id = new_turn_id()
    state = %{state | current_turn_id: turn_id}
    run_direct_command(command, state, turn_id)
    state = %{state | current_turn_id: nil}
    {:reply, {:ok, turn_id}, state}
  end

  def handle_call({:submit, content, opts}, _from, %{status: :idle} = state) do
    state = start_turn(content, opts, state)
    {:reply, {:ok, state.current_turn_id}, state}
  end

  def handle_call({:submit, content, opts}, _from, state) do
    turn_id = new_turn_id()
    state = %{state | queue: :queue.in({content, opts, turn_id}, state.queue)}
    broadcast(state, %{type: :queued, turn_id: turn_id, position: :queue.len(state.queue)})
    {:reply, {:ok, turn_id}, state}
  end

  # --- Collect (for delegated agents) ---

  @impl true
  def handle_call(:collect, _from, %{status: :idle, current_turn_id: nil} = state) do
    # Already done — check if there's a stored result
    {:reply, {:ok, "completed"}, state}
  end

  def handle_call(:collect, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  # --- Subscribe / Unsubscribe ---

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  # --- Info / Status ---

  @impl true
  def handle_call(:info, _from, state) do
    tape_info = state.memory_mod.info(state.memory_ref)

    info = %{
      agent_id: state.agent_id,
      session_id: state.session_id,
      role: state.role,
      workspace: state.workspace,
      real_workspace: state.real_workspace,
      sandbox: state.sandbox,
      tape_name: state.memory_ref,
      agent_name: state.agent_name,
      status: state.status,
      depth: state.depth,
      capabilities: state.capabilities,
      queued: :queue.len(state.queue),
      tape: tape_info,
      current_tool: state.current_tool,
      current_step: state.current_step,
      token_usage: state.token_usage,
      last_activity_at: state.last_activity_at
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  # --- Cancel ---

  @impl true
  def handle_cast(:cancel, %{status: :idle} = state) do
    {:noreply, state}
  end

  def handle_cast(:cancel, %{status: :cancelling} = state) do
    {:noreply, state}
  end

  def handle_cast(:cancel, %{status: :busy, task_pid: pid} = state) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    {:noreply, %{state | status: :cancelling}}
  end

  # --- Signal delivery ---

  @impl true
  def handle_cast({:set_persistent_tools, tools}, state) do
    {:noreply, %{state | persistent_tools: tools}}
  end

  def handle_cast({:deliver_signal, signal}, %{status: :idle} = state) do
    # Process signal immediately
    state = process_signal(signal, state)
    {:noreply, state}
  end

  def handle_cast({:deliver_signal, signal}, state) do
    # Queue for later
    {:noreply, %{state | mailbox: :queue.in(signal, state.mailbox)}}
  end

  # --- Incoming bus signals ---

  @impl true
  def handle_info({:signal, %Jido.Signal{type: type, data: data}}, %{status: :idle} = state) do
    signal = %{type: type, data: data}
    state = process_signal(signal, state)
    {:noreply, state}
  end

  def handle_info({:signal, %Jido.Signal{type: type, data: data}}, state) do
    signal = %{type: type, data: data}
    {:noreply, %{state | mailbox: :queue.in(signal, state.mailbox)}}
  end

  # --- Task result handling ---

  def handle_info({ref, {:final, value}}, %{task_ref: ref} = state) do
    # Final result (from `finish` tool) — reply to waiters and publish completion
    Process.demonitor(ref, [:flush])

    reply_to_waiters(state, {:ok, value})
    maybe_publish_task_completed(state, {:ok, value})

    state = %{
      state
      | status: :idle,
        task_ref: nil,
        task_pid: nil,
        current_turn_id: nil,
        waiters: []
    }

    AgentRegistry.update_status(state.agent_id, :idle)

    state = process_queue(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task_ref: ref} = state) do
    # Regular turn end (end_turn, max_steps, text response)
    Process.demonitor(ref, [:flush])

    maybe_publish_task_completed(state, result)

    state = %{state | status: :idle, task_ref: nil, task_pid: nil, current_turn_id: nil}
    AgentRegistry.update_status(state.agent_id, :idle)

    state = process_queue(state)

    # If still idle after processing queue (no pending messages):
    if state.status == :idle do
      # Reply to waiters if this is a delegated agent with no more work —
      # the task is effectively done even without an explicit `finish` call
      if state.waiters != [] and :queue.is_empty(state.mailbox) do
        result_text =
          case result do
            {:ok, text} -> text
            {:error, reason} -> "error: #{inspect(reason)}"
            other -> inspect(other)
          end

        reply_to_waiters(state, {:ok, result_text})
        state = %{state | waiters: []}
        broadcast(state, %{type: :agent_idle, result: result, agent_id: state.agent_id})
        {:noreply, state}
      else
        broadcast(state, %{type: :agent_idle, result: result, agent_id: state.agent_id})
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Task died
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    if state.status == :cancelling do
      broadcast(state, %{type: :turn_cancelled, turn_id: state.current_turn_id})
      publish_event(state, "rho.turn.cancelled", %{turn_id: state.current_turn_id})
    else
      # Emit turn_finished so the UI knows the turn ended (even on crash)
      error_result = {:error, "agent task failed: #{inspect(reason)}"}

      event = %{
        type: :turn_finished,
        turn_id: state.current_turn_id,
        result: error_result,
        agent_id: state.agent_id,
        session_id: state.session_id
      }

      broadcast(state, event)

      Comms.publish(
        "rho.session.#{state.session_id}.events.turn_finished",
        event,
        source: "/session/#{state.session_id}/agent/#{state.agent_id}",
        correlation_id: state.current_turn_id
      )
    end

    reply_to_waiters(state, {:error, "agent task failed"})

    state = %{
      state
      | status: :idle,
        task_ref: nil,
        task_pid: nil,
        current_turn_id: nil,
        waiters: []
    }

    AgentRegistry.update_status(state.agent_id, :idle)

    state = process_queue(state)
    {:noreply, state}
  end

  # Subscriber process died
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {_ref, subscribers} = Map.pop(state.subscribers, pid)
    {:noreply, %{state | subscribers: subscribers || state.subscribers}}
  end

  # Port messages from sandbox
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    Logger.debug("[Sandbox] mount output: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    if code != 0 do
      Logger.warning("[Sandbox] mount process exited with code #{code}")
    end

    {:noreply, state}
  end

  # Runtime metadata updates from emit function
  def handle_info({:meta_update, key, value}, state) do
    {:noreply, Map.put(state, key, value)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # Mark stopped in agent registry (preserve entry for tape lookup)
    AgentRegistry.update(state.agent_id, %{status: :stopped, pid: nil})

    # Unsubscribe from bus
    for sub_id <- state.bus_subscriptions do
      Comms.unsubscribe(sub_id)
    end

    # Publish stopped event
    Comms.publish(
      "rho.agent.stopped",
      %{
        agent_id: state.agent_id,
        session_id: state.session_id,
        reason: inspect(reason)
      },
      source: "/session/#{state.session_id}/agent/#{state.agent_id}"
    )

    # Cleanup sandbox
    Rho.Sandbox.stop(state.sandbox)

    :ok
  end

  # --- Private ---

  defp start_turn(content, opts, state) do
    turn_id = new_turn_id()
    {emit, _} = build_emit(state, turn_id)

    config = Rho.Config.agent(state.agent_name)
    model = opts[:model] || config.model
    is_delegated = opts[:delegated] || false
    task_id = opts[:task_id]

    # Use provided tools, or persisted tools from a prior turn, or resolve from mounts
    tools =
      cond do
        opts[:tools] -> opts[:tools]
        state.persistent_tools -> state.persistent_tools
        true -> resolve_all_tools(state, depth: state.depth, emit: emit)
      end

    agent_opts =
      [
        system_prompt: opts[:system_prompt] || config.system_prompt,
        tools: tools,
        agent_name: state.agent_name,
        max_steps: opts[:max_steps] || config.max_steps,
        tape_name: state.memory_ref,
        memory_mod: state.memory_mod,
        emit: emit,
        workspace: state.workspace,
        reasoner: config.reasoner,
        depth: state.depth,
        prompt_format: config[:prompt_format] || :markdown
      ]
      |> maybe_put(:provider, config.provider)
      |> maybe_put(:task_id, task_id)

    # For delegated agents at depth > 0, include subagent flag for lifecycle
    agent_opts =
      if is_delegated and state.depth > 0 do
        Keyword.put(agent_opts, :subagent, true)
      else
        agent_opts
      end

    messages = [ReqLLM.Context.user(content)]

    task =
      Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
        emit.(%{type: :turn_started})
        publish_event(state, "rho.turn.started", %{turn_id: turn_id})

        result =
          try do
            Rho.AgentLoop.run(model, messages, agent_opts)
          rescue
            error ->
              Logger.error(
                "AgentLoop crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
              )

              {:error, Exception.message(error)}
          catch
            kind, reason ->
              Logger.error("AgentLoop crashed: #{Exception.format(kind, reason, __STACKTRACE__)}")
              {:error, "#{kind}: #{inspect(reason)}"}
          end

        emit.(%{type: :turn_finished, result: result})
        publish_event(state, "rho.turn.finished", %{turn_id: turn_id, result: inspect(result)})

        result
      end)

    AgentRegistry.update_status(state.agent_id, :busy)

    # Persist tools for future turns (message-triggered turns reuse them)
    persistent = if opts[:tools], do: opts[:tools], else: state.persistent_tools

    %{
      state
      | status: :busy,
        task_ref: task.ref,
        task_pid: task.pid,
        current_turn_id: turn_id,
        persistent_tools: persistent
    }
  end

  defp process_queue(state) do
    # First check mailbox for signals
    case :queue.out(state.mailbox) do
      {{:value, signal}, rest} ->
        state = %{state | mailbox: rest}
        process_signal(signal, state)

      {:empty, _} ->
        # Then check regular queue
        case :queue.out(state.queue) do
          {{:value, {"," <> command, _opts, turn_id}}, rest} ->
            state = %{state | queue: rest, current_turn_id: turn_id}
            run_direct_command(command, state, turn_id)
            %{state | current_turn_id: nil}

          {{:value, {content, opts, _turn_id}}, rest} ->
            state = %{state | queue: rest}
            start_turn(content, opts, state)

          {:empty, _} ->
            state
        end
    end
  end

  defp process_signal(%{type: "rho.task.requested", data: data}, state) do
    task = data[:task] || data["task"]
    task_id = data[:task_id] || data["task_id"]

    if task do
      start_turn(
        task,
        [
          task_id: task_id,
          delegated: true,
          max_steps: data[:max_steps] || data["max_steps"] || 30
        ],
        state
      )
    else
      state
    end
  end

  defp process_signal(%{type: "rho.message.sent", data: data}, state) do
    message = data[:message] || data["message"]
    from = data[:from] || data["from"]

    if message do
      content =
        cond do
          from == "external" ->
            """
            [External message]
            #{message}
            """

          from ->
            {from_role, from_id} =
              case AgentRegistry.get(from) do
                %{role: role} -> {role, from}
                _ -> {:unknown, from}
              end

            """
            [Inter-agent message from #{from_role} (#{from_id})]
            #{message}

            ---
            This message is from another agent, not a human user. \
            To reply, use send_message with target: "#{from_id}". \
            Do not use end_turn to reply — that only works for human conversations.\
            """

          true ->
            message
        end

      # Ensure tools are resolved and persisted so subsequent message turns
      # don't re-resolve from mounts each time
      state =
        if state.persistent_tools == nil do
          tools = resolve_all_tools(state, depth: state.depth)
          %{state | persistent_tools: tools}
        else
          state
        end

      start_turn(content, [tools: state.persistent_tools], state)
    else
      state
    end
  end

  defp process_signal(_signal, state), do: state

  defp broadcast(state, event) do
    for {pid, _ref} <- state.subscribers do
      send(pid, {:session_event, state.session_id, state.current_turn_id, event})
    end

    :ok
  end

  defp build_emit(state, turn_id) do
    session_id = state.session_id
    agent_id = state.agent_id
    worker_pid = self()
    subscriber_pids = Map.keys(state.subscribers)
    has_bus_subs = state.bus_subscriptions != []

    emit = fn event ->
      tagged = Map.put(event, :turn_id, turn_id)

      # Update worker runtime metadata
      case event.type do
        :step_start ->
          send(worker_pid, {:meta_update, :current_step, event[:step]})

        :tool_start ->
          send(worker_pid, {:meta_update, :current_tool, event[:name]})

        :tool_result ->
          send(worker_pid, {:meta_update, :current_tool, nil})

        :llm_usage ->
          usage = event[:usage] || %{}

          send(
            worker_pid,
            {:meta_update, :token_usage,
             %{
               input: usage[:input_tokens] || 0,
               output: usage[:output_tokens] || 0
             }}
          )

        _ ->
          :ok
      end

      send(worker_pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})

      # Direct broadcast to subscribers (for CLI/Web backward compat)
      for pid <- subscriber_pids do
        send(pid, {:session_event, session_id, turn_id, tagged})
      end

      # Publish to signal bus (skip high-freq events unless bus subscribers exist)
      signal_type = event_to_signal_type(event, has_bus_subs)

      if signal_type do
        payload = Map.merge(event, %{agent_id: agent_id, session_id: session_id})

        Comms.publish(
          "rho.session.#{session_id}.events.#{signal_type}",
          payload,
          source: "/session/#{session_id}/agent/#{agent_id}",
          correlation_id: turn_id
        )
      end

      :ok
    end

    {emit, subscriber_pids}
  end

  # High-frequency events only published to bus when explicitly needed
  @high_freq_event_types ~w(text_delta llm_text llm_usage structured_partial)a

  @signal_event_types ~w(
    text_delta llm_text tool_start tool_result step_start llm_usage
    turn_started turn_finished turn_cancelled compact error
    subagent_progress subagent_tool subagent_error before_llm
    structured_partial
  )a

  defp event_to_signal_type(%{type: type}, _publish_high_freq = true)
       when type in @signal_event_types,
       do: Atom.to_string(type)

  defp event_to_signal_type(%{type: type}, _publish_high_freq) when type in @signal_event_types do
    if type in @high_freq_event_types, do: nil, else: Atom.to_string(type)
  end

  defp event_to_signal_type(_, _), do: nil

  defp publish_event(state, type, payload) do
    Comms.publish(
      type,
      Map.merge(payload, %{
        agent_id: state.agent_id,
        session_id: state.session_id
      }),
      source: "/session/#{state.session_id}/agent/#{state.agent_id}"
    )
  end

  defp maybe_publish_task_completed(state, result) do
    if state.depth > 0 do
      result_text =
        case result do
          {:ok, text} -> text
          {:error, reason} -> "error: #{inspect(reason)}"
          other -> inspect(other)
        end

      Comms.publish(
        "rho.task.completed",
        %{
          agent_id: state.agent_id,
          session_id: state.session_id,
          result: result_text
        },
        source: "/session/#{state.session_id}/agent/#{state.agent_id}"
      )
    end
  end

  defp reply_to_waiters(state, result) do
    for from <- state.waiters do
      GenServer.reply(from, result)
    end

    :ok
  end

  defp new_turn_id do
    System.unique_integer([:positive]) |> Integer.to_string()
  end

  defp resolve_all_tools(state, opts) do
    context = build_context(state, opts[:depth] || state.depth, opts)
    Rho.MountRegistry.collect_tools(context)
  end

  defp build_context(state, depth, opts \\ []) do
    %Rho.Mount.Context{
      model: nil,
      tape_name: state.memory_ref,
      memory_mod: state.memory_mod,
      input_messages: [],
      workspace: state.workspace,
      agent_name: state.agent_name,
      agent_id: state.agent_id,
      session_id: state.session_id,
      depth: depth,
      subagent: false,
      opts: Enum.into(opts, %{}),
      user_id: state.user_id
    }
  end

  defp subscribe_to_bus(session_id, agent_id) do
    pattern = "rho.session.#{session_id}.agent.#{agent_id}.inbox"

    case Comms.subscribe(pattern) do
      {:ok, sub_id} -> [sub_id]
      {:error, _} -> []
    end
  end

  defp maybe_start_sandbox(session_id, workspace) do
    if Rho.Config.sandbox_enabled?() do
      case Rho.Sandbox.start(session_id, workspace) do
        {:ok, sandbox} ->
          {sandbox.mount_path, sandbox}

        {:error, reason} ->
          Logger.error("[Sandbox] Failed to start: #{reason}. Falling back to direct workspace.")
          {workspace, nil}
      end
    else
      {workspace, nil}
    end
  end

  defp maybe_put(kwlist, _key, nil), do: kwlist
  defp maybe_put(kwlist, key, value), do: Keyword.put(kwlist, key, value)

  # --- Direct command execution ---

  defp run_direct_command(command, state, turn_id) do
    {emit, _} = build_emit(state, turn_id)
    {tool_name, args} = Rho.CommandParser.parse(command)

    emit.(%{type: :turn_started})
    emit.(%{type: :tool_start, name: tool_name, args: args})
    result = execute_direct_command(tool_name, args, state)

    case result do
      {:ok, output} -> emit.(%{type: :tool_result, status: :ok, output: output})
      {:error, reason} -> emit.(%{type: :tool_result, status: :error, output: inspect(reason)})
    end

    emit.(%{type: :turn_finished, result: result})
  end

  defp execute_direct_command(tool_name, args, state) do
    tools = Rho.MountRegistry.collect_tools(build_context(state, state.depth))
    tool_map = Map.new(tools, fn t -> {t.tool.name, t} end)

    case Map.get(tool_map, tool_name) do
      nil ->
        available = tools |> Enum.map(& &1.tool.name) |> Enum.sort() |> Enum.join(", ")
        {:error, "Unknown tool: #{tool_name}. Available: #{available}"}

      tool_def ->
        tool_def.execute.(args)
    end
  end
end
