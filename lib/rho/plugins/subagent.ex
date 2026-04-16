defmodule Rho.Plugins.Subagent do
  @moduledoc """
  Plugin that allows an agent to spawn child agents with separate context windows,
  run them asynchronously, and collect their results.
  """

  @behaviour Rho.Mount

  alias Rho.Plugins.Subagent.{Worker, Supervisor}

  @max_depth 3
  @max_concurrent 5
  @collect_timeout 600_000
  @default_max_steps 30

  # --- Mount callbacks ---

  @impl Rho.Mount
  def tools(_mount_opts, %{tape_name: tape_name, workspace: workspace} = ctx) do
    memory_mod = ctx[:memory_mod] || Rho.Memory.Tape
    depth = ctx[:depth] || 0
    session_id = ctx[:session_id]
    parent_agent_id = ctx[:agent_id]
    parent_emit = get_in(ctx, [:opts, :emit])

    if depth >= @max_depth,
      do: [],
      else: [
        spawn_tool(
          tape_name,
          workspace,
          depth,
          memory_mod,
          parent_emit,
          session_id,
          parent_agent_id
        ),
        collect_tool(memory_mod)
      ]
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Mount
  def after_tool(%{name: _name} = _call, result, _mount_opts, %{tape_name: tape_name})
      when is_binary(tape_name) do
    case check_completed(tape_name) do
      [] ->
        {:ok, result}

      done ->
        notice =
          Enum.map_join(done, "\n", fn {id, r} ->
            "[subagent #{id} finished: #{String.slice(to_string(r), 0..300)}]"
          end)

        {:replace, result <> "\n\n" <> notice}
    end
  end

  def after_tool(_call, result, _mount_opts, _context), do: {:ok, result}

  # --- Tool definitions ---

  defp spawn_tool(
         parent_tape,
         workspace,
         parent_depth,
         memory_mod,
         parent_emit,
         session_id,
         parent_agent_id
       ) do
    %{
      tool:
        ReqLLM.tool(
          name: "spawn_subagent",
          description:
            "Spawn a child agent with its own context window to work on a subtask in parallel. " <>
              "Returns a subagent_id immediately. Use collect_subagent to get the result later.",
          parameter_schema: [
            task: [type: :string, required: true, doc: "The task prompt for the subagent"],
            tools: [
              type: {:list, :string},
              doc:
                "Tool names for the subagent (default: bash, fs_read, fs_write, fs_edit). Use fewer tools for faster startup."
            ],
            inherit_context: [
              type: :boolean,
              doc:
                "If true, fork the parent tape so the child sees conversation history (default: false). Adds startup overhead."
            ],
            max_steps: [
              type: :integer,
              doc: "Max steps for the subagent (default: #{@default_max_steps})"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        execute_spawn(
          args,
          parent_tape,
          workspace,
          parent_depth,
          memory_mod,
          parent_emit,
          session_id,
          parent_agent_id
        )
      end
    }
  end

  defp collect_tool(memory_mod) do
    %{
      tool:
        ReqLLM.tool(
          name: "collect_subagent",
          description:
            "Wait for a subagent to complete and return its result. " <>
              "Blocks until the subagent finishes or times out (10 min).",
          parameter_schema: [
            subagent_id: [
              type: :string,
              required: true,
              doc: "The subagent_id returned by spawn_subagent"
            ],
            merge: [
              type: :boolean,
              doc: "If true, merge the subagent's tape entries back to parent (default: false)"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        execute_collect(args, memory_mod)
      end
    }
  end

  # --- Spawn implementation ---

  defp execute_spawn(
         args,
         parent_tape,
         workspace,
         parent_depth,
         memory_mod,
         parent_emit,
         session_id,
         parent_agent_id
       ) do
    task_prompt = args["task"] || args[:task]
    max_steps = args["max_steps"] || args[:max_steps] || @default_max_steps
    inherit_context = args["inherit_context"] || args[:inherit_context] || false
    requested_tools = args["tools"] || args[:tools]

    unless task_prompt do
      {:error, "task parameter is required"}
    else
      active_count = length(Worker.active_children_of(parent_tape))

      if active_count >= @max_concurrent do
        {:error,
         "concurrency limit reached (#{@max_concurrent} active subagents). Collect some before spawning more."}
      else
        do_spawn(task_prompt, max_steps, parent_tape, workspace, parent_depth,
          inherit_context: inherit_context,
          memory_mod: memory_mod,
          parent_emit: parent_emit,
          session_id: session_id,
          requested_tools: requested_tools,
          parent_agent_id: parent_agent_id
        )
      end
    end
  end

  defp do_spawn(task_prompt, max_steps, parent_tape, workspace, parent_depth, opts) do
    child_depth = parent_depth + 1
    subagent_id = "sub_#{:erlang.unique_integer([:positive])}"
    inherit_context = opts[:inherit_context] || false
    memory_mod = opts[:memory_mod] || Rho.Memory.Tape
    parent_emit = opts[:parent_emit]

    # Memory strategy
    tape_name =
      if inherit_context && function_exported?(memory_mod, :fork, 2) do
        {:ok, fork_ref} = memory_mod.fork(parent_tape, [])
        fork_ref
      else
        fresh_tape = "subagent_#{subagent_id}"
        memory_mod.bootstrap(fresh_tape)
        fresh_tape
      end

    # Build system prompt
    system_prompt = subagent_system_prompt(task_prompt, child_depth, @max_depth)

    # Resolve tools via MountRegistry for the child's context
    tool_context = %{
      tape_name: tape_name,
      workspace: workspace,
      memory_mod: memory_mod,
      agent_name: :default,
      depth: child_depth,
      sandbox: nil
    }

    requested_tools = opts[:requested_tools]

    mount_tools =
      if is_list(requested_tools) && requested_tools != [] do
        # Resolve requested tool names to mount modules and collect their tools directly
        requested_tool_modules(requested_tools, tool_context)
      else
        Rho.MountRegistry.collect_tools(tool_context)
      end

    finish_tool = Rho.Tools.Finish.tool_def()
    all_tools = mount_tools ++ [finish_tool]

    # Determine model from config
    config = Rho.Config.agent(:default)
    model = config.model

    # Start the worker GenServer under the Subagent.Supervisor
    {:ok, _pid} =
      Supervisor.start_worker(
        subagent_id: subagent_id,
        parent_tape: parent_tape,
        parent_agent_id: opts[:parent_agent_id],
        tape_name: tape_name,
        prompt: task_prompt,
        workspace: workspace,
        depth: child_depth,
        model: model,
        tools: all_tools,
        system_prompt: system_prompt,
        max_steps: max_steps,
        parent_emit: parent_emit,
        session_id: opts[:session_id]
      )

    # Render UI from the parent process
    active = Worker.active_children_of(parent_tape)
    Rho.Plugins.Subagent.UI.initial_render(active)

    {:ok, "Spawned subagent #{subagent_id} for task: #{String.slice(task_prompt, 0..80)}"}
  end

  # --- Collect implementation ---

  defp execute_collect(args, memory_mod) do
    subagent_id = args["subagent_id"] || args[:subagent_id]
    merge? = args["merge"] || args[:merge] || false

    unless subagent_id do
      {:error, "subagent_id parameter is required"}
    else
      pid = Worker.whereis(subagent_id)

      unless pid do
        {:error, "unknown subagent: #{subagent_id}"}
      else
        # Read metadata before collecting (worker stays alive until we stop it)
        info = Worker.status(pid)

        # Block until the worker finishes — deferred GenServer reply if still running
        result = Worker.collect(pid, @collect_timeout)

        # Optionally merge fork tape back to parent
        if merge? and match?({:ok, _}, result) do
          if function_exported?(memory_mod, :merge, 2) do
            memory_mod.merge(info.tape_name, info.parent_tape)
          end
        end

        # Stop the worker (triggers terminate/2 which cleans up descendants)
        GenServer.stop(pid, :normal, 5_000)

        # Render UI from the parent process
        active = Worker.active_children_of(info.parent_tape)

        if active == [] do
          Rho.Plugins.Subagent.UI.clear(0)
        else
          Rho.Plugins.Subagent.UI.render_status(active)
        end

        result
      end
    end
  end

  # --- Tool resolution ---

  defp requested_tool_modules(tool_names, context) do
    Enum.flat_map(tool_names, fn name ->
      try do
        atom_name = if is_binary(name), do: String.to_existing_atom(name), else: name
        {mod, mod_opts} = Rho.Config.resolve_mount(atom_name)
        Code.ensure_loaded!(mod)

        if function_exported?(mod, :tools, 2) do
          mod.tools(mod_opts, context)
        else
          []
        end
      rescue
        _ -> []
      end
    end)
  end

  # --- System prompt ---

  defp subagent_system_prompt(task, depth, max_depth) do
    can_spawn = depth < max_depth

    """
    You are a subagent (depth #{depth}/#{max_depth}). You cannot interact with the user.
    Make reasonable assumptions instead of asking clarifying questions.
    Call the `finish` tool with your final result when your task is complete.

    #{if can_spawn do
      "You may spawn sub-subagents for parallel subtasks."
    else
      "You are at max depth. Do all work directly — do not attempt to spawn subagents."
    end}

    Your task:
    #{task}
    """
  end

  # --- Completion checking ---

  defp check_completed(parent_tape) do
    for {subagent_id, result} <- Worker.completed_children_of(parent_tape) do
      Worker.clear_status(subagent_id)

      case result do
        {:ok, text} -> {subagent_id, text}
        {:error, reason} -> {subagent_id, reason}
      end
    end
  end
end
