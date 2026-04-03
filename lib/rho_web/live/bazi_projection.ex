defmodule RhoWeb.BaziProjection do
  @moduledoc """
  Projects structured BaZi domain events into LiveView assigns.
  No freeform text parsing — only typed events from the signal bus.
  """

  import Phoenix.Component, only: [assign: 3]

  # Normalize session-scoped signal types to generic keys for projection.
  # e.g. "rho.bazi.session_123.round.started" -> "rho.bazi.round.started"
  def project(socket, type, data) do
    normalized = normalize_type(socket.assigns[:session_id], type)
    do_project(socket, normalized, data)
  end

  defp normalize_type(nil, type), do: type

  defp normalize_type(sid, type) do
    String.replace(type, ".#{sid}.", ".")
  end

  # --- Simulation lifecycle ---

  defp do_project(socket, "rho.bazi.simulation.started", data) do
    socket
    |> assign(:simulation_status, :running)
    |> assign(:user_options, data[:options] || data["options"] || socket.assigns[:user_options] || [])
    |> assign(:user_question, data[:question] || data["question"] || socket.assigns[:user_question] || "")
  end

  defp do_project(socket, "rho.bazi.simulation.completed", _data) do
    assign(socket, :simulation_status, :completed)
  end

  # --- Chart parsing ---

  defp do_project(socket, "rho.bazi.chart.parsed", data) do
    chart_data = data[:chart_data] || data["chart_data"]
    assign(socket, :chart_data, chart_data)
  end

  defp do_project(socket, "rho.bazi.chart.diffs", data) do
    timeline = socket.assigns[:timeline] || []

    diffs = data[:diffs] || data["diffs"] || []
    diff_text = Enum.join(diffs, "\n")

    entry = %{
      type: :chart_validation,
      text: "Chart cross-validation found differences:\n#{diff_text}",
      round: 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    assign(socket, :timeline, timeline ++ [entry])
  end

  # --- Chairman messages ---

  defp do_project(socket, "rho.bazi.chairman.message", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :chairman,
      agent_id: data[:agent_id],
      text: data[:text] || "",
      round: socket.assigns[:round] || 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    assign(socket, :timeline, timeline ++ [entry])
  end

  defp do_project(socket, "rho.bazi.chairman.summary", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :chairman_summary,
      agent_id: data[:agent_id],
      text: data[:text] || "",
      round: socket.assigns[:round] || 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:timeline, timeline ++ [entry])
    |> assign(:phase, :completed)
    |> assign(:chairman_ready, true)
  end

  defp do_project(socket, "rho.bazi.chairman.reply", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :chairman_reply,
      agent_id: data[:agent_id],
      text: data[:text] || "",
      round: socket.assigns[:round] || 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    assign(socket, :timeline, timeline ++ [entry])
  end

  # --- Dimensions ---

  defp do_project(socket, "rho.bazi.dimensions.merged", data) do
    timeline = socket.assigns[:timeline] || []
    merged = data[:merged] || data["merged"] || []

    entry = %{
      type: :chairman,
      agent_id: nil,
      text: "Proposed dimensions: #{Enum.join(merged, ", ")}",
      round: 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:proposed_dimensions, merged)
    |> assign(:phase, :awaiting_dimension_approval)
    |> assign(:timeline, timeline ++ [entry])
  end

  defp do_project(socket, "rho.bazi.dimensions.approved", data) do
    dims = data[:dimensions] || data["dimensions"] || []
    assign(socket, :dimensions, dims)
  end

  # --- Rounds ---

  defp do_project(socket, "rho.bazi.round.started", data) do
    timeline = socket.assigns[:timeline] || []
    round_num = data[:round] || data["round"] || 1

    entry = %{
      type: :round_start,
      text: "Round #{round_num}",
      round: round_num,
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:round, round_num)
    |> assign(:phase, :"round_#{round_num}")
    |> assign(:simulation_status, :running)
    |> assign(:chairman_ready, false)
    |> assign(:timeline, timeline ++ [entry])
  end

  # --- Scoring ---

  defp do_project(socket, "rho.bazi.scores.submitted", data) do
    # Ignore late scores after simulation completed
    if socket.assigns[:simulation_status] == :completed do
      socket
    else
      do_project_scores(socket, data)
    end
  end

  # --- User info requests ---

  defp do_project(socket, "rho.bazi.user_info.requested", data) do
    question = data[:question] || data["question"] || ""
    role = data[:from_advisor] || data["from_advisor"] || data[:role] || data["role"]

    assign(socket, :pending_user_question, %{question: question, from: role})
  end

  defp do_project(socket, "rho.bazi.user_info.replied", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :user_reply,
      text: data[:answer] || data["answer"] || "",
      original_question: data[:original_question] || data["original_question"] || "",
      round: socket.assigns[:round] || 0,
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:pending_user_question, nil)
    |> assign(:timeline, timeline ++ [entry])
  end

  # --- Agent lifecycle ---

  defp do_project(socket, "rho.agent.started", data) do
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

  defp do_project(socket, "rho.agent.stopped", data) do
    agents =
      Map.update(socket.assigns.agents, data.agent_id, %{}, fn a ->
        %{a | alive: false, status: :stopped}
      end)

    assign(socket, :agents, agents)
  end

  # --- Session events (activity tracking for drawer) ---

  defp do_project(socket, "rho.session." <> _ = type, data) when is_map(data) do
    cond do
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

  # --- Catch-all ---

  defp do_project(socket, _type, _data), do: socket

  # --- Score projection helpers ---

  defp do_project_scores(socket, data) do
    role = data[:role] || data["role"]
    advisor_key = advisor_key_for(role)
    scores_data = data[:scores] || data["scores"] || %{}
    round_num = data[:round] || data["round"] || socket.assigns[:round] || 0

    # scores_data is %{option_name => %{dim => score, "rationale" => "..."}}
    # We store as %{option_name => %{advisor_key => %{dim => score}}}
    scores =
      Enum.reduce(scores_data, socket.assigns.scores, fn {option_name, dim_scores}, acc ->
        dim_map =
          dim_scores
          |> Enum.reject(fn {k, _v} -> k in ["rationale", :rationale] end)
          |> Map.new()

        option_scores = Map.get(acc, option_name, %{})
        updated_option = Map.put(option_scores, advisor_key, dim_map)
        Map.put(acc, option_name, updated_option)
      end)

    # Build timeline entries
    timeline = socket.assigns[:timeline] || []

    timeline_entries =
      Enum.map(scores_data, fn {option_name, dim_scores} ->
        rationale = dim_scores["rationale"] || dim_scores[:rationale] || ""

        # Compute a composite score for display
        numeric_scores =
          dim_scores
          |> Enum.reject(fn {k, _v} -> k in ["rationale", :rationale] end)
          |> Enum.map(fn {_k, v} -> v end)
          |> Enum.filter(&is_number/1)

        avg =
          if numeric_scores == [],
            do: nil,
            else: Enum.sum(numeric_scores) / length(numeric_scores)

        %{
          type: :score,
          advisor: advisor_key,
          role: role,
          option: option_name,
          score: avg && Float.round(avg, 1),
          text: String.slice(to_string(rationale), 0, 150),
          round: round_num,
          timestamp: System.monotonic_time(:millisecond)
        }
      end)

    socket
    |> assign(:scores, scores)
    |> assign(:timeline, timeline ++ timeline_entries)
  end

  # --- Activity helpers (for agent drawer) ---

  defp append_activity_text(socket, nil, _text), do: socket
  defp append_activity_text(socket, agent_id, text) do
    activity = socket.assigns[:activity] || %{}
    agent_activity = Map.get(activity, agent_id, %{text: "", entries: []})

    new_text = agent_activity.text <> text
    new_text = if String.length(new_text) > 1500, do: String.slice(new_text, -1500, 1500), else: new_text

    updated = %{agent_activity | text: new_text}
    assign(socket, :activity, Map.put(activity, agent_id, updated))
  end

  defp add_activity_entry(socket, nil, _type, _content), do: socket
  defp add_activity_entry(socket, agent_id, type, content) do
    activity = socket.assigns[:activity] || %{}
    agent_activity = Map.get(activity, agent_id, %{text: "", entries: []})

    entry = %{type: type, content: content, at: System.monotonic_time(:millisecond)}

    updated = case type do
      :step -> agent_activity
      _ -> %{agent_activity | entries: [entry | agent_activity.entries] |> Enum.take(10)}
    end

    assign(socket, :activity, Map.put(activity, agent_id, updated))
  end

  defp advisor_key_for(:bazi_advisor_qwen), do: :qwen
  defp advisor_key_for(:bazi_advisor_deepseek), do: :deepseek
  defp advisor_key_for(:bazi_advisor_gpt), do: :gpt
  defp advisor_key_for("bazi_advisor_qwen"), do: :qwen
  defp advisor_key_for("bazi_advisor_deepseek"), do: :deepseek
  defp advisor_key_for("bazi_advisor_gpt"), do: :gpt
  defp advisor_key_for(role) when is_atom(role), do: role
  defp advisor_key_for(role) when is_binary(role), do: String.to_atom(role)
  defp advisor_key_for(_), do: :unknown
end
