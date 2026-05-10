defmodule Rho.Stdlib.Plugins.MultiAgent do
  @moduledoc """
  Plugin providing multi-agent coordination tools.

  Replaces Rho.Plugins.Subagent with a signal-based delegation model
  where every agent is a first-class peer that communicates via signals.

  Tools provided:
  - delegate_task: Spawn a new agent to handle a subtask
  - await_task: Block until a delegated task completes
  - send_message: Send a direct message to another agent
  - list_agents: Discover active agents in this session
  - get_agent_card: Get detailed info about a specific agent

  Id cards (description + skills) are configured statically in .rho.exs and
  registered automatically when the agent starts.
  """

  @behaviour Rho.Plugin

  alias Rho.Agent.{LiteTracker, Primary, Registry, Supervisor, Worker}

  @max_depth 3
  @max_agents_per_session 10
  @default_max_steps 30
  @await_timeout 300_000
  defp known_roles_cache do
    Rho.Config.agent_names() |> Enum.map(&Atom.to_string/1)
  end

  # Validate an explicitly-supplied role string. "worker" is the documented
  # generic-default sentinel and is always allowed. Otherwise the role must
  # be a configured agent name. Unknown roles error loudly so a hallucinated
  # role doesn't silently degrade to a generic worker.
  defp resolve_role(role_str) when is_binary(role_str) do
    cond do
      role_str == "worker" ->
        {:ok, :worker}

      role_str in known_roles_cache() ->
        {:ok, String.to_existing_atom(role_str)}

      true ->
        available = Enum.join(["worker" | known_roles_cache()], ", ")
        {:error, "unknown role #{inspect(role_str)}; available: #{available}"}
    end
  end

  # --- Plugin callbacks ---

  @impl Rho.Plugin
  def tools(mount_opts, %{depth: depth} = ctx) when depth < @max_depth do
    session_id = ctx[:session_id] || ctx[:tape_name]
    agent_id = ctx[:agent_id]
    workspace = ctx[:workspace]
    memory_mod = ctx[:tape_module] || Rho.Tape.Projection.JSONL
    parent_emit = get_in(ctx, [:opts, :emit])
    identity = %{user_id: ctx[:user_id], organization_id: ctx[:organization_id]}
    role_hint = build_role_hint(mount_opts, ctx[:agent_name])

    [
      delegate_task_tool(
        session_id,
        agent_id,
        workspace,
        depth,
        memory_mod,
        parent_emit,
        identity,
        role_hint
      ),
      delegate_task_lite_tool(session_id, agent_id, ctx, role_hint),
      await_task_tool(session_id),
      await_all_tool(session_id),
      spawn_agent_tool(session_id, agent_id, workspace, depth, memory_mod, parent_emit, identity),
      collect_results_tool(session_id),
      stop_agent_tool(session_id),
      send_message_tool(session_id, agent_id),
      broadcast_message_tool(session_id, agent_id),
      list_agents_tool(session_id),
      find_capable_tool(session_id),
      get_agent_card_tool(session_id),
      Rho.Stdlib.Tools.Finish.tool_def()
    ]
    |> filter_tools(mount_opts)
  end

  def tools(mount_opts, %{depth: depth} = ctx) when depth >= @max_depth do
    session_id = ctx[:session_id] || ctx[:tape_name]
    # At max depth, only provide discovery (no delegation)
    [list_agents_tool(session_id), find_capable_tool(session_id), get_agent_card_tool(session_id)]
    |> filter_tools(mount_opts)
  end

  def tools(_mount_opts, _context), do: []

  # No prompt_sections — available agent roles are inlined into
  # delegate_task/delegate_task_lite param @desc via the BAML schema.

  # --- Signal handling ---

  @impl Rho.Plugin
  def handle_signal(%{type: "rho.task.requested", data: data}, _opts, _ctx) do
    task = data[:task] || data["task"]
    task_id = data[:task_id] || data["task_id"]
    max_steps = data[:max_steps] || data["max_steps"] || @default_max_steps

    if task do
      {:start_turn, task,
       [
         task_id: task_id,
         delegated: true,
         max_steps: max_steps
       ]}
    else
      :ignore
    end
  end

  def handle_signal(%{type: "rho.message.sent", data: data}, _opts, _ctx) do
    message = data[:message] || data["message"]
    from = data[:from] || data["from"]

    if message do
      {:start_turn, format_incoming_message(message, from), []}
    else
      :ignore
    end
  end

  def handle_signal(_signal, _opts, _ctx), do: :ignore

  defp format_incoming_message(message, "external") do
    """
    [External message]
    #{message}
    """
  end

  defp format_incoming_message(message, from) when is_binary(from) do
    {from_role, from_id} =
      case Registry.get(from) do
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
  end

  defp format_incoming_message(message, _from), do: message

  # Some delegated/spawned agents have multi_agent in their plugin set
  # (which already provides Finish via tools/2), but the spawn paths
  # historically appended Finish unconditionally — producing a duplicate.
  # Only add Finish when it isn't already present in the collected tools.
  defp ensure_finish_tool(tools) do
    finish_def = Rho.Stdlib.Tools.Finish.tool_def()

    if Enum.any?(tools, &(&1.tool.name == finish_def.tool.name)) do
      tools
    else
      tools ++ [finish_def]
    end
  end

  defp build_role_hint(mount_opts, self_name) do
    visible = Keyword.get(mount_opts, :visible_agents)

    names =
      Rho.Config.agent_names()
      |> Enum.reject(&(&1 == self_name))
      |> then(fn names ->
        if is_list(visible),
          do: Enum.filter(names, &(&1 in visible)),
          else: names
      end)

    if names == [], do: nil, else: Enum.map_join(names, ", ", &to_string/1)
  end

  # --- Tool definitions ---

  defp delegate_task_tool(
         session_id,
         parent_agent_id,
         workspace,
         parent_depth,
         memory_mod,
         parent_emit,
         identity,
         role_hint
       ) do
    role_doc = role_hint || "Agent role name"

    %{
      tool:
        ReqLLM.tool(
          name: "delegate_task",
          description: "Spawn a sub-agent for a subtask. Use await_task for the result.",
          parameter_schema: [
            task: [type: :string, required: true, doc: "Task prompt"],
            role: [type: :string, doc: role_doc],
            capability: [type: :string, doc: "Route to idle agent with this capability"],
            context_summary: [type: :string, doc: "Why this task is needed"],
            inherit_context: [type: :boolean, doc: "Fork parent tape (default: false)"],
            max_steps: [type: :integer, doc: "Max steps (default: #{@default_max_steps})"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_delegate(
          args,
          session_id,
          parent_agent_id,
          workspace,
          parent_depth,
          memory_mod,
          parent_emit,
          identity
        )
      end
    }
  end

  defp await_task_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "await_task",
          description: "Wait for a delegated agent to finish.",
          parameter_schema: [
            agent_id: [type: :string, required: true],
            timeout: [type: :integer, doc: "default: 300"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_await(args, session_id)
      end
    }
  end

  defp delegate_task_lite_tool(session_id, parent_agent_id, ctx, role_hint) do
    role_doc = role_hint || "Role for config lookup (default: worker)"

    %{
      tool:
        ReqLLM.tool(
          name: "delegate_task_lite",
          description:
            "Spawn a lightweight agent for single-purpose generation. Use await_all for results.",
          parameter_schema: [
            task: [type: :string, required: true, doc: "Task prompt"],
            role: [type: :string, doc: role_doc],
            max_steps: [type: :integer, doc: "Max LLM round-trips (default: 3)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_delegate_lite(args, session_id, parent_agent_id, ctx)
      end
    }
  end

  defp await_all_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "await_all",
          description: "Wait for all delegated agents to finish.",
          parameter_schema: [
            agent_ids: [type: :string, required: true, doc: "JSON array of agent_ids"],
            timeout: [type: :integer, doc: "default: 300"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_await_all(args, session_id)
      end
    }
  end

  defp send_message_tool(session_id, self_agent_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "send_message",
          description:
            "Send a direct message to another agent. The target agent will process " <>
              "it as a new turn when it becomes idle.",
          parameter_schema: [
            target: [type: :string, required: true, doc: "agent_id or role of the target agent"],
            message: [type: :string, required: true, doc: "The message to send"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_send_message(args, session_id, self_agent_id)
      end
    }
  end

  defp broadcast_message_tool(session_id, self_agent_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "broadcast_message",
          description: "Send a message to all other agents in this session.",
          parameter_schema: [
            message: [type: :string, required: true, doc: "The message to broadcast"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_broadcast_message(args, session_id, self_agent_id)
      end
    }
  end

  defp list_agents_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "list_agents",
          description:
            "List all active agents in this session with their roles, status, and id cards.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args, _ctx ->
        execute_list_agents(session_id)
      end
    }
  end

  defp find_capable_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "find_capable",
          description:
            "Find agents in this session that have a specific capability (e.g. :bash, :python, :web_fetch).",
          parameter_schema: [
            capability: [
              type: :string,
              required: true,
              doc: "The capability to search for (e.g. \"bash\", \"python\", \"web_fetch\")"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        cap = arg(args, :capability)

        cap_atom =
          try do
            String.to_existing_atom(cap)
          rescue
            ArgumentError -> cap
          end

        agents = Registry.find_by_capability(session_id, cap_atom)

        if agents == [] do
          {:ok, "No agents with capability '#{cap}' found in this session."}
        else
          lines =
            Enum.map(agents, fn agent ->
              "- #{agent.agent_id} (#{agent.role}, #{agent.status})"
            end)

          {:ok, "Agents with '#{cap}':\n#{Enum.join(lines, "\n")}"}
        end
      end
    }
  end

  defp get_agent_card_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_agent_card",
          description: "Get the detailed id card of a specific agent by agent_id or role.",
          parameter_schema: [
            target: [
              type: :string,
              required: true,
              doc: "agent_id or role of the agent to look up"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_get_agent_card(args, session_id)
      end
    }
  end

  defp spawn_agent_tool(
         session_id,
         parent_agent_id,
         workspace,
         parent_depth,
         memory_mod,
         parent_emit,
         identity
       ) do
    %{
      tool:
        ReqLLM.tool(
          name: "spawn_agent",
          description:
            "Spawn an agent that starts idle, ready to receive messages. " <>
              "Unlike delegate_task, this does NOT give the agent an initial task. " <>
              "Use send_message to start a conversation with it. " <>
              "Use collect_results to read its conversation history. " <>
              "Use stop_agent to shut it down when done.",
          parameter_schema: [
            role: [
              type: :string,
              required: true,
              doc:
                "Role for the agent (e.g., 'researcher', 'technical_evaluator'). Uses role-specific config."
            ],
            system_prompt_extra: [
              type: :string,
              doc: "Additional instructions appended to the role's system prompt"
            ],
            max_steps: [
              type: :integer,
              doc: "Max steps per turn (default: #{@default_max_steps})"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_spawn(
          args,
          session_id,
          parent_agent_id,
          workspace,
          parent_depth,
          memory_mod,
          parent_emit,
          identity
        )
      end
    }
  end

  defp collect_results_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "collect_results",
          description:
            "Read an agent's conversation history without stopping it. " <>
              "Returns the agent's tape entries (messages exchanged). " <>
              "The agent stays alive and can continue receiving messages.",
          parameter_schema: [
            agent_id: [type: :string, required: true, doc: "The agent_id to observe"],
            limit: [type: :integer, doc: "Max number of recent entries to return (default: 20)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_collect_results(args, session_id)
      end
    }
  end

  defp stop_agent_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "stop_agent",
          description:
            "Stop a spawned agent. Use after the simulation or discussion is complete.",
          parameter_schema: [
            agent_id: [type: :string, required: true, doc: "The agent_id to stop"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_stop_agent(args, session_id)
      end
    }
  end

  # --- Delegate implementation ---

  defp execute_delegate(
         args,
         session_id,
         parent_agent_id,
         workspace,
         parent_depth,
         memory_mod,
         parent_emit,
         identity
       ) do
    task_prompt = arg(args, :task)
    role_str = arg(args, :role) || "worker"
    capability = arg(args, :capability)
    context_summary = arg(args, :context_summary)
    inherit_context = arg(args, :inherit_context) || false
    max_steps = arg(args, :max_steps) || @default_max_steps

    if task_prompt do
      delegate_or_route(task_prompt, %{
        capability: capability,
        role_str: role_str,
        session_id: session_id,
        parent_agent_id: parent_agent_id,
        workspace: workspace,
        parent_depth: parent_depth,
        tape_module: memory_mod,
        parent_emit: parent_emit,
        context_summary: context_summary,
        inherit_context: inherit_context,
        max_steps: max_steps,
        user_id: identity[:user_id],
        organization_id: identity[:organization_id]
      })
    else
      {:error, "task parameter is required"}
    end
  end

  defp delegate_or_route(task_prompt, params) do
    case route_by_capability(
           params.capability,
           params.session_id,
           params.parent_agent_id,
           task_prompt
         ) do
      {:routed, result} ->
        result

      :not_routed ->
        case resolve_role(params.role_str) do
          {:ok, role_atom} ->
            do_delegate(task_prompt, %{
              session_id: params.session_id,
              parent_agent_id: params.parent_agent_id,
              workspace: params.workspace,
              parent_depth: params.parent_depth,
              tape_module: params.tape_module,
              parent_emit: params.parent_emit,
              role: role_atom,
              context_summary: params.context_summary,
              inherit_context: params.inherit_context,
              max_steps: params.max_steps,
              user_id: params[:user_id],
              organization_id: params[:organization_id]
            })

          {:error, _} = err ->
            err
        end
    end
  end

  defp route_by_capability(nil, _session_id, _parent_agent_id, _task), do: :not_routed

  defp route_by_capability(capability, session_id, parent_agent_id, task) do
    cap_atom =
      try do
        String.to_existing_atom(capability)
      rescue
        ArgumentError -> capability
      end

    # Find idle agents with this capability (exclude self)
    candidates =
      Registry.find_by_capability(session_id, cap_atom)
      |> Enum.filter(fn agent ->
        agent.agent_id != parent_agent_id and agent.status == :idle
      end)

    case candidates do
      [target | _] ->
        task_id = "task_#{:erlang.unique_integer([:positive])}"

        # Send task as a signal to the existing agent
        Worker.deliver_signal(target.pid, %{
          type: "rho.task.requested",
          data: %{task: task, task_id: task_id}
        })

        task_data = %{
          task_id: task_id,
          session_id: session_id,
          agent_id: target.agent_id,
          parent_agent_id: parent_agent_id,
          role: to_string(target.role),
          task: task,
          max_steps: @default_max_steps
        }

        Rho.Events.broadcast(
          session_id,
          Rho.Events.event(:task_requested, session_id, target.agent_id, task_data)
        )

        {:routed,
         {:ok,
          "Routed to existing agent #{target.agent_id} (capability: #{capability}). " <>
            "Use await_task(agent_id: \"#{target.agent_id}\") to get the result."}}

      [] ->
        :not_routed
    end
  end

  defp do_delegate(task_prompt, params) do
    role_str = Atom.to_string(params.role)

    with {:ok, prepared} <-
           prepare_child_agent(role_str, %{
             session_id: params.session_id,
             parent_agent_id: params.parent_agent_id,
             workspace: params.workspace,
             parent_depth: params.parent_depth,
             tape_module: params.tape_module,
             max_steps: params.max_steps,
             inherit_context: params.inherit_context,
             user_id: params[:user_id],
             organization_id: params[:organization_id]
           }) do
      task_id = "task_#{:erlang.unique_integer([:positive])}"
      config = prepared.config

      system_prompt =
        delegate_system_prompt(
          task_prompt,
          params.context_summary,
          prepared.child_depth,
          @max_depth,
          config.system_prompt
        )

      {:ok, _pid} =
        Supervisor.start_worker(
          agent_id: prepared.agent_id,
          session_id: params.session_id,
          workspace: params.workspace,
          agent_name: prepared.agent_name,
          role: params.role,
          tape_ref: prepared.tape_name,
          initial_task: task_prompt,
          task_id: task_id,
          max_steps: params.max_steps,
          system_prompt: system_prompt,
          tools: prepared.tools,
          model: config.model,
          user_id: params[:user_id],
          organization_id: params[:organization_id]
        )

      task_data = %{
        task_id: task_id,
        session_id: params.session_id,
        agent_id: prepared.agent_id,
        parent_agent_id: params.parent_agent_id,
        role: role_str,
        task: task_prompt,
        context_summary: params.context_summary,
        max_steps: params.max_steps
      }

      Rho.Events.broadcast(
        params.session_id,
        Rho.Events.event(:task_requested, params.session_id, prepared.agent_id, task_data)
      )

      {:ok,
       "Delegated #{task_id} to #{prepared.agent_id} (role: #{params.role}). Use await_task(agent_id: \"#{prepared.agent_id}\") to get the result."}
    end
  end

  # --- Await implementation ---

  defp execute_await(args, _session_id) do
    agent_id = arg(args, :agent_id)
    timeout_secs = arg(args, :timeout) || 300
    timeout_ms = min(timeout_secs * 1000, @await_timeout)

    if agent_id do
      await_agent(agent_id, timeout_ms, timeout_secs)
    else
      {:error, "agent_id parameter is required"}
    end
  end

  defp await_agent(agent_id, timeout_ms, timeout_secs) do
    case LiteTracker.lookup(agent_id) do
      nil ->
        await_full_worker(agent_id, timeout_ms, timeout_secs)

      _lite_entry ->
        case LiteTracker.await(agent_id, timeout_ms) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, "lite agent #{agent_id} failed: #{reason}"}
        end
    end
  end

  defp await_full_worker(agent_id, timeout_ms, timeout_secs) do
    pid = Worker.whereis(agent_id)

    if pid do
      collect_full_worker(pid, agent_id, timeout_ms, timeout_secs)
    else
      {:error, "unknown agent: #{agent_id}"}
    end
  end

  defp collect_full_worker(pid, agent_id, timeout_ms, timeout_secs) do
    case Worker.collect(pid, timeout_ms) do
      {:ok, text} ->
        safe_stop(pid)
        {:ok, text}

      {:error, reason} ->
        {:error, "agent #{agent_id} failed: #{inspect(reason)}"}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "agent #{agent_id} timed out after #{timeout_secs}s (still running in background)"}

    :exit, reason ->
      {:error, "agent #{agent_id} exited: #{inspect(reason)}"}
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  # --- Delegate lite implementation ---

  defp execute_delegate_lite(args, session_id, parent_agent_id, %Rho.Context{} = ctx) do
    task_prompt = arg(args, :task)
    role_str = arg(args, :role) || "worker"

    with {:ok, agent_name} <- resolve_role(role_str) do
      role_config =
        if agent_name in Rho.Config.agent_names(),
          do: Rho.Config.agent_config(agent_name),
          else: %{}

      max_steps = arg(args, :max_steps) || Map.get(role_config, :max_steps, 5)

      do_execute_delegate_lite(
        task_prompt,
        role_str,
        agent_name,
        role_config,
        max_steps,
        session_id,
        parent_agent_id,
        ctx
      )
    end
  end

  defp do_execute_delegate_lite(
         task_prompt,
         role_str,
         agent_name,
         role_config,
         max_steps,
         session_id,
         parent_agent_id,
         %Rho.Context{} = ctx
       ) do
    if task_prompt do
      # Resolve tools once from context — lite workers reuse them directly
      tools = Rho.PluginRegistry.collect_tools(ctx)
      tools = ensure_finish_tool(tools)

      agent_id = Primary.new_agent_id(parent_agent_id)
      parent_worker_pid = Worker.whereis(parent_agent_id)

      emit = build_lite_emit(session_id, agent_id, parent_worker_pid)

      base_prompt = Map.get(role_config, :system_prompt, "You are a helpful assistant.")

      spec =
        Rho.RunSpec.build(
          model: Map.get(role_config, :model, "openrouter:anthropic/claude-haiku-4.5"),
          system_prompt: lite_worker_prompt(base_prompt),
          tools: tools,
          emit: emit,
          tape_name: nil,
          max_steps: max_steps,
          agent_name: agent_name,
          agent_id: agent_id,
          session_id: session_id,
          organization_id: ctx.organization_id,
          turn_strategy: Map.get(role_config, :turn_strategy, Rho.TurnStrategy.Direct),
          provider: role_config[:provider],
          depth: ctx.depth + 1,
          lite: true
        )

      messages = [ReqLLM.Context.user(task_prompt)]

      task =
        Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
          result = Rho.Runner.run(messages, spec)
          LiteTracker.complete(agent_id, result)
          publish_lite_completion(session_id, agent_id, result)
          result
        end)

      LiteTracker.register(agent_id, task.ref, task.pid)

      task_data = %{
        session_id: session_id,
        agent_id: agent_id,
        parent_agent_id: parent_agent_id,
        role: role_str,
        task: task_prompt,
        lite: true
      }

      Rho.Events.broadcast(
        session_id,
        Rho.Events.event(:task_requested, session_id, agent_id, task_data)
      )

      {:ok,
       "Lite agent #{agent_id} spawned (role: #{role_str}). " <>
         "Use await_task(agent_id: \"#{agent_id}\") or await_all to get the result."}
    else
      {:error, "task parameter is required"}
    end
  end

  defp lite_worker_prompt(base) do
    """
    #{base}

    You are a focused worker agent. Complete the given task efficiently.
    Call the appropriate tool with your result when done.
    Do not ask clarifying questions — make reasonable assumptions.
    """
  end

  defp build_lite_emit(session_id, agent_id, parent_pid) do
    fn event ->
      if is_pid(parent_pid) and Process.alive?(parent_pid) do
        send(parent_pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})
      end

      publish_lite_event(session_id, agent_id, event)
      :ok
    end
  end

  @lite_signal_types ~w(
    text_delta llm_text tool_start tool_result step_start llm_usage
    error structured_partial before_llm
  )a

  defp publish_lite_event(nil, _agent_id, _event), do: :ok

  defp publish_lite_event(session_id, agent_id, event) when is_binary(session_id) do
    case event do
      %{type: type} when type in @lite_signal_types ->
        tagged = Map.put(event, :lite, true)
        Rho.Events.broadcast(session_id, Rho.Events.normalize(tagged, session_id, agent_id))

      _ ->
        :ok
    end
  end

  defp publish_lite_completion(nil, _agent_id, _result), do: :ok

  defp publish_lite_completion(session_id, agent_id, result) when is_binary(session_id) do
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

  defp publish_lite_completion(_, _, _), do: :ok

  # --- Await all implementation ---

  defp execute_await_all(args, session_id) do
    ids_raw = arg(args, :agent_ids) || "[]"
    timeout_secs = arg(args, :timeout) || 300
    timeout_ms = min(timeout_secs * 1000, @await_timeout)

    ids =
      case Jason.decode(ids_raw) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    if ids == [] do
      {:error, "agent_ids must be a non-empty JSON array of strings"}
    else
      results = await_all_agents(ids, session_id, timeout_ms)

      summary = Map.new(results, &format_await_result/1)

      {:ok, Jason.encode!(summary)}
    end
  end

  defp await_all_agents(ids, session_id, timeout_ms) do
    tasks =
      Enum.map(ids, fn id ->
        Task.async(fn ->
          result = do_await_single(id, session_id, timeout_ms)
          {id, result}
        end)
      end)

    Task.await_many(tasks, timeout_ms + 5_000)
  end

  defp format_await_result({id, {:ok, text}}),
    do: {id, %{"status" => "ok", "result" => text}}

  defp format_await_result({id, {:error, reason}}),
    do: {id, %{"status" => "error", "error" => reason}}

  defp do_await_single(agent_id, _session_id, timeout_ms) do
    # Check lite tracker first
    case LiteTracker.lookup(agent_id) do
      nil ->
        await_full_worker_single(agent_id, timeout_ms)

      _lite_entry ->
        LiteTracker.await(agent_id, timeout_ms)
    end
  end

  defp await_full_worker_single(agent_id, timeout_ms) do
    pid = Worker.whereis(agent_id)

    if pid do
      collect_and_stop(pid, agent_id, timeout_ms)
    else
      {:error, "unknown agent: #{agent_id}"}
    end
  end

  defp collect_and_stop(pid, _agent_id, timeout_ms) do
    case Worker.collect(pid, timeout_ms) do
      {:ok, text} ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

        {:ok, text}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ -> {:error, "timeout"}
  end

  # --- Send message implementation ---

  # --- Spawn implementation ---

  defp execute_spawn(
         args,
         session_id,
         parent_agent_id,
         workspace,
         parent_depth,
         memory_mod,
         _parent_emit,
         identity
       ) do
    role_str = arg(args, :role) || "worker"
    system_prompt_extra = arg(args, :system_prompt_extra)
    max_steps = arg(args, :max_steps) || @default_max_steps

    with {:ok, prepared} <-
           prepare_child_agent(role_str, %{
             session_id: session_id,
             parent_agent_id: parent_agent_id,
             workspace: workspace,
             parent_depth: parent_depth,
             tape_module: memory_mod,
             max_steps: max_steps,
             user_id: identity[:user_id],
             organization_id: identity[:organization_id]
           }) do
      config = prepared.config
      base_prompt = config.system_prompt

      spawn_prompt = """
      #{base_prompt}

      You are agent #{prepared.agent_id} (role: #{role_str}) in a multi-agent simulation.
      You will receive messages from other agents. Read them, reason about them, and reply using send_message.
      You can also use broadcast_message to address all agents, or list_agents to see who else is active.
      When you have nothing more to contribute, simply call end_turn.
      #{if system_prompt_extra, do: "\n#{system_prompt_extra}", else: ""}
      """

      {:ok, _pid} =
        Supervisor.start_worker(
          agent_id: prepared.agent_id,
          session_id: session_id,
          workspace: workspace,
          agent_name: prepared.agent_name,
          role: prepared.role_atom,
          tape_ref: prepared.tape_name,
          max_steps: max_steps,
          system_prompt: spawn_prompt,
          tools: prepared.tools,
          model: config.model,
          user_id: identity[:user_id],
          organization_id: identity[:organization_id]
        )

      spawn_data = %{
        session_id: session_id,
        agent_id: prepared.agent_id,
        role: role_str
      }

      Rho.Events.broadcast(
        session_id,
        Rho.Events.event(:agent_spawned, session_id, prepared.agent_id, spawn_data)
      )

      {:ok,
       "Spawned #{prepared.agent_id} (role: #{role_str}). Agent is idle and ready for messages. Use send_message(target: \"#{prepared.agent_id}\", message: \"...\") to start a conversation."}
    end
  end

  # --- Collect results implementation ---

  defp execute_collect_results(args, session_id) do
    limit = arg(args, :limit) || 20

    with_validated_agent(args, session_id, fn agent ->
      memory_mod = Rho.Config.tape_module()
      history = memory_mod.history(agent.tape_ref)
      entries = Enum.take(history, -limit)

      formatted =
        entries
        |> Enum.map(&format_tape_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n---\n")

      {:ok, "Agent #{agent.agent_id} (#{agent.role}, status: #{agent.status}):\n\n#{formatted}"}
    end)
  end

  defp format_tape_entry(entry) when is_map(entry) do
    role = entry_field(entry, [:role, :kind], "unknown")
    content = entry_field(entry, [:content, :payload], nil)
    format_tape_content(role, content)
  end

  defp format_tape_entry(_), do: nil

  defp entry_field(entry, keys, default) do
    Enum.find_value(keys, default, fn key ->
      entry[key] || entry[Atom.to_string(key)]
    end)
  end

  defp format_tape_content(_role, nil), do: nil

  defp format_tape_content(role, c) when is_binary(c) and byte_size(c) > 1000 do
    "[#{role}] #{String.slice(c, 0, 1000)}... [truncated]"
  end

  defp format_tape_content(role, c) when is_binary(c), do: "[#{role}] #{c}"
  defp format_tape_content(role, c), do: "[#{role}] #{inspect(c)}"

  # --- Stop agent implementation ---

  defp execute_stop_agent(args, session_id) do
    with_validated_agent(args, session_id, fn agent ->
      pid = Worker.whereis(agent.agent_id)

      if pid do
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end

      {:ok, "Stopped agent #{agent.agent_id}"}
    end)
  end

  # --- Send message implementation ---

  defp execute_send_message(args, session_id, self_agent_id) do
    target = arg(args, :target)
    message = arg(args, :message)

    if target && message do
      # Resolve target — could be agent_id or role
      target_pid = resolve_target(target, session_id)

      if target_pid do
        Worker.deliver_signal(target_pid, %{
          type: "rho.message.sent",
          data: %{message: message, from: self_agent_id}
        })

        # Publish observable event for signal timeline
        msg_data = %{
          session_id: session_id,
          agent_id: self_agent_id,
          from: self_agent_id,
          to: target,
          message: message
        }

        Rho.Events.broadcast(
          session_id,
          Rho.Events.event(:message_sent, session_id, self_agent_id, msg_data)
        )

        {:ok, "Message sent to #{target}"}
      else
        {:error, "unknown agent or role: #{target}"}
      end
    else
      {:error, "target and message parameters are required"}
    end
  end

  # --- Broadcast message implementation ---

  defp execute_broadcast_message(args, session_id, self_agent_id) do
    message = arg(args, :message)

    if message do
      targets = Registry.list_except(session_id, self_agent_id)

      Enum.each(targets, fn agent ->
        signal = %{type: "rho.message.sent", data: %{message: message, from: self_agent_id}}
        Worker.deliver_signal(agent.pid, signal)
      end)

      # Publish observable event for signal timeline
      bcast_data = %{
        session_id: session_id,
        agent_id: self_agent_id,
        from: self_agent_id,
        message: message,
        target_count: length(targets)
      }

      Rho.Events.broadcast(
        session_id,
        Rho.Events.event(:broadcast, session_id, self_agent_id, bcast_data)
      )

      {:ok, "Broadcast sent to #{length(targets)} agents"}
    else
      {:error, "message parameter is required"}
    end
  end

  # --- List agents implementation ---

  defp execute_list_agents(session_id) do
    agents = Registry.list(session_id)

    if agents == [] do
      {:ok, "No other agents active in this session."}
    else
      lines = Enum.map(agents, &format_agent_line/1)

      {:ok, "Active agents:\n#{Enum.join(lines, "\n")}"}
    end
  end

  defp format_agent_line(agent) do
    status_str = to_string(agent.status)
    role_str = to_string(agent.role)
    desc = agent[:description]
    skills = agent[:skills] || []

    card_line = "- #{agent.agent_id} (#{role_str}, #{status_str}, depth: #{agent.depth})"
    card_line = if desc, do: card_line <> "\n  #{desc}", else: card_line

    if skills != [],
      do: card_line <> "\n  skills: #{Enum.join(skills, ", ")}",
      else: card_line
  end

  # --- Get agent card implementation ---

  defp execute_get_agent_card(args, session_id) do
    target = arg(args, :target)

    if target do
      agent = resolve_agent_entry(target, session_id)

      if agent do
        format_agent_card(agent)
      else
        {:error, "unknown agent or role: #{target}"}
      end
    else
      {:error, "target parameter is required"}
    end
  end

  defp format_agent_card(agent) do
    desc = agent[:description] || "(no description set)"
    skills = agent[:skills] || []
    skills_str = if skills != [], do: Enum.join(skills, ", "), else: "(none)"

    card = """
    Agent: #{agent.agent_id}
    Role: #{agent.role}
    Status: #{agent.status}
    Depth: #{agent.depth}
    Description: #{desc}
    Skills: #{skills_str}
    Parent: #{Rho.Agent.Primary.parent_of(agent.agent_id) || "(none)"}
    """

    {:ok, String.trim(card)}
  end

  # --- Tool filtering ---

  defp filter_tools(tools, mount_opts) do
    only = Keyword.get(mount_opts, :only)
    except = Keyword.get(mount_opts, :except)

    cond do
      is_list(only) ->
        allowed = MapSet.new(only, &to_string/1)
        Enum.filter(tools, fn %{tool: t} -> MapSet.member?(allowed, t.name) end)

      is_list(except) ->
        blocked = MapSet.new(except, &to_string/1)
        Enum.reject(tools, fn %{tool: t} -> MapSet.member?(blocked, t.name) end)

      true ->
        tools
    end
  end

  # --- Shared child agent setup ---

  defp prepare_child_agent(role_str, params) do
    session_id = params.session_id
    agent_count = Registry.count(session_id)

    if agent_count >= @max_agents_per_session do
      {:error, "agent limit reached (#{@max_agents_per_session} per session)."}
    else
      with {:ok, role_atom} <- resolve_role(role_str) do
        prepare_child_agent_resolved(role_atom, agent_count, params)
      end
    end
  end

  defp prepare_child_agent_resolved(role_atom, _agent_count, params) do
    session_id = params.session_id
    agent_name = if role_atom in Rho.Config.agent_names(), do: role_atom, else: :default
    config = Rho.Config.agent_config(agent_name)
    child_depth = params.parent_depth + 1
    agent_id = Rho.Agent.Primary.new_agent_id(params.parent_agent_id)
    memory_mod = params.tape_module

    tape_name =
      with true <- params[:inherit_context],
           true <- function_exported?(memory_mod, :fork, 2),
           %{tape_ref: ref} when is_binary(ref) <-
             Registry.get(Rho.Agent.Primary.agent_id(session_id)),
           {:ok, fork_ref} <- memory_mod.fork(ref, []) do
        fork_ref
      else
        _ ->
          memory_mod.bootstrap(agent_id)
          agent_id
      end

    tool_context = %{
      tape_name: tape_name,
      workspace: params.workspace,
      tape_module: memory_mod,
      agent_name: agent_name,
      agent_id: agent_id,
      session_id: session_id,
      depth: child_depth,
      sandbox: nil,
      user_id: params[:user_id],
      organization_id: params[:organization_id]
    }

    mount_tools = Rho.PluginRegistry.collect_tools(tool_context)
    all_tools = ensure_finish_tool(mount_tools)

    {:ok,
     %{
       agent_id: agent_id,
       agent_name: agent_name,
       role_atom: role_atom,
       config: config,
       child_depth: child_depth,
       tape_name: tape_name,
       tools: all_tools
     }}
  end

  # --- Helpers ---

  defp arg(args, key) when is_atom(key) do
    args[key] || args[Atom.to_string(key)]
  end

  defp with_validated_agent(args, session_id, fun) do
    agent_id = arg(args, :agent_id)

    if agent_id do
      agent = Registry.get(agent_id)

      cond do
        agent == nil ->
          {:error, "unknown agent: #{agent_id}"}

        agent.session_id != session_id ->
          {:error, "agent #{agent_id} is not in this session"}

        true ->
          fun.(agent)
      end
    else
      {:error, "agent_id parameter is required"}
    end
  end

  defp resolve_agent_entry(target, session_id) do
    case Registry.get(target) do
      nil ->
        role =
          try do
            String.to_existing_atom(target)
          rescue
            ArgumentError -> :worker
          end

        case Registry.find_by_role(session_id, role) do
          [agent | _] -> agent
          [] -> nil
        end

      entry ->
        entry
    end
  end

  defp resolve_target(target, session_id) do
    case resolve_agent_entry(target, session_id) do
      %{pid: pid} -> pid
      nil -> nil
    end
  end

  defp delegate_system_prompt(task, context_summary, depth, max_depth, base_prompt) do
    can_delegate = depth < max_depth

    context_line =
      if context_summary,
        do: "\nContext: #{context_summary}\n",
        else: ""

    """
    #{base_prompt}

    You are a delegated agent (depth #{depth}/#{max_depth}). You cannot interact with the user directly.
    Make reasonable assumptions instead of asking clarifying questions.
    Call the `finish` tool with your final result when your task is complete.
    #{context_line}
    #{if can_delegate do
      "You may delegate subtasks to other agents using delegate_task."
    else
      "You are at max depth. Do all work directly — do not attempt to delegate."
    end}

    Your task:
    #{task}
    """
  end
end
