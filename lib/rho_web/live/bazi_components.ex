defmodule RhoWeb.BaziComponents do
  @moduledoc """
  UI components for the BaZi Decision Advisor Observatory.
  Server-rendered HTML + CSS. LiveView push_event + JS hooks only for auto-scroll.
  """

  use Phoenix.Component

  # --- Top bar ---

  attr :phase, :atom, required: true
  attr :round, :integer, required: true
  attr :simulation_status, :atom, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="bazi-header">
      <h1 class="bazi-title">八字决策顾问</h1>
      <div class="bazi-phase-track">
        <.phase_dot label="维度" active={@phase in [:proposing_dimensions, :awaiting_dimension_approval]} done={phase_rank(@phase) > 1} />
        <span class="bazi-phase-arrow">&rarr;</span>
        <.phase_dot label="分析" active={@phase in [:round_1]} done={phase_rank(@phase) > 2} />
        <span class="bazi-phase-arrow">&rarr;</span>
        <.phase_dot label="辩论" active={@phase in [:round_2]} done={phase_rank(@phase) > 3} />
        <span class="bazi-phase-arrow">&rarr;</span>
        <.phase_dot label="总结" active={@phase == :completed} done={false} />
      </div>
      <div class="bazi-header-stats">
        <span>Round <%= @round %></span>
        <span class={"bazi-status-badge bazi-status-#{@simulation_status}"}>
          <%= @simulation_status %>
        </span>
      </div>
    </header>
    """
  end

  attr :label, :string, required: true
  attr :active, :boolean, required: true
  attr :done, :boolean, required: true

  defp phase_dot(assigns) do
    ~H"""
    <span class={"bazi-phase-dot #{if @active, do: "active"} #{if @done, do: "done"}"}>
      <span class="bazi-phase-circle"></span>
      <span class="bazi-phase-label"><%= @label %></span>
    </span>
    """
  end

  defp phase_rank(:not_started), do: 0
  defp phase_rank(:proposing_dimensions), do: 1
  defp phase_rank(:awaiting_dimension_approval), do: 1
  defp phase_rank(:round_1), do: 2
  defp phase_rank(:round_2), do: 3
  defp phase_rank(:completed), do: 4
  defp phase_rank(_), do: 0

  # --- Agent panel ---

  attr :agents, :map, required: true

  def agent_panel(assigns) do
    advisors = [
      {:bazi_advisor_qwen, "Qwen", "bazi-agent-qwen"},
      {:bazi_advisor_deepseek, "DeepSeek", "bazi-agent-deepseek"},
      {:bazi_advisor_gpt, "GPT-5.4", "bazi-agent-gpt"}
    ]

    chairman = {:bazi_chairman, "Chairman", "bazi-agent-chairman"}
    assigns = Phoenix.Component.assign(assigns, advisors: advisors, chairman: chairman)

    ~H"""
    <div class="bazi-agent-panel">
      <h3 class="bazi-section-title">Advisors</h3>
      <div class="bazi-agent-grid">
        <.advisor_card
          :for={{role, label, css_class} <- @advisors}
          role={role}
          label={label}
          css_class={css_class}
          agent={find_agent_by_role(@agents, role)}
        />
        <.advisor_card
          role={elem(@chairman, 0)}
          label={elem(@chairman, 1)}
          css_class={elem(@chairman, 2)}
          agent={find_agent_by_role(@agents, elem(@chairman, 0))}
        />
      </div>
    </div>
    """
  end

  attr :role, :atom, required: true
  attr :label, :string, required: true
  attr :css_class, :string, required: true
  attr :agent, :map, default: nil

  defp advisor_card(assigns) do
    ~H"""
    <div class={"bazi-agent-card #{@css_class} #{if @agent, do: status_class(@agent.status), else: "offline"} #{if @agent && !@agent.alive, do: "dead"}"}
         phx-click={@agent && "select_agent"}
         phx-value-agent-id={@agent && @agent.agent_id}>
      <div class="bazi-agent-header">
        <span class={"bazi-status-dot #{if @agent, do: status_class(@agent.status), else: "offline"}"}></span>
        <span class="bazi-agent-label"><%= @label %></span>
        <span :if={@agent} class="bazi-agent-model"><%= model_label(@role) %></span>
      </div>
      <div :if={@agent} class="bazi-agent-stats">
        <div class="bazi-stat">
          <span class="bazi-stat-label">step</span>
          <span class="bazi-stat-value"><%= @agent.current_step || "—" %></span>
        </div>
        <div class="bazi-stat">
          <span class="bazi-stat-label">heap</span>
          <span class="bazi-stat-value"><%= format_heap(@agent.heap_size) %></span>
        </div>
        <div class="bazi-stat">
          <span class="bazi-stat-label">mailbox</span>
          <span class={"bazi-stat-value #{if @agent.message_queue_len > 3, do: "hot"}"}>
            <%= @agent.message_queue_len || 0 %>
          </span>
        </div>
        <div class="bazi-stat">
          <span class="bazi-stat-label">work</span>
          <span class="bazi-stat-value"><%= format_reductions(@agent[:reductions_per_sec]) %></span>
        </div>
      </div>
      <div :if={@agent && @agent.current_tool} class="bazi-agent-tool">
        <span class="bazi-tool-indicator"></span>
        <%= @agent.current_tool %>
      </div>
      <div :if={!@agent} class="bazi-agent-offline">not started</div>
    </div>
    """
  end

  # --- Agent drawer ---

  attr :agent, :map, required: true
  attr :activity, :map, required: true

  def agent_drawer(assigns) do
    ~H"""
    <div class={"bazi-drawer #{if @agent, do: "open", else: ""}"}>
      <div class="bazi-drawer-header">
        <div class="bazi-drawer-name">
          <span class={"bazi-status-dot #{status_class(@agent.status)}"}></span>
          <span class="bazi-agent-label"><%= format_advisor(drawer_advisor_key(@agent.role)) %></span>
          <span :if={@agent.current_step} class="bazi-drawer-step">step <%= @agent.current_step %></span>
        </div>
        <span class="bazi-drawer-close" phx-click="close_drawer">&times;</span>
      </div>

      <div class="bazi-drawer-meta">
        <span class="bazi-drawer-model"><%= model_label(@agent.role) %></span>
        <span :if={@agent.heap_size > 0} class="bazi-drawer-heap">heap: <%= format_heap(@agent.heap_size) %></span>
      </div>

      <div class="bazi-drawer-body">
        <div :if={@activity.text != ""} class="bazi-drawer-text">
          <%= @activity.text %>
        </div>

        <div :for={entry <- Enum.take(@activity.entries, 15)} class={"bazi-drawer-entry bazi-drawer-#{entry.type}"}>
          <%= case entry.type do %>
            <% :tool_start -> %>
              <span class="bazi-drawer-tool-pill"><%= entry.content %></span>
            <% :tool_result -> %>
              <div class="bazi-drawer-tool-result"><%= String.slice(entry.content, 0, 100) %></div>
            <% _ -> %>
              <span class="bazi-drawer-misc"><%= entry.content %></span>
          <% end %>
        </div>

        <div :if={@activity.text == "" and @activity.entries == []} class="bazi-drawer-waiting">
          Waiting for activity...
        </div>
      </div>
    </div>
    """
  end

  # --- Timeline ---

  attr :timeline, :list, required: true
  attr :phase, :atom, required: true
  attr :proposed_dimensions, :list, default: []
  attr :pending_user_questions, :list, default: []
  attr :chairman_ready, :boolean, default: false

  def timeline(assigns) do
    ~H"""
    <div class="bazi-timeline" id="bazi-timeline" phx-hook="AutoScroll">
      <h3 class="bazi-section-title">Timeline</h3>

      <div :for={entry <- @timeline} class={"bazi-timeline-entry bazi-timeline-#{entry.type}"}>
        <%= case entry.type do %>
          <% :round_start -> %>
            <div class="bazi-timeline-round-divider">
              <div class="bazi-timeline-round-line"></div>
              <span><%= entry.text %></span>
              <div class="bazi-timeline-round-line"></div>
            </div>

          <% :chairman -> %>
            <div class="bazi-timeline-row">
              <span class="bazi-timeline-tag bazi-tag-chairman">Chairman</span>
              <div class="markdown-body"
                   id={"bazi-chairman-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :chairman_summary -> %>
            <div class="bazi-timeline-summary">
              <span class="bazi-timeline-tag bazi-tag-chairman">Chairman — Final Summary</span>
              <div class="bazi-timeline-summary-body markdown-body"
                   id={"bazi-summary-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :chairman_reply -> %>
            <div class="bazi-timeline-reply">
              <span class="bazi-timeline-tag bazi-tag-chairman">Chairman</span>
              <div class="bazi-timeline-reply-body markdown-body"
                   id={"bazi-reply-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :score -> %>
            <div class="bazi-timeline-row">
              <span class={"bazi-timeline-tag bazi-tag-#{entry[:advisor] || "unknown"}"}><%= format_advisor(entry[:advisor]) %></span>
              <div>
                <span>Scored <strong><%= entry[:option] %></strong></span>
                <span :if={entry[:score]} class="bazi-score-inline"><%= entry.score %></span>
                <span :if={entry[:delta]} class={delta_class(entry.delta)}>
                  <%= if entry.delta > 0, do: "↑#{entry.delta}", else: "↓#{abs(entry.delta)}" %>
                </span>
                <span :if={entry[:text] && entry.text != ""} class="bazi-timeline-rationale">— "<%= String.slice(entry.text, 0, 100) %>"</span>
              </div>
            </div>

          <% :user_reply -> %>
            <div class="bazi-timeline-user-reply">
              <div class="bazi-timeline-user-bubble"><%= entry.text %></div>
            </div>

          <% :debate -> %>
            <div class={"bazi-timeline-debate bazi-timeline-debate-#{advisor_css_key(entry.agent_role)}"}>
              <span class={"bazi-timeline-tag bazi-tag-#{advisor_css_key(entry.agent_role)}"}><%= format_advisor_short(entry.agent_role) %></span>
              <div>
                <div class="bazi-timeline-debate-to">
                  &rarr; <%= if entry.target == :all do %>
                    <span class="bazi-timeline-tag bazi-tag-all">ALL</span>
                  <% else %>
                    <span class={"bazi-timeline-tag bazi-tag-#{advisor_css_key(entry.target)}"}><%= format_advisor_short(entry.target) %></span>
                  <% end %>
                </div>
                <div class="bazi-timeline-debate-text markdown-body"
                     id={"bazi-debate-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                     phx-hook="Markdown"
                     data-md={entry.text}></div>
              </div>
            </div>

          <% :chart_validation -> %>
            <div class="bazi-timeline-row bazi-timeline-system">
              <span class="bazi-timeline-tag bazi-tag-system">System</span>
              <div><%= entry.text %></div>
            </div>

          <% _ -> %>
            <div></div>
        <% end %>
      </div>

      <!-- Dimension approval form -->
      <div :if={@phase == :awaiting_dimension_approval && @proposed_dimensions != []} class="bazi-dimension-approval">
        <h4>Proposed Dimensions</h4>
        <div class="bazi-dim-list">
          <span :for={dim <- @proposed_dimensions} class="bazi-dim-tag"><%= dim %></span>
        </div>
        <form phx-submit="approve_dimensions">
          <input type="hidden" name="dimensions" value={Jason.encode!(@proposed_dimensions)} />
          <p class="bazi-dim-hint">You can approve these dimensions or edit the JSON below before approving.</p>
          <textarea name="dimensions_edit" rows="2" class="bazi-dim-textarea"><%= Jason.encode!(@proposed_dimensions) %></textarea>
          <button type="submit" class="bazi-btn bazi-btn-primary">Approve Dimensions</button>
        </form>
      </div>

      <!-- Pending user question from advisor -->
      <div :if={@pending_user_questions != []} class="bazi-user-question-popup">
        <div class="bazi-uq-header">An advisor needs more information:</div>
        <div class="bazi-uq-question"><%= hd(@pending_user_questions).question %></div>
        <div :if={length(@pending_user_questions) > 1} class="bazi-uq-queue-count">
          + <%= length(@pending_user_questions) - 1 %> more question(s) queued
        </div>
        <form phx-submit="reply_to_advisor">
          <input type="text" name="answer" placeholder="Your answer..." autocomplete="off" class="bazi-uq-input" />
          <button type="submit" class="bazi-btn bazi-btn-primary">Reply</button>
        </form>
      </div>

      <!-- Post-simulation Q&A -->
      <form :if={@chairman_ready} phx-submit="ask_chairman" class="bazi-chat-input">
        <input type="text" name="question" placeholder="Ask the Chairman about the analysis..." autocomplete="off" />
        <button type="submit">Ask</button>
      </form>

      <div :if={@timeline == []} class="bazi-timeline-empty">
        Waiting for agent activity...
      </div>
    </div>
    """
  end

  # --- Scoreboard ---

  attr :scores, :map, required: true
  attr :dimensions, :list, required: true

  def scoreboard(assigns) do
    ~H"""
    <div class="bazi-scoreboard">
      <h3 class="bazi-section-title">Scoreboard</h3>

      <div :if={@dimensions == []} class="bazi-scoreboard-empty">
        Waiting for dimensions...
      </div>

      <div :for={{option, advisor_scores} <- Enum.sort(@scores)} class="bazi-score-option">
        <h4 class="bazi-score-option-name"><%= option %></h4>
        <table class="bazi-score-table">
          <thead>
            <tr>
              <th>Advisor</th>
              <th :for={dim <- @dimensions}><%= dim %></th>
              <th>Avg</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={advisor <- [:qwen, :deepseek, :gpt]}>
              <td class={"bazi-advisor-name bazi-tag-#{advisor}"}><%= format_advisor(advisor) %></td>
              <td :for={dim <- @dimensions} class={score_cell_class(get_dim_score(advisor_scores, advisor, dim))}>
                <%= get_dim_score(advisor_scores, advisor, dim) || "—" %>
                <%= render_score_delta(advisor_scores, advisor, dim) %>
              </td>
              <td class="bazi-score-avg"><%= compute_advisor_avg(advisor_scores, advisor, @dimensions) %></td>
            </tr>
            <tr class="bazi-score-avg-row">
              <td><strong>Average</strong></td>
              <td :for={dim <- @dimensions} class="bazi-score-avg">
                <%= compute_dim_avg(advisor_scores, dim) %>
              </td>
              <td class="bazi-score-avg"><%= compute_composite(advisor_scores, @dimensions) %></td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # --- Setup form ---

  attr :birth_input_mode, :string, required: true
  attr :uploads, :any, required: true

  def setup_form(assigns) do
    ~H"""
    <div class="bazi-setup">
      <div class="bazi-setup-header">
        <h1>八字决策顾问</h1>
        <p>Upload your BaZi chart image, enter birth details, or both for cross-validation.</p>
      </div>

      <form phx-submit="begin_simulation" phx-change="validate_upload" class="bazi-setup-form">
        <div class="bazi-input-mode-toggle">
          <button type="button" phx-click="toggle_input_mode" phx-value-mode="image"
                  class={"bazi-mode-btn #{if @birth_input_mode in ["image", "both"], do: "active"}"}>
            Chart Image
          </button>
          <button type="button" phx-click="toggle_input_mode" phx-value-mode="birth"
                  class={"bazi-mode-btn #{if @birth_input_mode in ["birth", "both"], do: "active"}"}>
            Birth Details
          </button>
          <button type="button" phx-click="toggle_input_mode" phx-value-mode="both"
                  class={"bazi-mode-btn #{if @birth_input_mode == "both", do: "active"}"}>
            Both
          </button>
        </div>

        <!-- Image upload -->
        <div :if={@birth_input_mode in ["image", "both"]} class="bazi-upload-section">
          <label class="bazi-label">Chart Image (PNG/JPG)</label>
          <.live_file_input upload={@uploads.chart_image} class="bazi-file-input" />
          <div :for={entry <- @uploads.chart_image.entries} class="bazi-upload-preview">
            <.live_img_preview entry={entry} width="200" />
            <span><%= entry.client_name %></span>
          </div>
        </div>

        <!-- Birth details -->
        <div :if={@birth_input_mode in ["birth", "both"]} class="bazi-birth-section">
          <label class="bazi-label">Birth Details</label>
          <div class="bazi-birth-grid">
            <div>
              <label>Year</label>
              <input type="number" name="birth_year" min="1900" max="2100" placeholder="1990" />
            </div>
            <div>
              <label>Month</label>
              <input type="number" name="birth_month" min="1" max="12" placeholder="6" />
            </div>
            <div>
              <label>Day</label>
              <input type="number" name="birth_day" min="1" max="31" placeholder="15" />
            </div>
            <div>
              <label>Hour</label>
              <input type="number" name="birth_hour" min="0" max="23" placeholder="14" />
            </div>
            <div>
              <label>Minute</label>
              <input type="number" name="birth_minute" min="0" max="59" placeholder="30" />
            </div>
            <div>
              <label>Gender</label>
              <select name="birth_gender">
                <option value="male">Male</option>
                <option value="female">Female</option>
              </select>
            </div>
          </div>
        </div>

        <!-- Options and question -->
        <div class="bazi-options-section">
          <label class="bazi-label">Options to Evaluate (one per line)</label>
          <textarea name="options" rows="4" placeholder="Option A&#10;Option B&#10;Option C" class="bazi-textarea"></textarea>
        </div>

        <div class="bazi-question-section">
          <label class="bazi-label">Your Question</label>
          <textarea name="question" rows="3" placeholder="What should I focus on in my career?" class="bazi-textarea"></textarea>
        </div>

        <button type="submit" class="bazi-btn bazi-btn-primary bazi-btn-large">
          Start Analysis
        </button>
      </form>
    </div>
    """
  end

  # --- Helpers ---

  defp find_agent_by_role(agents, role) do
    agents
    |> Map.values()
    |> Enum.find(fn a -> a.role == role || a.agent_name == role end)
  end

  defp status_class(:busy), do: "busy"
  defp status_class(:idle), do: "idle"
  defp status_class(:stopped), do: "dead"
  defp status_class(_), do: "idle"

  defp format_advisor(:qwen), do: "Qwen"
  defp format_advisor(:deepseek), do: "DeepSeek"
  defp format_advisor(:gpt), do: "GPT-5.4"
  defp format_advisor(:bazi_chairman), do: "Chairman"
  defp format_advisor(other), do: to_string(other)

  defp get_dim_score(advisor_scores, advisor, dim) do
    case Map.get(advisor_scores, advisor) do
      nil -> nil
      dim_map -> Map.get(dim_map, dim)
    end
  end

  defp compute_advisor_avg(advisor_scores, advisor, dimensions) do
    case Map.get(advisor_scores, advisor) do
      nil ->
        "—"

      dim_map ->
        vals =
          dimensions
          |> Enum.map(&Map.get(dim_map, &1))
          |> Enum.filter(&is_number/1)

        if vals == [], do: "—", else: Float.round(Enum.sum(vals) / length(vals), 1)
    end
  end

  defp compute_dim_avg(advisor_scores, dim) do
    vals =
      [:qwen, :deepseek, :gpt]
      |> Enum.map(&get_dim_score(advisor_scores, &1, dim))
      |> Enum.filter(&is_number/1)

    if vals == [], do: "—", else: Float.round(Enum.sum(vals) / length(vals), 1)
  end

  defp compute_composite(advisor_scores, dimensions) do
    all_vals =
      for advisor <- [:qwen, :deepseek, :gpt],
          dim <- dimensions,
          val = get_dim_score(advisor_scores, advisor, dim),
          is_number(val),
          do: val

    if all_vals == [], do: "—", else: Float.round(Enum.sum(all_vals) / length(all_vals), 1)
  end

  defp score_cell_class(nil), do: "bazi-score bazi-score-pending"
  defp score_cell_class(n) when is_number(n) and n >= 80, do: "bazi-score bazi-score-high"
  defp score_cell_class(n) when is_number(n) and n >= 60, do: "bazi-score bazi-score-mid"
  defp score_cell_class(_), do: "bazi-score bazi-score-low"

  defp model_label(:bazi_advisor_qwen), do: "qwen3-235b"
  defp model_label(:bazi_advisor_deepseek), do: "deepseek-v3"
  defp model_label(:bazi_advisor_gpt), do: "gpt-5.4"
  defp model_label(:bazi_chairman), do: "coordinator"
  defp model_label(_), do: ""

  defp drawer_advisor_key(:bazi_advisor_qwen), do: :qwen
  defp drawer_advisor_key(:bazi_advisor_deepseek), do: :deepseek
  defp drawer_advisor_key(:bazi_advisor_gpt), do: :gpt
  defp drawer_advisor_key(:bazi_chairman), do: :bazi_chairman
  defp drawer_advisor_key(other), do: other

  defp format_heap(nil), do: "—"
  defp format_heap(0), do: "0"
  defp format_heap(words) when is_integer(words) do
    bytes = words * 8
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{div(bytes, 1_024)} KB"
      true -> "#{bytes} B"
    end
  end
  defp format_heap(_), do: "—"

  defp format_reductions(nil), do: "—"
  defp format_reductions(0), do: "0"
  defp format_reductions(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end
  defp format_reductions(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end
  defp format_reductions(n) when is_integer(n), do: "#{n}"
  defp format_reductions(_), do: "—"

  # --- Debate helpers ---

  defp format_advisor_short(:bazi_advisor_qwen), do: "Qwen"
  defp format_advisor_short(:bazi_advisor_deepseek), do: "DeepSeek"
  defp format_advisor_short(:bazi_advisor_gpt), do: "GPT-5.4"
  defp format_advisor_short(:bazi_chairman), do: "Chairman"
  defp format_advisor_short(:all), do: "ALL"
  defp format_advisor_short(role) when is_atom(role), do: Atom.to_string(role) |> String.capitalize()
  defp format_advisor_short(role) when is_binary(role), do: String.capitalize(role)
  defp format_advisor_short(_), do: "?"

  defp advisor_css_key(:bazi_advisor_qwen), do: "qwen"
  defp advisor_css_key(:bazi_advisor_deepseek), do: "deepseek"
  defp advisor_css_key(:bazi_advisor_gpt), do: "gpt"
  defp advisor_css_key(:bazi_chairman), do: "chairman"
  defp advisor_css_key(:all), do: "all"
  defp advisor_css_key(role) when is_atom(role), do: Atom.to_string(role)
  defp advisor_css_key(role) when is_binary(role), do: role
  defp advisor_css_key(_), do: "unknown"

  # --- Score delta helpers ---

  defp delta_class(d) when is_number(d) and d > 0, do: "bazi-delta-up"
  defp delta_class(d) when is_number(d) and d < 0, do: "bazi-delta-down"
  defp delta_class(_), do: ""

  defp render_score_delta(advisor_scores, advisor, dim) do
    prev_key = :"prev_#{advisor}"
    current = get_dim_score(advisor_scores, advisor, dim)
    prev = get_dim_score(advisor_scores, prev_key, dim)

    cond do
      is_number(current) and is_number(prev) and current > prev ->
        Phoenix.HTML.raw(~s(<span class="bazi-delta-up">↑#{Float.round(current - prev, 1)}</span>))

      is_number(current) and is_number(prev) and current < prev ->
        Phoenix.HTML.raw(~s(<span class="bazi-delta-down">↓#{Float.round(abs(current - prev), 1)}</span>))

      true ->
        ""
    end
  end
end
