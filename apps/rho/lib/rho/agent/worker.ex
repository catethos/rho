defmodule Rho.Agent.Worker do
  @moduledoc """
  Unified agent process. Every agent — whether the primary chat agent,
  a delegated researcher, or a nested sub-task worker — is the same
  process shape.

  Replaces both Session.Worker and Subagent.Worker. Key differences:
  - Has an agent_id separate from session_id (multiple agents per session)
  - Has a role and capabilities for discovery
  - Has a mailbox queue of incoming signals
  - Publishes events to the signal bus (sole delivery path)
  - Full mount/lifecycle support regardless of depth
  """

  use GenServer, restart: :transient

  # Rho.Stdlib lives in a sibling umbrella app — discovered at runtime.
  @compile {:no_warn_undefined, Rho.Stdlib}

  require Logger

  @ask_inactivity_timeout 120_000
  @turn_watchdog_interval 30_000
  @turn_inactivity_limit 60_000

  alias Rho.Agent.Registry, as: AgentRegistry

  defstruct [
    :agent_id,
    :session_id,
    :role,
    :workspace,
    :real_workspace,
    :sandbox,
    :tape_module,
    :tape_ref,
    :agent_name,
    :run_spec,
    :task_ref,
    :task_pid,
    :current_turn_id,
    capabilities: [],
    status: :idle,
    queue: :queue.new(),
    mailbox: :queue.new(),
    waiters: [],
    persistent_tools: nil,
    current_tool: nil,
    current_step: nil,
    token_usage: %{input: 0, output: 0},
    last_activity_at: nil,
    user_id: nil,
    organization_id: nil,
    conversation_id: nil,
    thread_id: nil,
    last_result: nil,
    current_task_id: nil
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

  @doc """
  Bump the agent's `last_activity_at` so the turn watchdog doesn't kill a
  long-running tool. Use cases that stream partials via `Rho.Events`
  (rather than the runner's `emit`) should call this so the runner can
  see the tool is making progress.

  Resolution lookup is best-effort — silently no-ops when the agent
  isn't registered or the pid is dead.
  """
  @spec touch_activity(String.t() | nil) :: :ok
  def touch_activity(nil), do: :ok

  def touch_activity(agent_id) when is_binary(agent_id) do
    case Registry.lookup(Rho.AgentRegistry, agent_id) do
      [{pid, _}] when is_pid(pid) ->
        send(pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Synchronous submit — subscribe to the worker's session
  `turn_finished` bus topic, submit the input, collect signals
  until the turn is done, return the result.

  Options:
    - `await: :finish` — wait until the agent calls `finish` (for
      multi-turn simulations). Default: `:turn`, return after the
      first turn completes.

  Bus-only: the subscription is to a `rho.session.<sid>.events.*`
  topic, not a direct-pid message.
  """
  def ask(pid, content, opts \\ []) when is_pid(pid) do
    session_id = info(pid).session_id
    Rho.Events.subscribe(session_id)
    {:ok, turn_id} = submit(pid, content, opts)
    await_mode = Keyword.get(opts, :await, :turn)
    result = await_reply(turn_id, await_mode)
    Rho.Events.unsubscribe(session_id)
    result
  end

  # Default: return after first turn completes
  defp await_reply(turn_id, :turn) do
    await_reply_turn(turn_id, System.monotonic_time(:millisecond))
  end

  # Simulation mode: wait until the agent calls `finish` or goes idle
  # with no pending work.
  defp await_reply(_turn_id, :finish), do: await_reply_finish(nil)

  defp await_reply_turn(turn_id, last_activity_at) do
    remaining = @ask_inactivity_timeout - (System.monotonic_time(:millisecond) - last_activity_at)
    remaining = max(remaining, 0)

    receive do
      %Rho.Events.Event{kind: :turn_finished, data: %{turn_id: ^turn_id} = data} ->
        unwrap_result(Map.get(data, :result))

      %Rho.Events.Event{} ->
        # Any event is proof of life — reset the inactivity timer
        await_reply_turn(turn_id, System.monotonic_time(:millisecond))
    after
      remaining ->
        {:error, "ask timed out: no activity for #{div(@ask_inactivity_timeout, 1000)}s"}
    end
  end

  defp await_reply_finish(last_result) do
    timeout =
      if last_result do
        30_000
      else
        @ask_inactivity_timeout
      end

    receive do
      %Rho.Events.Event{kind: :turn_finished, data: data} ->
        case Map.get(data, :result) do
          {:final, value} -> {:ok, value}
          {:ok, _text} = ok -> await_reply_finish(ok)
          {:error, _} = err -> err
          other -> await_reply_finish(other)
        end

      %Rho.Events.Event{} ->
        await_reply_finish(last_result)
    after
      timeout -> last_result || {:error, "ask timed out: no activity for #{div(timeout, 1000)}s"}
    end
  end

  defp unwrap_result({:final, value}), do: {:ok, value}
  defp unwrap_result(other), do: other

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
    capabilities = Keyword.get(opts, :capabilities, [])

    depth = Rho.Agent.Primary.depth_of(agent_id)

    # Accept an explicit RunSpec, or synthesize one from agent_config + opts.
    # state.run_spec is always non-nil from this point on.
    run_spec = opts[:run_spec] || build_default_run_spec(opts, agent_name)

    memory_mod = run_spec.tape_module || Rho.Tape.Projection.JSONL
    sandbox_enabled = run_spec.sandbox_enabled

    {memory_ref, effective_workspace, sandbox} =
      if opts[:tape_ref] do
        # Delegated agent with pre-configured memory
        {opts[:tape_ref], workspace, nil}
      else
        # Primary agent — bootstrap memory and maybe sandbox
        ref = memory_mod.memory_ref(session_id, workspace)
        memory_mod.bootstrap(ref)
        {eff_ws, sb} = maybe_start_sandbox(session_id, workspace, sandbox_enabled)
        {ref, eff_ws, sb}
      end

    config_capabilities = derive_capabilities(run_spec.plugins)
    capabilities = (config_capabilities ++ capabilities) |> Enum.uniq()
    description = run_spec.description
    skills = run_spec.skills || []

    # Finalize the RunSpec with runtime-resolved fields
    run_spec = %{
      run_spec
      | agent_id: agent_id,
        session_id: session_id,
        workspace: effective_workspace,
        depth: depth,
        tape_name: memory_ref,
        tape_module: memory_mod,
        agent_name: agent_name,
        user_id: Keyword.get(opts, :user_id) || run_spec.user_id,
        organization_id: Keyword.get(opts, :organization_id) || run_spec.organization_id,
        conversation_id: Keyword.get(opts, :conversation_id) || run_spec.conversation_id,
        thread_id: Keyword.get(opts, :thread_id) || run_spec.thread_id
    }

    state = %__MODULE__{
      agent_id: agent_id,
      session_id: session_id,
      role: role,
      workspace: effective_workspace,
      real_workspace: workspace,
      sandbox: sandbox,
      tape_module: memory_mod,
      tape_ref: memory_ref,
      agent_name: agent_name,
      run_spec: run_spec,
      capabilities: capabilities,
      user_id: Keyword.get(opts, :user_id),
      organization_id: Keyword.get(opts, :organization_id),
      conversation_id: run_spec.conversation_id,
      thread_id: run_spec.thread_id
    }

    # Register in agent registry
    AgentRegistry.register(agent_id, %{
      session_id: session_id,
      role: role,
      agent_name: agent_name,
      capabilities: capabilities,
      pid: self(),
      status: :idle,
      depth: depth,
      description: Keyword.get(opts, :description) || description,
      skills: Keyword.get(opts, :skills) || skills,
      tape_ref: memory_ref
    })

    # Publish agent started event
    started_event =
      Rho.Events.event(:agent_started, session_id, agent_id, %{
        role: role,
        agent_name: agent_name,
        capabilities: capabilities,
        depth: depth,
        model: run_spec.model
      })

    Rho.Events.broadcast(session_id, started_event)
    Rho.Events.broadcast_lifecycle(started_event)

    Logger.debug("Agent worker started: #{agent_id} (session: #{session_id}, role: #{role})")

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
  def handle_call({:submit, content, opts}, _from, %{status: :idle} = state) do
    state = start_turn(content, opts, state)
    {:reply, {:ok, state.current_turn_id}, state}
  end

  def handle_call({:submit, content, opts}, _from, state) do
    turn_id = new_turn_id()
    queue_size = :queue.len(state.queue)

    Logger.warning(
      "[worker] Submit while busy: agent=#{state.agent_id} status=#{state.status} " <>
        "current_turn=#{state.current_turn_id} task_alive=#{is_pid(state.task_pid) and Process.alive?(state.task_pid)} " <>
        "queue_size=#{queue_size} idle_ms=#{System.monotonic_time(:millisecond) - (state.last_activity_at || 0)}"
    )

    state = %{state | queue: :queue.in({content, opts, turn_id}, state.queue)}
    {:reply, {:ok, turn_id}, state}
  end

  # --- Collect (for delegated agents) ---

  @impl true
  def handle_call(
        :collect,
        _from,
        %{status: :idle, current_turn_id: nil, last_result: result} = state
      )
      when not is_nil(result) do
    # Already done — return the stored terminal result.
    {:reply, result, state}
  end

  def handle_call(:collect, _from, %{status: :idle, current_turn_id: nil} = state) do
    # Already done — no stored result yet (no turn has been run).
    {:reply, {:ok, "completed"}, state}
  end

  def handle_call(:collect, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  # --- Info / Status ---

  @impl true
  def handle_call(:info, _from, state) do
    tape_info = state.tape_module.info(state.tape_ref)

    info = %{
      agent_id: state.agent_id,
      session_id: state.session_id,
      role: state.role,
      workspace: state.workspace,
      real_workspace: state.real_workspace,
      sandbox: state.sandbox,
      tape_name: state.tape_ref,
      agent_name: state.agent_name,
      status: state.status,
      depth: agent_depth(state),
      capabilities: state.capabilities,
      queued: :queue.len(state.queue),
      tape: tape_info,
      current_tool: state.current_tool,
      current_step: state.current_step,
      token_usage: state.token_usage,
      last_activity_at: state.last_activity_at,
      conversation_id: state.conversation_id,
      thread_id: state.thread_id
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

  # --- Task result handling ---

  @impl true
  def handle_info({ref, {:final, value}}, %{task_ref: ref} = state) do
    # Final result (from `finish` tool) — reply to waiters and publish completion
    Process.demonitor(ref, [:flush])

    final_result = {:ok, value}

    reply_to_waiters(state, final_result)
    maybe_publish_task_completed(state, final_result)
    AgentRegistry.record_result(state.agent_id, final_result)

    state = %{
      state
      | status: :idle,
        task_ref: nil,
        task_pid: nil,
        current_turn_id: nil,
        waiters: [],
        last_result: final_result
    }

    AgentRegistry.update_status(state.agent_id, :idle)

    state = process_queue(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task_ref: ref} = state) do
    # Regular turn end (end_turn, max_steps, text response)
    Process.demonitor(ref, [:flush])

    maybe_publish_task_completed(state, result)
    AgentRegistry.record_result(state.agent_id, result)

    state = %{
      state
      | status: :idle,
        task_ref: nil,
        task_pid: nil,
        current_turn_id: nil,
        last_result: result
    }

    AgentRegistry.update_status(state.agent_id, :idle)

    state = process_queue(state)

    # If still idle after processing queue (no pending messages):
    if state.status == :idle do
      # Reply to waiters if this is a delegated agent with no more work —
      # the task is effectively done even without an explicit `finish` call.
      # Pass the raw result tuple through unchanged so that the waiter path
      # matches what a post-turn `collect` would return from `last_result`.
      if state.waiters != [] and :queue.is_empty(state.mailbox) do
        reply_to_waiters(state, result)
        state = %{state | waiters: []}
        {:noreply, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Task died
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    sid = state.session_id
    aid = state.agent_id

    if state.status == :cancelling do
      Rho.Events.broadcast(
        sid,
        Rho.Events.event(:turn_cancelled, sid, aid, %{turn_id: state.current_turn_id})
      )
    else
      # Emit turn_finished so the UI knows the turn ended (even on crash)
      error_result = {:error, "agent task failed: #{inspect(reason)}"}

      Rho.Events.broadcast(
        sid,
        Rho.Events.event(:turn_finished, sid, aid, %{
          turn_id: state.current_turn_id,
          result: error_result
        })
      )
    end

    error_result = {:error, "agent task failed"}
    reply_to_waiters(state, error_result)
    AgentRegistry.record_result(state.agent_id, error_result)

    state = %{
      state
      | status: :idle,
        task_ref: nil,
        task_pid: nil,
        current_turn_id: nil,
        waiters: [],
        last_result: error_result
    }

    AgentRegistry.update_status(state.agent_id, :idle)

    state = process_queue(state)
    {:noreply, state}
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

  # Turn-level watchdog: kills stuck runner tasks
  def handle_info(:turn_watchdog, %{status: :busy, task_pid: pid} = state) when is_pid(pid) do
    idle_ms = System.monotonic_time(:millisecond) - (state.last_activity_at || 0)

    if idle_ms >= @turn_inactivity_limit do
      Logger.warning(
        "[worker] Turn watchdog fired: no activity for #{div(idle_ms, 1000)}s, " <>
          "killing runner task (step=#{state.current_step}, tool=#{state.current_tool})"
      )

      Process.exit(pid, :turn_inactive)
    else
      schedule_turn_watchdog()
    end

    {:noreply, state}
  end

  def handle_info(:turn_watchdog, state) do
    # Not busy — ignore stale timer
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Mark stopped in agent registry (preserve entry for tape lookup)
    AgentRegistry.update(state.agent_id, %{status: :stopped, pid: nil})

    # Publish stopped event
    stopped_event = Rho.Events.event(:agent_stopped, state.session_id, state.agent_id, %{})
    Rho.Events.broadcast(state.session_id, stopped_event)
    Rho.Events.broadcast_lifecycle(stopped_event)

    # Stop any live descendants (grandchildren etc.) so they don't orphan
    # when a parent worker exits mid-flight. Best-effort: Registry entries
    # may race with terminations, and :noproc is ignored.
    for descendant <- AgentRegistry.descendants_of(state.agent_id),
        is_pid(descendant[:pid]) and Process.alive?(descendant[:pid]) do
      try do
        GenServer.stop(descendant[:pid], :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    # Cleanup sandbox
    Rho.Sandbox.stop(state.sandbox)

    :ok
  end

  # --- Private ---

  defp start_turn(content, opts, state) do
    turn_id = new_turn_id()
    emit = build_emit(state, turn_id)
    task_id = opts[:task_id]
    messages = [ReqLLM.Context.user(content)]
    turn_spec = build_turn_spec(opts, state, emit, turn_id)

    task =
      Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
        run_turn_spec(emit, state, turn_id, messages, turn_spec)
      end)

    AgentRegistry.update_status(state.agent_id, :busy)
    maybe_publish_task_accepted(state, task_id)

    persistent = if opts[:tools], do: opts[:tools], else: state.persistent_tools
    schedule_turn_watchdog()

    %{
      state
      | status: :busy,
        task_ref: task.ref,
        task_pid: task.pid,
        current_turn_id: turn_id,
        persistent_tools: persistent,
        current_task_id: task_id,
        last_activity_at: System.monotonic_time(:millisecond)
    }
  end

  # -- RunSpec path --

  defp build_turn_spec(opts, state, emit, turn_id) do
    spec = state.run_spec

    tools =
      opts[:tools] || state.persistent_tools || spec.tools ||
        resolve_all_tools(state, depth: agent_depth(state), emit: emit)

    %{
      spec
      | tools: tools,
        emit: emit,
        turn_id: turn_id,
        system_prompt: opts[:system_prompt] || spec.system_prompt,
        max_steps: opts[:max_steps] || spec.max_steps,
        model: opts[:model] || spec.model
    }
  end

  defp run_turn_spec(emit, state, turn_id, messages, spec) do
    emit.(%{type: :turn_started})

    Rho.Events.broadcast(
      state.session_id,
      Rho.Events.event(:turn_started, state.session_id, state.agent_id, %{turn_id: turn_id})
    )

    result =
      try do
        Rho.Runner.run(messages, spec)
      rescue
        error ->
          Logger.error("AgentLoop crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
          {:error, Exception.message(error)}
      catch
        kind, reason ->
          Logger.error("AgentLoop crashed: #{Exception.format(kind, reason, __STACKTRACE__)}")
          {:error, "#{kind}: #{inspect(reason)}"}
      end

    emit.(%{type: :turn_finished, result: result})

    Rho.Events.broadcast(
      state.session_id,
      Rho.Events.event(:turn_finished, state.session_id, state.agent_id, %{
        turn_id: turn_id,
        result: inspect(result)
      })
    )

    result
  end

  # Build a default RunSpec for callers that didn't pass `:run_spec`.
  # Reads `.rho.exs` config for the role and folds in legacy spawn-time
  # opts (`:tools`, `:system_prompt`, `:model`, `:max_steps`).
  defp build_default_run_spec(opts, agent_name) do
    config = Rho.Config.agent_config(agent_name)

    Rho.RunSpec.build(
      model: opts[:model] || config.model,
      system_prompt: opts[:system_prompt] || config.system_prompt,
      max_steps: opts[:max_steps] || config.max_steps,
      max_tokens: config.max_tokens,
      plugins: config.plugins,
      transformers: [],
      turn_strategy: config.turn_strategy,
      prompt_format: config[:prompt_format] || :markdown,
      provider: config.provider,
      description: config.description,
      skills: config.skills || [],
      avatar: config.avatar,
      tools: opts[:tools],
      agent_name: agent_name,
      conversation_id: opts[:conversation_id],
      thread_id: opts[:thread_id],
      sandbox_enabled: Rho.Config.sandbox_enabled?()
    )
  end

  defp maybe_publish_task_accepted(_state, nil), do: :ok

  defp maybe_publish_task_accepted(state, task_id) do
    Rho.Events.broadcast(
      state.session_id,
      Rho.Events.event(:task_accepted, state.session_id, state.agent_id, %{task_id: task_id})
    )
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
          {{:value, {content, opts, _turn_id}}, rest} ->
            state = %{state | queue: rest}
            start_turn(content, opts, state)

          {:empty, _} ->
            state
        end
    end
  end

  defp process_signal(signal, state) do
    ctx = build_context(state, agent_depth(state))

    case Rho.PluginRegistry.dispatch_signal(signal, ctx) do
      {:start_turn, content, opts} ->
        state = ensure_persistent_tools(state)
        opts = Keyword.put_new(opts, :tools, state.persistent_tools)
        start_turn(content, opts, state)

      :ignore ->
        state
    end
  end

  defp ensure_persistent_tools(state) do
    if state.persistent_tools == nil do
      tools = resolve_all_tools(state, depth: agent_depth(state))
      %{state | persistent_tools: tools}
    else
      state
    end
  end

  defp build_emit(state, turn_id) do
    session_id = state.session_id
    agent_id = state.agent_id
    worker_pid = self()

    fn event ->
      tagged = Map.put(event, :turn_id, turn_id)
      send_meta_updates(worker_pid, event)
      send(worker_pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})
      Rho.Events.broadcast(session_id, Rho.Events.normalize(tagged, session_id, agent_id))
      :ok
    end
  end

  defp send_meta_updates(worker_pid, event) do
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
           %{input: usage[:input_tokens] || 0, output: usage[:output_tokens] || 0}}
        )

      _ ->
        :ok
    end
  end

  defp maybe_publish_task_completed(state, result) do
    if agent_depth(state) > 0 do
      result_text =
        case result do
          {:ok, text} -> text
          {:error, reason} -> "error: #{inspect(reason)}"
          other -> inspect(other)
        end

      data =
        %{
          agent_id: state.agent_id,
          session_id: state.session_id,
          result: result_text
        }
        |> maybe_put_field(:task_id, state.current_task_id)

      Rho.Events.broadcast(
        state.session_id,
        Rho.Events.event(:task_completed, state.session_id, state.agent_id, data)
      )
    end
  end

  defp reply_to_waiters(state, result) do
    for from <- state.waiters do
      GenServer.reply(from, result)
    end

    :ok
  end

  defp schedule_turn_watchdog do
    Process.send_after(self(), :turn_watchdog, @turn_watchdog_interval)
  end

  defp new_turn_id do
    System.unique_integer([:positive]) |> Integer.to_string()
  end

  defp resolve_all_tools(state, opts) do
    context = build_context(state, opts[:depth] || agent_depth(state), opts)
    Rho.PluginRegistry.collect_tools(context)
  end

  defp build_context(state, depth, _opts \\ []) do
    %Rho.Context{
      tape_name: state.tape_ref,
      tape_module: state.tape_module,
      workspace: state.workspace,
      agent_name: state.agent_name,
      agent_id: state.agent_id,
      session_id: state.session_id,
      depth: depth,
      user_id: state.user_id,
      organization_id: state.organization_id
    }
  end

  defp maybe_start_sandbox(session_id, workspace, sandbox_enabled) do
    if sandbox_enabled do
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

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put(map, key, value)

  defp agent_depth(%__MODULE__{agent_id: agent_id}) do
    Rho.Agent.Primary.depth_of(agent_id)
  end

  # Derive capability atoms from plugin config entries.
  # Mirrors Rho.Stdlib.capabilities_from_plugins/1 but without
  # requiring the stdlib dependency at compile time.
  defp derive_capabilities(plugins) when is_list(plugins) do
    if Code.ensure_loaded?(Rho.Stdlib) and
         function_exported?(Rho.Stdlib, :capabilities_from_plugins, 1) do
      Rho.Stdlib.capabilities_from_plugins(plugins)
    else
      []
    end
  end

  defp derive_capabilities(_), do: []
end
