defmodule RhoFrameworks.AgentJobs do
  @moduledoc """
  Lightweight async agent jobs for frameworks.

  Spawns single-shot worker tasks under `Rho.TaskSupervisor` using
  `Runner.run` in lite mode — no tape, no transformer pipeline, no
  compaction, direct tool execution.

  Results are tracked via `LiteTracker` and completion events are
  published via `Rho.Events`.
  """

  require Logger

  alias Rho.Agent.{LiteTracker, Primary}

  @default_max_steps 5

  @doc """
  Start an async agent job. Returns `{:ok, agent_id}`.

  ## Required options

    * `:task` — the task prompt
    * `:parent_agent_id` — parent for hierarchical agent ID
    * `:tools` — list of tool_def maps
    * `:model` — LLM model string

  ## Optional

    * `:system_prompt` — base system prompt (default: generic worker prompt)
    * `:max_steps` — max LLM round-trips (default 5)
    * `:turn_strategy` — strategy module (default `Rho.TurnStrategy.Direct`)
    * `:provider` — provider options map
    * `:session_id` — for event publishing
    * `:organization_id` — for context
    * `:agent_name` — role atom (default `:worker`)
  """
  @spec start(keyword()) :: {:ok, String.t()}
  def start(opts) do
    task_prompt = Keyword.fetch!(opts, :task)
    parent_agent_id = Keyword.fetch!(opts, :parent_agent_id)

    agent_id = Primary.new_agent_id(parent_agent_id)
    session_id = opts[:session_id]

    parent_worker_pid = resolve_parent_worker_pid(parent_agent_id)
    emit = build_emit(session_id, agent_id, parent_worker_pid)

    base_prompt = opts[:system_prompt] || "You are a helpful assistant."

    spec =
      Rho.RunSpec.build(
        model: Keyword.fetch!(opts, :model),
        system_prompt: worker_prompt(base_prompt),
        tools: Keyword.fetch!(opts, :tools),
        emit: emit,
        tape_name: nil,
        max_steps: opts[:max_steps] || @default_max_steps,
        agent_name: opts[:agent_name] || :worker,
        agent_id: agent_id,
        session_id: session_id,
        organization_id: opts[:organization_id],
        turn_strategy:
          Rho.AgentConfig.resolve_turn_strategy(opts[:turn_strategy] || Rho.TurnStrategy.Direct),
        provider: opts[:provider],
        depth: (opts[:depth] || 0) + 1,
        lite: true
      )

    messages = [ReqLLM.Context.user(task_prompt)]

    task =
      Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
        result = Rho.Runner.run(messages, spec)
        LiteTracker.complete(agent_id, result)
        publish_completion(session_id, agent_id, result)
        result
      end)

    LiteTracker.register(agent_id, task.ref, task.pid)

    {:ok, agent_id}
  end

  @doc """
  Best-effort cancel of a running lite worker. Used by the research
  panel's "Continue early" — the flow advances regardless, so this is
  fire-and-forget cleanup, not a synchronisation point.

  Returns `:ok` whether the worker was running, already done, or never
  existed. Safe to call concurrently with completion.
  """
  @spec cancel(String.t()) :: :ok
  def cancel(agent_id) when is_binary(agent_id) do
    case LiteTracker.lookup(agent_id) do
      {:running, _result, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)
        :ok

      _ ->
        :ok
    end
  end

  # -- Private --

  defp worker_prompt(base) do
    """
    #{base}

    You are a focused worker agent. Complete the given task efficiently.
    Call the appropriate tool with your result when done.
    Do not ask clarifying questions — make reasonable assumptions.
    """
  end

  defp build_emit(session_id, agent_id, parent_pid) do
    fn event ->
      if is_pid(parent_pid) and Process.alive?(parent_pid) do
        send(parent_pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})
      end

      publish_event(session_id, agent_id, event)
      :ok
    end
  end

  defp resolve_parent_worker_pid(parent_agent_id) when is_binary(parent_agent_id) do
    Rho.Agent.Worker.whereis(parent_agent_id)
  rescue
    _ -> nil
  end

  defp resolve_parent_worker_pid(_), do: nil

  defp publish_completion(nil, _agent_id, _result), do: :ok

  defp publish_completion(session_id, agent_id, result) when is_binary(session_id) do
    {status, text} =
      case result do
        {:ok, t} -> {:ok, t}
        {:error, r} -> {:error, inspect(r)}
      end

    data = %{session_id: session_id, agent_id: agent_id, status: status, result: text}

    Rho.Events.broadcast(
      session_id,
      Rho.Events.event(:task_completed, session_id, agent_id, data)
    )
  end

  defp publish_completion(_, _, _), do: :ok

  @signal_event_types ~w(
    text_delta llm_text tool_start tool_result step_start llm_usage
    error structured_partial before_llm
  )a

  defp publish_event(nil, _agent_id, _event), do: :ok

  defp publish_event(session_id, agent_id, event) when is_binary(session_id) do
    case event do
      %{type: type} when type in @signal_event_types ->
        tagged = Map.put(event, :lite, true)
        Rho.Events.broadcast(session_id, Rho.Events.normalize(tagged, session_id, agent_id))

      _ ->
        :ok
    end
  end
end
