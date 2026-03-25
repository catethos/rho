defmodule RhoWeb.ObservatoryProjection do
  @moduledoc """
  Projects structured domain events into Observatory LiveView assigns.
  No freeform text parsing — only typed events.
  """

  import Phoenix.Component, only: [assign: 3]

  def project(socket, "rho.agent.started", data) do
    agent = %{
      agent_id: data.agent_id,
      role: data.role,
      agent_name: data[:agent_name] || data.role,
      status: :idle,
      depth: data[:depth] || 0,
      pid: Rho.Agent.Worker.whereis(data.agent_id),
      current_tool: nil,
      current_step: nil,
      message_queue_len: 0,
      heap_size: 0,
      reductions: 0,
      prev_reductions: 0,
      reductions_per_sec: 0,
      alive: true
    }

    agents = Map.put(socket.assigns.agents, data.agent_id, agent)
    assign(socket, :agents, agents)
  end

  def project(socket, "rho.agent.stopped", data) do
    agents =
      Map.update(socket.assigns.agents, data.agent_id, %{}, fn a ->
        %{a | alive: false, status: :stopped}
      end)

    assign(socket, :agents, agents)
  end

  def project(socket, "rho.hiring.scores.submitted", data) do
    require Logger
    role = data[:role] || data["role"]
    role_key = score_column(role)
    Logger.info("[Projection] scores.submitted role=#{inspect(role)} role_key=#{role_key}")

    scores_data = data[:scores] || data["scores"] || []

    # Update scores with prev_* tracking
    scores =
      Enum.reduce(scores_data, socket.assigns.scores, fn entry, acc ->
        id = entry["id"] || entry[:id]
        score = entry["score"] || entry[:score]
        prev_key = :"prev_#{role_key}"

        Map.update(acc, id, %{name: id, technical: nil, culture: nil, compensation: nil, avg: nil,
                               prev_technical: nil, prev_culture: nil, prev_compensation: nil}, fn row ->
          row
          |> Map.put(prev_key, row[role_key])
          |> Map.put(role_key, score)
          |> recompute_avg()
        end)
      end)

    # Build timeline entries from the updated scores
    timeline_entries =
      Enum.map(scores_data, fn entry ->
        id = entry["id"] || entry[:id]
        score = entry["score"] || entry[:score]
        prev = scores[id][:"prev_#{role_key}"]
        delta = if is_integer(prev), do: score - prev, else: nil
        rationale = entry["rationale"] || entry[:rationale] || ""

        %{
          type: :score,
          agent_role: role,
          agent_id: data[:agent_id],
          target: nil,
          text: String.slice(rationale, 0, 150),
          candidate_id: id,
          candidate_name: scores[id][:name] || id,
          score: score,
          delta: delta,
          round: socket.assigns[:round] || 0,
          timestamp: System.monotonic_time(:millisecond)
        }
      end)

    timeline = socket.assigns[:timeline] || []

    socket
    |> assign(:scores, scores)
    |> assign(:timeline, timeline ++ timeline_entries)
    |> maybe_update_convergence()
  end

  def project(socket, "rho.hiring.round.started", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :round_start,
      agent_role: nil,
      agent_id: nil,
      target: nil,
      text: "Round #{data.round}",
      candidate_id: nil,
      candidate_name: nil,
      score: nil,
      delta: nil,
      round: data.round,
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:round, data.round)
    |> assign(:simulation_status, :running)
    |> assign(:timeline, timeline ++ [entry])
  end

  def project(socket, "rho.hiring.simulation.completed", _data) do
    assign(socket, :simulation_status, :completed)
  end

  def project(socket, "rho.session." <> _ = type, data) when is_map(data) do
    cond do
      String.contains?(type, "broadcast") ->
        add_debate_to_timeline(socket, data[:from], :all, data[:message], data[:agent_id])

      String.contains?(type, "message_sent") ->
        add_debate_to_timeline(socket, data[:from], data[:to], data[:message], data[:agent_id])

      String.contains?(type, "text_delta") ->
        append_activity_text(socket, data[:agent_id], data[:text] || data[:delta] || "")

      String.contains?(type, "llm_text") ->
        append_activity_text(socket, data[:agent_id], data[:text] || "")

      String.contains?(type, "tool_start") ->
        tool_name = data[:name] || "unknown"
        add_activity_entry(socket, data[:agent_id], :tool_start, "Calling #{tool_name}...")

      String.contains?(type, "tool_result") ->
        output = String.slice(to_string(data[:output] || ""), 0, 200)
        status = data[:status] || :ok
        add_activity_entry(socket, data[:agent_id], :tool_result, "[#{status}] #{output}")

      String.contains?(type, "step_start") ->
        add_activity_entry(socket, data[:agent_id], :step, "Step #{data[:step]}")

      true ->
        socket
    end
  end

  def project(socket, _type, _data), do: socket

  # --- Helpers ---

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

  defp append_activity_text(socket, nil, _text), do: socket
  defp append_activity_text(socket, agent_id, text) do
    activity = socket.assigns.activity
    agent_activity = Map.get(activity, agent_id, %{text: "", entries: []})

    # Append to streaming text buffer (keep last 1500 chars)
    new_text = agent_activity.text <> text
    new_text = if String.length(new_text) > 1500, do: String.slice(new_text, -1500, 1500), else: new_text

    updated = %{agent_activity | text: new_text}
    assign(socket, :activity, Map.put(activity, agent_id, updated))
  end

  defp add_activity_entry(socket, nil, _type, _content), do: socket
  defp add_activity_entry(socket, agent_id, type, content) do
    activity = socket.assigns.activity
    agent_activity = Map.get(activity, agent_id, %{text: "", entries: []})

    entry = %{type: type, content: content, at: System.monotonic_time(:millisecond)}

    # Only record tool entries, skip step noise
    updated = case type do
      :step ->
        agent_activity
      _ ->
        %{agent_activity | entries: [entry | agent_activity.entries] |> Enum.take(10)}
    end

    assign(socket, :activity, Map.put(activity, agent_id, updated))
  end

  defp maybe_update_convergence(socket) do
    scores = socket.assigns.scores

    # Collect candidates that have all 3 evaluator scores
    complete =
      scores
      |> Map.values()
      |> Enum.filter(fn row ->
        row[:technical] != nil and row[:culture] != nil and row[:compensation] != nil
      end)

    if complete == [] do
      socket
    else
      # Convergence = 1 - (average spread / 100)
      # Spread = max - min across evaluators for each candidate
      avg_spread =
        complete
        |> Enum.map(fn row ->
          vals = [row.technical, row.culture, row.compensation]
          Enum.max(vals) - Enum.min(vals)
        end)
        |> then(fn spreads -> Enum.sum(spreads) / length(spreads) end)

      convergence = max(0.0, 1.0 - avg_spread / 100.0)

      history = socket.assigns.convergence_history ++ [convergence]
      assign(socket, :convergence_history, history)
    end
  end

  defp add_debate_to_timeline(socket, from, to, message, agent_id) do
    timeline = socket.assigns[:timeline] || []

    from_role =
      case socket.assigns[:agents][from] do
        %{role: role} -> role
        _ -> from
      end

    entry = %{
      type: :debate,
      agent_role: from_role,
      agent_id: agent_id || from,
      target: to,
      text: to_string(message || ""),
      candidate_id: nil,
      candidate_name: nil,
      score: nil,
      delta: nil,
      round: socket.assigns[:round] || 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    assign(socket, :timeline, timeline ++ [entry])
  end
end
