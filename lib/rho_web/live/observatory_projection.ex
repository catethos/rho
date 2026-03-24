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
    Logger.info("[Projection] scores.submitted role=#{inspect(role)} role_key=#{role_key} scores=#{inspect(data[:scores] || data["scores"])}")

    scores_data = data[:scores] || data["scores"] || []

    scores =
      Enum.reduce(scores_data, socket.assigns.scores, fn entry, acc ->
        id = entry["id"] || entry[:id]
        score = entry["score"] || entry[:score]

        Map.update(acc, id, %{name: id, technical: nil, culture: nil, compensation: nil, avg: nil}, fn row ->
          row
          |> Map.put(role_key, score)
          |> recompute_avg()
        end)
      end)

    assign(socket, :scores, scores)
  end

  def project(socket, "rho.hiring.round.started", data) do
    socket
    |> assign(:round, data.round)
    |> assign(:simulation_status, :running)
  end

  def project(socket, "rho.hiring.simulation.completed", _data) do
    assign(socket, :simulation_status, :completed)
  end

  def project(socket, "rho.session." <> _ = type, data) when is_map(data) do
    cond do
      String.contains?(type, "broadcast") ->
        add_signal(socket, data[:from], :all, data[:message])

      String.contains?(type, "message_sent") ->
        add_signal(socket, data[:from], data[:to], data[:message])

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

  defp add_signal(socket, from, to, message) do
    signal = %{
      id: System.unique_integer([:positive]) |> to_string(),
      timestamp: System.monotonic_time(:millisecond),
      from_agent: from,
      to_agent: to,
      type: if(to == :all, do: "broadcast", else: "direct"),
      preview: String.slice(to_string(message || ""), 0, 120)
    }

    signals = [signal | socket.assigns.signals] |> Enum.take(100)
    assign(socket, :signals, signals)
  end
end
