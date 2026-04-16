defmodule RhoWeb.ObservatoryProjection do
  @moduledoc """
  Projects signal bus events into Observatory LiveView assigns.
  Builds a chronological discussion timeline from agent interactions.
  """

  import Phoenix.Component, only: [assign: 3]

  @max_discussion_entries 500
  @noisy_tools ~w(end_turn stop_agent present_ui list_agents get_agent_card)

  # --- Agent lifecycle ---

  def project(socket, "rho.agent.started", data) do
    with_session_guard(socket, data, fn ->
      role = safe_to_atom(data[:role] || data["role"])
      agent_id = data[:agent_id] || data["agent_id"]
      project_agent_started(socket, data, role, agent_id)
    end)
  end

  def project(socket, "rho.agent.stopped", data) do
    with_session_guard(socket, data, fn ->
      agent_id = data[:agent_id] || data["agent_id"]

      agents =
        Map.update(socket.assigns.agents, agent_id, %{alive: false, status: :stopped}, fn a ->
          Map.merge(a, %{alive: false, status: :stopped})
        end)

      # Only show "left the session" for agents we know about
      if Map.has_key?(socket.assigns.agents, agent_id) do
        socket
        |> assign(:agents, agents)
        |> append_entry(:agent_event, agent_id, "left the session", meta: %{event: :stopped})
      else
        assign(socket, :agents, agents)
      end
    end)
  end

  # --- Hiring domain events ---

  def project(socket, "rho.hiring.scores.submitted", data) do
    role = data[:role] || data["role"]
    role_key = score_column(role)
    scores_data = data[:scores] || data["scores"] || []

    scores =
      Enum.reduce(scores_data, socket.assigns.scores, fn entry, acc ->
        id = entry["id"] || entry[:id]
        score = entry["score"] || entry[:score]

        Map.update(
          acc,
          id,
          %{name: id, technical: nil, culture: nil, compensation: nil, avg: nil},
          fn row ->
            row
            |> Map.put(role_key, score)
            |> recompute_avg()
          end
        )
      end)

    # Format scores for the timeline
    summary =
      scores_data
      |> Enum.map(fn e -> "#{e["id"] || e[:id]}: #{e["score"] || e[:score]}" end)
      |> Enum.join(", ")

    socket
    |> assign(:scores, scores)
    |> append_entry(
      :tool_result,
      find_agent_for_role(socket, role),
      "Submitted scores: #{summary}",
      meta: %{tool: "submit_scores", status: :ok}
    )
  end

  def project(socket, "rho.hiring.round.started", data) do
    round = data[:round] || data["round"] || 0

    socket
    |> assign(:round, round)
    |> assign(:status, :running)
    |> append_entry(:marker, nil, "Round #{round} started", meta: %{kind: :round})
  end

  def project(socket, "rho.hiring.simulation.completed", _data) do
    socket
    |> assign(:status, :completed)
    |> append_entry(:marker, nil, "Simulation complete", meta: %{kind: :complete})
  end

  # --- Turn finished (top-level signal, not under rho.session.*) ---

  def project(socket, "rho.turn.finished", data) do
    raw = to_string(data[:result] || data["result"] || "")
    text = extract_result_text(raw)
    agent_id = data[:agent_id] || data["agent_id"]

    if String.length(text) > 100 do
      append_entry(socket, :turn_end, agent_id, text, meta: %{})
    else
      socket
    end
  end

  # --- Session events (the core discussion data) ---

  def project(socket, "rho.session." <> _ = type, data) when is_map(data) do
    cond do
      # Inter-agent messages — the heart of the discussion
      String.contains?(type, "message_sent") ->
        from = data[:from] || data[:agent_id]
        to = data[:to]
        message = to_string(data[:message] || "")

        socket
        |> record_edge(from, to)
        |> append_entry(:message, from, message, meta: %{to: to, direction: :direct})

      String.contains?(type, "broadcast") ->
        from = data[:from] || data[:agent_id]
        message = to_string(data[:message] || "")

        # Record edges to all other agents
        socket
        |> record_broadcast_edges(from)
        |> append_entry(:message, from, message, meta: %{to: :all, direction: :broadcast})

      # Agent reasoning text — shown as thinking
      String.contains?(type, "llm_text") ->
        agent_id = data[:agent_id]
        text = data[:text] || ""

        if String.trim(text) != "" do
          append_or_extend_text(socket, agent_id, text)
        else
          socket
        end

      # Tool usage
      String.contains?(type, "tool_start") ->
        tool_name = data[:name] || "unknown"
        args_preview = format_tool_args(data[:args])

        # Skip noisy infrastructure tools
        if tool_name in @noisy_tools do
          socket
        else
          append_entry(socket, :tool_use, data[:agent_id], tool_name,
            meta: %{tool: tool_name, args: args_preview}
          )
        end

      String.contains?(type, "tool_result") ->
        tool = data[:name] || ""
        # Skip results from filtered tools
        if tool in @noisy_tools do
          socket
        else
          output = String.slice(to_string(data[:output] || ""), 0, 300)
          status = data[:status] || :ok

          append_entry(socket, :tool_result, data[:agent_id], output,
            meta: %{tool: tool, status: status}
          )
        end

      # Turn boundaries
      String.contains?(type, "turn_started") ->
        socket

      String.contains?(type, "turn_finished") ->
        # Only show turn results that have substantial content (skip short acks)
        raw = to_string(data[:result] || "")
        text = extract_result_text(raw)

        if String.length(text) > 100 do
          append_entry(socket, :turn_end, data[:agent_id], text, meta: %{})
        else
          socket
        end

      # Step markers (skip — too noisy)
      true ->
        socket
    end
  end

  def project(socket, _type, _data), do: socket

  # --- Agent started helper ---

  defp project_agent_started(socket, data, role, agent_id) do
    agent_name = safe_to_atom(data[:agent_name]) || role

    agent = %{
      agent_id: agent_id,
      role: role,
      agent_name: agent_name,
      status: :idle,
      depth: data[:depth] || data["depth"] || 0,
      pid: Rho.Agent.Worker.whereis(agent_id),
      current_tool: nil,
      current_step: nil,
      message_queue_len: 0,
      heap_size: 0,
      reductions: 0,
      prev_reductions: 0,
      reductions_per_sec: 0,
      token_usage: %{input: 0, output: 0},
      alive: true
    }

    socket
    |> put_agent(agent_id, agent)
    |> append_entry(:agent_event, agent_id, "joined the session",
      meta: %{event: :started, role: role}
    )
  end

  # --- Entry builders ---

  defp put_agent(socket, agent_id, agent) do
    agents = Map.put(socket.assigns.agents, agent_id, agent)
    assign(socket, :agents, agents)
  end

  defp append_entry(socket, type, agent_id, content, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})
    counter = socket.assigns.discussion_counter + 1
    agent = Map.get(socket.assigns.agents, agent_id)

    entry = %{
      id: counter,
      type: type,
      agent_id: agent_id,
      agent_name: agent_name(agent, agent_id),
      content: content,
      meta: meta,
      at: System.monotonic_time(:millisecond)
    }

    discussion = [entry | socket.assigns.discussion] |> Enum.take(@max_discussion_entries)

    socket
    |> assign(:discussion, discussion)
    |> assign(:discussion_counter, counter)
  end

  # Extend the last text entry if from the same agent, otherwise create new
  defp append_or_extend_text(socket, agent_id, text) do
    case socket.assigns.discussion do
      [%{type: :thinking, agent_id: ^agent_id} = last | rest] ->
        updated = %{last | content: last.content <> text}
        assign(socket, :discussion, [updated | rest])

      _ ->
        append_entry(socket, :thinking, agent_id, text)
    end
  end

  # --- Helpers ---

  defp agent_name(%{agent_name: name}, _id), do: name
  defp agent_name(_, id) when is_binary(id), do: id
  defp agent_name(_, _), do: "unknown"

  defp with_session_guard(socket, data, fun) do
    session_id = data[:session_id] || data["session_id"]

    if session_id && socket.assigns[:session_id] && session_id != socket.assigns.session_id do
      socket
    else
      fun.()
    end
  end

  defp find_agent_for_role(socket, role) when is_atom(role) do
    case Enum.find(socket.assigns.agents, fn {_id, a} -> a.agent_name == role end) do
      {id, _} -> id
      nil -> nil
    end
  end

  defp find_agent_for_role(socket, role) when is_binary(role) do
    atom_role = String.to_existing_atom(role)
    find_agent_for_role(socket, atom_role)
  rescue
    ArgumentError -> nil
  end

  defp find_agent_for_role(_, _), do: nil

  defp score_column(:technical_evaluator), do: :technical
  defp score_column(:culture_evaluator), do: :culture
  defp score_column(:compensation_evaluator), do: :compensation
  defp score_column("technical_evaluator"), do: :technical
  defp score_column("culture_evaluator"), do: :culture
  defp score_column("compensation_evaluator"), do: :compensation

  defp score_column(role) when is_binary(role) do
    cond do
      String.contains?(role, "technical") -> :technical
      String.contains?(role, "culture") -> :culture
      String.contains?(role, "compensation") -> :compensation
      true -> :other
    end
  end

  defp score_column(_), do: :other

  defp recompute_avg(row) do
    values =
      [row[:technical], row[:culture], row[:compensation]]
      |> Enum.reject(&is_nil/1)

    avg = if values == [], do: nil, else: Enum.sum(values) / length(values)
    Map.put(row, :avg, avg)
  end

  # Extract readable text from "{:ok, \"the actual text\"}" format
  defp extract_result_text("{:ok, \"" <> rest) do
    # Strip the trailing "}
    rest
    |> String.trim_trailing("\"}")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
  end

  defp extract_result_text("{:ok, " <> rest), do: String.trim_trailing(rest, "}")
  defp extract_result_text(text), do: text

  defp format_tool_args(nil), do: nil

  defp format_tool_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} ->
      v_str =
        if is_binary(v) and String.length(v) > 80,
          do: String.slice(v, 0, 80) <> "...",
          else: inspect(v)

      "#{k}: #{v_str}"
    end)
    |> Enum.join(", ")
  end

  defp format_tool_args(_), do: nil

  defp record_edge(socket, from, to) when is_nil(from) or is_nil(to), do: socket

  defp record_edge(socket, from, to) do
    edges = Map.get(socket.assigns, :edges, %{})
    key = {from, to}
    edges = Map.update(edges, key, 1, &(&1 + 1))

    # Track recent edges for animation (keep last 8, expire after render)
    recent = Map.get(socket.assigns, :recent_edges, [])
    recent = [{from, to, System.monotonic_time(:millisecond)} | recent] |> Enum.take(8)

    socket
    |> assign(:edges, edges)
    |> assign(:recent_edges, recent)
  end

  defp record_broadcast_edges(socket, from) do
    agents = socket.assigns.agents

    Enum.reduce(agents, socket, fn {agent_id, _agent}, acc ->
      if agent_id != from do
        record_edge(acc, from, agent_id)
      else
        acc
      end
    end)
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(a) when is_atom(a), do: a

  defp safe_to_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> s
    end
  end

  defp safe_to_atom(_), do: nil
end
