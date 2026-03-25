# Observatory Enhancement — Design Spec

## Goal

Enhance the Hiring Committee Observatory demo to be self-explanatory, visually readable, and complete. A developer should be able to open the URL, understand what's happening, and follow the multi-agent debate without external explanation.

---

## Changes

### 1. Add 2 Candidates + Tension Field

Add to `lib/rho/demos/hiring/candidates.ex`:

**Add `tension` field (plain string) to ALL candidate maps.** This is used by the landing page cards and scoreboard tooltips.

Existing candidates — add `tension:` field:
- **C01 Sarah Chen**: `tension: "$5K over budget · 3 jobs in 4yr"`
- **C02 Wei Zhang**: `tension: "\"Brutal\" reviews · 2 reports transferred"`
- **C03 Marcus Johnson**: `tension: "No CS degree · limited scale experience"`

New candidates:

**C04 — Aisha Patel**
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
}
```

**C05 — David Park**
```elixir
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

Update `seed_scoreboard/0` in `observatory_live.ex` — it reads from `Candidates.all()` so it auto-picks up new candidates.

### 2. Scoreboard Round History with Deltas

**File:** `lib/rho_web/live/observatory_projection.ex`

Current behavior: `rho.hiring.scores.submitted` overwrites the score in the scoreboard. Round 2 scores replace Round 1.

New score data shape:

```elixir
# Initial (from seed_scoreboard):
scores: %{
  "C01" => %{name: "Sarah Chen", technical: nil, culture: nil, compensation: nil, avg: nil,
             prev_technical: nil, prev_culture: nil, prev_compensation: nil}
}

# After Round 1 technical scores:
%{... technical: 87, prev_technical: nil ...}

# After Round 2 technical scores:
%{... technical: 85, prev_technical: 87 ...}
```

When a score arrives for a role that already has a value, the old value moves to `prev_<role>`. The component computes delta as `score - prev_score` when `prev_score` is not nil.

Helper for the component:

```elixir
defp score_delta(current, prev) when is_integer(current) and is_integer(prev), do: current - prev
defp score_delta(_, _), do: nil
```

`seed_scoreboard/0` must be updated to include `prev_*` fields:

```elixir
defp seed_scoreboard do
  Map.new(Candidates.all(), fn c ->
    {c.id, %{name: c.name,
             technical: nil, culture: nil, compensation: nil, avg: nil,
             prev_technical: nil, prev_culture: nil, prev_compensation: nil}}
  end)
end
```

The `recompute_avg/1` helper uses the current (non-prev) values only.

**Score projection logic** — updated reducer in `project/3` for `rho.hiring.scores.submitted`:

```elixir
fn row ->
  prev_key = :"prev_#{role_key}"
  row
  |> Map.put(prev_key, row[role_key])   # move current → prev (nil on first round)
  |> Map.put(role_key, score)            # set new score
  |> recompute_avg()
end
```

**Timeline entry creation** — happens after the score map is updated (so `prev_*` is available):

```elixir
# After updating scores map, build timeline entries:
Enum.map(scores_data, fn entry ->
  id = entry["id"]
  score = entry["score"]
  prev = updated_scores[id][:"prev_#{role_key}"]
  delta = if prev, do: score - prev, else: nil
  %{type: :score, agent_role: role, text: entry["rationale"], candidate_id: id,
    score: score, delta: delta, round: socket.assigns.round,
    timestamp: System.monotonic_time(:millisecond)}
end)
```

The `tension` field is UI-only — it does not need to appear in `format_all/0` (which formats candidate data for LLM prompts).

**File:** `lib/rho_web/components/observatory_components.ex`

Update `scoreboard/1` component:
- Score cells: `<span>84</span> <span :if={delta} class={delta_class(delta)}>↓8</span>`
- `defp delta_class(d) when d > 0, do: "obs-delta-up"`
- `defp delta_class(d) when d < 0, do: "obs-delta-down"`
- CSS classes: `.obs-delta-down { color: var(--red); font-size: 10px; }`, `.obs-delta-up { color: var(--green); font-size: 10px; }`

### 3. Cost Estimate on Landing Page

**File:** `lib/rho_web/live/observatory_live.ex`

Add below the Start button in the landing page render:
```
<div class="obs-start-meta">~2 min · 3 agents × 2 rounds · Uses Claude Haiku</div>
```

CSS: `.obs-start-meta { font-size: 12px; color: var(--text-muted); margin-top: 8px; }`

### 4. Layout Redesign — Unified Timeline + Agent Drawer

#### 4a. Replace Activity Feed with Unified Timeline

**File:** `lib/rho_web/components/observatory_components.ex`

Remove `activity_feed/1` component. Add `unified_timeline/1`:

Renders all agent actions chronologically in a single scrollable feed:
- **Score entries**: `[Tag] Scored Candidate Score — "rationale excerpt"`
- **Debate messages** (send_message/broadcast): tinted background in sender's color + left border + `→ Target` label + italic message text
- **Round dividers**: horizontal line with `ROUND 2` label centered
- **Score deltas in Round 2**: `[Tag] Revised Candidate Score ↓8 — "rationale"`

Each entry has a colored role tag pill (Technical=#5B8ABA, Culture=#B55BA0, Compensation=#D4A855).

**File:** `lib/rho_web/live/observatory_projection.ex`

Add new assign `timeline: []` — a list of timeline entry maps:
```elixir
%{
  type: :score | :debate | :round_start,
  agent_role: atom(),
  agent_id: String.t(),
  target: String.t() | nil,
  text: String.t(),
  candidate_id: String.t() | nil,
  score: integer() | nil,
  delta: integer() | nil,
  round: integer(),
  timestamp: integer()
}
```

Project events into timeline:
- `rho.hiring.scores.submitted` → one `:score` entry per candidate
- `rho.session.*.message_sent` / `broadcast` → `:debate` entry
- `rho.hiring.round.started` → `:round_start` entry

Remove `signal_flow/1` component from right sidebar (merged into timeline). Remove `signals` assign from both `mount/3` clauses and remove `add_signal/4` from the projection — signals data is fully replaced by the timeline.

**Keep** per-agent `activity` assign and its projection handlers (`append_activity_text`, `add_activity_entry`) — this data feeds the agent drawer (Section 4b), not the removed activity feed component.

**File:** `lib/rho_web/live/observatory_live.ex`

Add `timeline: []` to both `mount/3` clauses (landing page and session mounts).

Remove `signals: []` from both `mount/3` clauses.

Update render: replace `<.activity_feed>` with `<.unified_timeline timeline={@timeline} />`. Move timeline to `obs-left`. Remove `<.signal_flow>` from `obs-right`. Keep scoreboard + convergence in `obs-right`.

Update header stats bar: remove `<span><%= length(@signals) %> signals</span>` (signals assign is removed). Replace with `<span><%= length(@timeline) %> events</span>` or remove entirely.

Layout:
```
obs-left:  agent cards (top) + unified timeline (fills remaining)
obs-right: scoreboard + convergence chart (no signal flow)
```

#### 4b. Agent Detail Drawer

**File:** `lib/rho_web/components/observatory_components.ex`

New `agent_drawer/1` component. Slides in from right, overlays the right sidebar.

Shows for the selected agent:
- Header: color dot + name + current step/status + close button (`phx-click="close_drawer"`)
- Persona: one-line italic bias description from evaluator system prompt
- Body (scrollable): uses existing `activity` assign data:
  - **Streaming text** (`activity.text`): rendered in a grey rounded card. This is the raw LLM output buffer — contains reasoning and response text. Displayed as-is (no further parsing needed).
  - **Tool entries** (`activity.entries`): rendered as pills for `:tool_start`/`:tool_result` entries — pill with tool name + ✓/✗ status + output preview (truncated to 100 chars)

This deliberately reuses the existing activity data model. No new event-to-entry mappings needed — the `append_activity_text` and `add_activity_entry` projection handlers already produce the data in the right shape.

CSS:
- `.obs-drawer { position: absolute; right: 0; top: 0; bottom: 0; width: 380px; z-index: 30; background: var(--bg-surface); border-left: 1px solid var(--border); transform: translateX(100%); transition: transform 200ms ease-out; }`
- `.obs-drawer.open { transform: translateX(0); }`
- Parent (`obs-main`) gets `position: relative; overflow: hidden;`

**File:** `lib/rho_web/live/observatory_live.ex`

- `selected_agent` assign already exists
- `handle_event("select_agent")` already exists
- Add `handle_event("close_drawer")` → `assign(socket, selected_agent: nil)`
- Render: `<.agent_drawer :if={@selected_agent} agent={@agents[@selected_agent]} activity={Map.get(@activity, @selected_agent, %{text: "", entries: []})} />`

**File:** `lib/rho_web/live/observatory_projection.ex`

Per-agent `activity` tracking (text + entries) is kept as-is — it feeds the drawer now instead of the removed activity feed component. No changes to `append_activity_text` or `add_activity_entry`.

### 5. Rich Landing Page

**File:** `lib/rho_web/live/observatory_live.ex`

Replace the landing page render (`%{session_id: nil}`) with:

```
Header:   "Hiring Committee Observatory"
          "Watch 3 AI agents evaluate candidates, debate each other, and
           converge on a hiring decision — in real-time. Every agent is a BEAM process."

Section:  "THE EVALUATORS"
          3 cards side by side:
          - Technical (blue #5B8ABA): "System design, coding depth, OSS contributions" + tag "Defends technical stars"
          - Culture (pink #B55BA0): "Communication, teamwork, mentoring, long-term fit" + tag "Flags brilliant jerks"
          - Compensation (gold #D4A855): "Salary vs budget band, total comp, hire count limits" + tag "Guards the budget"

Section:  "THE CANDIDATES — Senior Backend Engineer · $160K–$190K · Max 3 offers"
          5 cards (data from Candidates.all/0):
          Each card: name, meta (years + company + salary), one-line strength, tension tag

Section:  "HOW IT WORKS"
          3 numbered circles connected by arrows:
          1. Round 1 — "Each agent independently scores all candidates"
          2. Debate — "Agents see disagreements and argue via messages"
          3. Round 2 — "Revised scores after debate. Top 3 get offers."

Button:   "Start Simulation"
Meta:     "~2 min · 3 agents × 2 rounds · Uses Claude Haiku"
```

**File:** `lib/rho_web/components/observatory_components.ex`

New components: `evaluator_cards/1`, `candidate_cards/1`, `how_it_works/1`. Data-driven from `Candidates.all()` and hardcoded evaluator config.

**File:** `lib/rho_web/inline_css.ex`

Add CSS for landing page sections: `.obs-eval-cards`, `.obs-cand-cards`, `.obs-how-steps`, `.obs-eval-card`, `.obs-cand-card`, `.obs-eval-tag`, `.obs-cand-tension`. Follow existing patterns (Outfit font, card-based, teal accents).

### 6. Candidate Tooltip on Scoreboard Hover

**File:** `lib/rho_web/components/observatory_components.ex`

Update `scoreboard/1`: wrap each candidate name in a `<span>` with `position: relative` and a hidden tooltip `<div>`.

Tooltip content (from `Candidates.all/0`):
- Name (bold, 16px)
- Meta: years + company + education
- Rows: Skills, Salary, Work style
- Strength text
- Tension tag (colored pill)

CSS:
- `.obs-cand-name-hover { border-bottom: 1px dashed var(--border); cursor: pointer; position: relative; }`
- `.obs-cand-name-hover:hover { color: var(--teal); border-bottom-color: var(--teal); }`
- `.obs-cand-tooltip { display: none; position: absolute; right: 100%; top: -10px; margin-right: 8px; width: 250px; background: var(--bg-surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px; box-shadow: 0 8px 24px rgba(0,0,0,0.1); z-index: 40; }`
- `.obs-cand-name-hover:hover .obs-cand-tooltip { display: block; }`

Pure CSS — no JS or LiveView events needed. Tooltip pops left since scoreboard is on the right edge.

Pass candidate data to the scoreboard component via a `candidates` assign built from `Candidates.all/0`.

### Already Fixed

- **Convergence chart data pipeline** — `observatory_projection.ex` now computes convergence when all 3 evaluators have scored and appends to `convergence_history`.

---

## Files Changed

| File | Changes |
|------|---------|
| `lib/rho/demos/hiring/candidates.ex` | Add Aisha Patel + David Park |
| `lib/rho_web/live/observatory_live.ex` | New landing page render, add timeline/drawer assigns, layout restructure |
| `lib/rho_web/live/observatory_projection.ex` | Timeline entries, round-aware scores with deltas, convergence fix (done) |
| `lib/rho_web/components/observatory_components.ex` | New: unified_timeline, agent_drawer, evaluator_cards, candidate_cards, how_it_works. Update: scoreboard (deltas + tooltips). Remove: activity_feed, signal_flow |
| `lib/rho_web/inline_css.ex` | Landing page CSS, timeline CSS, drawer CSS, tooltip CSS, delta CSS |

## Not Changed

- `lib/rho/demos/hiring/simulation.ex` — no changes needed, it reads from `Candidates.all()`
- `lib/rho/demos/hiring/tools.ex` — no changes
- `.rho.exs` — evaluator configs stay as-is
- Backend signal bus / agent worker — no changes
