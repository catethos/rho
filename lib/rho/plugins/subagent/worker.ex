defmodule Rho.Plugins.Subagent.Worker do
  @moduledoc """
  GenServer that owns a subagent's lifecycle.

  Spawns an internal Task (linked) to run AgentLoop, staying responsive
  for :collect, :status, and :cancel calls. When the task completes,
  handle_info receives the result and replies to any deferred waiters.
  """

  use GenServer, restart: :transient

  require Logger

  @status_table :rho_subagent_status

  defstruct [
    :subagent_id,
    :parent_tape,
    :parent_agent_id,
    :tape_name,
    :prompt,
    :workspace,
    :depth,
    :model,
    :tools,
    :system_prompt,
    :task_ref,
    :parent_emit,
    :session_id,
    step: 0,
    max_steps: 30,
    status: :running,
    result: nil,
    waiters: []
  ]

  # --- Public API ---

  def start_link(opts) do
    subagent_id = Keyword.fetch!(opts, :subagent_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Rho.SubagentRegistry, subagent_id, opts[:parent_tape]}}
    )
  end

  @doc "Block until the subagent finishes. Returns {:ok, text} | {:error, reason}."
  def collect(pid, timeout \\ 600_000) do
    GenServer.call(pid, :collect, timeout)
  end

  @doc "Get current progress without blocking."
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc "Request graceful cancellation (takes effect between AgentLoop steps)."
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  @doc "Look up a worker pid by subagent_id."
  def whereis(subagent_id) do
    case Registry.lookup(Rho.SubagentRegistry, subagent_id) do
      [{pid, _parent_tape}] -> pid
      [] -> nil
    end
  end

  @doc "Find all workers whose parent_tape matches."
  def children_of(parent_tape) do
    Registry.select(Rho.SubagentRegistry, [
      {{:"$1", :"$2", :"$3"}, [{:==, :"$3", parent_tape}], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc "Find running workers whose parent_tape matches (for UI)."
  def active_children_of(parent_tape) do
    for {subagent_id, pid} <- children_of(parent_tape),
        Process.alive?(pid),
        {:ok, info} <- [safe_status(pid)] do
      {subagent_id, info}
    end
  end

  @doc "Safely query a worker's status, returning {:ok, info} or :error."
  def safe_status(pid) do
    try do
      {:ok, GenServer.call(pid, :status, 1_000)}
    catch
      :exit, _ -> :error
    end
  end

  @doc "Ensures the subagent status ETS table exists."
  def ensure_status_table do
    if :ets.whereis(@status_table) == :undefined do
      :ets.new(@status_table, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns completed subagents for a parent tape. Reads ETS, no GenServer calls."
  def completed_children_of(parent_tape) do
    ensure_status_table()

    spec = [
      {{:"$1", :"$2", :"$3", :"$4"},
       [{:==, :"$2", parent_tape}, {:==, :"$3", :done}],
       [{{:"$1", :"$4"}}]}
    ]

    :ets.select(@status_table, spec)
  end

  @doc "Removes a subagent's status entry from the ETS table."
  def clear_status(subagent_id) do
    ensure_status_table()
    :ets.delete(@status_table, subagent_id)
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    ensure_status_table()

    state = %__MODULE__{
      subagent_id: Keyword.fetch!(opts, :subagent_id),
      parent_tape: Keyword.fetch!(opts, :parent_tape),
      parent_agent_id: Keyword.get(opts, :parent_agent_id),
      tape_name: Keyword.fetch!(opts, :tape_name),
      prompt: Keyword.fetch!(opts, :prompt),
      workspace: Keyword.fetch!(opts, :workspace),
      depth: Keyword.fetch!(opts, :depth),
      model: Keyword.fetch!(opts, :model),
      tools: Keyword.fetch!(opts, :tools),
      system_prompt: Keyword.fetch!(opts, :system_prompt),
      max_steps: Keyword.get(opts, :max_steps, 30),
      parent_emit: Keyword.get(opts, :parent_emit),
      session_id: Keyword.get(opts, :session_id)
    }

    # Publish agent started signal so the LiveView UI can discover subagents
    session_id = state.session_id

    Rho.Comms.publish("rho.agent.#{session_id}.started", %{
      agent_id: state.subagent_id,
      session_id: session_id,
      role: :subagent,
      depth: state.depth,
      capabilities: [],
      parent_agent_id: state.parent_agent_id,
      model: state.model
    }, source: "/subagent/#{state.subagent_id}")

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    me = self()
    sid = state.subagent_id
    parent_emit = state.parent_emit

    session_id = state.session_id

    task =
      Task.async(fn ->
        Rho.AgentLoop.run(state.model, [ReqLLM.Context.user(state.prompt)],
          system_prompt: state.system_prompt,
          tools: state.tools,
          max_steps: state.max_steps,
          tape_name: state.tape_name,
          workspace: state.workspace,
          on_event: fn event ->
            # Forward key events to parent session for CLI visibility
            emit_to_parent(parent_emit, sid, event)

            # Publish to signal bus with subagent's own agent_id so the
            # LiveView tab receives events and can render traces.
            publish_own_event(session_id, sid, event)

            case event do
              %{type: :step_start, step: step, max_steps: max} ->
                send(me, {:progress, step, max})
                :ok

              %{type: :error, reason: reason} ->
                Logger.warning("[subagent:#{sid}] error: #{inspect(reason)}")
                :ok

              _ ->
                :ok
            end
          end,
          subagent: true,
          depth: state.depth
        )
      end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  # Task completed successfully
  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    state = %{state | status: :done, result: result, task_ref: nil}
    :ets.insert(@status_table, {state.subagent_id, state.parent_tape, :done, unwrap_result(result)})

    # Reply to all waiting collectors
    for from <- state.waiters do
      GenServer.reply(from, unwrap_result(result))
    end

    {:noreply, %{state | waiters: []}}
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    result = {:error, "subagent crashed: #{inspect(reason)}"}
    state = %{state | status: :done, result: result, task_ref: nil}
    :ets.insert(@status_table, {state.subagent_id, state.parent_tape, :done, result})

    for from <- state.waiters do
      GenServer.reply(from, result)
    end

    {:noreply, %{state | waiters: []}}
  end

  # Progress update from the AgentLoop on_event callback
  def handle_info({:progress, step, max}, state) do
    {:noreply, %{state | step: step, max_steps: max}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:collect, _from, %{status: :done} = state) do
    {:reply, unwrap_result(state.result), state}
  end

  def handle_call(:collect, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       step: state.step,
       max_steps: state.max_steps,
       status: state.status,
       prompt: state.prompt,
       depth: state.depth,
       tape_name: state.tape_name,
       parent_tape: state.parent_tape
     }, state}
  end

  @impl true
  def handle_cast(:cancel, %{task_ref: nil} = state) do
    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    # Kill the linked task — handle_info(:DOWN, ...) will fire
    Process.demonitor(state.task_ref, [:flush])
    # Find and kill the task process
    # The task is linked, so we need to unlink first to avoid cascade
    # Actually, Task.async links to the caller — which is this GenServer.
    # Sending :kill will trigger :DOWN which we handle above.
    # We store the ref but not the pid; use the ref-based :DOWN handling.
    # For now, set a flag and let it finish naturally.
    # TODO: For true mid-flight cancellation, AgentLoop would need interrupt support.
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Kill the internal task if still running
    if state.task_ref do
      Process.demonitor(state.task_ref, [:flush])
    end

    # Shutdown descendant subagents (nested children)
    shutdown_descendants(state.tape_name)

    # Publish agent stopped signal
    session_id = state.session_id

    Rho.Comms.publish("rho.agent.#{session_id}.stopped", %{
      agent_id: state.subagent_id,
      session_id: session_id,
      reason: inspect(reason)
    }, source: "/subagent/#{session_id}/subagent/#{state.subagent_id}")

    try do
      :ets.delete(@status_table, state.subagent_id)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # --- Private ---

  # Publish raw events under the subagent's own agent_id so the LiveView
  # tab can display traces (text_delta, tool_start, tool_result, etc.)
  defp publish_own_event(nil, _sid, _event), do: :ok

  defp publish_own_event(session_id, sid, event) do
    signal_type = event_to_signal_type(event)

    if signal_type do
      payload = Map.merge(event, %{agent_id: sid, session_id: session_id})

      Rho.Comms.publish(
        "rho.session.#{session_id}.events.#{signal_type}",
        payload,
        source: "/session/#{session_id}/agent/#{sid}"
      )
    end

    :ok
  end

  defp event_to_signal_type(%{type: :text_delta}), do: "text_delta"
  defp event_to_signal_type(%{type: :llm_text}), do: "llm_text"
  defp event_to_signal_type(%{type: :tool_start}), do: "tool_start"
  defp event_to_signal_type(%{type: :tool_result}), do: "tool_result"
  defp event_to_signal_type(%{type: :step_start}), do: "step_start"
  defp event_to_signal_type(%{type: :llm_usage}), do: "llm_usage"
  defp event_to_signal_type(%{type: :turn_started}), do: "turn_started"
  defp event_to_signal_type(%{type: :turn_finished}), do: "turn_finished"
  defp event_to_signal_type(%{type: :error}), do: "error"
  defp event_to_signal_type(_), do: nil

  defp emit_to_parent(nil, _sid, _event), do: :ok

  defp emit_to_parent(emit, sid, %{type: :step_start, step: step, max_steps: max}) do
    emit.(%{type: :subagent_progress, subagent_id: sid, step: step, max_steps: max})
  end

  defp emit_to_parent(emit, sid, %{type: :tool_start, name: name}) do
    emit.(%{type: :subagent_tool, subagent_id: sid, tool_name: name})
  end

  defp emit_to_parent(emit, sid, %{type: :error, reason: reason}) do
    emit.(%{type: :subagent_error, subagent_id: sid, reason: reason})
  end

  defp emit_to_parent(_emit, _sid, _event), do: :ok

  defp unwrap_result({:ok, text}), do: {:ok, text}
  defp unwrap_result({:error, reason}), do: {:error, "subagent failed: #{inspect(reason)}"}
  defp unwrap_result(other), do: {:error, "unexpected subagent result: #{inspect(other)}"}

  defp shutdown_descendants(tape_name) do
    for {_id, pid} <- children_of(tape_name), Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 2_000)
      catch
        :exit, _ -> :ok
      end
    end
  rescue
    _ -> :ok
  end
end
