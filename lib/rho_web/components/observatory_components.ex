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
        <span class="obs-agent-avatar"><.evaluator_avatar role={@agent.agent_name} size={24} /></span>
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
    max_rounds = max(2, length(assigns.convergence_history))

    labeled_coords =
      assigns.convergence_history
      |> Enum.with_index()
      |> Enum.map(fn {value, i} ->
        x = (i + 1) / max_rounds * 220 + 40
        y = 75 - value * 60
        label = "#{round(value * 100)}%"
        {x, y, label}
      end)

    polyline = labeled_coords |> Enum.map(fn {x, y, _} -> "#{x},#{y}" end) |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:polyline, polyline)
      |> assign(:labeled_coords, labeled_coords)
      |> assign(:max_rounds, max_rounds)

    ~H"""
    <div class="obs-convergence">
      <h3 class="obs-section-title">Convergence</h3>
      <svg viewBox="0 0 320 100" class="obs-convergence-svg">
        <line x1="35" y1="10" x2="35" y2="80" stroke="var(--border)" stroke-width="0.5" />
        <line x1="35" y1="80" x2="290" y2="80" stroke="var(--border)" stroke-width="0.5" />
        <text x="5" y="17" fill="var(--text-muted)" font-size="8">100%</text>
        <text x="15" y="82" fill="var(--text-muted)" font-size="8">0%</text>
        <text :for={r <- 1..@max_rounds}
          x={r / @max_rounds * 220 + 40} y="95"
          fill="var(--text-muted)" font-size="8" text-anchor="middle">
          R<%= r %>
        </text>
        <polyline :if={@polyline != ""}
          points={@polyline}
          fill="none" stroke="var(--teal)" stroke-width="2" />
        <circle :for={{x, y, _} <- @labeled_coords}
          cx={x} cy={y} r="4" fill="var(--teal)" />
        <text :for={{x, y, label} <- @labeled_coords}
          x={x} y={y - 8}
          fill="var(--teal)" font-size="9" font-weight="600" text-anchor="middle">
          <%= label %>
        </text>
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
                  → <%= if entry.target == :all do %>
                    <span class="obs-timeline-tag obs-timeline-tag-all">ALL</span>
                  <% else %>
                    <span class={"obs-timeline-tag obs-timeline-tag-#{role_css_key(entry.target)}"}><%= format_role_short(entry.target) %></span>
                  <% end %>
                </div>
                <div class="obs-timeline-debate-text markdown-body"
                     id={"timeline-debate-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                     phx-hook="Markdown"
                     data-md={entry.text}></div>
              </div>
            </div>

          <% :chairman -> %>
            <div class="obs-timeline-row">
              <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman</span>
              <div class="markdown-body"
                   id={"timeline-chairman-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :chairman_summary -> %>
            <div class="obs-timeline-summary">
              <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman — Final Recommendation</span>
              <div class="obs-timeline-summary-body markdown-body"
                   id={"timeline-summary-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :chairman_reply -> %>
            <div class="obs-timeline-reply">
              <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman</span>
              <div class="obs-timeline-reply-body markdown-body"
                   id={"timeline-reply-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :user_question -> %>
            <div class="obs-timeline-user-question">
              <div class="obs-timeline-user-bubble"><%= entry.text %></div>
            </div>

          <% :system_notice -> %>
            <div class="obs-timeline-system-notice"><%= entry.text %></div>

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
        <div class="obs-cand-avatar"><.candidate_avatar id={c.id} /></div>
        <div class="obs-cand-name"><%= c.name %></div>
        <div class="obs-cand-meta"><%= c.years_experience %>yr · <%= c.current_company %> · $<%= format_salary(c.salary_expectation) %></div>
        <div class="obs-cand-strength"><%= c.strengths %></div>
        <span class="obs-cand-tension"><%= c.tension %></span>
      </div>
    </div>
    """
  end

  def panel_formation(assigns) do
    ~H"""
    <div class="obs-panel-formation">
      <svg class="obs-panel-lines" viewBox="0 0 400 380" preserveAspectRatio="xMidYMid meet">
        <line x1="200" y1="75" x2="200" y2="150" stroke="#e0e0e0" stroke-width="1.5" stroke-dasharray="4 3"/>
        <line x1="80" y1="275" x2="175" y2="210" stroke="#e0e0e0" stroke-width="1.5" stroke-dasharray="4 3"/>
        <line x1="320" y1="275" x2="225" y2="210" stroke="#e0e0e0" stroke-width="1.5" stroke-dasharray="4 3"/>
        <line x1="200" y1="75" x2="80" y2="275" stroke="#eee" stroke-width="1" stroke-dasharray="3 4"/>
        <line x1="200" y1="75" x2="320" y2="275" stroke="#eee" stroke-width="1" stroke-dasharray="3 4"/>
        <line x1="80" y1="275" x2="320" y2="275" stroke="#eee" stroke-width="1" stroke-dasharray="3 4"/>
      </svg>

      <div class="obs-eval-node obs-eval-pos-top">
        <div class="obs-eval-node-avatar" style="background: rgba(91,138,186,0.1)"><.evaluator_avatar role={:technical_evaluator} size={48} /></div>
        <div class="obs-eval-node-name" style="color: #5B8ABA">Technical</div>
        <div class="obs-eval-node-desc">System design, coding depth, OSS</div>
        <span class="obs-eval-node-tag" style="background: rgba(91,138,186,0.08); color: #4a7aaa">Defends technical stars</span>
      </div>

      <div class="obs-chairman-hub">
        <div class="obs-chairman-avatar-lg"><.evaluator_avatar role={:chairman} size={56} /></div>
        <div class="obs-chairman-label">Chairman</div>
        <div class="obs-chairman-sublabel">Synthesizes & decides</div>
      </div>

      <div class="obs-eval-node obs-eval-pos-bl">
        <div class="obs-eval-node-avatar" style="background: rgba(181,91,160,0.1)"><.evaluator_avatar role={:culture_evaluator} size={48} /></div>
        <div class="obs-eval-node-name" style="color: #B55BA0">Culture</div>
        <div class="obs-eval-node-desc">Communication, mentoring, fit</div>
        <span class="obs-eval-node-tag" style="background: rgba(181,91,160,0.08); color: #a04d8a">Flags brilliant jerks</span>
      </div>

      <div class="obs-eval-node obs-eval-pos-br">
        <div class="obs-eval-node-avatar" style="background: rgba(212,168,85,0.1)"><.evaluator_avatar role={:compensation_evaluator} size={48} /></div>
        <div class="obs-eval-node-name" style="color: #D4A855">Compensation</div>
        <div class="obs-eval-node-desc">Budget, total comp, limits</div>
        <span class="obs-eval-node-tag" style="background: rgba(212,168,85,0.08); color: #9a7a2e">Guards the budget</span>
      </div>
    </div>
    """
  end

  def why_multi_agent(assigns) do
    ~H"""
    <div class="obs-why-box">
      <div class="obs-why-title">Why 3 agents, not 1?</div>
      <div class="obs-why-comparison">
        <div class="obs-why-item obs-why-single">
          <strong>1 agent</strong> tries to balance everything, averages it out, gives you a "play safe" answer.
        </div>
        <div class="obs-why-item obs-why-multi">
          <strong>3 agents</strong> with competing priorities push back on each other. The tension is what makes the outcome better.
        </div>
      </div>
      <div class="obs-why-punchline">Disagreement is the feature, not the bug.</div>
    </div>
    """
  end

  def how_it_works(assigns) do
    ~H"""
    <div class="obs-flow-track">
      <div class="obs-flow-step">
        <div class="obs-flow-num">1</div>
        <div class="obs-flow-title">Score</div>
        <div class="obs-flow-desc">Each agent independently scores all 5 candidates</div>
      </div>
      <div class="obs-flow-arrow">></div>
      <div class="obs-flow-step obs-flow-highlight">
        <div class="obs-flow-num">2</div>
        <div class="obs-flow-title">Debate</div>
        <div class="obs-flow-desc">They see disagreements and argue — in real-time</div>
      </div>
      <div class="obs-flow-arrow">></div>
      <div class="obs-flow-step">
        <div class="obs-flow-num">3</div>
        <div class="obs-flow-title">Revise</div>
        <div class="obs-flow-desc">Re-score after debate. Top 3 get offers.</div>
      </div>
    </div>
    """
  end

  # --- SVG Avatars ---

  @doc "Candidate cartoon avatar by ID"
  attr :id, :string, required: true

  def candidate_avatar(%{id: "C01"} = assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="28" cy="28" r="28" fill="#FFE0D0"/>
      <circle cx="28" cy="24" r="12" fill="#FFD0B8"/>
      <path d="M16 18c0-8 6-12 12-12s12 4 12 12c0 2-1 3-2 4 1-3 0-8-4-10-2-1-5-1-6 0-1-1-4-1-6 0-4 2-5 7-4 10-1-1-2-2-2-4z" fill="#2a1810"/>
      <ellipse cx="23" cy="24" rx="2" ry="2.2" fill="#2a1810"/><ellipse cx="33" cy="24" rx="2" ry="2.2" fill="#2a1810"/>
      <circle cx="24" cy="23.5" r="0.7" fill="#fff"/><circle cx="34" cy="23.5" r="0.7" fill="#fff"/>
      <path d="M24 29c1.5 2 4.5 2 6 0" stroke="#c47a5a" stroke-width="1.2" fill="none" stroke-linecap="round"/>
      <circle cx="23" cy="24" r="4" stroke="#555" stroke-width="0.8" fill="none"/>
      <circle cx="33" cy="24" r="4" stroke="#555" stroke-width="0.8" fill="none"/>
      <line x1="27" y1="24" x2="29" y2="24" stroke="#555" stroke-width="0.8"/>
      <path d="M14 52c0-8 6-12 14-12s14 4 14 12" fill="#e74c3c"/>
    </svg>
    """
  end

  def candidate_avatar(%{id: "C02"} = assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="28" cy="28" r="28" fill="#F5D5B8"/>
      <circle cx="28" cy="24" r="12" fill="#EECBAA"/>
      <path d="M15 16c1-7 7-11 13-11s12 4 13 11c0 1 0 2-1 3 0-4-2-8-5-9-2-1-4-1-7 0-3-1-5-1-7 0-3 1-5 5-5 9-1-1-1-2-1-3z" fill="#1a1a1a"/>
      <ellipse cx="23" cy="24" rx="1.8" ry="1.5" fill="#1a1a1a"/><ellipse cx="33" cy="24" rx="1.8" ry="1.5" fill="#1a1a1a"/>
      <line x1="25" y1="30" x2="31" y2="30" stroke="#b87a5a" stroke-width="1" stroke-linecap="round"/>
      <rect x="19" y="21" width="8" height="6" rx="2" stroke="#333" stroke-width="0.8" fill="none"/>
      <rect x="29" y="21" width="8" height="6" rx="2" stroke="#333" stroke-width="0.8" fill="none"/>
      <line x1="27" y1="24" x2="29" y2="24" stroke="#333" stroke-width="0.8"/>
      <path d="M14 52c0-8 6-12 14-12s14 4 14 12" fill="#3b6ea5"/>
    </svg>
    """
  end

  def candidate_avatar(%{id: "C03"} = assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="28" cy="28" r="28" fill="#C8956A"/>
      <circle cx="28" cy="24" r="12" fill="#BA8860"/>
      <path d="M16 17c1-6 6-10 12-10s11 4 12 10c0 1-1 2-1 2 0-5-3-8-11-8s-11 3-11 8c0 0-1-1-1-2z" fill="#2a1810"/>
      <ellipse cx="23" cy="23" rx="2" ry="2" fill="#2a1810"/><ellipse cx="33" cy="23" rx="2" ry="2" fill="#2a1810"/>
      <circle cx="24" cy="22.5" r="0.7" fill="#fff"/><circle cx="34" cy="22.5" r="0.7" fill="#fff"/>
      <path d="M23 29c2 3 6 3 8 0" stroke="#8a5a3a" stroke-width="1.2" fill="none" stroke-linecap="round"/>
      <path d="M20 28c0 4 3 7 8 7s8-3 8-7" stroke="#2a1810" stroke-width="0.6" fill="rgba(42,24,16,0.15)"/>
      <path d="M14 52c0-8 6-12 14-12s14 4 14 12" fill="#2ecc71"/>
    </svg>
    """
  end

  def candidate_avatar(%{id: "C04"} = assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="28" cy="28" r="28" fill="#E8C8A0"/>
      <circle cx="28" cy="24" r="12" fill="#DFC098"/>
      <path d="M15 20c0-9 6-14 13-14s13 5 13 14c0 1 0 3-1 4-1 2-1 6-1 10h-3c0-4 1-7 2-9-1-4-4-7-10-7s-9 3-10 7c1 2 2 5 2 9h-3c0-4 0-8-1-10-1-1-1-3-1-4z" fill="#1a0a00"/>
      <ellipse cx="23" cy="24" rx="2" ry="2.2" fill="#1a0a00"/><ellipse cx="33" cy="24" rx="2" ry="2.2" fill="#1a0a00"/>
      <circle cx="24" cy="23.5" r="0.7" fill="#fff"/><circle cx="34" cy="23.5" r="0.7" fill="#fff"/>
      <path d="M24 29c1.5 2 4.5 2 6 0" stroke="#b07a5a" stroke-width="1.2" fill="none" stroke-linecap="round"/>
      <circle cx="28" cy="18" r="1" fill="#e74c3c"/>
      <path d="M14 52c0-8 6-12 14-12s14 4 14 12" fill="#8e44ad"/>
    </svg>
    """
  end

  def candidate_avatar(%{id: "C05"} = assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="28" cy="28" r="28" fill="#F0D5B5"/>
      <circle cx="28" cy="24" r="12" fill="#E5C8A5"/>
      <path d="M16 17c1-6 6-10 12-10s11 4 12 10c0 1 0 2-1 3 0-5-2-8-11-8s-11 3-11 8c0 0-1-2-1-3z" fill="#555"/>
      <path d="M20 10c2-1 5-1 8 0" stroke="#999" stroke-width="1.5" fill="none"/>
      <ellipse cx="23" cy="24" rx="1.8" ry="1.8" fill="#2a1a10"/><ellipse cx="33" cy="24" rx="1.8" ry="1.8" fill="#2a1a10"/>
      <path d="M25 29.5c1 1.2 3 1.2 4 0" stroke="#b07a5a" stroke-width="1" fill="none" stroke-linecap="round"/>
      <path d="M14 52c0-8 6-12 14-12s14 4 14 12" fill="#2c3e50"/>
      <path d="M28 40l-2 6 2 2 2-2-2-6z" fill="#c0392b"/>
    </svg>
    """
  end

  def candidate_avatar(assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" fill="none"><circle cx="28" cy="28" r="28" fill="#ddd"/></svg>
    """
  end

  @doc "Evaluator robot avatar by role"
  attr :role, :atom, required: true
  attr :size, :integer, default: 24

  def evaluator_avatar(%{role: :technical_evaluator} = assigns) do
    ~H"""
    <svg viewBox="0 0 48 48" width={@size} height={@size} fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect x="14" y="8" width="20" height="20" rx="6" fill="#5B8ABA"/>
      <rect x="18" y="14" width="4.5" height="3" rx="0.8" fill="#fff"/>
      <rect x="25" y="14" width="4.5" height="3" rx="0.8" fill="#fff"/>
      <line x1="24" y1="8" x2="24" y2="3" stroke="#5B8ABA" stroke-width="1.5"/>
      <circle cx="24" cy="2.5" r="2" fill="#5B8ABA"/>
      <rect x="17" y="30" width="14" height="10" rx="3" fill="#5B8ABA"/>
      <rect x="20" y="33" width="8" height="4" rx="1.2" fill="#dce8f3"/>
    </svg>
    """
  end

  def evaluator_avatar(%{role: :culture_evaluator} = assigns) do
    ~H"""
    <svg viewBox="0 0 48 48" width={@size} height={@size} fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect x="14" y="10" width="20" height="20" rx="6" fill="#B55BA0"/>
      <circle cx="21" cy="18" r="2" fill="#fff"/><circle cx="27" cy="18" r="2" fill="#fff"/>
      <circle cx="21" cy="18.4" r="0.9" fill="#333"/><circle cx="27" cy="18.4" r="0.9" fill="#333"/>
      <path d="M21 24c1.5 2 4.5 2 6 0" stroke="#fff" stroke-width="1.2" fill="none" stroke-linecap="round"/>
      <path d="M24 8c-1.5-3-5.5-3-5.5 0s5.5 5.5 5.5 5.5 5.5-2.5 5.5-5.5-4-3-5.5 0z" fill="#B55BA0"/>
      <rect x="17" y="32" width="14" height="10" rx="3" fill="#B55BA0"/>
    </svg>
    """
  end

  def evaluator_avatar(%{role: :compensation_evaluator} = assigns) do
    ~H"""
    <svg viewBox="0 0 48 48" width={@size} height={@size} fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect x="14" y="10" width="20" height="20" rx="6" fill="#D4A855"/>
      <line x1="18" y1="16" x2="22" y2="17.5" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
      <line x1="26" y1="17.5" x2="30" y2="16" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
      <line x1="21" y1="24" x2="27" y2="24" stroke="#fff" stroke-width="1.2" stroke-linecap="round"/>
      <text x="24" y="8" text-anchor="middle" font-size="9" font-weight="700" fill="#D4A855">$</text>
      <rect x="17" y="32" width="14" height="10" rx="3" fill="#D4A855"/>
      <rect x="20" y="34" width="3" height="2" rx="0.5" fill="#f5ecd5"/>
      <rect x="25" y="34" width="3" height="2" rx="0.5" fill="#f5ecd5"/>
      <rect x="20" y="38" width="3" height="2" rx="0.5" fill="#f5ecd5"/>
      <rect x="25" y="38" width="3" height="2" rx="0.5" fill="#f5ecd5"/>
    </svg>
    """
  end

  def evaluator_avatar(%{role: :chairman} = assigns) do
    ~H"""
    <svg viewBox="0 0 56 56" width={@size} height={@size} fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="28" cy="28" r="28" fill="#e8f5f1"/>
      <path d="M17 16l2.5-6 3 3L28 7l5.5 6 3-3L39 16z" fill="#f1c40f"/>
      <rect x="17" y="16" width="22" height="3" rx="1" fill="#e8b800"/>
      <rect x="19" y="19" width="18" height="16" rx="6" fill="#4a9e8e"/>
      <circle cx="25" cy="26" r="2" fill="#fff"/><circle cx="31" cy="26" r="2" fill="#fff"/>
      <circle cx="25" cy="26.4" r="1" fill="#1a1a1a"/><circle cx="31" cy="26.4" r="1" fill="#1a1a1a"/>
      <path d="M25 32c1.2 1.8 4.8 1.8 6 0" stroke="#fff" stroke-width="1.2" fill="none" stroke-linecap="round"/>
      <rect x="22" y="36" width="12" height="10" rx="3" fill="#4a9e8e"/>
      <path d="M26 38l-2.5-1.5v3l2.5-1.5zm4 0l2.5-1.5v3l-2.5-1.5z" fill="#f1c40f"/>
      <circle cx="28" cy="38" r="1.2" fill="#e8b800"/>
    </svg>
    """
  end

  def evaluator_avatar(assigns) do
    ~H"""
    <svg viewBox="0 0 48 48" width={@size} height={@size} fill="none">
      <circle cx="24" cy="24" r="20" fill="#ddd"/>
    </svg>
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
