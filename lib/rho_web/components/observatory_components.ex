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
  attr :candidates, :list, default: []

  def scoreboard(assigns) do
    cand_map = Map.new(assigns.candidates, &{&1.id, &1})
    assigns = Phoenix.Component.assign(assigns, :cand_map, cand_map)

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
          <tr :for={{id, scores} <- sorted_scores(@scores)}>
            <td class="obs-candidate-name">
              <span class="obs-cand-name-hover">
                <%= scores.name %>
                <.candidate_tooltip :if={@cand_map[id]} candidate={@cand_map[id]} />
              </span>
            </td>
            <td class={score_class(scores.technical)}>
              <%= scores.technical || "—" %>
              <%= render_delta(scores.technical, scores[:prev_technical]) %>
            </td>
            <td class={score_class(scores.culture)}>
              <%= scores.culture || "—" %>
              <%= render_delta(scores.culture, scores[:prev_culture]) %>
            </td>
            <td class={score_class(scores.compensation)}>
              <%= scores.compensation || "—" %>
              <%= render_delta(scores.compensation, scores[:prev_compensation]) %>
            </td>
            <td class="obs-score-avg"><%= format_avg(scores.avg) %></td>
          </tr>
        </tbody>
      </table>
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

  # --- Unified timeline ---

  attr :timeline, :list, required: true

  def unified_timeline(assigns) do
    ~H"""
    <div class="obs-timeline" id="timeline" phx-hook="AutoScroll">
      <h3 class="obs-section-title">Timeline</h3>
      <div :for={entry <- @timeline} class={"obs-timeline-entry obs-timeline-#{entry.type}"}>
        <%= case entry.type do %>
          <% :round_start -> %>
            <div class="obs-timeline-round-divider">
              <div class="obs-timeline-round-line"></div>
              <span><%= entry.text %></span>
              <div class="obs-timeline-round-line"></div>
            </div>

          <% :score -> %>
            <div class="obs-timeline-row">
              <span class={"obs-timeline-tag obs-timeline-tag-#{role_css_key(entry.agent_role)}"}><%= format_role_short(entry.agent_role) %></span>
              <div>
                <span>Scored <strong><%= entry.candidate_name %> <%= entry.score %></strong></span>
                <span :if={entry.delta} class={delta_class(entry.delta)}>
                  <%= if entry.delta > 0, do: "↑#{entry.delta}", else: "↓#{abs(entry.delta)}" %>
                </span>
                <span :if={entry.text != ""} class="obs-timeline-rationale">— "<%= String.slice(entry.text, 0, 100) %>"</span>
              </div>
            </div>

          <% :debate -> %>
            <div class={"obs-timeline-debate obs-timeline-debate-#{role_css_key(entry.agent_role)}"}>
              <span class={"obs-timeline-tag obs-timeline-tag-#{role_css_key(entry.agent_role)}"}><%= format_role_short(entry.agent_role) %></span>
              <div>
                <div class="obs-timeline-debate-to">
                  → <%= if entry.target == :all, do: "ALL", else: format_agent_name(entry.target) %>
                </div>
                <div class="obs-timeline-debate-text"><%= entry.text %></div>
              </div>
            </div>

          <% _ -> %>
            <div></div>
        <% end %>
      </div>
      <div :if={@timeline == []} class="obs-timeline-empty">
        Waiting for agent activity...
      </div>
    </div>
    """
  end

  # --- Agent detail drawer ---

  attr :agent, :map, required: true
  attr :activity, :map, required: true

  def agent_drawer(assigns) do
    ~H"""
    <div class={"obs-drawer #{if @agent, do: "open", else: ""}"}>
      <div class="obs-drawer-header">
        <div class="obs-drawer-name">
          <span class={"obs-status-dot #{status_class(@agent.status)}"}></span>
          <span class={"obs-agent-role obs-role-#{@agent.agent_name}"}><%= format_role(@agent.agent_name) %></span>
          <span :if={@agent.current_step} class="obs-drawer-step">step <%= @agent.current_step %></span>
        </div>
        <span class="obs-drawer-close" phx-click="close_drawer">✕</span>
      </div>

      <div class="obs-drawer-body">
        <div :if={@activity.text != ""} class="obs-drawer-text">
          <%= @activity.text %>
        </div>

        <div :for={entry <- Enum.take(@activity.entries, 15)} class={"obs-drawer-entry obs-drawer-#{entry.type}"}>
          <%= case entry.type do %>
            <% :tool_start -> %>
              <span class="obs-drawer-tool-pill"><%= entry.content %></span>
            <% :tool_result -> %>
              <div class="obs-drawer-tool-result"><%= String.slice(entry.content, 0, 100) %></div>
            <% _ -> %>
              <span class="obs-drawer-misc"><%= entry.content %></span>
          <% end %>
        </div>

        <div :if={@activity.text == "" and @activity.entries == []} class="obs-drawer-waiting">
          Waiting for activity...
        </div>
      </div>
    </div>
    """
  end

  # --- Landing page components ---

  attr :candidates, :list, required: true

  def candidate_cards(assigns) do
    ~H"""
    <div class="obs-cand-cards">
      <div :for={c <- @candidates} class="obs-cand-card">
        <div class="obs-cand-name"><%= c.name %></div>
        <div class="obs-cand-meta"><%= c.years_experience %>yr · <%= c.current_company %> · $<%= format_salary(c.salary_expectation) %></div>
        <div class="obs-cand-strength"><%= String.slice(c.strengths, 0, 80) %></div>
        <span class="obs-cand-tension"><%= c.tension %></span>
      </div>
    </div>
    """
  end

  def evaluator_cards(assigns) do
    evaluators = [
      %{name: "Technical", color: "#5B8ABA", desc: "System design, coding depth, OSS contributions", tag: "Defends technical stars"},
      %{name: "Culture", color: "#B55BA0", desc: "Communication, teamwork, mentoring, long-term fit", tag: "Flags brilliant jerks"},
      %{name: "Compensation", color: "#D4A855", desc: "Salary vs budget band, total comp, hire count limits", tag: "Guards the budget"}
    ]
    assigns = Phoenix.Component.assign(assigns, :evaluators, evaluators)

    ~H"""
    <div class="obs-eval-cards">
      <div :for={e <- @evaluators} class="obs-eval-card" style={"border-left: 3px solid #{e.color}"}>
        <div class="obs-eval-card-header">
          <span class="obs-eval-dot" style={"background: #{e.color}"}></span>
          <span class="obs-eval-card-name" style={"color: #{e.color}"}><%= e.name %></span>
        </div>
        <div class="obs-eval-card-desc"><%= e.desc %></div>
        <span class="obs-eval-tag" style={"background: #{e.color}1a; color: #{e.color}"}><%= e.tag %></span>
      </div>
    </div>
    """
  end

  def how_it_works(assigns) do
    ~H"""
    <div class="obs-how">
      <div class="obs-how-step">
        <div class="obs-how-num">1</div>
        <div class="obs-how-title">Round 1</div>
        <div class="obs-how-desc">Each agent independently scores all candidates</div>
      </div>
      <div class="obs-how-arrow">→</div>
      <div class="obs-how-step">
        <div class="obs-how-num">2</div>
        <div class="obs-how-title">Debate</div>
        <div class="obs-how-desc">Agents see disagreements and argue via messages</div>
      </div>
      <div class="obs-how-arrow">→</div>
      <div class="obs-how-step">
        <div class="obs-how-num">3</div>
        <div class="obs-how-title">Round 2</div>
        <div class="obs-how-desc">Revised scores after debate. Top 3 get offers.</div>
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

  defp format_agent_name(name) when is_atom(name), do: format_role(name)
  defp format_agent_name(name) when is_binary(name) do
    if String.contains?(name, "_evaluator") do
      name |> String.replace("_evaluator", "") |> String.capitalize()
    else
      String.slice(name, -8, 8)
    end
  end
  defp format_agent_name(name), do: to_string(name)

  defp render_delta(current, prev) when is_integer(current) and is_integer(prev) do
    delta = current - prev
    cond do
      delta > 0 -> Phoenix.HTML.raw(~s(<span class="obs-delta-up">↑#{delta}</span>))
      delta < 0 -> Phoenix.HTML.raw(~s(<span class="obs-delta-down">↓#{abs(delta)}</span>))
      true -> ""
    end
  end
  defp render_delta(_, _), do: ""

  defp candidate_tooltip(assigns) do
    ~H"""
    <div class="obs-cand-tooltip">
      <div class="obs-cand-tooltip-name"><%= @candidate.name %></div>
      <div class="obs-cand-tooltip-meta">
        <%= @candidate.years_experience %>yr · <%= @candidate.current_company %> · <%= @candidate.education %>
      </div>
      <div class="obs-cand-tooltip-row">
        <span class="obs-cand-tooltip-label">Skills</span>
        <span><%= Enum.join(@candidate.skills, ", ") %></span>
      </div>
      <div class="obs-cand-tooltip-row">
        <span class="obs-cand-tooltip-label">Salary</span>
        <span>$<%= format_salary(@candidate.salary_expectation) %></span>
      </div>
      <div class="obs-cand-tooltip-row">
        <span class="obs-cand-tooltip-label">Work style</span>
        <span><%= @candidate.work_style %></span>
      </div>
      <div class="obs-cand-tooltip-strength"><%= @candidate.strengths %></div>
      <span class="obs-cand-tension"><%= @candidate.tension %></span>
    </div>
    """
  end

  defp format_salary(amount) when is_integer(amount) do
    amount |> Integer.to_string() |> String.graphemes() |> Enum.reverse()
    |> Enum.chunk_every(3) |> Enum.join(",") |> String.reverse()
  end
  defp format_salary(amount), do: to_string(amount)

  defp format_role_short(role) when is_atom(role) do
    role
    |> Atom.to_string()
    |> String.replace("_evaluator", "")
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
  defp format_role_short(role) when is_binary(role) do
    role |> String.replace("_evaluator", "") |> String.capitalize()
  end
  defp format_role_short(role), do: to_string(role)

  defp role_css_key(role) when is_atom(role), do: Atom.to_string(role)
  defp role_css_key(role) when is_binary(role), do: role
  defp role_css_key(_), do: "unknown"

  defp delta_class(d) when d > 0, do: "obs-delta-up"
  defp delta_class(d) when d < 0, do: "obs-delta-down"
  defp delta_class(_), do: ""
end
