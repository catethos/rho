# Prism — Lens System Plan

> **Status**: Not yet started. Depends on [Skill Library & Role Profile Restructure](skill-library-restructure-plan-v2.md).
> **First concrete lens**: ARIA AI Readiness (2-axis: AI Impact × Adaptability)

## Goal

Add a configurable N-dimensional scoring framework ("Lenses") to Prism. A lens defines 1–N axes, each with weighted variables. Scores produce a composite per axis. For 2-axis lenses, an optional classification matrix maps band combinations to labels (e.g., "Transform", "Maintain").

Prism outputs structured data (composites, bands, classifications); the web layer adapts visualization to dimensionality (1 axis = ranked bars, 2 axes = scatter + matrix, 3+ axes = radar chart).

## Prerequisites

From the core restructure plan:
- `skills` table with slug-based identity and status
- `role_profiles` with `role_skills`
- `Prism.Catalog` and `Prism.Roles` context modules
- DataTable schema switching

> **Note**: Work activities are NOT a prerequisite. ARIA scoring extracts and classifies activities at LLM scoring time from the role's skills and description, not from stored work_activities data.

## First Lens: ARIA AI Readiness

The ARIA lens is a 2-axis lens that scores **role profiles** on:

- **X-axis: AI Impact** — how much AI/automation could change this role's work activities
  - Variables: automatable task %, tool displacement risk, data routine intensity, output standardization
- **Y-axis: Adaptability** — how well the role's required skills position it to adapt
  - Variables: technical learning agility, AI tool proficiency, cross-functional breadth, creative/strategic ratio

### Classification Matrix (2×2 → 4 quadrants)

| | High Adaptability | Low Adaptability |
|---|---|---|
| **High AI Impact** | **Transform** — Role will change significantly but can adapt | **Restructure** — Role at risk, needs intervention |
| **Low AI Impact** | **Leverage** — Well-positioned to adopt AI tools proactively | **Maintain** — Low urgency, continue current path |

### ARIA-specific: Work Activity Tagging

Each role's work activities are tagged with AI-relevant classifications:
- `automatable` — task could be fully automated by current/near-term AI
- `augmentable` — AI assists but human judgment still needed
- `human_essential` — requires human creativity, empathy, or physical presence
- `data_dependent` — task involves structured data processing

Tags are stored in `work_activity_tags` (lens-specific, one primary tag per activity per lens for v1).

## Schema Design

### Table: `lenses`

```elixir
schema "lenses" do
  field :name, :string
  field :slug, :string
  field :description, :string
  field :status, :string, default: "draft"   # "draft" | "active" | "archived"
  field :score_target, :string               # "skill" | "role_profile" | "individual_profile"
  field :scoring_method, :string             # "manual" | "llm" | "hybrid" | "derived"

  belongs_to :organization, Organization
  has_many :axes, LensAxis
  has_many :classifications, LensClassification
  has_many :scores, LensScore

  timestamps()
end
```

Constraints:
- `unique_index([:organization_id, :slug])`

### Table: `lens_axes`

```elixir
schema "lens_axes" do
  field :sort_order, :integer       # 0, 1, 2, ... (NOT "x"/"y")
  field :name, :string              # "AI Impact"
  field :short_name, :string        # "AII"
  field :band_thresholds, {:array, :float}  # [40.0, 70.0] → 3 bands
  field :band_labels, {:array, :string}     # ["low", "medium", "high"]

  belongs_to :lens, Lens
  has_many :variables, LensVariable
  has_many :axis_scores, LensAxisScore

  timestamps()
end
```

Constraints:
- `unique_index([:lens_id, :sort_order])`
- Changeset validates: `length(band_labels) == length(band_thresholds) + 1`

### Table: `lens_variables`

```elixir
schema "lens_variables" do
  field :key, :string               # "at" (short key for API/display)
  field :name, :string              # "Automatable Task %"
  field :weight, :float             # 0.0-1.0 (weights within axis must sum to 1.0)
  field :description, :string       # scoring guidance for LLM/human
  field :inverse, :boolean, default: false  # if true, high raw → low contribution

  belongs_to :axis, LensAxis

  timestamps()
end
```

Constraints:
- `unique_index([:axis_id, :key])`
- Changeset validates: all variable weights within an axis sum to 1.0 (within float tolerance)

### Table: `lens_classifications` (2-axis lenses only)

```elixir
schema "lens_classifications" do
  field :axis_0_band, :integer      # band index for first axis (0-based)
  field :axis_1_band, :integer      # band index for second axis (0-based)
  field :label, :string             # "Transform", "Restructure", etc.
  field :color, :string             # hex color for visualization
  field :description, :string       # what this classification means

  belongs_to :lens, Lens

  timestamps()
end
```

Constraints:
- `unique_index([:lens_id, :axis_0_band, :axis_1_band])`

### Table: `lens_scores`

```elixir
schema "lens_scores" do
  field :scored_at, :utc_datetime
  field :scoring_method, :string     # "manual" | "llm" | "hybrid"
  field :classification, :string     # looked up from matrix (2-axis only)
  field :version, :integer, default: 1  # incremented on re-score

  belongs_to :lens, Lens
  # Exactly one of these is set:
  belongs_to :skill, Skill
  belongs_to :role_profile, RoleProfile
  # (future) belongs_to :individual_profile, IndividualProfile

  has_many :axis_scores, LensAxisScore

  timestamps()
end
```

Constraints:
- Changeset validates: exactly one target FK is set
- `index([:lens_id, :classification])` — filter by quadrant
- Scores are **historical**: each re-score creates a new row with incremented `version`. Latest score per target is `ORDER BY version DESC LIMIT 1`.

### Table: `lens_axis_scores`

```elixir
schema "lens_axis_scores" do
  field :composite, :float          # weighted composite for this axis (0-100)
  field :band, :integer             # band index after threshold classification

  belongs_to :lens_score, LensScore
  belongs_to :axis, LensAxis
  has_many :variable_scores, LensVariableScore

  timestamps()
end
```

### Table: `lens_variable_scores`

```elixir
schema "lens_variable_scores" do
  field :raw_score, :float          # 0-100 input score
  field :adjusted_score, :float     # after inverse adjustment
  field :weighted_score, :float     # adjusted × weight
  field :rationale, :string         # LLM explanation or manual note

  belongs_to :axis_score, LensAxisScore
  belongs_to :variable, LensVariable

  timestamps()
end
```

### Table: `work_activity_tags` (lens-specific activity classification)

```elixir
schema "work_activity_tags" do
  field :tag, :string               # "automatable", "augmentable", etc.
  field :confidence, :float         # LLM confidence (0.0-1.0)
  field :activity_description, :string   # the activity text (extracted by LLM at scoring time)

  belongs_to :role_profile, RoleProfile  # which role this activity belongs to
  belongs_to :lens, Lens

  timestamps()
end
```

Constraints:
- `unique_index([:role_profile_id, :lens_id, :activity_description, :tag])` — no duplicate tags per activity per role per lens
- `index([:role_profile_id])`

## Scoring Engine

### Compute score

```elixir
def score(lens_id, target, variable_scores) do
  lens = get_lens!(lens_id) |> Repo.preload(axes: :variables)

  axis_results = Enum.map(lens.axes |> Enum.sort_by(& &1.sort_order), fn axis ->
    vars = Enum.map(axis.variables, fn var ->
      raw = Map.fetch!(variable_scores, var.key)
      adjusted = if var.inverse, do: 100 - raw, else: raw
      weighted = adjusted * var.weight
      %{variable_id: var.id, raw_score: raw, adjusted_score: adjusted, weighted_score: weighted}
    end)

    composite = Enum.sum(Enum.map(vars, & &1.weighted_score))
    band = classify_band(composite, axis.band_thresholds)

    %{axis_id: axis.id, composite: composite, band: band, variable_scores: vars}
  end)

  classification = classify_matrix(lens, axis_results)

  persist_score(lens, target, axis_results, classification)
end

defp classify_band(composite, thresholds) do
  thresholds
  |> Enum.sort()
  |> Enum.with_index()
  |> Enum.reduce(0, fn {threshold, idx}, _acc ->
    if composite >= threshold, do: idx + 1, else: idx
  end)
end

defp classify_matrix(lens, axis_results) do
  case axis_results do
    [a0, a1 | _] when length(axis_results) == 2 ->
      Repo.get_by(LensClassification,
        lens_id: lens.id, axis_0_band: a0.band, axis_1_band: a1.band)
      |> case do
        nil -> nil
        c -> c.label
      end
    _ -> nil  # no matrix classification for 1-axis or 3+-axis lenses
  end
end
```

### Seed ARIA lens

```elixir
def seed_aria_lens(org_id) do
  {:ok, lens} = create_lens(org_id, %{
    name: "ARIA — AI Readiness Impact Assessment",
    slug: "aria",
    description: "Evaluates roles on AI disruption potential and organizational adaptability",
    status: "active",
    score_target: "role_profile",
    scoring_method: "hybrid"
  })

  # X-axis: AI Impact
  {:ok, x_axis} = create_axis(lens.id, %{
    sort_order: 0, name: "AI Impact", short_name: "AII",
    band_thresholds: [40.0, 70.0], band_labels: ["low", "medium", "high"]
  })

  create_variables(x_axis.id, [
    %{key: "at", name: "Automatable Task %", weight: 0.30,
      description: "Percentage of role's work activities classifiable as automatable by current/near-term AI"},
    %{key: "td", name: "Tool Displacement Risk", weight: 0.25,
      description: "Likelihood existing tools/processes will be replaced by AI alternatives"},
    %{key: "dr", name: "Data Routine Intensity", weight: 0.25,
      description: "Degree to which role involves repetitive data processing"},
    %{key: "os", name: "Output Standardization", weight: 0.20,
      description: "How standardized/templated are the role's deliverables"}
  ])

  # Y-axis: Adaptability
  {:ok, y_axis} = create_axis(lens.id, %{
    sort_order: 1, name: "Adaptability", short_name: "ADP",
    band_thresholds: [40.0, 70.0], band_labels: ["low", "medium", "high"]
  })

  create_variables(y_axis.id, [
    %{key: "tla", name: "Technical Learning Agility", weight: 0.30,
      description: "Role's required ability to learn and adopt new technical tools"},
    %{key: "atp", name: "AI Tool Proficiency", weight: 0.25,
      description: "Current AI/ML tool usage in role's skill requirements"},
    %{key: "cfb", name: "Cross-functional Breadth", weight: 0.25,
      description: "Breadth of collaboration across teams and disciplines"},
    %{key: "csr", name: "Creative/Strategic Ratio", weight: 0.20,
      description: "Proportion of work requiring creative judgment vs routine execution"}
  ])

  # Classifications (2×2 matrix, 3 bands per axis = 9 cells simplified to 4 quadrants)
  # Using band indices: 0=low, 1=medium, 2=high
  classifications = [
    # High AI Impact + High Adaptability → Transform
    %{axis_0_band: 2, axis_1_band: 2, label: "Transform", color: "#3B82F6",
      description: "Role will change significantly but can adapt"},
    # High AI Impact + Low Adaptability → Restructure
    %{axis_0_band: 2, axis_1_band: 0, label: "Restructure", color: "#EF4444",
      description: "Role at risk, needs intervention"},
    # Low AI Impact + High Adaptability → Leverage
    %{axis_0_band: 0, axis_1_band: 2, label: "Leverage", color: "#10B981",
      description: "Well-positioned to adopt AI tools proactively"},
    # Low AI Impact + Low Adaptability → Maintain
    %{axis_0_band: 0, axis_1_band: 0, label: "Maintain", color: "#6B7280",
      description: "Low urgency, continue current path"},
    # Medium combinations
    %{axis_0_band: 1, axis_1_band: 2, label: "Transform", color: "#3B82F6"},
    %{axis_0_band: 2, axis_1_band: 1, label: "Restructure", color: "#EF4444"},
    %{axis_0_band: 1, axis_1_band: 0, label: "Maintain", color: "#6B7280"},
    %{axis_0_band: 0, axis_1_band: 1, label: "Leverage", color: "#10B981"},
    %{axis_0_band: 1, axis_1_band: 1, label: "Monitor", color: "#F59E0B",
      description: "Moderate impact and adaptability — monitor and prepare"}
  ]

  Enum.each(classifications, &create_classification(lens.id, &1))

  {:ok, lens}
end
```

## Lens Dashboard (Workspace Panel)

### Architecture

The lens dashboard is a **workspace panel** (not inline LiveRender), following the same signal-driven projection pattern as DataTable.

Rationale:
1. **Persistence** — dashboard stays visible while chatting about results
2. **Bidirectional interaction** — click a classification cell to filter → signal flows to agent
3. **Multi-chart layout** — matrix + scatter + detail panel simultaneously
4. **Live updates** — as the agent scores roles, the dashboard updates via signals

### Signal flow

```
Agent scores a role
  → Prism.Lenses.score/3 persists to DB
  → Publishes signal: rho.session.{id}.events.lens_score_update
      data: %{lens_id: ..., score: %{...}}

LensDashboardProjection.apply/2
  → Reduces signal into dashboard state

LensDashboardComponent renders from projection state
  → Selects chart components based on axis count
  → User clicks → updates active_filters → publishes signal for agent
```

### Visualization components

| Component | When used | Input |
|---|---|---|
| `LensDashboardComponent` | Always (workspace root) | Full projection state |
| `LensMatrixComponent` | 2-axis lenses with classifications | `scores_by_classification` |
| `LensScatterComponent` | 2-axis lenses | `scores_with_axes` |
| `LensRadarComponent` | 3+ axis lenses | `scores_with_axes` |
| `LensBarChartComponent` | 1-axis lenses | `scores_with_axes` |
| `LensVariableBreakdownComponent` | Detail view for any score | `variable_breakdown` |
| `LensDetailPanelComponent` | Slide-in for selected score | `score_detail` |
| `LensSummaryCards` | Top of dashboard | `score_summary` |

Charts are rendered as **server-side SVG** (matching the existing `interaction_graph` pattern in `observatory_components.ex`).

### Multi-workspace split view

To support DataTable + Lens Dashboard side-by-side:
- `active_workspace_id` (atom) becomes `visible_workspace_ids` (ordered list)
- Grid adapts: 1 panel = `1fr 6px 1fr`, 2 panels = `1fr 6px 1fr 6px minmax(300px, 1fr)`
- Click = replace, Ctrl+Click = split alongside

## Context Module: `Prism.Lenses`

- `list_lenses(org_id)` — all lenses for this org
- `get_lens(org_id, slug)` — full lens with axes, variables, classifications
- `create_lens(org_id, attrs)` — define a new lens
- `score(lens_id, target, variable_scores)` — compute composites, classify, persist
- `score_via_llm(lens_id, target)` — trigger LLM scoring
- `get_score(lens_id, target_id)` — retrieve latest score with breakdown
- `list_scores(lens_id, opts)` — all scores, filterable by classification/band/version
- `scores_by_classification(lens_id)` — aggregated counts per cell
- `scores_with_axes(lens_id)` — all scores with per-axis composites
- `score_summary(lens_id)` — aggregate counts for metric cards
- `score_detail(lens_score)` — full breakdown for one scored item
- `seed_aria_lens(org_id)` — seed the built-in ARIA lens

## Implementation Order

### Step 1: Lens schema + migration
- Create: `Lens`, `LensAxis`, `LensVariable`, `LensClassification`, `LensScore`, `LensAxisScore`, `LensVariableScore`, `WorkActivityTag` (references `role_profile` directly, not a separate `WorkActivity` table)
- Migration adds tables alongside existing ones

### Step 2: Scoring engine
- `score/3` — composite computation, band classification, matrix lookup
- `classify_band/2`, `classify_matrix/2`
- Changeset validations: variable weights sum to 1.0, band_labels count = thresholds + 1, exactly one target FK

### Step 3: ARIA lens seed
- `seed_aria_lens/1` — creates the built-in ARIA lens with axes, variables, classifications
- Tests: seed + score a role profile + verify classification

### Step 4: LLM scoring integration
- `score_via_llm/2` — prompt construction from lens variable descriptions
- Work activity tagging flow (activities are LLM-extracted at scoring time, not read from a stored table):
  1. LLM reads role profile (skills, description, required levels)
  2. LLM infers work activities for the role
  3. LLM tags each activity (automatable, augmentable, etc.)
  4. Tags are persisted in `work_activity_tags` for the `role_profile`
  5. Variable scores are computed from the tags
- Streaming support for real-time scoring feedback

### Step 5: Dashboard data queries
- `scores_by_classification/1`, `scores_with_axes/1`, `score_summary/1`, `score_detail/1`
- All return plain maps — no rendering

### Step 6: Dashboard workspace panel
- `LensDashboardProjection` — reduces lens signals into dashboard state
- `LensDashboardComponent` — root panel, selects sub-components by axis count
- Chart components (server-side SVG)
- Multi-workspace split view support

### Step 7: Plugin tools
- `score_role`, `show_lens_dashboard`, `switch_lens` tools in `Prism.Plugin`
- Agent prompt updates for lens workflow

## Other Lens Examples (future)

To show the model isn't ARIA-specific:

- **Market Criticality** (2-axis: Supply Scarcity × Business Impact, targets role_profiles)
- **Development Priority** (2-axis: Current Gap Size × Strategic Importance, targets skills, derived from gap data)
- **Succession Readiness** (3-axis: Skill Fit × Experience Depth × Leadership Readiness, targets individual_profiles, radar chart)
- **Hiring Evaluation** (5-axis: Technical × Problem Solving × Communication × Culture × Growth, targets individual_profiles, radar chart)
