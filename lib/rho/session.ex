defmodule Rho.Session do
  @moduledoc """
  Session = a namespace for a group of cooperating agents.

  Every session has one primary agent (the human's interlocutor)
  and zero or more peer agents spawned during the conversation.
  Manages their collective lifecycle and the primary agent that
  the human talks to.
  """

  alias Rho.Agent.Worker

  @doc "Find or start a session. Returns {:ok, primary_agent_pid}."
  def ensure_started(session_id, opts \\ []) do
    workspace = opts[:workspace] || File.cwd!()

    result =
      case whereis(session_id) do
        nil ->
          agent_id = primary_agent_id(session_id)

          worker_opts = [
            agent_id: agent_id,
            session_id: session_id,
            workspace: workspace,
            agent_name: opts[:agent_name] || :default,
            role: :primary,
            depth: 0,
            extra_opts: Keyword.drop(opts, [:workspace, :agent_name])
          ]

          case Rho.Agent.Supervisor.start_worker(worker_opts) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end

        pid ->
          {:ok, pid}
      end

    # Start EventLog for this session (idempotent)
    case result do
      {:ok, _pid} ->
        ensure_event_log(session_id, workspace)
        result

      error ->
        error
    end
  end

  @doc "Look up the primary agent for a running session. Returns pid or nil."
  def whereis(session_id) do
    agent_id = primary_agent_id(session_id)

    case Registry.lookup(Rho.AgentRegistry, agent_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Submit input to the primary agent. Returns {:ok, turn_id} immediately."
  def submit(session, content, opts \\ []) do
    pid = resolve_pid!(session)
    Worker.submit(pid, content, opts)
  end

  @doc "Subscribe to session events. Auto-cleaned on process death."
  def subscribe(session, pid \\ self()) do
    server_pid = resolve_pid!(session)
    Worker.subscribe(server_pid, pid)
  end

  @doc "Unsubscribe from session events."
  def unsubscribe(session, pid \\ self()) do
    server_pid = resolve_pid!(session)
    Worker.unsubscribe(server_pid, pid)
  end

  @doc "Cancel the current turn."
  def cancel(session) do
    pid = resolve_pid!(session)
    Worker.cancel(pid)
  end

  @doc "Get session info."
  def info(session) do
    pid = resolve_pid!(session)
    Worker.info(pid)
  end

  @doc "List active sessions, optionally filtered by prefix."
  def list(opts \\ []) do
    prefix = opts[:prefix]

    Rho.Agent.Supervisor.active_agents()
    |> Enum.map(fn pid ->
      try do
        Worker.info(pid)
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn info ->
      info.role == :primary and
        case prefix do
          nil -> true
          p -> String.starts_with?(info.session_id, p)
        end
    end)
  end

  @doc """
  Synchronous submit — subscribe, submit, collect events until done.

  Options:
    - `await: :finish` — wait until the agent calls `finish` (for multi-turn simulations).
      Default: return after the first turn completes.
  """
  def ask(session, content, opts \\ []) do
    pid = resolve_pid!(session)
    Worker.subscribe(pid)
    {:ok, turn_id} = Worker.submit(pid, content, opts)
    await_mode = Keyword.get(opts, :await, :turn)
    result = receive_until_done(turn_id, await_mode)
    Worker.unsubscribe(pid)
    result
  end

  @doc """
  Inject a message into a session, optionally targeting a specific agent.

  If `target_agent_id` is nil or "primary", delegates to `submit/3`.
  Otherwise delivers a signal directly to the target agent.
  """
  def inject(session_id, target_agent_id, message, opts \\ []) do
    cond do
      target_agent_id in [nil, "primary"] ->
        submit(session_id, message, opts)

      true ->
        case Worker.whereis(target_agent_id) do
          nil ->
            {:error, :agent_not_found}

          pid ->
            from = opts[:from] || "external"

            Worker.deliver_signal(pid, %{
              type: "rho.message.sent",
              data: %{message: message, from: from}
            })

            {:ok, :injected}
        end
    end
  end

  @doc "Returns the JSONL event log file path for a session."
  def event_log_path(session_id) do
    Rho.Session.EventLog.path(session_id)
  end

  @doc "List all agents in a session."
  def agents(session_id) do
    Rho.Agent.Registry.list(session_id)
  end

  @doc "Resolve session ID from opts."
  def resolve_id(opts) do
    if opts[:session_id] do
      opts[:session_id]
    else
      channel = opts[:channel] || "cli"
      chat_id = opts[:chat_id] || "default"
      "#{channel}:#{chat_id}"
    end
  end

  @doc "Unsubscribe from session events, ignoring errors if the session is gone."
  def safe_unsubscribe(session) do
    unsubscribe(session)
  catch
    _, _ -> :ok
  end

  @doc "Stop all agents in a session."
  def stop(session_id) do
    # Stop EventLog first
    Rho.Session.EventLog.stop(session_id)

    for agent <- Rho.Agent.Registry.list_all(session_id) do
      if pid = Worker.whereis(agent.agent_id) do
        GenServer.stop(pid, :shutdown, 5_000)
      end

      # Clean up registry entry (including already-stopped agents)
      Rho.Agent.Registry.unregister(agent.agent_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Generate a new agent ID for use in a session."
  def new_agent_id do
    "agent_#{:erlang.unique_integer([:positive])}"
  end

  # --- Private ---

  defp primary_agent_id(session_id) do
    "primary_#{session_id}"
  end

  defp resolve_pid!(session) when is_pid(session), do: session

  defp resolve_pid!(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> raise "Session not found: #{session_id}"
      pid -> pid
    end
  end

  defp ensure_event_log(session_id, workspace) do
    case Registry.lookup(Rho.EventLogRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        try do
          DynamicSupervisor.start_child(
            Rho.Session.EventLog.Supervisor,
            {Rho.Session.EventLog, session_id: session_id, workspace: workspace}
          )
        catch
          :exit, _ -> :ok
        end
    end
  end

  # Default: return after first turn completes (backwards compatible)
  defp receive_until_done(turn_id, :turn) do
    receive do
      {:session_event, _sid, ^turn_id, %{type: :turn_finished, result: {:final, value}}} ->
        {:ok, value}

      {:session_event, _sid, ^turn_id, %{type: :turn_finished, result: result}} ->
        result
    end
  end

  # Simulation mode: wait until the agent calls `finish` or goes idle with no pending work.
  # After each regular turn end, waits up to 30s for more activity before treating as done.
  defp receive_until_done(_turn_id, :finish), do: receive_until_finish(nil)

  defp receive_until_finish(last_result) do
    # Wait for events. After a regular turn ends, use a 30s timeout — if no new turn
    # starts within 30s, the agent is done (either waiting for messages that won't come,
    # or the model forgot to call finish).
    timeout = if last_result, do: 30_000, else: :infinity

    receive do
      {:session_event, _sid, _tid, %{type: :turn_finished, result: {:final, value}}} ->
        {:ok, value}

      {:session_event, _sid, _tid, %{type: :turn_finished, result: {:ok, _text} = ok}} ->
        receive_until_finish(ok)

      {:session_event, _sid, _tid, %{type: :turn_finished, result: {:error, _} = err}} ->
        err
    after
      timeout ->
        # No new activity — return the last result we saw
        last_result || {:ok, "completed"}
    end
  end
end
