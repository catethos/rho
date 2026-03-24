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
    case whereis(session_id) do
      nil ->
        agent_id = primary_agent_id(session_id)

        worker_opts = [
          agent_id: agent_id,
          session_id: session_id,
          workspace: opts[:workspace] || File.cwd!(),
          agent_name: opts[:agent_name] || :default,
          role: :primary,
          depth: 0
        ]

        case Rho.Agent.Supervisor.start_worker(worker_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end

      pid ->
        {:ok, pid}
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

  @doc "Synchronous submit — subscribe, submit, collect events until turn_finished."
  def ask(session, content, opts \\ []) do
    pid = resolve_pid!(session)
    Worker.subscribe(pid)
    {:ok, turn_id} = Worker.submit(pid, content, opts)
    result = receive_until_done(turn_id)
    Worker.unsubscribe(pid)
    result
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
    for agent <- Rho.Agent.Registry.list(session_id) do
      if pid = Worker.whereis(agent.agent_id) do
        GenServer.stop(pid, :shutdown, 5_000)
      end
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

  defp receive_until_done(turn_id) do
    receive do
      {:session_event, _sid, ^turn_id, %{type: :turn_finished, result: result}} ->
        result
    end
  end
end
