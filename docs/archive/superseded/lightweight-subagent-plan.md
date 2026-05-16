# Lightweight Subagent Plan

## Problem

Spawning subagents for proficiency generation has massive overhead per agent:

| Layer | What happens | Cost |
|-------|-------------|------|
| `prepare_child_agent` | ETS scan all plugins, invoke `tools/2` + `prompt_sections/2` per plugin | ~ms CPU, allocations |
| `Supervisor.start_worker` | Start GenServer, register in AgentRegistry, publish `agent.started` signal | Process + ETS + signal |
| `Worker.init` | Bootstrap tape, build capabilities list, sandbox check | Tape ETS setup |
| `Worker.start_turn` | Build emit closure, re-resolve config, spawn Task | Closure + process |
| `Runner.build_runtime` | Re-collect plugin prompt sections, build system prompt, construct Runtime struct | String concat + ETS scan |
| `Runner.do_loop` per step | Compaction check, `prompt_out` transformer stage, `response_in` stage, `tool_args_out` stage, `tool_result_in` stage, `post_step` stage | 5 ETS scans per step |
| Signal bus | ~8 events per turn (start, step_start, before_llm, llm_usage, tool_start, tool_result, turn_finished, task.completed) | 8 signal publishes |

For 20 subagents generating proficiency levels, that's 20x all of the above — but each subagent just needs: system prompt + task -> 1 LLM call -> call `add_proficiency_levels` -> done.

## Design: Two-tier subagent system

Keep the existing `delegate_task` for complex multi-turn agents. Add `delegate_task_lite` for single-purpose generation tasks.

### What "lite" means — skip list

| Skip | Why safe |
|------|----------|
| Worker GenServer | No need for mailbox, queue, status tracking, signal delivery |
| AgentRegistry registration | No inter-agent messaging needed |
| Tape bootstrap + recording | Single-shot, no history needed |
| Transformer pipeline (all 6 stages) | No policy/mutation needed for generation tasks |
| Plugin prompt section collection | System prompt passed directly |
| Compaction check | No tape = no compaction |
| Most signal bus events | Parent only needs the final result |
| `subagent_nudge` re-prompting | Give tools directly, LLM will use them |

### What "lite" keeps

| Keep | Why |
|------|-----|
| Clean context window | The whole point — fresh messages per subagent |
| LLM streaming with retry | Need the actual generation |
| Tool execution | Subagent needs `add_proficiency_levels` (or `finish`) |
| Task.Supervisor | OTP supervision for crash recovery |
| Single `task.completed` signal | Parent needs to know when done |

## Implementation

### 1. `delegate_task_lite` tool in MultiAgent

New tool alongside `delegate_task`:

```elixir
defp delegate_task_lite_tool(session_id, parent_agent_id, workspace, parent_depth, parent_emit, identity) do
  %{
    tool: ReqLLM.tool(
      name: "delegate_task_lite",
      description: """
      Spawn a lightweight agent for a single-purpose task (e.g., generating data).
      Much faster than delegate_task — no persistent state, no multi-turn reasoning.
      The agent gets a clean context window, makes 1-2 LLM calls, returns the result.
      Use await_task to get the result (same as delegate_task).
      """,
      parameter_schema: [
        task: [type: :string, required: true, doc: "The task prompt"],
        role: [type: :string, doc: "Role for config lookup (model, system_prompt)"],
        tools: [type: :string, doc: "JSON array of tool names to include (default: all from role config)"],
        max_steps: [type: :integer, doc: "Max LLM calls (default: 3)"]
      ]
    ),
    execute: fn args -> ... end
  }
end
```

### 2. `Rho.Agent.LiteWorker` — bare Task, no GenServer

```elixir
defmodule Rho.Agent.LiteWorker do
  @moduledoc """
  Lightweight single-shot agent. Runs as a plain Task (no GenServer).
  Clean context window, minimal overhead, 1-3 LLM steps max.
  """

  require Logger

  @default_max_steps 3

  defstruct [:agent_id, :model, :system_prompt, :tools, :tool_map, :req_tools,
             :gen_opts, :max_steps, :emit]

  @doc """
  Start a lite worker under TaskSupervisor. Returns {agent_id, task_ref, task_pid}.
  The caller can use Worker.collect-style waiting via the agent_id.
  """
  def start(opts) do
    agent_id = opts[:agent_id] || generate_id(opts[:parent_agent_id])
    task_prompt = Keyword.fetch!(opts, :task)
    role = opts[:role] || :worker
    max_steps = opts[:max_steps] || @default_max_steps

    config = Rho.Config.agent_config(role)
    model = config.model
    gen_opts = build_gen_opts(config[:provider])

    # Only resolve tools once, for the specific tools needed
    tools = opts[:tools] || resolve_minimal_tools(opts)
    req_tools = Enum.map(tools, & &1.tool)
    tool_map = Map.new(tools, fn t -> {t.tool.name, t} end)

    system_prompt = build_lite_prompt(config.system_prompt, task_prompt)

    state = %__MODULE__{
      agent_id: agent_id,
      model: model,
      system_prompt: system_prompt,
      tools: tools,
      tool_map: tool_map,
      req_tools: req_tools,
      gen_opts: gen_opts,
      max_steps: max_steps,
      emit: opts[:emit] || fn _ -> :ok end
    }

    task = Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
      run(state, task_prompt)
    end)

    {agent_id, task.ref, task.pid}
  end

  @doc """
  Minimal agent loop: system + user prompt -> LLM -> tool call -> done.
  No tape, no transformers, no compaction, no signal bus noise.
  """
  def run(state, task_prompt) do
    messages = [
      ReqLLM.Context.system(state.system_prompt),
      ReqLLM.Context.user(task_prompt)
    ]

    do_step(messages, state, 1)
  end

  defp do_step(_messages, _state, step) when step > state.max_steps do
    {:error, "lite agent exceeded max steps"}
  end

  defp do_step(messages, state, step) do
    stream_opts = Keyword.merge([tools: state.req_tools], state.gen_opts)

    case ReqLLM.stream_text(state.model, messages, stream_opts) do
      {:ok, stream} ->
        case ReqLLM.StreamResponse.process_stream(stream, []) do
          {:ok, response} ->
            handle_response(response, messages, state, step)
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_response(response, messages, state, step) do
    tool_calls = ReqLLM.Response.tool_calls(response)
    text = ReqLLM.Response.text(response)

    case tool_calls do
      [] ->
        # No tool calls = done (text response)
        {:ok, text}

      calls ->
        # Execute tools, check for terminal
        {tool_results, final} = execute_tools(calls, state)

        if final do
          {:ok, final}
        else
          # Continue with tool results appended
          assistant_msg = ReqLLM.Context.assistant("", tool_calls: calls)
          next_messages = messages ++ [assistant_msg | tool_results]
          do_step(next_messages, state, step + 1)
        end
    end
  end

  defp execute_tools(tool_calls, state) do
    results = Enum.map(tool_calls, fn tc ->
      name = ReqLLM.ToolCall.name(tc)
      args = ReqLLM.ToolCall.args_map(tc) || %{}
      call_id = tc.id
      tool_def = Map.get(state.tool_map, name)

      result = if tool_def, do: tool_def.execute.(args), else: {:error, "unknown tool: #{name}"}

      case result do
        {:final, output} ->
          {ReqLLM.Context.tool_result(call_id, to_string(output)), to_string(output)}
        {:ok, output} ->
          {ReqLLM.Context.tool_result(call_id, to_string(output)), nil}
        {:error, reason} ->
          {ReqLLM.Context.tool_result(call_id, "Error: #{reason}"), nil}
      end
    end)

    {tool_msgs, finals} = Enum.unzip(results)
    {tool_msgs, Enum.find(finals, & &1)}
  end

  defp build_lite_prompt(base_prompt, _task) do
    """
    #{base_prompt}

    You are a focused worker agent. Complete the given task efficiently.
    Call the appropriate tool with your result. Do not ask clarifying questions.
    """
  end

  # ... helpers for generate_id, build_gen_opts, resolve_minimal_tools
end
```

### 3. Tracking lite workers for `await_task`

The existing `await_task` uses `Worker.whereis` (Registry lookup) + `Worker.collect` (GenServer.call). Lite workers aren't GenServers.

**Option A: ETS-based tracking (recommended)**

Store `{agent_id, task_ref, task_pid, status, result}` in a simple ETS table. `await_task` checks this table first, falls back to Worker registry.

```elixir
# In MultiAgent, maintain a lightweight tracker
defmodule Rho.Agent.LiteTracker do
  @table :rho_lite_tasks

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  end

  def register(agent_id, task_ref, task_pid) do
    :ets.insert(@table, {agent_id, task_ref, task_pid, :running, nil})
  end

  def complete(agent_id, result) do
    :ets.update_element(@table, agent_id, [{4, :done}, {5, result}])
  end

  def lookup(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{_, _ref, _pid, status, result}] -> {status, result}
      [] -> nil
    end
  end
end
```

**Option B**: Register lite workers in the existing AgentRegistry with a `:lite` flag. Simpler but muddies the registry.

Recommend Option A — separate concerns.

### 4. `await_all` tool

Regardless of lite vs full agents, this cuts parent LLM round-trips from N awaits to 1:

```elixir
defp await_all_tool(session_id) do
  %{
    tool: ReqLLM.tool(
      name: "await_all",
      description: "Wait for multiple delegated agents to complete. Returns all results as a JSON object keyed by agent_id.",
      parameter_schema: [
        agent_ids: [type: :string, required: true, doc: "JSON array of agent_id strings"]
      ]
    ),
    execute: fn args ->
      ids = Jason.decode!(args["agent_ids"] || "[]")

      tasks = Enum.map(ids, fn id ->
        Task.async(fn ->
          result = do_await_single(id, session_id, 300_000)
          {id, result}
        end)
      end)

      results = Task.await_many(tasks, 300_000)
      summary = Map.new(results, fn {id, result} ->
        case result do
          {:ok, text} -> {id, %{status: "ok", result: text}}
          {:error, reason} -> {id, %{status: "error", reason: reason}}
        end
      end)

      {:ok, Jason.encode!(summary)}
    end
  }
end
```

## Overhead comparison

| | Full delegate_task | delegate_task_lite |
|---|---|---|
| Process type | GenServer + Task | Task only |
| Registry entries | AgentRegistry + Elixir Registry | ETS entry only |
| Tape | Bootstrap + record + compact | None |
| Transformer stages per step | 5 (prompt_out, response_in, tool_args_out, tool_result_in, post_step) | 0 |
| Plugin resolution | collect_tools + collect_prompt_material | Passed directly |
| Signal bus events | ~8 per turn | 0-1 (completion only) |
| System prompt assembly | Plugin sections + strategy sections + render | String concat |
| Compaction | Check every step | None |
| Streaming callbacks | emit closure with metadata updates | None (or minimal) |
| Estimated overhead per agent | ~50-100ms setup + ongoing | ~5ms setup |

## Migration path

1. Add `Rho.Agent.LiteWorker` module
2. Add `Rho.Agent.LiteTracker` ETS table
3. Add `delegate_task_lite` and `await_all` tools to MultiAgent
4. Update `await_task` to check LiteTracker before Worker registry
5. Update spreadsheet proficiency generation prompt to use `delegate_task_lite`

No changes to existing `delegate_task` — this is purely additive.

## Open questions

- Should lite workers get streaming text deltas published? (Probably no — parent doesn't display them)
- Should lite workers share the parent's `emit` for progress tracking? (Optional, adds minor overhead)
- Tool filtering: should `delegate_task_lite` accept a list of tool names and resolve only those? (Yes — avoids resolving bash/fs tools when only spreadsheet tools are needed)
