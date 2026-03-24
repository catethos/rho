defmodule RhoWeb.ObservatoryComponents do
  @moduledoc """
  UI components for the Hiring Committee Observatory.
  All server-rendered HTML + CSS. LiveView push_event + JS hooks only for auto-scroll.
  """

  use Phoenix.Component

  # --- Agent card ---

  attr :agent, :map, required: true

  def agent_card(assigns) do
    ~H"""
    <div class={"obs-agent-card #{status_class(@agent.status)} #{if !@agent.alive, do: "dead"}"}
         phx-click="select_agent" phx-value-agent-id={@agent.agent_id}>
      <div class="obs-agent-header">
        <span class={"obs-status-dot #{status_class(@agent.status)}"}></span>
        <span class="obs-agent-role"><%= format_role(@agent.agent_name) %></span>
      </div>
      <div class="obs-agent-stats">
        <div class="obs-stat">
          <span class="obs-stat-label">mailbox</span>
          <span class={"obs-stat-value #{if @agent.message_queue_len > 3, do: "hot"}"}>
            <%= @agent.message_queue_len || 0 %>
          </span>
        </div>
        <div class="obs-stat">
          <span class="obs-stat-label">heap</span>
          <span class="obs-stat-value"><%= format_heap(@agent.heap_size) %></span>
        </div>
        <div class="obs-stat">
          <span class="obs-stat-label">work</span>
          <span class="obs-stat-value"><%= format_reductions(@agent[:reductions_per_sec]) %></span>
        </div>
      </div>
      <div :if={@agent.current_tool} class="obs-agent-tool">
        <span class="obs-tool-indicator"></span>
        <%= @agent.current_tool %>
      </div>
      <div :if={@agent.current_step} class="obs-agent-step">
        step <%= @agent.current_step %>
      </div>
    </div>
    """
  end

  # --- Candidate scoreboard ---

  attr :scores, :map, required: true

  def scoreboard(assigns) do
    ~H"""
    <div class="obs-scoreboard">
      <h3 class="obs-section-title">Candidate Scores</h3>
      <table class="obs-score-table">
        <thead>
          <tr>
            <th>Candidate</th>
            <th title="Technical">T</th>
            <th title="Culture">C</th>
            <th title="Compensation">$</th>
            <th>Avg</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{_id, scores} <- sorted_scores(@scores)}>
            <td class="obs-candidate-name"><%= scores.name %></td>
            <td class={score_class(scores.technical)}><%= scores.technical || "—" %></td>
            <td class={score_class(scores.culture)}><%= scores.culture || "—" %></td>
            <td class={score_class(scores.compensation)}><%= scores.compensation || "—" %></td>
            <td class="obs-score-avg"><%= format_avg(scores.avg) %></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # --- Signal flow timeline ---

  attr :signals, :list, required: true

  def signal_flow(assigns) do
    ~H"""
    <div class="obs-signal-flow" id="signal-flow" phx-hook="AutoScroll">
      <h3 class="obs-section-title">Signal Flow</h3>
      <div :for={signal <- Enum.take(@signals, 50)} class="obs-signal-row">
        <span class="obs-signal-time"><%= format_time(signal.timestamp) %></span>
        <span class={"obs-signal-from obs-role-#{signal.from_agent}"}><%= format_agent_name(signal.from_agent) %></span>
        <span class="obs-signal-arrow">
          <%= if signal.to_agent == :all, do: "=> ALL", else: "=>" %>
        </span>
        <span :if={signal.to_agent != :all} class="obs-signal-to">
          <%= format_agent_name(signal.to_agent) %>
        </span>
        <span class="obs-signal-preview"><%= signal.preview %></span>
      </div>
      <div :if={@signals == []} class="obs-signal-empty">
        Waiting for agent communication...
      </div>
    </div>
    """
  end

  # --- Activity feed ---

  attr :activity, :map, required: true
  attr :agents, :map, required: true

  def activity_feed(assigns) do
    ~H"""
    <div class="obs-activity-feed" id="activity-feed" phx-hook="AutoScroll">
      <h3 class="obs-section-title">Agent Activity</h3>
      <div class="obs-activity-columns">
        <div :for={{agent_id, agent} <- @agents} class="obs-activity-column">
          <div class={"obs-activity-agent-label obs-role-#{agent.agent_name}"}>
            <%= format_role(agent.agent_name) %>
          </div>
          <div class="obs-activity-content">
            <% agent_activity = Map.get(@activity, agent_id, %{text: "", entries: []}) %>
            <div :if={agent_activity.text != ""} class="obs-activity-text">
              <%= agent_activity.text %>
            </div>
            <div :for={entry <- Enum.take(agent_activity.entries, 5)} class={"obs-activity-entry obs-activity-#{entry.type}"}>
              <%= entry.content %>
            </div>
            <div :if={agent_activity.text == "" and agent_activity.entries == []} class="obs-activity-waiting">
              Waiting...
            </div>
          </div>
        </div>
      </div>
      <div :if={@agents == %{}} class="obs-activity-waiting">
        No agents spawned yet.
      </div>
    </div>
    """
  end

  # --- Convergence chart ---

  attr :convergence_history, :list, required: true

  def convergence_chart(assigns) do
    max_rounds = 4

    coords =
      assigns.convergence_history
      |> Enum.with_index()
      |> Enum.map(fn {value, i} ->
        x = (i + 1) / max_rounds * 280 + 20
        y = 80 - value * 70
        {x, y}
      end)

    polyline = coords |> Enum.map(fn {x, y} -> "#{x},#{y}" end) |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:polyline, polyline)
      |> assign(:coords, coords)
      |> assign(:max_rounds, max_rounds)

    ~H"""
    <div class="obs-convergence">
      <h3 class="obs-section-title">Convergence</h3>
      <svg viewBox="0 0 300 90" class="obs-convergence-svg">
        <line x1="20" y1="10" x2="20" y2="80" stroke="var(--border)" stroke-width="0.5" />
        <line x1="20" y1="80" x2="290" y2="80" stroke="var(--border)" stroke-width="0.5" />
        <text x="5" y="15" fill="var(--text-muted)" font-size="8">100%</text>
        <text x="5" y="82" fill="var(--text-muted)" font-size="8">0%</text>
        <text :for={r <- 1..@max_rounds}
          x={r / @max_rounds * 280 + 20} y="90"
          fill="var(--text-muted)" font-size="7" text-anchor="middle">
          R<%= r %>
        </text>
        <polyline :if={@polyline != ""}
          points={@polyline}
          fill="none" stroke="var(--teal)" stroke-width="2" />
        <circle :for={{x, y} <- @coords}
          cx={x} cy={y} r="3" fill="var(--teal)" />
      </svg>
      <div class="obs-convergence-current">
        Round <%= length(@convergence_history) %> —
        <%= case List.last(@convergence_history) do
          nil -> "waiting..."
          v -> "#{round(v * 100)}% agreement"
        end %>
      </div>
    </div>
    """
  end

  # --- BEAM insights bar ---

  attr :insights, :list, required: true

  def insights_bar(assigns) do
    ~H"""
    <div :if={@insights != []} class="obs-insights">
      <div :for={insight <- @insights} class={"obs-insight obs-insight-#{insight.severity}"}>
        <span class="obs-insight-icon">
          <%= if insight.severity == :highlight, do: "!", else: "i" %>
        </span>
        <%= insight.text %>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp format_role(role) when is_atom(role) do
    role
    |> Atom.to_string()
    |> String.replace("_evaluator", "")
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_role(role), do: to_string(role)

  defp format_heap(nil), do: "—"
  defp format_heap(0), do: "0"
  defp format_heap(words) when is_integer(words) do
    kb = div(words * 8, 1024)
    if kb > 1024, do: "#{div(kb, 1024)}MB", else: "#{kb}KB"
  end

  defp format_reductions(nil), do: "—"
  defp format_reductions(r) when r > 1_000_000, do: "#{div(r, 1_000_000)}M/s"
  defp format_reductions(r) when r > 1_000, do: "#{div(r, 1_000)}K/s"
  defp format_reductions(r), do: "#{r}/s"

  defp status_class(:busy), do: "busy"
  defp status_class(:idle), do: "idle"
  defp status_class(:stopped), do: "dead"
  defp status_class(_), do: "idle"

  defp sorted_scores(scores) do
    scores
    |> Enum.sort_by(fn {_id, s} -> -(s.avg || 0) end)
  end

  defp score_class(nil), do: "obs-score obs-score-pending"
  defp score_class(n) when n >= 80, do: "obs-score obs-score-high"
  defp score_class(n) when n >= 60, do: "obs-score obs-score-mid"
  defp score_class(_), do: "obs-score obs-score-low"

  defp format_avg(nil), do: "—"
  defp format_avg(avg), do: Float.round(avg, 1)

  defp format_time(timestamp) do
    # Show relative seconds from start (monotonic time)
    secs = div(timestamp, 1000)
    mins = div(secs, 60)
    remaining_secs = rem(abs(secs), 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(remaining_secs), 2, "0")}"
  end

  defp format_agent_name(name) when is_atom(name), do: format_role(name)
  defp format_agent_name(name) when is_binary(name) do
    if String.contains?(name, "_evaluator") do
      name |> String.replace("_evaluator", "") |> String.capitalize()
    else
      String.slice(name, -8, 8)
    end
  end
  defp format_agent_name(name), do: to_string(name)
end
