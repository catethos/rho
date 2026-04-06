defmodule RhoWeb.SessionProjection do
  @moduledoc """
  Translates raw signal bus events into LiveView assign updates.
  Single function: project(socket, signal) :: socket.
  Templates never interpret raw backend events.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  def project(socket, %{type: "rho.session." <> _ = type, data: data}) do
    cond do
      String.ends_with?(type, ".text_delta") ->
        project_text_delta(socket, data)

      String.ends_with?(type, ".llm_text") ->
        project_text_delta(socket, data)

      String.ends_with?(type, ".tool_start") ->
        project_tool_start(socket, data)

      String.ends_with?(type, ".tool_result") ->
        project_tool_result(socket, data)

      String.ends_with?(type, ".turn_started") ->
        project_turn_started(socket, data)

      String.ends_with?(type, ".turn_finished") ->
        project_turn_finished(socket, data)

      String.ends_with?(type, ".llm_usage") ->
        project_usage(socket, data)

      String.ends_with?(type, ".step_start") ->
        project_step_start(socket, data)

      String.ends_with?(type, ".before_llm") ->
        project_before_llm(socket, data)

      String.ends_with?(type, ".ui_spec_delta") ->
        project_ui_spec_delta(socket, data)

      String.ends_with?(type, ".ui_spec") ->
        project_ui_spec(socket, data)

      String.ends_with?(type, ".message_sent") ->
        project_message_sent(socket, data)

      true ->
        add_signal(socket, type, data)
    end
  end

  def project(socket, %{type: "rho.agent.started", data: data}) do
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

    agents = Map.put(socket.assigns.agents, data.agent_id, agent)

    # Add tab and initialize message list for new agent
    tab_order = socket.assigns.tab_order

    tab_order =
      if data.agent_id in tab_order do
        tab_order
      else
        tab_order ++ [data.agent_id]
      end

    agent_messages = Map.put_new(socket.assigns.agent_messages, data.agent_id, [])

    socket
    |> assign(:agents, agents)
    |> assign(:tab_order, tab_order)
    |> assign(:agent_messages, agent_messages)
    |> add_signal("rho.agent.started", data)
  end

  def project(socket, %{type: "rho.agent.stopped", data: data}) do
    agent = Map.get(socket.assigns.agents, data.agent_id)

    # Remove ephemeral subagents (depth > 0) from sidebar; keep primary agents
    if agent && agent.depth > 0 do
      agents = Map.delete(socket.assigns.agents, data.agent_id)
      tab_order = Enum.reject(socket.assigns.tab_order, &(&1 == data.agent_id))

      # If the stopped agent was selected, switch to primary
      selected =
        if socket.assigns[:selected_agent_id] == data.agent_id do
          List.first(tab_order)
        else
          socket.assigns[:selected_agent_id]
        end

      socket
      |> assign(:agents, agents)
      |> assign(:tab_order, tab_order)
      |> assign(:selected_agent_id, selected)
      |> add_signal("rho.agent.stopped", data)
    else
      # Primary agent: mark as stopped but keep visible
      agents =
        if agent do
          Map.put(socket.assigns.agents, data.agent_id, %{agent | status: :stopped})
        else
          socket.assigns.agents
        end

      socket
      |> assign(:agents, agents)
      |> add_signal("rho.agent.stopped", data)
    end
  end

  def project(socket, %{type: "rho.task.requested" = type, data: data}) do
    msg = %{
      id: msg_id(),
      role: :system,
      type: :delegation,
      agent_id: data[:agent_id],
      target_role: data[:role],
      task: data[:task],
      status: :pending,
      content: "Delegated task"
    }

    socket
    |> append_message(msg)
    |> add_signal(type, data)
  end

  def project(socket, %{type: "rho.task.completed" = type, data: data}) do
    msg = %{
      id: msg_id(),
      role: :system,
      type: :delegation,
      agent_id: data[:agent_id],
      status: :ok,
      result: data[:result],
      content: "Task completed"
    }

    socket
    |> append_message(msg)
    |> add_signal(type, data)
  end

  def project(socket, %{type: type, data: data}) do
    add_signal(socket, type, data)
  end

  # Catch-all for unexpected shapes
  def project(socket, _signal), do: socket

  # --- Private projections ---

  defp project_text_delta(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)
    text = data[:text] || ""

    # Buffer chunks for push_event to JS hook
    inflight = socket.assigns.inflight

    entry =
      Map.get(inflight, agent_id, %{
        agent_id: agent_id,
        turn_id: data[:turn_id],
        chunks: [],
        envelope: nil
      })

    entry = %{entry | chunks: entry.chunks ++ [text]}

    # Lenient-parse the accumulated buffer for an envelope preview (action /
    # thinking). This is best-effort — on failure we keep the previous
    # envelope summary, if any, so the UI doesn't flicker.
    buffer = IO.iodata_to_binary(entry.chunks)

    envelope =
      case RhoWeb.StreamEnvelope.analyze(buffer) do
        {:envelope, summary} -> summary
        :no_envelope -> entry[:envelope]
      end

    entry = Map.put(entry, :envelope, envelope)
    inflight = Map.put(inflight, agent_id, entry)

    socket
    |> clear_pending_response(agent_id)
    |> assign(:inflight, inflight)
    |> push_event("text-chunk", %{agent_id: agent_id, text: text})
  end

  defp project_tool_start(socket, data) do
    # Skip internal tools that don't add value in the UI
    if data[:name] in ["end_turn", "finish", "present_ui"] do
      socket
    else
      agent_id = data[:agent_id] || primary_agent_id(socket)

      socket = clear_pending_response(socket, agent_id)

      # Flush inflight chunks into a thinking message before the tool call
      socket = flush_inflight_to_thinking(socket, agent_id)

      msg = %{
        id: msg_id(),
        role: :assistant,
        type: :tool_call,
        name: data[:name],
        args: data[:args],
        call_id: data[:call_id],
        agent_id: agent_id,
        status: :pending,
        content: "Tool: #{data[:name]}"
      }

      append_message(socket, msg)
    end
  end

  defp project_tool_result(socket, data) do
    if data[:name] in ["end_turn", "finish", "present_ui"] do
      socket
    else
      call_id = data[:call_id]
      agent_id = data[:agent_id] || primary_agent_id(socket)
      status = data[:status] || :ok

      # Update the existing pending tool_call message instead of appending a new one
      socket =
        if call_id do
          update_message_by(socket, &(&1[:call_id] == call_id), fn msg ->
            Map.merge(msg, %{output: data[:output], status: status})
          end)
        else
          # Fallback: no call_id match, append as before
          msg = %{
            id: msg_id(),
            role: :assistant,
            type: :tool_call,
            name: data[:name],
            output: data[:output],
            call_id: call_id,
            agent_id: agent_id,
            status: status,
            content: "Tool result: #{data[:name]}"
          }

          append_message(socket, msg)
        end

      # If tool output contains images, append them as a visible assistant message
      socket =
        case RhoWeb.ChatComponents.extract_image_uris(data[:output]) do
          [] ->
            socket

          image_uris ->
            img_msg = %{
              id: msg_id(),
              role: :assistant,
              type: :image,
              images: image_uris,
              agent_id: agent_id,
              content: "Visualization"
            }

            append_message(socket, img_msg)
        end

      # Reset token counters when memory is cleared
      if data[:name] == "clear_memory" and data[:status] == :ok do
        socket
        |> assign(:total_input_tokens, 0)
        |> assign(:total_output_tokens, 0)
        |> assign(:total_cost, 0.0)
        |> assign(:total_cached_tokens, 0)
        |> assign(:total_reasoning_tokens, 0)
        |> assign(:step_input_tokens, 0)
        |> assign(:step_output_tokens, 0)
      else
        socket
      end
    end
  end

  defp project_ui_spec_delta(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)
    spec = data[:spec]
    title = data[:title]
    delta_msg_id = data[:message_id]

    ui_streams = socket.assigns.ui_streams

    case Map.get(ui_streams, delta_msg_id) do
      nil ->
        # First delta — create the message and start the stream queue
        mid = delta_msg_id || msg_id()

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

        stream = %{queue: [], final_spec: nil}
        ui_streams = Map.put(ui_streams, mid, stream)

        # Schedule the first tick to start draining
        Process.send_after(self(), {:ui_spec_tick, mid}, 40)

        socket
        |> assign(:ui_streams, ui_streams)
        |> append_message(msg)

      %{} = stream ->
        # Subsequent delta — enqueue for the tick loop to apply
        stream = %{stream | queue: stream.queue ++ [spec]}
        ui_streams = Map.put(ui_streams, delta_msg_id, stream)
        assign(socket, :ui_streams, ui_streams)
    end
  end

  defp project_ui_spec(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)
    delta_msg_id = data[:message_id]
    ui_streams = socket.assigns.ui_streams

    socket =
      case Map.get(ui_streams, delta_msg_id) do
        %{queue: []} = _stream ->
          # Queue already drained — finalize immediately
          socket
          |> update_message(delta_msg_id, fn msg ->
            %{msg | spec: data[:spec], title: data[:title] || msg.title, streaming: false}
          end)
          |> assign(:ui_streams, Map.delete(ui_streams, delta_msg_id))

        %{} = stream ->
          # Tick loop still running — store final spec for it to apply when done
          stream = %{stream | final_spec: data[:spec]}
          assign(socket, :ui_streams, Map.put(ui_streams, delta_msg_id, stream))

        nil ->
          # No stream existed — render complete spec directly
          msg = %{
            id: delta_msg_id || msg_id(),
            role: :assistant,
            type: :ui,
            agent_id: agent_id,
            title: data[:title],
            spec: data[:spec],
            streaming: false,
            content: "Structured UI"
          }

          append_message(socket, msg)
      end

    add_signal(socket, "ui_spec", data)
  end

  defp project_message_sent(socket, data) do
    from = data[:from]
    to = data[:to]
    message = data[:message]

    # Look up sender role for display
    from_label =
      case Rho.Agent.Registry.get(from) do
        %{role: role} -> to_string(role)
        _ -> from || "unknown"
      end

    # Show the message in the target agent's tab as an incoming message
    target_agent_id =
      case Rho.Agent.Worker.whereis(to) do
        pid when is_pid(pid) ->
          to

        nil ->
          # Try resolving as role — use to_existing_atom to prevent atom table exhaustion
          role_atom =
            try do
              String.to_existing_atom(to)
            rescue
              ArgumentError -> nil
            end

          case role_atom && Rho.Agent.Registry.find_by_role(socket.assigns.session_id, role_atom) do
            [agent | _] -> agent.agent_id
            _ -> to
          end
      end

    msg = %{
      id: msg_id(),
      role: :user,
      type: :text,
      content: message,
      agent_id: target_agent_id,
      from_agent: from_label
    }

    socket
    |> append_message(msg)
    |> add_signal("message_sent", data)
  end

  defp project_turn_started(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)
    agents = update_agent_status(socket.assigns.agents, agent_id, :busy)

    socket
    |> clear_pending_response(agent_id)
    |> assign(:agents, agents)
    |> add_signal("turn.started", data)
  end

  defp project_turn_finished(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)

    socket = clear_pending_response(socket, agent_id)

    # Flush any remaining streamed chunks as a thinking message
    socket = flush_inflight_to_thinking(socket, agent_id)

    inflight = Map.delete(socket.assigns.inflight, agent_id)
    agents = update_agent_status(socket.assigns.agents, agent_id, :idle)

    # Add final message if there's a text result, or error message if failed
    socket =
      case data[:result] do
        {:ok, text} when is_binary(text) and text != "" ->
          msg = %{
            id: msg_id(),
            role: :assistant,
            type: :text,
            content: text,
            agent_id: agent_id
          }

          append_message(socket, msg)

        {:error, reason} ->
          msg = %{
            id: msg_id(),
            role: :system,
            type: :error,
            content: format_error(reason),
            agent_id: agent_id
          }

          append_message(socket, msg)

        _ ->
          socket
      end

    socket
    |> assign(:inflight, inflight)
    |> assign(:agents, agents)
    |> push_event("stream-end", %{agent_id: agent_id})
    |> add_signal("turn.finished", data)
  end

  defp project_usage(socket, data) do
    usage = data[:usage] || %{}
    input = usage[:input_tokens] || Map.get(usage, "input_tokens", 0)
    output = usage[:output_tokens] || Map.get(usage, "output_tokens", 0)
    cost = usage[:total_cost] || Map.get(usage, "total_cost", 0.0)
    cached = usage[:cached_tokens] || Map.get(usage, "cached_tokens", 0)
    reasoning = usage[:reasoning_tokens] || Map.get(usage, "reasoning_tokens", 0)

    socket
    |> assign(:total_input_tokens, socket.assigns.total_input_tokens + input)
    |> assign(:total_output_tokens, socket.assigns.total_output_tokens + output)
    |> assign(:total_cost, socket.assigns.total_cost + (cost || 0.0))
    |> assign(:total_cached_tokens, socket.assigns.total_cached_tokens + cached)
    |> assign(:total_reasoning_tokens, socket.assigns.total_reasoning_tokens + reasoning)
    |> assign(:step_input_tokens, input)
    |> assign(:step_output_tokens, output)
  end

  defp project_before_llm(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)
    projection = data[:projection] || %{}

    # Store the latest projection keyed by agent_id
    debug_projections =
      Map.put(socket.assigns[:debug_projections] || %{}, agent_id, %{
        context: format_projection_context(projection[:context] || []),
        tools: format_projection_tools(projection[:tools] || []),
        step: projection[:step],
        timestamp: System.monotonic_time(:millisecond),
        raw_message_count: length(projection[:context] || []),
        raw_tool_count: length(projection[:tools] || [])
      })

    assign(socket, :debug_projections, debug_projections)
  end

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

  defp project_step_start(socket, data) do
    agent_id = data[:agent_id] || primary_agent_id(socket)
    step = data[:step]
    max_steps = data[:max_steps]

    agents =
      case Map.get(socket.assigns.agents, agent_id) do
        nil ->
          socket.assigns.agents

        agent ->
          Map.put(socket.assigns.agents, agent_id, %{agent | step: step, max_steps: max_steps})
      end

    assign(socket, :agents, agents)
  end

  defp flush_inflight_to_thinking(socket, agent_id) do
    case Map.get(socket.assigns.inflight, agent_id) do
      %{chunks: chunks} when chunks != [] ->
        raw = Enum.join(chunks)

        if String.trim(raw) != "" do
          thinking_msg = %{
            id: msg_id(),
            role: :assistant,
            type: :thinking,
            content: raw,
            agent_id: agent_id
          }

          # Clear chunks but keep the inflight entry (stream-end will remove it)
          inflight =
            Map.put(socket.assigns.inflight, agent_id, %{
              Map.get(socket.assigns.inflight, agent_id)
              | chunks: []
            })

          socket
          |> assign(:inflight, inflight)
          |> push_event("stream-end", %{agent_id: agent_id})
          |> append_message(thinking_msg)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp update_agent_status(agents, agent_id, status) do
    case Map.get(agents, agent_id) do
      nil -> agents
      agent -> Map.put(agents, agent_id, %{agent | status: status})
    end
  end

  defp clear_pending_response(socket, agent_id) do
    pending = socket.assigns[:pending_response] || MapSet.new()
    assign(socket, :pending_response, MapSet.delete(pending, agent_id))
  end

  defp add_signal(socket, type, data) do
    signal = %{
      id: msg_id(),
      type: type,
      agent_id: data[:agent_id],
      timestamp: System.monotonic_time(:millisecond),
      correlation_id: data[:correlation_id]
    }

    signals = socket.assigns.signals
    signals = Enum.take([signal | signals], 500)

    socket
    |> assign(:signals, signals)
    |> push_event("signal", signal)
  end

  @doc "Appends a message to the agent_messages map in socket assigns."
  def append_message(socket, msg) do
    agent_id = msg[:agent_id] || primary_agent_id(socket)
    agent_messages = socket.assigns.agent_messages
    current = Map.get(agent_messages, agent_id, [])
    updated = Map.put(agent_messages, agent_id, Enum.take(current ++ [msg], -200))
    assign(socket, :agent_messages, updated)
  end

  defp update_message(socket, msg_id, update_fn) do
    agent_messages = socket.assigns.agent_messages

    updated =
      Map.new(agent_messages, fn {agent_id, msgs} ->
        {agent_id,
         Enum.map(msgs, fn msg ->
           if msg.id == msg_id, do: update_fn.(msg), else: msg
         end)}
      end)

    assign(socket, :agent_messages, updated)
  end

  defp update_message_by(socket, pred, update_fn) do
    agent_messages = socket.assigns.agent_messages

    updated =
      Map.new(agent_messages, fn {agent_id, msgs} ->
        {agent_id,
         Enum.map(msgs, fn msg ->
           if pred.(msg), do: update_fn.(msg), else: msg
         end)}
      end)

    assign(socket, :agent_messages, updated)
  end

  defp format_error(%Mint.TransportError{reason: reason}),
    do: "Connection error: #{inspect(reason)}. The request will be retried automatically."

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  defp primary_agent_id(socket) do
    case socket.assigns.session_id do
      nil -> "primary"
      sid -> Rho.Agent.Primary.agent_id(sid)
    end
  end

  defp msg_id do
    System.unique_integer([:positive]) |> Integer.to_string()
  end
end
