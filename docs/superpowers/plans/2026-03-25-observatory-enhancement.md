# Observatory Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Hiring Committee Observatory self-explanatory and visually polished — rich landing page, unified timeline replacing fragmented activity columns, agent detail drawer, scoreboard with round deltas and hover tooltips, 2 new candidates.

**Architecture:** Data layer first (candidates, projection), then components, then LiveView wiring, then CSS. Each task produces a compiling codebase. No task depends on CSS to function — CSS is batched last.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.0, inline CSS (no Tailwind/esbuild), server-rendered HTML, pure CSS tooltips/transitions.

**Spec:** `docs/superpowers/specs/2026-03-25-observatory-enhancement-design.md`

---

## Critical Context for Implementers

**This is a Phoenix LiveView app with NO asset pipeline.** All CSS is in `lib/rho_web/inline_css.ex` as a single string. All JS is in `lib/rho_web/inline_js.ex`. Components are in `lib/rho_web/components/observatory_components.ex`. There is no Tailwind, no esbuild, no node_modules.

**No existing tests for observatory code.** The existing test suite uses Mimic for mocking. Observatory components are UI — verify by running the server and clicking through.

**The simulation reads from `Candidates.all()` dynamically.** Adding candidates to `candidates.ex` is automatically picked up by `Simulation.spawn_evaluators/1` and `format_all/0`. No simulation code changes needed.

**Evaluator role colors** used everywhere:
- Technical: `#5B8ABA`
- Culture: `#B55BA0`
- Compensation: `#D4A855`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/rho/demos/hiring/candidates.ex` | Modify | Add tension field to 3 existing + 2 new candidates |
| `lib/rho_web/live/observatory_projection.ex` | Modify | Score deltas (prev_* fields), timeline entries, remove add_signal |
| `lib/rho_web/components/observatory_components.ex` | Modify | Remove activity_feed + signal_flow. Add unified_timeline, agent_drawer, landing components. Update scoreboard (deltas + tooltips) |
| `lib/rho_web/live/observatory_live.ex` | Modify | New landing page, new assigns (timeline), remove signals, layout change, close_drawer event |
| `lib/rho_web/inline_css.ex` | Modify | New CSS for timeline, drawer, landing, tooltips, deltas. Remove activity_feed + signal_flow CSS |

---

### Task 1: Add Candidates + Tension Field

**Why first:** Everything downstream (landing page, tooltips, scoreboard seeding) reads from `Candidates.all()`. This is a pure data change with zero risk to existing code — `format_all/0` ignores unknown keys, and `simulation.ex` passes the formatted text to LLMs.

**Files:**
- Modify: `lib/rho/demos/hiring/candidates.ex:7-39`

- [ ] **Step 1: Add `tension` field to existing 3 candidates**

```elixir
# Line 17 — add after work_style in Sarah Chen's map:
tension: "$5K over budget · 3 jobs in 4yr"

# Line 27 — add after work_style in Wei Zhang's map:
tension: "\"Brutal\" reviews · 2 reports transferred"

# Line 37 — add after work_style in Marcus Johnson's map:
tension: "No CS degree · limited scale experience"
```

- [ ] **Step 2: Add C04 Aisha Patel and C05 David Park**

Add after Marcus Johnson's map (after line 38, before the closing `]`):

```elixir
      %{
        id: "C04", name: "Aisha Patel",
        years_experience: 5, current_company: "Shopify",
        education: "BS CS, Waterloo",
        skills: ["Elixir", "LiveView", "GraphQL", "PostgreSQL"],
        salary_expectation: 172_000,
        strengths: "Led LiveView migration at Shopify. Built real-time inventory system. Strong async communicator.",
        concerns: "Only 5 years experience. No distributed consensus work. May need senior mentoring.",
        work_style: "Hybrid, strong async + sync",
        tension: "Best all-rounder? · Less senior"
      },
      %{
        id: "C05", name: "David Park",
        years_experience: 15, current_company: "Netflix",
        education: "MS CS, Berkeley",
        skills: ["Elixir", "Rust", "event systems", "Kubernetes"],
        salary_expectation: 210_000,
        strengths: "Built real-time event pipeline at Netflix. Architect-level system design. 15yr track record.",
        concerns: "$20K over budget ceiling. May be overqualified — risk of boredom. Prefers architect role, not hands-on coding.",
        work_style: "Office, mentors architects",
        tension: "$20K over budget · may be overqualified"
      }
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. `format_all/0` still works (it doesn't reference `tension`).

- [ ] **Step 4: Commit**

```bash
git add lib/rho/demos/hiring/candidates.ex
git commit -m "feat(hiring): add tension field + 2 new candidates (Aisha Patel, David Park)"
```

---

### Task 2: Update Projection — Score Deltas + Timeline + Remove Signals

**Why second:** The projection is the data engine. All UI components consume its output. Getting the data shape right before touching components avoids double-work.

**Risk analysis:**
- Changing the score map shape from `%{technical: int}` to `%{technical: int, prev_technical: int}` — the `scoreboard/1` component accesses `scores.technical` (line 69 of components). This still works because `row[:technical]` returns the same value. `prev_*` keys are new, not replacing old ones. **No breakage.**
- Removing `add_signal/4` — the `signal_flow/1` component reads `@signals` assign. We remove it from the LiveView in Task 4. Between Task 2 and Task 4, `add_signal` will be gone but `@signals` assign still exists (just stays `[]`). **No runtime error** — signals simply stop being populated.
- Adding `timeline` entries — no consumer yet until Task 3 adds the component. Entries accumulate harmlessly. **No breakage.**

**Files:**
- Modify: `lib/rho_web/live/observatory_projection.ex`

- [ ] **Step 1: Update the score projection to track prev_* values and build timeline entries**

Replace the entire `project/3` clause for `"rho.hiring.scores.submitted"` (lines 40-62):

```elixir
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
          round: socket.assigns.round,
          timestamp: System.monotonic_time(:millisecond)
        }
      end)

    timeline = socket.assigns[:timeline] || []

    socket
    |> assign(:scores, scores)
    |> assign(:timeline, timeline ++ timeline_entries)
    |> maybe_update_convergence()
  end
```

- [ ] **Step 2: Add timeline entries for round_started**

Replace the `project/3` clause for `"rho.hiring.round.started"` (lines 64-68):

```elixir
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
```

- [ ] **Step 3: Add timeline entries for debate messages, remove add_signal**

In the `project/3` clause for `"rho.session." <> _` (lines 74-103), replace the `broadcast` and `message_sent` branches to write to timeline instead of signals. Keep activity tracking as-is:

```elixir
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
```

- [ ] **Step 4: Add the `add_debate_to_timeline/5` helper and remove `add_signal/4`**

Delete the `add_signal/4` function (lines 196-208). Add in its place:

```elixir
  defp add_debate_to_timeline(socket, from, to, message, agent_id) do
    timeline = socket.assigns[:timeline] || []

    # Resolve role from agents assign if possible
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
```

- [ ] **Step 5: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. Warning about unused `add_signal` is gone since we deleted it. The `signal_flow` component still exists but `@signals` assign won't be populated — it stays as `[]`.

- [ ] **Step 6: Commit**

```bash
git add lib/rho_web/live/observatory_projection.ex
git commit -m "feat(observatory): score deltas with prev_* tracking, timeline entries, remove add_signal"
```

---

### Task 3: Update Components — Remove Old, Add New

**Why third:** Components consume the data shapes from Task 2. We can't wire them in the LiveView until they exist.

**Risk analysis:**
- Removing `activity_feed/1` — referenced at `observatory_live.ex:190`. This will cause a compile error until Task 4 updates the LiveView render. **Strategy:** replace the function body with a no-op that renders empty div temporarily, then remove entirely in Task 4. Actually — simpler: just add the new components in this task, and update the LiveView render in Task 4 to swap them. The old components stay until Task 4 removes references.
- Removing `signal_flow/1` — same situation, referenced at line 195. Keep it until Task 4.
- New components (`unified_timeline`, `agent_drawer`, landing components) — no references yet. Safe to add.

**Files:**
- Modify: `lib/rho_web/components/observatory_components.ex`

- [ ] **Step 1: Add `unified_timeline/1` component**

Add after the `convergence_chart/1` function (after line 193):

```elixir
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
```

- [ ] **Step 2: Add timeline helper functions**

Add to the helpers section (after `format_agent_name`):

```elixir
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
```

- [ ] **Step 3: Add `agent_drawer/1` component**

Add after `unified_timeline/1`:

```elixir
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
```

- [ ] **Step 4: Add landing page components**

Add after `agent_drawer/1`:

```elixir
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
    assigns = assign(assigns, :evaluators, evaluators)

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

  defp format_salary(amount) when is_integer(amount) do
    amount |> Integer.to_string() |> String.graphemes() |> Enum.reverse()
    |> Enum.chunk_every(3) |> Enum.join(",") |> String.reverse()
  end
  defp format_salary(amount), do: to_string(amount)
```

- [ ] **Step 5: Update `scoreboard/1` with deltas and tooltips**

Replace the scoreboard function (lines 50-78). The new version accepts a `candidates` attr for tooltip data:

```elixir
  attr :scores, :map, required: true
  attr :candidates, :list, default: []

  def scoreboard(assigns) do
    cand_map = Map.new(assigns.candidates, &{&1.id, &1})
    assigns = assign(assigns, :cand_map, cand_map)

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
```

- [ ] **Step 6: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. New components exist but are not yet referenced by the LiveView — that's Task 4. Old components (`activity_feed`, `signal_flow`) still exist and are still referenced.

- [ ] **Step 7: Commit**

```bash
git add lib/rho_web/components/observatory_components.ex
git commit -m "feat(observatory): add unified_timeline, agent_drawer, landing components, scoreboard deltas + tooltips"
```

---

### Task 4: Update LiveView — Wiring, Layout, Landing Page

**Why fourth:** Now the projection produces the right data (Task 2) and components exist (Task 3). This task wires them together and removes old references.

**Risk analysis:**
- Removing `signals` assign — `length(@signals)` at line 172 will break. We replace it in this task. **Handled.**
- Removing `<.activity_feed>` reference — component still exists in the file. We just stop calling it. **Safe.**
- Removing `<.signal_flow>` reference — same. **Safe.**
- Adding `timeline` assign — projection already writes to it (Task 2). If `timeline` key doesn't exist in assigns, `socket.assigns[:timeline]` returns nil, and `|| []` handles it. **Safe.**

**Files:**
- Modify: `lib/rho_web/live/observatory_live.ex`

- [ ] **Step 1: Update landing page mount — remove signals, add timeline**

Replace the landing page mount (lines 13-28):

```elixir
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    {:ok,
     assign(socket,
       session_id: nil,
       simulation_status: :not_started,
       agents: %{},
       timeline: [],
       scores: %{},
       round: 0,
       convergence_history: [],
       insights: [],
       activity: %{},
       selected_agent: nil,
       bus_subs: []
     ), layout: {RhoWeb.Layouts, :app}}
  end
```

- [ ] **Step 2: Update session mount — remove signals, add timeline, update seed_scoreboard**

Replace the session mount assigns (lines 33-45):

```elixir
      assign(socket,
        session_id: sid,
        simulation_status: :not_started,
        agents: %{},
        timeline: [],
        scores: seed_scoreboard(),
        round: 0,
        convergence_history: [],
        insights: [],
        activity: %{},
        selected_agent: nil,
        bus_subs: []
      )
```

- [ ] **Step 3: Update `seed_scoreboard/0` to include prev_* fields**

Replace the function (lines 230-234):

```elixir
  defp seed_scoreboard do
    Map.new(Candidates.all(), fn c ->
      {c.id, %{name: c.name, technical: nil, culture: nil, compensation: nil, avg: nil,
               prev_technical: nil, prev_culture: nil, prev_compensation: nil}}
    end)
  end
```

- [ ] **Step 4: Add `close_drawer` event handler**

Add after the `select_agent` handler (after line 109):

```elixir
  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_agent: nil)}
  end
```

- [ ] **Step 5: Replace landing page render**

Replace the landing page render (lines 147-161):

```elixir
  def render(%{session_id: nil} = assigns) do
    candidates = Candidates.all()
    assigns = Phoenix.Component.assign(assigns, :candidates, candidates)

    ~H"""
    <div class="obs-landing">
      <div class="obs-landing-header">
        <h1>Hiring Committee Observatory</h1>
        <p>Watch 3 AI agents evaluate candidates, debate each other, and converge on a hiring decision — in real-time. Every agent is a BEAM process.</p>
      </div>

      <div class="obs-landing-section">
        <div class="obs-landing-section-title">The Evaluators</div>
        <.evaluator_cards />
      </div>

      <div class="obs-landing-section">
        <div class="obs-landing-section-title">The Candidates — Senior Backend Engineer · $160K–$190K · Max 3 offers</div>
        <.candidate_cards candidates={@candidates} />
      </div>

      <div class="obs-landing-section">
        <div class="obs-landing-section-title">How It Works</div>
        <.how_it_works />
      </div>

      <button class="obs-start-btn-large" phx-click="start_simulation">
        Start Simulation
      </button>
      <div class="obs-start-meta">~2–3 min · 3 agents × 2 rounds · 5 candidates · Uses Claude Haiku</div>
    </div>
    """
  end
```

- [ ] **Step 6: Replace active observatory render**

Replace the active observatory render (lines 164-201):

```elixir
  def render(assigns) do
    candidates = Candidates.all()
    assigns = Phoenix.Component.assign(assigns, :candidates, candidates)

    ~H"""
    <div class="obs-layout">
      <header class="obs-header">
        <h1 class="obs-title">Hiring Committee Observatory</h1>
        <div class="obs-header-stats">
          <span>Round <%= @round %></span>
          <span><%= map_size(@agents) %> agents</span>
          <span><%= length(@timeline) %> events</span>
          <span class={"obs-status-badge obs-status-#{@simulation_status}"}>
            <%= @simulation_status %>
          </span>
          <button :if={@simulation_status == :not_started}
            class="obs-start-btn" phx-click="begin_simulation">
            Begin
          </button>
        </div>
      </header>

      <.insights_bar insights={@insights} />

      <div class="obs-main">
        <div class="obs-left">
          <div class="obs-agents-grid">
            <.agent_card :for={{_id, agent} <- @agents} agent={agent} />
          </div>
          <.unified_timeline timeline={@timeline} />
        </div>

        <div class="obs-right">
          <.scoreboard scores={@scores} candidates={@candidates} />
          <.convergence_chart convergence_history={@convergence_history} />
        </div>

        <.agent_drawer
          :if={@selected_agent && @agents[@selected_agent]}
          agent={@agents[@selected_agent]}
          activity={Map.get(@activity, @selected_agent, %{text: "", entries: []})}
        />
      </div>
    </div>
    """
  end
```

- [ ] **Step 7: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. May get warnings about unused `activity_feed/1` and `signal_flow/1` in components — that's OK, we clean them up in the next step.

- [ ] **Step 8: Remove dead component functions**

In `lib/rho_web/components/observatory_components.ex`, delete:
- `signal_flow/1` function (lines 80-104)
- `activity_feed/1` function (lines 106-139)
- Their `attr` declarations

- [ ] **Step 9: Verify compilation again**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean with no warnings.

- [ ] **Step 10: Commit**

```bash
git add lib/rho_web/live/observatory_live.ex lib/rho_web/components/observatory_components.ex
git commit -m "feat(observatory): wire unified timeline, agent drawer, rich landing page, remove old components"
```

---

### Task 5: CSS

**Why last:** All structural changes are done. CSS is purely visual — it can't break compilation or data flow. Batching it avoids context-switching between Elixir and CSS.

**Files:**
- Modify: `lib/rho_web/inline_css.ex`

- [ ] **Step 1: Remove dead CSS**

Delete the following CSS blocks from `inline_css.ex`:
- `.obs-activity-feed` through `.obs-activity-waiting` (lines ~1296-1311)
- `.obs-signal-flow` through `.obs-signal-empty` (lines ~1314-1324)

- [ ] **Step 2: Add timeline CSS**

Add after the agent card CSS section:

```css
    /* Unified timeline */
    .obs-timeline { flex: 1; overflow-y: auto; padding: 12px 16px; }
    .obs-timeline-entry { margin-bottom: 8px; }
    .obs-timeline-row { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; color: var(--text-primary); }
    .obs-timeline-tag { padding: 1px 7px; border-radius: 4px; font-size: 10px; white-space: nowrap; color: #fff; font-weight: 500; flex-shrink: 0; margin-top: 1px; }
    .obs-timeline-tag-technical_evaluator { background: #5B8ABA; }
    .obs-timeline-tag-culture_evaluator { background: #B55BA0; }
    .obs-timeline-tag-compensation_evaluator { background: #D4A855; }
    .obs-timeline-rationale { color: var(--text-secondary); font-size: 11px; }
    .obs-timeline-round-divider { display: flex; align-items: center; gap: 10px; margin: 14px 0; font-size: 10px; color: var(--text-muted); font-weight: 500; text-transform: uppercase; }
    .obs-timeline-round-line { flex: 1; height: 1px; background: var(--border); }
    .obs-timeline-empty { color: var(--text-muted); font-style: italic; padding: 12px 0; }

    /* Debate messages in timeline */
    .obs-timeline-debate { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; padding: 8px 10px; border-radius: 8px; }
    .obs-timeline-debate-technical_evaluator { background: rgba(91, 138, 186, 0.06); border-left: 3px solid #5B8ABA; }
    .obs-timeline-debate-culture_evaluator { background: rgba(181, 91, 160, 0.06); border-left: 3px solid #B55BA0; }
    .obs-timeline-debate-compensation_evaluator { background: rgba(212, 168, 85, 0.06); border-left: 3px solid #D4A855; }
    .obs-timeline-debate-to { font-size: 10px; color: var(--text-muted); margin-bottom: 3px; }
    .obs-timeline-debate-text { color: var(--text-primary); font-style: italic; line-height: 1.5; }

    /* Score deltas */
    .obs-delta-up { color: #27ae60; font-size: 10px; font-weight: 600; margin-left: 2px; }
    .obs-delta-down { color: #e74c3c; font-size: 10px; font-weight: 600; margin-left: 2px; }
```

- [ ] **Step 3: Add drawer CSS**

```css
    /* Agent drawer */
    .obs-drawer { position: absolute; right: 0; top: 0; bottom: 0; width: 380px; z-index: 30;
      background: var(--bg-surface); border-left: 1px solid var(--border);
      transform: translateX(100%); transition: transform 200ms ease-out;
      display: flex; flex-direction: column; overflow: hidden; }
    .obs-drawer.open { transform: translateX(0); box-shadow: -4px 0 12px rgba(0,0,0,0.06); }
    .obs-main { position: relative; }
    .obs-drawer-header { display: flex; justify-content: space-between; align-items: center;
      padding: 10px 14px; border-bottom: 1px solid var(--border); flex-shrink: 0; }
    .obs-drawer-name { display: flex; align-items: center; gap: 8px; }
    .obs-drawer-step { font-size: 11px; color: var(--text-muted); }
    .obs-drawer-close { cursor: pointer; color: var(--text-muted); font-size: 18px; padding: 4px; }
    .obs-drawer-close:hover { color: var(--text-primary); }
    .obs-drawer-body { flex: 1; overflow-y: auto; padding: 12px 14px; }
    .obs-drawer-text { background: var(--bg-shelf); border-radius: 8px; padding: 10px 12px;
      margin-bottom: 10px; font-size: 12px; line-height: 1.6; color: var(--text-primary);
      white-space: pre-wrap; word-break: break-word; max-height: 300px; overflow-y: auto; }
    .obs-drawer-tool-pill { display: inline-block; background: rgba(91,181,162,0.1); color: var(--teal);
      padding: 2px 8px; border-radius: 12px; font-size: 10px; margin: 4px 2px; }
    .obs-drawer-tool-result { font-size: 10px; color: var(--text-secondary); padding: 2px 0; }
    .obs-drawer-waiting { color: var(--text-muted); font-style: italic; padding: 12px 0; }
```

- [ ] **Step 4: Add landing page CSS**

```css
    /* Landing page — rich version */
    .obs-landing { display: flex; flex-direction: column; align-items: center;
      padding: 48px 32px; min-height: 100vh; }
    .obs-landing-header { text-align: center; margin-bottom: 36px; max-width: 560px; }
    .obs-landing-header h1 { font-size: 1.8rem; font-weight: 700; color: var(--text-primary); margin-bottom: 8px; }
    .obs-landing-header p { color: var(--text-secondary); line-height: 1.6; font-size: 15px; }
    .obs-landing-section { margin-bottom: 32px; width: 100%; max-width: 720px; }
    .obs-landing-section-title { font-size: 11px; text-transform: uppercase; letter-spacing: 1px;
      color: var(--text-muted); margin-bottom: 10px; font-weight: 600; }
    .obs-start-meta { font-size: 12px; color: var(--text-muted); margin-top: 8px; }

    /* Evaluator cards */
    .obs-eval-cards { display: flex; gap: 12px; }
    .obs-eval-card { flex: 1; border-radius: 10px; padding: 14px; background: var(--bg-shelf); border: 1px solid var(--border); }
    .obs-eval-card-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
    .obs-eval-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
    .obs-eval-card-name { font-weight: 600; font-size: 14px; }
    .obs-eval-card-desc { font-size: 12px; color: var(--text-secondary); line-height: 1.5; margin-bottom: 6px; }
    .obs-eval-tag { display: inline-block; font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 500; }

    /* Candidate cards */
    .obs-cand-cards { display: flex; gap: 10px; flex-wrap: wrap; }
    .obs-cand-card { flex: 1; min-width: 130px; border-radius: 8px; padding: 10px 12px;
      background: var(--bg-shelf); border: 1px solid var(--border); }
    .obs-cand-card .obs-cand-name { font-weight: 600; font-size: 13px; color: var(--text-primary); margin-bottom: 2px; }
    .obs-cand-meta { font-size: 10px; color: var(--text-muted); margin-bottom: 6px; }
    .obs-cand-strength { font-size: 11px; color: var(--text-primary); line-height: 1.4; margin-bottom: 4px; }
    .obs-cand-tension { display: inline-block; font-size: 9px; padding: 2px 6px; border-radius: 8px;
      font-weight: 500; background: rgba(229,83,75,0.08); color: #e74c3c; }

    /* How it works */
    .obs-how { display: flex; gap: 16px; align-items: flex-start; justify-content: center; }
    .obs-how-step { text-align: center; flex: 1; max-width: 160px; }
    .obs-how-num { width: 28px; height: 28px; border-radius: 50%; background: var(--teal); color: #fff;
      display: flex; align-items: center; justify-content: center; font-size: 13px;
      font-weight: 600; margin: 0 auto 6px; }
    .obs-how-title { font-size: 12px; font-weight: 600; color: var(--text-primary); margin-bottom: 2px; }
    .obs-how-desc { font-size: 11px; color: var(--text-secondary); }
    .obs-how-arrow { color: var(--text-muted); font-size: 18px; padding-top: 4px; }
```

- [ ] **Step 5: Add tooltip CSS**

```css
    /* Candidate tooltip on scoreboard */
    .obs-cand-name-hover { border-bottom: 1px dashed var(--border); cursor: pointer; position: relative; }
    .obs-cand-name-hover:hover { color: var(--teal); border-bottom-color: var(--teal); }
    .obs-cand-tooltip { display: none; position: absolute; right: 100%; top: -10px; margin-right: 8px;
      width: 250px; background: var(--bg-surface); border: 1px solid var(--border);
      border-radius: 10px; padding: 14px; box-shadow: 0 8px 24px rgba(0,0,0,0.1); z-index: 40;
      text-align: left; font-weight: normal; }
    .obs-cand-name-hover:hover .obs-cand-tooltip { display: block; }
    .obs-cand-tooltip-name { font-weight: 700; font-size: 14px; color: var(--text-primary); margin-bottom: 2px; }
    .obs-cand-tooltip-meta { font-size: 11px; color: var(--text-muted); margin-bottom: 8px; }
    .obs-cand-tooltip-row { display: flex; justify-content: space-between; font-size: 11px;
      padding: 3px 0; border-bottom: 1px solid var(--bg-shelf); color: var(--text-primary); }
    .obs-cand-tooltip-row:last-of-type { border-bottom: none; }
    .obs-cand-tooltip-label { color: var(--text-muted); font-size: 10px; }
    .obs-cand-tooltip-strength { font-size: 11px; color: var(--text-secondary); margin-top: 8px; line-height: 1.5; }
```

- [ ] **Step 6: Verify compilation and visual check**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

Then start the server and visually verify:
```bash
RHO_WEB_ENABLED=true elixir --no-halt -S mix run
```

Open http://localhost:4001/observatory and check:
1. Landing page shows evaluator cards, candidate cards, how it works, start button with meta
2. Click Start → Begin → timeline populates with scores and debates
3. Scoreboard shows deltas in round 2
4. Hover candidate names → tooltip appears to the left
5. Click agent card → drawer slides in from right
6. Click ✕ → drawer closes

- [ ] **Step 7: Commit**

```bash
git add lib/rho_web/inline_css.ex lib/rho_web/components/observatory_components.ex
git commit -m "feat(observatory): CSS for timeline, drawer, landing page, tooltips, score deltas"
```

---

## Verification Checklist

After all tasks are complete:

- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test` passes (no existing tests broken — observatory has no tests)
- [ ] Landing page at `/observatory` shows evaluators, 5 candidates, how it works
- [ ] Start simulation → observatory shows unified timeline
- [ ] Scores appear with ↑/↓ deltas in round 2
- [ ] Debate messages highlighted in timeline with agent colors
- [ ] Round dividers separate phases
- [ ] Agent card click opens drawer
- [ ] Drawer close button works
- [ ] Candidate name hover shows tooltip
- [ ] Convergence chart plots points
