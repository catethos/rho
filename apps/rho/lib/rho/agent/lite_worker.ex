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
  alias Rho.LLM.Admission
  alias Rho.PromptSection
  alias Rho.TurnStrategy.Shared

  @default_max_steps 3
  @default_turn_strategy Rho.TurnStrategy.Direct
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
    * `:turn_strategy` — strategy module (default from role config,
      falls back to `Rho.TurnStrategy.Direct`). Non-Direct strategies
      are driven via `turn_strategy.run/2` per step.
  """
  def start(opts) do
    task_prompt = Keyword.fetch!(opts, :task)
    tools = Keyword.fetch!(opts, :tools)
    parent_agent_id = Keyword.fetch!(opts, :parent_agent_id)

    role = opts[:role] || :default
    config = Rho.Config.agent_config(role)

    agent_id = Primary.new_agent_id(parent_agent_id)
    context = opts[:context] || %Rho.Context{agent_name: role, agent_id: agent_id}

    turn_strategy =
      opts[:turn_strategy] || Map.get(config, :turn_strategy) || @default_turn_strategy

    base_prompt = opts[:system_prompt] || config.system_prompt
    system_prompt = build_system_prompt(base_prompt, task_prompt, turn_strategy, tools)

    parent_worker_pid = resolve_parent_worker_pid(parent_agent_id)

    run_opts = %{
      agent_id: agent_id,
      model: opts[:model] || config.model,
      system_prompt: system_prompt,
      tool_defs: tools,
      req_tools: Enum.map(tools, & &1.tool),
      tool_map: Map.new(tools, fn t -> {t.tool.name, t} end),
      gen_opts: build_gen_opts(opts[:provider] || config[:provider]),
      max_steps: opts[:max_steps] || @default_max_steps,
      context: context,
      turn_strategy: turn_strategy,
      emit: build_emit(context, agent_id, parent_worker_pid)
    }

    task =
      Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
        result = run(run_opts, task_prompt)
        LiteTracker.complete(agent_id, result)
        publish_completion(context, agent_id, result)
        result
      end)

    LiteTracker.register(agent_id, task.ref, task.pid)

    {:ok, agent_id}
  end

  defp publish_completion(%{session_id: nil}, _agent_id, _result), do: :ok

  defp publish_completion(%{session_id: session_id}, agent_id, result)
       when is_binary(session_id) do
    {status, text} =
      case result do
        {:ok, t} -> {:ok, t}
        {:error, r} -> {:error, inspect(r)}
      end

    Rho.Comms.publish(
      "rho.task.completed",
      %{session_id: session_id, agent_id: agent_id, status: status, result: text},
      source: "/session/#{session_id}/agent/#{agent_id}"
    )
  end

  defp publish_completion(_, _, _), do: :ok

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
        await_running(agent_id, pid, timeout)
    end
  end

  defp await_running(agent_id, pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        collect_completed_result(agent_id)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        LiteTracker.delete(agent_id)
        {:error, "lite agent crashed: #{inspect(reason)}"}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, "lite agent timed out after #{div(timeout, 1000)}s"}
    end
  end

  defp collect_completed_result(agent_id) do
    case LiteTracker.lookup(agent_id) do
      {:done, result, _} ->
        LiteTracker.delete(agent_id)
        result

      _ ->
        {:error, "lite agent completed but no result found"}
    end
  end

  # --- Core execution ---

  defp run(opts, task_prompt) do
    messages = [
      ReqLLM.Context.system([
        ReqLLM.Message.ContentPart.text(opts.system_prompt, %{
          cache_control: %{type: "ephemeral"}
        })
      ]),
      ReqLLM.Context.user(task_prompt)
    ]

    do_step(messages, opts, 1)
  end

  defp do_step(_messages, %{max_steps: max}, step) when step > max do
    {:error, "lite agent exceeded max steps (#{max})"}
  end

  defp do_step(messages, %{turn_strategy: @default_turn_strategy} = opts, step) do
    do_step_direct(messages, opts, step)
  end

  defp do_step(messages, opts, step) do
    do_step_strategy(messages, opts, step)
  end

  # Native tool_use path — used when turn_strategy is Direct (the default).
  defp do_step_direct(messages, opts, step) do
    publish_progress(opts, step)
    opts.emit.(%{type: :step_start, step: step, max_steps: opts.max_steps})
    stream_opts = Keyword.merge([tools: opts.req_tools], opts.gen_opts)

    case stream_with_retry(opts.model, messages, stream_opts, 1) do
      {:ok, response} ->
        handle_response(response, messages, opts, step)

      {:error, reason} ->
        opts.emit.(%{type: :error, reason: reason})
        publish_error(opts, reason)
        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  # Strategy-driven path — delegates each turn to `turn_strategy.run/2`.
  # Used for non-native protocols (e.g. Structured JSON) where the LLM
  # writes tool calls as visible text instead of the provider's
  # tool_use protocol.
  #
  # The strategy runs inside the subagent's ctx, which causes
  # `Rho.TransformerRegistry.apply_stage/3` to short-circuit into a
  # pass-through — so Lite keeps its "no transformers" property even
  # though the strategy calls `apply_stage` internally.
  defp do_step_strategy(messages, opts, step) do
    publish_progress(opts, step)
    opts.emit.(%{type: :step_start, step: step, max_steps: opts.max_steps})

    projection = %{context: messages, tools: opts.req_tools, step: step}

    runtime = %{
      model: opts.model,
      emit: opts.emit,
      gen_opts: opts.gen_opts,
      tool_defs: opts.tool_defs,
      tool_map: opts.tool_map,
      context: opts.context
    }

    case opts.turn_strategy.run(projection, runtime) do
      {:done, %{type: :response, text: text}} ->
        {:ok, text}

      {:final, value, _entries} ->
        {:ok, to_string(value)}

      {:continue, %{assistant_msg: assistant_msg, tool_results: tool_results}} ->
        next_messages = messages ++ [assistant_msg | tool_results]
        do_step(next_messages, opts, step + 1)

      {:error, reason} ->
        opts.emit.(%{type: :error, reason: reason})
        publish_error(opts, reason)
        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  defp publish_progress(%{context: %{session_id: sid}} = opts, step) when is_binary(sid) do
    Rho.Comms.publish(
      "rho.task.progress",
      %{
        session_id: sid,
        agent_id: opts.agent_id,
        step: step,
        max_steps: opts.max_steps
      },
      source: "/session/#{sid}/agent/#{opts.agent_id}"
    )
  end

  defp publish_progress(_, _), do: :ok

  defp publish_error(%{context: %{session_id: sid}} = opts, reason) when is_binary(sid) do
    Rho.Comms.publish(
      "rho.session.#{sid}.error",
      %{
        session_id: sid,
        agent_id: opts.agent_id,
        reason: reason
      },
      source: "/session/#{sid}/agent/#{opts.agent_id}"
    )
  end

  defp publish_error(_, _), do: :ok

  # --- Observability & heartbeat ---
  #
  # The emit callback does two jobs:
  #
  # 1. **Observability.** Publishes the lite worker's internal events
  #    (llm_usage, tool_start, tool_result, step_start, text_delta,
  #    structured_partial, error) to `rho.session.<sid>.events.<type>`
  #    — the same topic pattern full Workers use. UI, EventLog, and
  #    any debug subscriber see them just like primary-agent events,
  #    with a `lite: true` flag so they can be distinguished.
  #
  # 2. **Heartbeat.** Each emit sends a `{:meta_update,
  #    :last_activity_at, now}` to the parent Worker's pid. This
  #    prevents the parent's turn watchdog (60s inactivity limit from
  #    worker.ex) from killing the parent's runner while it's blocked
  #    inside `await_task`. The parent's own emit only fires on
  #    `:tool_start` / `:tool_result` — nothing between — so without
  #    this heartbeat a long lite-worker await looks like primary
  #    inactivity and gets terminated with `:turn_inactive`.
  defp build_emit(%Rho.Context{session_id: sid}, agent_id, parent_pid) do
    fn event ->
      if is_pid(parent_pid) and Process.alive?(parent_pid) do
        send(parent_pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})
      end

      publish_lite_event(sid, agent_id, event)
      :ok
    end
  end

  # Look up the parent Worker's pid once at start; nil if the parent
  # isn't a full Worker (e.g. nested lite workers or CLI-invoked lite).
  defp resolve_parent_worker_pid(parent_agent_id) when is_binary(parent_agent_id) do
    Rho.Agent.Worker.whereis(parent_agent_id)
  rescue
    _ -> nil
  end

  defp resolve_parent_worker_pid(_), do: nil

  defp publish_lite_event(nil, _agent_id, _event), do: :ok

  defp publish_lite_event(session_id, agent_id, event) when is_binary(session_id) do
    case event_to_signal_type(event) do
      nil ->
        :ok

      signal_type ->
        payload =
          event
          |> Map.put(:agent_id, agent_id)
          |> Map.put(:session_id, session_id)
          |> Map.put(:lite, true)

        Rho.Comms.publish(
          "rho.session.#{session_id}.events.#{signal_type}",
          payload,
          source: "/session/#{session_id}/agent/#{agent_id}"
        )
    end
  end

  @signal_event_types ~w(
    text_delta llm_text tool_start tool_result step_start llm_usage
    error structured_partial before_llm
  )a

  defp event_to_signal_type(%{type: type}) when type in @signal_event_types,
    do: Atom.to_string(type)

  defp event_to_signal_type(_), do: nil

  defp handle_response(response, messages, opts, step) do
    tool_calls = ReqLLM.Response.tool_calls(response)
    text = ReqLLM.Response.text(response)

    case tool_calls do
      [] ->
        {:ok, text || ""}

      calls ->
        process_tool_calls(calls, text, messages, opts, step)
    end
  end

  defp process_tool_calls(calls, text, messages, opts, step) do
    {tool_results, final} = execute_tools(calls, opts.tool_map, opts.context, opts.emit)

    cond do
      final != nil ->
        {:ok, final}

      has_terminal_call?(calls) ->
        {:ok, extract_finish_result(calls) || text || ""}

      true ->
        assistant_msg = ReqLLM.Context.assistant(text || "", tool_calls: calls)
        next_messages = messages ++ [assistant_msg | tool_results]
        do_step(next_messages, opts, step + 1)
    end
  end

  # --- Tool execution ---

  defp execute_tools(tool_calls, tool_map, context, emit) do
    results =
      tool_calls
      |> Enum.map(fn tc ->
        Task.async(fn -> execute_single_tool(tc, tool_map, context, emit) end)
      end)
      |> Task.await_many(:timer.minutes(5))

    {tool_msgs, finals} = Enum.unzip(results)
    {tool_msgs, Enum.find(finals, & &1)}
  end

  defp execute_single_tool(tc, tool_map, context, emit) do
    name = ReqLLM.ToolCall.name(tc)
    args = ReqLLM.ToolCall.args_map(tc) || %{}
    call_id = tc.id
    tool_def = Map.get(tool_map, name)

    emit.(%{type: :tool_start, name: name, args: args, call_id: call_id})
    t0 = System.monotonic_time(:millisecond)

    result =
      if tool_def do
        case Rho.ToolArgs.prepare(args, tool_def.tool.parameter_schema) do
          {:ok, prepared_args, _repairs} ->
            try do
              tool_def.execute.(prepared_args, context)
            rescue
              e -> {:error, Exception.message(e)}
            end

          {:error, reason} ->
            {:error, "Arg preparation failed: #{inspect(reason)}"}
        end
      else
        {:error, "unknown tool: #{name}"}
      end

    latency_ms = System.monotonic_time(:millisecond) - t0

    {output_str, status, final, effects} =
      case result do
        {:final, output} -> {to_string(output), :ok, to_string(output), []}
        %Rho.ToolResponse{text: text, effects: fx} -> {text || "", :ok, nil, fx || []}
        {:ok, output} -> {to_string(output), :ok, nil, []}
        {:error, reason} -> {"Error: #{reason}", :error, nil, []}
      end

    event = %{
      type: :tool_result,
      name: name,
      status: status,
      output: output_str,
      call_id: call_id,
      latency_ms: latency_ms
    }

    emit.(if effects != [], do: Map.put(event, :effects, effects), else: event)

    tool_msg =
      case result do
        {:error, reason} -> ReqLLM.Context.tool_result(call_id, "Error: #{reason}")
        _ -> ReqLLM.Context.tool_result(call_id, output_str)
      end

    {tool_msg, final}
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

  defp build_system_prompt(base_prompt, _task, turn_strategy, tools) do
    base = """
    #{base_prompt}

    You are a focused worker agent. Complete the given task efficiently.
    Call the appropriate tool with your result when done.
    Do not ask clarifying questions — make reasonable assumptions.
    """

    case strategy_prompt_section(turn_strategy, tools) do
      nil -> base
      extra -> base <> "\n\n" <> extra
    end
  end

  # Render the strategy's own prompt_sections (e.g. the Structured
  # strategy's JSON format instructions) so LLMs that don't use native
  # tool_use know what output format is expected. Direct returns [], so
  # this is a no-op for the default path.
  defp strategy_prompt_section(turn_strategy, tools) do
    if function_exported?(turn_strategy, :prompt_sections, 2) do
      case turn_strategy.prompt_sections(tools, %{}) do
        [] ->
          nil

        sections when is_list(sections) ->
          sections
          |> Enum.map(&normalize_section/1)
          |> PromptSection.render(:markdown)
      end
    end
  end

  defp normalize_section(%PromptSection{} = s), do: s
  defp normalize_section(text) when is_binary(text), do: PromptSection.from_string(text)

  defp build_gen_opts(nil) do
    []
  end

  defp build_gen_opts(provider) do
    [provider_options: [openrouter_provider: provider]]
  end

  defp stream_with_retry(model, messages, stream_opts, attempt) do
    # Ensure receive_timeout is set to prevent hanging on stale connections
    stream_opts = Keyword.put_new(stream_opts, :receive_timeout, 120_000)

    # Admission slot per attempt — acquire timeout short-circuits
    # retries (if no slot is free after 60s of queueing, retrying
    # immediately won't help).
    result = Admission.with_slot(fn -> do_stream(model, messages, stream_opts) end)

    case result do
      {:ok, _response} = ok ->
        ok

      {:error, :acquire_timeout} = err ->
        Logger.error("[lite_worker] admission timeout — no LLM slot available after 60s")
        err

      {:error, reason} ->
        maybe_retry(model, messages, stream_opts, attempt, reason)
    end
  end

  defp do_stream(model, messages, stream_opts) do
    try do
      case ReqLLM.stream_text(model, messages, stream_opts) do
        {:ok, stream} ->
          ReqLLM.StreamResponse.process_stream(stream, [])

        {:error, _} = err ->
          err
      end
    rescue
      # Transport-level failures (e.g. Finch pool exhaustion,
      # mid-stream disconnect) can escape as raised exceptions.
      # Convert to `{:error, reason}` so the retry path gets a chance.
      exception ->
        Logger.warning("[lite_worker] stream raised: #{Exception.message(exception)}")
        {:error, exception}
    end
  end

  defp maybe_retry(model, messages, stream_opts, attempt, reason) do
    if Shared.should_retry?(reason, attempt) do
      Logger.warning("[lite_worker] retry attempt #{attempt}: #{inspect(reason)}")
      Shared.retry_backoff(attempt)
      stream_with_retry(model, messages, stream_opts, attempt + 1)
    else
      {:error, reason}
    end
  end
end
