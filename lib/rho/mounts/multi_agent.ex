defmodule Rho.Mounts.MultiAgent do
  @moduledoc """
  Mount providing multi-agent coordination tools.

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

  @behaviour Rho.Mount

  alias Rho.Agent.{Worker, Registry, Supervisor}
  alias Rho.Comms

  @max_depth 3
  @max_agents_per_session 10
  @default_max_steps 30
  @await_timeout 300_000
  @known_roles_cache Rho.Config.agent_names() |> Enum.map(&Atom.to_string/1)

  # --- Mount callbacks ---

  @impl Rho.Mount
  def tools(mount_opts, %{depth: depth} = ctx) when depth < @max_depth do
    session_id = ctx[:session_id] || ctx[:tape_name]
    agent_id = ctx[:agent_id]
    workspace = ctx[:workspace]
    memory_mod = ctx[:memory_mod] || Rho.Memory.Tape
    parent_emit = get_in(ctx, [:opts, :emit])

    [
      delegate_task_tool(session_id, agent_id, workspace, depth, memory_mod, parent_emit),
      await_task_tool(session_id),
      spawn_agent_tool(session_id, agent_id, workspace, depth, memory_mod, parent_emit),
      collect_results_tool(session_id),
      stop_agent_tool(session_id),
      send_message_tool(session_id, agent_id),
      broadcast_message_tool(session_id, agent_id),
      list_agents_tool(session_id),
      get_agent_card_tool(session_id),
      Rho.Tools.Finish.tool_def()
    ]
    |> filter_tools(mount_opts)
  end

  def tools(mount_opts, %{depth: depth} = ctx) when depth >= @max_depth do
    session_id = ctx[:session_id] || ctx[:tape_name]
    # At max depth, only provide discovery (no delegation)
    [list_agents_tool(session_id), get_agent_card_tool(session_id)]
    |> filter_tools(mount_opts)
  end

  def tools(_mount_opts, _context), do: []

  # --- Tool definitions ---

  defp delegate_task_tool(
         session_id,
         parent_agent_id,
         workspace,
         parent_depth,
         memory_mod,
         parent_emit
       ) do
    %{
      tool:
        ReqLLM.tool(
          name: "delegate_task",
          description:
            "Spawn a new agent to handle a subtask. Returns a task_id and agent_id immediately. " <>
              "Use await_task to get the result later. The new agent runs in parallel with full tool access.",
          parameter_schema: [
            task: [type: :string, required: true, doc: "The task prompt for the delegated agent"],
            role: [
              type: :string,
              doc:
                "Role for the agent (e.g., 'researcher', 'coder'). Uses role-specific config if available."
            ],
            context_summary: [type: :string, doc: "Brief context about why this task is needed"],
            inherit_context: [
              type: :boolean,
              doc:
                "If true, fork the parent tape so the child sees conversation history (default: false)"
            ],
            max_steps: [
              type: :integer,
              doc: "Max steps for the agent (default: #{@default_max_steps})"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        execute_delegate(
          args,
          session_id,
          parent_agent_id,
          workspace,
          parent_depth,
          memory_mod,
          parent_emit
        )
      end
    }
  end

  defp await_task_tool(session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "await_task",
          description:
            "Wait for a delegated agent to complete and return its result. " <>
              "Blocks until the agent finishes or times out (5 min default).",
          parameter_schema: [
            agent_id: [
              type: :string,
              required: true,
              doc: "The agent_id returned by delegate_task"
            ],
            timeout: [type: :integer, doc: "Timeout in seconds (default: 300)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        execute_await(args, session_id)
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
      execute: fn args ->
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
      execute: fn args ->
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
      execute: fn _args ->
        execute_list_agents(session_id)
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
      execute: fn args ->
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
         parent_emit
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
      execute: fn args ->
        execute_spawn(
          args,
          session_id,
          parent_agent_id,
          workspace,
          parent_depth,
          memory_mod,
          parent_emit
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
      execute: fn args ->
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
      execute: fn args ->
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
         parent_emit
       ) do
    task_prompt = arg(args, :task)
    role_str = arg(args, :role) || "worker"
    context_summary = arg(args, :context_summary)
    inherit_context = arg(args, :inherit_context) || false
    max_steps = arg(args, :max_steps) || @default_max_steps

    unless task_prompt do
      {:error, "task parameter is required"}
    else
      role_atom =
        if role_str in @known_roles_cache, do: String.to_existing_atom(role_str), else: :worker

      do_delegate(task_prompt, %{
        session_id: session_id,
        parent_agent_id: parent_agent_id,
        workspace: workspace,
        parent_depth: parent_depth,
        memory_mod: memory_mod,
        parent_emit: parent_emit,
        role: role_atom,
        context_summary: context_summary,
        inherit_context: inherit_context,
        max_steps: max_steps
      })
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
             memory_mod: params.memory_mod,
             max_steps: params.max_steps,
             inherit_context: params.inherit_context
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
          depth: prepared.child_depth,
          parent_agent_id: params.parent_agent_id,
          memory_ref: prepared.tape_name,
          initial_task: task_prompt,
          task_id: task_id,
          max_steps: params.max_steps,
          system_prompt: system_prompt,
          tools: prepared.tools,
          model: config.model
        )

      Comms.publish(
        "rho.task.requested",
        %{
          task_id: task_id,
          session_id: params.session_id,
          from_agent: params.parent_agent_id,
          to_agent: prepared.agent_id,
          task: task_prompt,
          context_summary: params.context_summary,
          max_steps: params.max_steps
        }, source: "/session/#{params.session_id}/agent/#{params.parent_agent_id}")

      {:ok,
       "Delegated #{task_id} to #{prepared.agent_id} (role: #{params.role}). Use await_task(agent_id: \"#{prepared.agent_id}\") to get the result."}
    end
  end

  # --- Await implementation ---

  defp execute_await(args, _session_id) do
    agent_id = arg(args, :agent_id)
    timeout_secs = arg(args, :timeout) || 300
    timeout_ms = min(timeout_secs * 1000, @await_timeout)

    unless agent_id do
      {:error, "agent_id parameter is required"}
    else
      pid = Worker.whereis(agent_id)

      unless pid do
        {:error, "unknown agent: #{agent_id}"}
      else
        try do
          case Worker.collect(pid, timeout_ms) do
            {:ok, text} ->
              # Stop the delegated worker
              try do
                GenServer.stop(pid, :normal, 5_000)
              catch
                :exit, _ -> :ok
              end

              {:ok, text}

            {:error, reason} ->
              {:error, "agent #{agent_id} failed: #{inspect(reason)}"}
          end
        catch
          :exit, {:timeout, _} ->
            {:error,
             "agent #{agent_id} timed out after #{timeout_secs}s (still running in background)"}

          :exit, reason ->
            {:error, "agent #{agent_id} exited: #{inspect(reason)}"}
        end
      end
    end
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
         _parent_emit
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
             memory_mod: memory_mod,
             max_steps: max_steps
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
          depth: prepared.child_depth,
          parent_agent_id: parent_agent_id,
          memory_ref: prepared.tape_name,
          max_steps: max_steps,
          system_prompt: spawn_prompt,
          tools: prepared.tools,
          model: config.model
        )

      Comms.publish(
        "rho.agent.spawned",
        %{
          session_id: session_id,
          agent_id: prepared.agent_id,
          role: role_str,
          spawned_by: parent_agent_id
        }, source: "/session/#{session_id}/agent/#{parent_agent_id}")

      {:ok,
       "Spawned #{prepared.agent_id} (role: #{role_str}). Agent is idle and ready for messages. Use send_message(target: \"#{prepared.agent_id}\", message: \"...\") to start a conversation."}
    end
  end

  # --- Collect results implementation ---

  defp execute_collect_results(args, session_id) do
    limit = arg(args, :limit) || 20

    with_validated_agent(args, session_id, fn agent ->
      memory_mod = Rho.Config.memory_module()
      history = memory_mod.history(agent.memory_ref)
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
    role = entry[:role] || entry["role"] || entry[:kind] || entry["kind"] || "unknown"
    content = entry[:content] || entry["content"] || entry[:payload] || entry["payload"]

    case content do
      nil ->
        nil

      c when is_binary(c) and byte_size(c) > 1000 ->
        "[#{role}] #{String.slice(c, 0, 1000)}... [truncated]"

      c when is_binary(c) ->
        "[#{role}] #{c}"

      c ->
        "[#{role}] #{inspect(c)}"
    end
  end

  defp format_tape_entry(_), do: nil

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

    unless target && message do
      {:error, "target and message parameters are required"}
    else
      # Resolve target — could be agent_id or role
      target_pid = resolve_target(target, session_id)

      unless target_pid do
        {:error, "unknown agent or role: #{target}"}
      else
        Worker.deliver_signal(target_pid, %{
          type: "rho.message.sent",
          data: %{message: message, from: self_agent_id}
        })

        # Publish observable event for signal timeline
        Comms.publish(
          "rho.session.#{session_id}.events.message_sent",
          %{
            from: self_agent_id,
            to: target,
            message: message
          }, source: "/session/#{session_id}/agent/#{self_agent_id}")

        {:ok, "Message sent to #{target}"}
      end
    end
  end

  # --- Broadcast message implementation ---

  defp execute_broadcast_message(args, session_id, self_agent_id) do
    message = arg(args, :message)

    unless message do
      {:error, "message parameter is required"}
    else
      targets = Registry.list_except(session_id, self_agent_id)

      for agent <- targets do
        signal = %{type: "rho.message.sent", data: %{message: message, from: self_agent_id}}
        Worker.deliver_signal(agent.pid, signal)
      end

      # Publish observable event for signal timeline
      Comms.publish(
        "rho.session.#{session_id}.events.broadcast",
        %{
          from: self_agent_id,
          message: message,
          target_count: length(targets)
        }, source: "/session/#{session_id}/agent/#{self_agent_id}")

      {:ok, "Broadcast sent to #{length(targets)} agents"}
    end
  end

  # --- List agents implementation ---

  defp execute_list_agents(session_id) do
    agents = Registry.list(session_id)

    if agents == [] do
      {:ok, "No other agents active in this session."}
    else
      lines =
        Enum.map(agents, fn agent ->
          status_str = to_string(agent.status)
          role_str = to_string(agent.role)
          desc = agent[:description]
          skills = agent[:skills] || []

          card_line = "- #{agent.agent_id} (#{role_str}, #{status_str}, depth: #{agent.depth})"
          card_line = if desc, do: card_line <> "\n  #{desc}", else: card_line

          card_line =
            if skills != [],
              do: card_line <> "\n  skills: #{Enum.join(skills, ", ")}",
              else: card_line

          card_line
        end)

      {:ok, "Active agents:\n#{Enum.join(lines, "\n")}"}
    end
  end

  # --- Get agent card implementation ---

  defp execute_get_agent_card(args, session_id) do
    target = arg(args, :target)

    unless target do
      {:error, "target parameter is required"}
    else
      agent = resolve_agent_entry(target, session_id)

      unless agent do
        {:error, "unknown agent or role: #{target}"}
      else
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
        Parent: #{agent[:parent_agent_id] || "(none)"}
        """

        {:ok, String.trim(card)}
      end
    end
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
      role_atom =
        if role_str in @known_roles_cache, do: String.to_existing_atom(role_str), else: :worker

      agent_name = if role_atom in Rho.Config.agent_names(), do: role_atom, else: :default
      config = Rho.Config.agent(agent_name)
      child_depth = params.parent_depth + 1
      agent_id = Rho.Session.new_agent_id()
      memory_mod = params.memory_mod

      tape_name =
        if params[:inherit_context] && function_exported?(memory_mod, :fork, 2) do
          parent_tape = "primary_#{session_id}"

          case memory_mod.fork(parent_tape, []) do
            {:ok, fork_ref} ->
              fork_ref

            {:error, _} ->
              fresh = "agent_#{agent_id}"
              memory_mod.bootstrap(fresh)
              fresh
          end
        else
          fresh = "agent_#{agent_id}"
          memory_mod.bootstrap(fresh)
          fresh
        end

      tool_context = %{
        tape_name: tape_name,
        workspace: params.workspace,
        memory_mod: memory_mod,
        agent_name: agent_name,
        agent_id: agent_id,
        session_id: session_id,
        depth: child_depth,
        sandbox: nil
      }

      mount_tools = Rho.MountRegistry.collect_tools(tool_context)
      all_tools = mount_tools ++ [Rho.Tools.Finish.tool_def()]

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
  end

  # --- Helpers ---

  defp arg(args, key) when is_atom(key) do
    args[Atom.to_string(key)] || args[key]
  end

  defp with_validated_agent(args, session_id, fun) do
    agent_id = arg(args, :agent_id)

    unless agent_id do
      {:error, "agent_id parameter is required"}
    else
      agent = Registry.get(agent_id)

      cond do
        agent == nil ->
          {:error, "unknown agent: #{agent_id}"}

        agent.session_id != session_id ->
          {:error, "agent #{agent_id} is not in this session"}

        true ->
          fun.(agent)
      end
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
