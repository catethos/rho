defmodule Rho.Agent.LiteWorker do
  @moduledoc """
  Lightweight single-shot agent. Runs as a plain Task (no GenServer).

  Provides a clean context window with minimal overhead: no tape, no
  transformer pipeline, no signal bus events, no compaction. Just:

      system prompt + task → LLM call → tool execution → result

  Designed for batch-parallel generation tasks (e.g., proficiency levels)
  where each subtask is independent and single-purpose.

  ## Comparison with Worker

  | Aspect           | Worker (full)      | LiteWorker         |
  |-----------------|--------------------|--------------------|
  | Process type    | GenServer + Task   | Task only          |
  | Tape/memory     | Full tape          | None               |
  | Transformers    | 5 stages per step  | None               |
  | Signal bus      | ~8 events/turn     | 0                  |
  | Plugin resolve  | Per-agent          | Tools passed in    |
  | Max steps       | Configurable (50)  | Small (default 3)  |
  """

  require Logger

  alias Rho.Agent.{LiteTracker, Primary}

  @default_max_steps 3
  @max_stream_retries 2
  @terminal_tools MapSet.new(["finish", "end_turn"])

  @doc """
  Start a lite worker under TaskSupervisor.

  Returns `{:ok, agent_id}`.

  ## Options

    * `:task` (required) — the task prompt
    * `:parent_agent_id` (required) — parent for hierarchical id
    * `:system_prompt` — base system prompt (default from role config)
    * `:tools` — list of tool_def maps (required)
    * `:model` — LLM model string (default from role config)
    * `:role` — role atom for config lookup (default `:worker`)
    * `:max_steps` — max LLM round-trips (default 3)
    * `:provider` — provider options for gen_opts
  """
  def start(opts) do
    task_prompt = Keyword.fetch!(opts, :task)
    tools = Keyword.fetch!(opts, :tools)
    parent_agent_id = Keyword.fetch!(opts, :parent_agent_id)

    role = opts[:role] || :default
    config = Rho.Config.agent_config(role)

    model = opts[:model] || config.model
    max_steps = opts[:max_steps] || @default_max_steps
    provider = opts[:provider] || config[:provider]

    agent_id = Primary.new_agent_id(parent_agent_id)

    system_prompt =
      build_system_prompt(
        opts[:system_prompt] || config.system_prompt,
        task_prompt
      )

    req_tools = Enum.map(tools, & &1.tool)
    tool_map = Map.new(tools, fn t -> {t.tool.name, t} end)
    gen_opts = build_gen_opts(provider)

    context = opts[:context] || %Rho.Context{agent_name: role, agent_id: agent_id}

    run_opts = %{
      agent_id: agent_id,
      model: model,
      system_prompt: system_prompt,
      req_tools: req_tools,
      tool_map: tool_map,
      gen_opts: gen_opts,
      max_steps: max_steps,
      context: context
    }

    task =
      Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
        result = run(run_opts, task_prompt)

        LiteTracker.complete(agent_id, result)
        result
      end)

    LiteTracker.register(agent_id, task.ref, task.pid)

    {:ok, agent_id}
  end

  @doc """
  Await a lite worker's result. Blocks until the task completes or times out.

  Returns the task's result (`{:ok, text}` or `{:error, reason}`).
  """
  def await(agent_id, timeout \\ 300_000) do
    case LiteTracker.lookup(agent_id) do
      nil ->
        {:error, "unknown lite agent: #{agent_id}"}

      {:done, result, _pid} ->
        LiteTracker.delete(agent_id)
        result

      {:running, _result, pid} ->
        # Monitor the task process and wait for it to finish
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} ->
            # Task completed — result should be in tracker now
            case LiteTracker.lookup(agent_id) do
              {:done, result, _} ->
                LiteTracker.delete(agent_id)
                result

              _ ->
                {:error, "lite agent completed but no result found"}
            end

          {:DOWN, ^ref, :process, ^pid, reason} ->
            LiteTracker.delete(agent_id)
            {:error, "lite agent crashed: #{inspect(reason)}"}
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            {:error, "lite agent timed out after #{div(timeout, 1000)}s"}
        end
    end
  end

  # --- Core execution ---

  defp run(opts, task_prompt) do
    messages = [
      ReqLLM.Context.system(opts.system_prompt),
      ReqLLM.Context.user(task_prompt)
    ]

    do_step(messages, opts, 1)
  end

  defp do_step(_messages, %{max_steps: max}, step) when step > max do
    {:error, "lite agent exceeded max steps (#{max})"}
  end

  defp do_step(messages, opts, step) do
    stream_opts = Keyword.merge([tools: opts.req_tools], opts.gen_opts)

    case stream_with_retry(opts.model, messages, stream_opts, 1) do
      {:ok, response} ->
        handle_response(response, messages, opts, step)

      {:error, reason} ->
        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  defp handle_response(response, messages, opts, step) do
    tool_calls = ReqLLM.Response.tool_calls(response)
    text = ReqLLM.Response.text(response)

    case tool_calls do
      [] ->
        # No tool calls — return text response
        {:ok, text || ""}

      calls ->
        {tool_results, final} = execute_tools(calls, opts.tool_map, opts.context)

        cond do
          final != nil ->
            {:ok, final}

          has_terminal_call?(calls) ->
            # Terminal tool was called (finish/end_turn) — extract result
            finish_text = extract_finish_result(calls) || text || ""
            {:ok, finish_text}

          true ->
            # Continue with tool results
            assistant_msg = ReqLLM.Context.assistant(text || "", tool_calls: calls)
            next_messages = messages ++ [assistant_msg | tool_results]
            do_step(next_messages, opts, step + 1)
        end
    end
  end

  # --- Tool execution ---

  defp execute_tools(tool_calls, tool_map, context) do
    results =
      tool_calls
      |> Enum.map(fn tc ->
        Task.async(fn -> execute_single_tool(tc, tool_map, context) end)
      end)
      |> Task.await_many(:timer.minutes(5))

    {tool_msgs, finals} = Enum.unzip(results)
    {tool_msgs, Enum.find(finals, & &1)}
  end

  defp execute_single_tool(tc, tool_map, context) do
    name = ReqLLM.ToolCall.name(tc)
    args = ReqLLM.ToolCall.args_map(tc) || %{}
    call_id = tc.id
    tool_def = Map.get(tool_map, name)

    result =
      if tool_def do
        cast_args = Rho.ToolArgs.cast(args, tool_def.tool.parameter_schema)

        try do
          tool_def.execute.(cast_args, context)
        rescue
          e -> {:error, Exception.message(e)}
        end
      else
        {:error, "unknown tool: #{name}"}
      end

    case result do
      {:final, output} ->
        {ReqLLM.Context.tool_result(call_id, to_string(output)), to_string(output)}

      {:ok, output} ->
        {ReqLLM.Context.tool_result(call_id, to_string(output)), nil}

      {:error, reason} ->
        {ReqLLM.Context.tool_result(call_id, "Error: #{reason}"), nil}
    end
  end

  # --- Helpers ---

  defp has_terminal_call?(tool_calls) do
    Enum.any?(tool_calls, fn tc ->
      MapSet.member?(@terminal_tools, ReqLLM.ToolCall.name(tc))
    end)
  end

  defp extract_finish_result(tool_calls) do
    Enum.find_value(tool_calls, fn tc ->
      if ReqLLM.ToolCall.name(tc) == "finish" do
        args = ReqLLM.ToolCall.args_map(tc) || %{}
        args["result"]
      end
    end)
  end

  defp build_system_prompt(base_prompt, _task) do
    """
    #{base_prompt}

    You are a focused worker agent. Complete the given task efficiently.
    Call the appropriate tool with your result when done.
    Do not ask clarifying questions — make reasonable assumptions.
    """
  end

  defp build_gen_opts(nil) do
    [provider_options: [openrouter_cache_control: %{type: "ephemeral"}]]
  end

  defp build_gen_opts(provider) do
    [
      provider_options: [
        openrouter_provider: provider,
        openrouter_cache_control: %{type: "ephemeral"}
      ]
    ]
  end

  defp stream_with_retry(model, messages, stream_opts, attempt) do
    case ReqLLM.stream_text(model, messages, stream_opts) do
      {:ok, stream} ->
        case ReqLLM.StreamResponse.process_stream(stream, []) do
          {:ok, _response} = ok -> ok
          {:error, reason} -> maybe_retry(model, messages, stream_opts, attempt, reason)
        end

      {:error, reason} ->
        maybe_retry(model, messages, stream_opts, attempt, reason)
    end
  end

  defp maybe_retry(model, messages, stream_opts, attempt, reason) do
    if attempt <= @max_stream_retries and retryable?(reason) do
      Logger.warning("[lite_worker] retry attempt #{attempt}: #{inspect(reason)}")
      Process.sleep(1_000 * attempt)
      stream_with_retry(model, messages, stream_opts, attempt + 1)
    else
      {:error, reason}
    end
  end

  defp retryable?(%Mint.TransportError{reason: reason}), do: retryable?(reason)
  defp retryable?({:timeout, _}), do: true
  defp retryable?({:closed, _}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(:closed), do: true
  defp retryable?(:econnrefused), do: true
  defp retryable?(:econnreset), do: true
  defp retryable?(_), do: false
end
