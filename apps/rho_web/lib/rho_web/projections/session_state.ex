defmodule RhoWeb.Projections.SessionState do
  @moduledoc """
  Pure reducer that transforms events into session state updates.

  Signals use atom-kind dispatch (e.g. `%{kind: :text_delta, data: %{...}}`).
  Returns `{state, effects}` tuples. Effects are descriptors — the caller
  decides how to apply them.

  ## Effect types

      {:push_event, name, payload}   — push a JS hook event
      {:send_after, delay, message}  — schedule a delayed message to self

  ## State shape

  A plain map containing all session-related fields. See `init/1`.
  """

  @doc "Returns initial session state for the given session_id."
  def init(session_id) do
    %{
      session_id: session_id,
      agents: %{},
      agent_tab_order: [],
      agent_messages: %{},
      inflight: %{},
      signals: [],
      ui_streams: %{},
      debug_projections: %{},
      selected_agent_id: nil,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost: 0.0,
      total_cached_tokens: 0,
      total_reasoning_tokens: 0,
      step_input_tokens: 0,
      step_output_tokens: 0,
      next_id: 1
    }
  end

  @doc """
  Reduces a signal into session state, returning `{new_state, effects}`.

  The signal must have `:kind` (atom) and `:data` keys. Optionally,
  `:emitted_at` (used for signal timestamps).
  """
  def reduce(state, signal) do
    {state, effects} = do_reduce(state, signal)
    {state, Enum.reverse(effects)}
  end

  # --- Dispatchers ---

  # Session event kinds — dispatched directly by atom
  @session_event_kinds ~w(
    text_delta llm_text tool_start tool_result step_start llm_usage
    turn_started turn_finished turn_cancelled compact error before_llm
    structured_partial ui_spec_delta ui_spec message_sent
  )a

  defp do_reduce(state, %{kind: kind, data: data} = signal) when kind in @session_event_kinds do
    dispatch_session_event(kind, state, data, signal)
  end

  defp do_reduce(state, %{kind: :agent_started, data: data} = signal) do
    agent = %{
      agent_id: data.agent_id,
      session_id: data.session_id,
      role: data[:role] || :unknown,
      status: :idle,
      depth: data[:depth] || 0,
      capabilities: data[:capabilities] || [],
      model: data[:model],
      step: nil,
      max_steps: nil
    }

    agents = Map.put(state.agents, data.agent_id, agent)

    agent_tab_order =
      if data.agent_id in state.agent_tab_order do
        state.agent_tab_order
      else
        state.agent_tab_order ++ [data.agent_id]
      end

    agent_messages = Map.put_new(state.agent_messages, data.agent_id, [])

    state =
      state
      |> Map.put(:agents, agents)
      |> Map.put(:agent_tab_order, agent_tab_order)
      |> Map.put(:agent_messages, agent_messages)

    add_signal(state, [], :agent_started, data, signal)
  end

  defp do_reduce(state, %{kind: :agent_stopped, data: data} = signal) do
    agent = Map.get(state.agents, data.agent_id)

    state =
      if agent && agent.depth > 0 do
        agents = Map.delete(state.agents, data.agent_id)
        agent_tab_order = Enum.reject(state.agent_tab_order, &(&1 == data.agent_id))

        selected =
          if state[:selected_agent_id] == data.agent_id do
            List.first(agent_tab_order)
          else
            state[:selected_agent_id]
          end

        state
        |> Map.put(:agents, agents)
        |> Map.put(:agent_tab_order, agent_tab_order)
        |> Map.put(:selected_agent_id, selected)
      else
        agents =
          if agent do
            Map.put(state.agents, data.agent_id, %{agent | status: :stopped})
          else
            state.agents
          end

        Map.put(state, :agents, agents)
      end

    add_signal(state, [], :agent_stopped, data, signal)
  end

  defp do_reduce(state, %{kind: :task_requested, data: data} = signal) do
    {id, state} = next_id(state)

    # worker_agent_id tracks the lite worker; agent_id is the parent (for chat feed placement)
    msg = %{
      id: id,
      role: :system,
      type: :delegation,
      agent_id: data[:agent_id],
      worker_agent_id: data[:worker_agent_id],
      target_role: data[:role],
      task: data[:task],
      status: :pending,
      content: "Delegated task"
    }

    state = append_message(state, msg)
    add_signal(state, [], :task_requested, data, signal)
  end

  defp do_reduce(state, %{kind: :task_progress, data: data}) do
    agent_id = data[:agent_id]

    pred = fn msg ->
      msg[:type] == :delegation and msg[:status] == :pending and
        (msg[:worker_agent_id] == agent_id or msg[:agent_id] == agent_id)
    end

    has_existing? =
      Enum.any?(state.agent_messages, fn {_aid, msgs} -> Enum.any?(msgs, pred) end)

    state =
      if has_existing? do
        update_message_by(state, pred, fn msg ->
          Map.merge(msg, %{step: data[:step], max_steps: data[:max_steps]})
        end)
      else
        state
      end

    {state, []}
  end

  defp do_reduce(state, %{kind: :task_completed, data: data} = signal) do
    agent_id = data[:agent_id]
    status = if data[:status] == :error, do: :error, else: :ok

    {id, state} = next_id(state)

    msg = %{
      id: id,
      role: :system,
      type: :delegation,
      agent_id: agent_id,
      worker_agent_id: data[:worker_agent_id],
      target_role: data[:role],
      task: data[:task],
      status: status,
      result: data[:result],
      content: "Delegated task"
    }

    state = append_message(state, msg)
    add_signal(state, [], :task_completed, data, signal)
  end

  defp do_reduce(state, %{kind: kind, data: data} = signal) do
    add_signal(state, [], kind, data, signal)
  end

  defp do_reduce(state, _signal), do: {state, []}

  # --- Session event dispatch ---

  defp dispatch_session_event(:text_delta, state, data, _s),
    do: reduce_text_delta(state, data)

  defp dispatch_session_event(:llm_text, state, data, _s),
    do: reduce_text_delta(state, data)

  defp dispatch_session_event(:tool_start, state, data, _s),
    do: reduce_tool_start(state, data)

  defp dispatch_session_event(:tool_result, state, data, _s),
    do: reduce_tool_result(state, data)

  defp dispatch_session_event(:turn_started, state, data, _s),
    do: reduce_turn_started(state, data)

  defp dispatch_session_event(:turn_finished, state, data, _s),
    do: reduce_turn_finished(state, data)

  defp dispatch_session_event(:llm_usage, state, data, _s),
    do: reduce_usage(state, data)

  defp dispatch_session_event(:step_start, state, data, _s),
    do: reduce_step_start(state, data)

  defp dispatch_session_event(:before_llm, state, data, signal),
    do: reduce_before_llm(state, data, signal)

  defp dispatch_session_event(:ui_spec_delta, state, data, _s),
    do: reduce_ui_spec_delta(state, data)

  defp dispatch_session_event(:ui_spec, state, data, _s),
    do: reduce_ui_spec(state, data)

  defp dispatch_session_event(:message_sent, state, data, _s),
    do: reduce_message_sent(state, data)

  defp dispatch_session_event(:error, state, data, _s),
    do: reduce_error(state, data)

  defp dispatch_session_event(kind, state, data, signal),
    do: add_signal(state, [], kind, data, signal)

  # --- Individual reducers ---

  defp reduce_text_delta(state, data) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    text = data[:text] || ""

    entry =
      Map.get(state.inflight, agent_id, %{
        agent_id: agent_id,
        turn_id: data[:turn_id],
        chunks: [],
        envelope: nil
      })

    entry = %{entry | chunks: entry.chunks ++ [text]}

    buffer = IO.iodata_to_binary(entry.chunks)

    envelope =
      try do
        case RhoWeb.StreamEnvelope.analyze(buffer) do
          {:envelope, summary} -> summary
          :no_envelope -> entry[:envelope]
        end
      rescue
        _ -> entry[:envelope]
      end

    entry = Map.put(entry, :envelope, envelope)
    inflight = Map.put(state.inflight, agent_id, entry)

    state =
      state
      |> Map.put(:inflight, inflight)

    effects = [{:push_event, "text-chunk", %{agent_id: agent_id, text: text}}]
    {state, effects}
  end

  defp reduce_tool_start(state, data) do
    if data[:name] in ["end_turn", "finish", "present_ui"] do
      {state, []}
    else
      agent_id = data[:agent_id] || primary_agent_id(state)

      {state, flush_effects, _} = flush_inflight_to_thinking(state, agent_id)

      {id, state} = next_id(state)

      msg = %{
        id: id,
        role: :assistant,
        type: :tool_call,
        name: data[:name],
        args: data[:args],
        call_id: data[:call_id],
        agent_id: agent_id,
        status: :pending,
        content: "Tool: #{data[:name]}"
      }

      {append_message(state, msg), flush_effects}
    end
  end

  defp reduce_tool_result(state, data) do
    if data[:name] in ["end_turn", "finish", "present_ui"] do
      {state, []}
    else
      agent_id = data[:agent_id] || primary_agent_id(state)

      state =
        state
        |> apply_tool_result_to_state(data, agent_id)
        |> maybe_append_image_message(data, agent_id)
        |> maybe_reset_tokens(data)

      effects = collect_tool_effects(data, state.session_id, agent_id)
      {state, effects}
    end
  end

  defp maybe_append_image_message(state, data, agent_id) do
    case RhoWeb.ChatComponents.extract_image_uris(data[:output]) do
      [] ->
        state

      image_uris ->
        {id, state} = next_id(state)

        img_msg = %{
          id: id,
          role: :assistant,
          type: :image,
          images: image_uris,
          agent_id: agent_id,
          content: "Visualization"
        }

        append_message(state, img_msg)
    end
  end

  defp maybe_reset_tokens(state, data) do
    if data[:name] == "clear_memory" and data[:status] == :ok do
      state
      |> Map.put(:total_input_tokens, 0)
      |> Map.put(:total_output_tokens, 0)
      |> Map.put(:total_cost, 0.0)
      |> Map.put(:total_cached_tokens, 0)
      |> Map.put(:total_reasoning_tokens, 0)
      |> Map.put(:step_input_tokens, 0)
      |> Map.put(:step_output_tokens, 0)
    else
      state
    end
  end

  defp collect_tool_effects(data, session_id, agent_id) do
    case data[:effects] do
      [_ | _] = tool_effects ->
        [{:dispatch_tool_effects, tool_effects, %{session_id: session_id, agent_id: agent_id}}]

      _ ->
        []
    end
  end

  defp apply_tool_result_to_state(state, data, agent_id) do
    call_id = data[:call_id]
    status = data[:status] || :ok

    if call_id do
      update_message_by(state, &(&1[:call_id] == call_id), fn msg ->
        Map.merge(msg, %{output: data[:output], status: status})
      end)
    else
      {id, state} = next_id(state)

      msg = %{
        id: id,
        role: :assistant,
        type: :tool_call,
        name: data[:name],
        output: data[:output],
        call_id: call_id,
        agent_id: agent_id,
        status: status,
        content: "Tool result: #{data[:name]}"
      }

      append_message(state, msg)
    end
  end

  defp reduce_ui_spec_delta(state, data) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    spec = data[:spec]
    title = data[:title]
    delta_msg_id = data[:message_id]

    case Map.get(state.ui_streams, delta_msg_id) do
      nil ->
        {mid, state} =
          if delta_msg_id do
            {delta_msg_id, state}
          else
            next_id(state)
          end

        msg = %{
          id: mid,
          role: :assistant,
          type: :ui,
          agent_id: agent_id,
          title: title,
          spec: spec,
          streaming: true,
          content: "Structured UI"
        }

        stream = %{queue: [], final_spec: nil, agent_id: agent_id}
        ui_streams = Map.put(state.ui_streams, mid, stream)

        state =
          state
          |> Map.put(:ui_streams, ui_streams)
          |> append_message(msg)

        effects = [{:send_after, 40, {:ui_spec_tick, mid}}]
        {state, effects}

      %{} = stream ->
        stream = %{stream | queue: stream.queue ++ [spec]}
        ui_streams = Map.put(state.ui_streams, delta_msg_id, stream)
        {Map.put(state, :ui_streams, ui_streams), []}
    end
  end

  defp reduce_ui_spec(state, data, signal \\ nil) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    delta_msg_id = data[:message_id]
    ui_streams = state.ui_streams

    state =
      case Map.get(ui_streams, delta_msg_id) do
        %{queue: []} = _stream ->
          state
          |> update_message(delta_msg_id, fn msg ->
            %{msg | spec: data[:spec], title: data[:title] || msg.title, streaming: false}
          end)
          |> Map.put(:ui_streams, Map.delete(ui_streams, delta_msg_id))

        %{} = stream ->
          stream = %{stream | final_spec: data[:spec]}
          Map.put(state, :ui_streams, Map.put(ui_streams, delta_msg_id, stream))

        nil ->
          {id, state} =
            if delta_msg_id do
              {delta_msg_id, state}
            else
              next_id(state)
            end

          msg = %{
            id: id,
            role: :assistant,
            type: :ui,
            agent_id: agent_id,
            title: data[:title],
            spec: data[:spec],
            streaming: false,
            content: "Structured UI"
          }

          append_message(state, msg)
      end

    add_signal(state, [], :ui_spec, data, signal)
  end

  defp reduce_message_sent(state, data) do
    from = data[:from]
    to = data[:to]
    message = data[:message]

    # Use pre-resolved labels if available (enriched by SignalRouter),
    # otherwise fall back to raw values
    from_label = data[:resolved_from_label] || from || "unknown"
    target_agent_id = data[:resolved_target_agent_id] || to

    {id, state} = next_id(state)

    msg = %{
      id: id,
      role: :user,
      type: :text,
      content: message,
      agent_id: target_agent_id,
      from_agent: from_label
    }

    state = append_message(state, msg)
    # No signal wrapper needed — use a minimal add_signal
    add_signal(state, [], :message_sent, data, nil)
  end

  defp reduce_turn_started(state, data, signal \\ nil) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    agents = update_agent_status(state.agents, agent_id, :busy)

    state = Map.put(state, :agents, agents)

    add_signal(state, [], :turn_started, data, signal)
  end

  defp reduce_turn_finished(state, data) do
    agent_id = data[:agent_id] || primary_agent_id(state)

    {state, flush_effects, has_final_answer} = flush_inflight_to_thinking(state, agent_id)

    inflight = Map.delete(state.inflight, agent_id)
    agents = update_agent_status(state.agents, agent_id, :idle)

    {state, msg_effects} =
      case data[:result] do
        {:ok, text} when is_binary(text) and text != "" ->
          if has_final_answer do
            # The thinking message already contains the final answer — skip duplicate
            {state, []}
          else
            {id, state} = next_id(state)

            msg = %{
              id: id,
              role: :assistant,
              type: :text,
              content: text,
              agent_id: agent_id
            }

            {append_message(state, msg), []}
          end

        {:error, reason} ->
          {id, state} = next_id(state)

          msg = %{
            id: id,
            role: :system,
            type: :error,
            content: format_error(reason),
            agent_id: agent_id
          }

          {append_message(state, msg), []}

        _ ->
          {state, []}
      end

    state =
      state
      |> Map.put(:inflight, inflight)
      |> Map.put(:agents, agents)

    stream_end = {:push_event, "stream-end", %{agent_id: agent_id}}
    {state, signal_effects} = add_signal(state, [], :turn_finished, data, nil)

    {state, flush_effects ++ msg_effects ++ [stream_end | signal_effects]}
  end

  defp reduce_usage(state, data) do
    usage = data[:usage] || %{}
    input = usage[:input_tokens] || Map.get(usage, "input_tokens", 0)
    output = usage[:output_tokens] || Map.get(usage, "output_tokens", 0)
    cost = usage[:total_cost] || Map.get(usage, "total_cost", 0.0)
    cached = usage[:cached_tokens] || Map.get(usage, "cached_tokens", 0)
    reasoning = usage[:reasoning_tokens] || Map.get(usage, "reasoning_tokens", 0)

    state =
      state
      |> Map.put(:total_input_tokens, state.total_input_tokens + input)
      |> Map.put(:total_output_tokens, state.total_output_tokens + output)
      |> Map.put(:total_cost, state.total_cost + (cost || 0.0))
      |> Map.put(:total_cached_tokens, state.total_cached_tokens + cached)
      |> Map.put(:total_reasoning_tokens, state.total_reasoning_tokens + reasoning)
      |> Map.put(:step_input_tokens, input)
      |> Map.put(:step_output_tokens, output)

    {state, []}
  end

  defp reduce_before_llm(state, data, signal) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    projection = data[:projection] || %{}
    timestamp = (signal || %{})[:emitted_at] || 0

    debug_projections =
      Map.put(state[:debug_projections] || %{}, agent_id, %{
        context: format_projection_context(projection[:context] || []),
        tools: format_projection_tools(projection[:tools] || []),
        step: projection[:step],
        timestamp: timestamp,
        raw_message_count: length(projection[:context] || []),
        raw_tool_count: length(projection[:tools] || [])
      })

    {Map.put(state, :debug_projections, debug_projections), []}
  end

  defp reduce_step_start(state, data) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    step = data[:step]
    max_steps = data[:max_steps]

    agents =
      case Map.get(state.agents, agent_id) do
        nil ->
          state.agents

        agent ->
          Map.put(state.agents, agent_id, %{agent | step: step, max_steps: max_steps})
      end

    {Map.put(state, :agents, agents), []}
  end

  defp reduce_error(state, data) do
    agent_id = data[:agent_id] || primary_agent_id(state)
    reason = data[:reason]

    {state, flush_effects, _} = flush_inflight_to_thinking(state, agent_id)

    inflight = Map.delete(state.inflight, agent_id)
    agents = update_agent_status(state.agents, agent_id, :error)

    {id, state} = next_id(state)

    msg = %{
      id: id,
      role: :system,
      type: :error,
      agent_id: agent_id,
      content: "Error: #{inspect(reason)}"
    }

    state =
      state
      |> Map.put(:inflight, inflight)
      |> Map.put(:agents, agents)
      |> append_message(msg)

    {state, flush_effects}
  end

  # --- Helpers ---

  defp flush_inflight_to_thinking(state, agent_id) do
    case Map.get(state.inflight, agent_id) do
      %{chunks: chunks} when chunks != [] ->
        raw = Enum.join(chunks)

        if String.trim(raw) != "" do
          has_final_answer = contains_final_answer?(raw)

          {id, state} = next_id(state)

          thinking_msg = %{
            id: id,
            role: :assistant,
            type: :thinking,
            content: raw,
            agent_id: agent_id
          }

          inflight =
            Map.put(state.inflight, agent_id, %{
              Map.get(state.inflight, agent_id)
              | chunks: []
            })

          state =
            state
            |> Map.put(:inflight, inflight)
            |> append_message(thinking_msg)

          {state, [{:push_event, "stream-end", %{agent_id: agent_id}}], has_final_answer}
        else
          {state, [], false}
        end

      _ ->
        {state, [], false}
    end
  end

  defp contains_final_answer?(raw) do
    case Rho.StructuredOutput.parse(raw) do
      {:ok, %{"tool" => "respond"}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp update_agent_status(agents, agent_id, status) do
    case Map.get(agents, agent_id) do
      nil -> agents
      agent -> Map.put(agents, agent_id, %{agent | status: status})
    end
  end

  defp add_signal(state, existing_effects, kind, data, signal) do
    {id, state} = next_id(state)
    timestamp = (signal || %{})[:emitted_at] || 0

    sig = %{
      id: id,
      type: Atom.to_string(kind),
      agent_id: data[:agent_id],
      timestamp: timestamp,
      correlation_id: data[:correlation_id]
    }

    signals = Enum.take(state.signals ++ [sig], -500)
    state = Map.put(state, :signals, signals)

    effects = [{:push_event, "signal", sig} | existing_effects]
    {state, effects}
  end

  @doc "Appends a message to the agent_messages map."
  def append_message(state, msg) do
    agent_id = msg[:agent_id] || primary_agent_id(state)
    current = Map.get(state.agent_messages, agent_id, [])
    updated = Map.put(state.agent_messages, agent_id, Enum.take(current ++ [msg], -200))
    Map.put(state, :agent_messages, updated)
  end

  defp update_message(state, msg_id, update_fn) do
    updated =
      Map.new(state.agent_messages, fn {agent_id, msgs} ->
        {agent_id,
         Enum.map(msgs, fn msg ->
           if msg.id == msg_id, do: update_fn.(msg), else: msg
         end)}
      end)

    Map.put(state, :agent_messages, updated)
  end

  defp update_message_by(state, pred, update_fn) do
    updated =
      Map.new(state.agent_messages, fn {agent_id, msgs} ->
        {agent_id,
         Enum.map(msgs, fn msg ->
           if pred.(msg), do: update_fn.(msg), else: msg
         end)}
      end)

    Map.put(state, :agent_messages, updated)
  end

  defp next_id(state) do
    id = Integer.to_string(state.next_id)
    {id, Map.put(state, :next_id, state.next_id + 1)}
  end

  defp primary_agent_id(state) do
    case state.session_id do
      nil -> "primary"
      sid -> sid <> "/primary"
    end
  end

  defp format_error(%Mint.TransportError{reason: reason}),
    do: "Connection error: #{inspect(reason)}. The request will be retried automatically."

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  defp format_projection_context(context) when is_list(context) do
    Enum.map(context, fn msg ->
      %{
        role: extract_role(msg),
        content: extract_content(msg),
        cache_control: extract_cache_control(msg)
      }
    end)
  end

  defp format_projection_context(_), do: []

  defp extract_role(%{role: role}), do: to_string(role)
  defp extract_role(%{"role" => role}), do: to_string(role)
  defp extract_role(_), do: "unknown"

  defp extract_content(%{content: content}) when is_binary(content), do: content

  defp extract_content(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      %{type: "image"} -> "[image]"
      %{type: :image} -> "[image]"
      other -> inspect(other, limit: 200, printable_limit: 500)
    end)
  end

  defp extract_content(%{"content" => content}) when is_binary(content), do: content

  defp extract_content(%{"content" => parts}) when is_list(parts) do
    extract_content(%{content: parts})
  end

  defp extract_content(msg), do: inspect(msg, limit: 200, printable_limit: 500)

  defp extract_cache_control(%{content: [%{cache_control: cc} | _]}), do: cc
  defp extract_cache_control(_), do: nil

  defp format_projection_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      %{name: name} -> name
      %{"name" => name} -> name
      other -> inspect(other, limit: 50)
    end)
  end

  defp format_projection_tools(_), do: []
end
