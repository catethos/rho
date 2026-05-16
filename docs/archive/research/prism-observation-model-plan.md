# Prism — Observation Model Plan

> **Status**: Not yet started. Depends on [Skill Library & Role Profile Restructure](../../active-plans/skill-library-restructure-plan-v2.md).
> **Replaces**: The "weighted evidence model" from the original plan. Renamed to **weighted evidence model** — it's a weighted running average with recency decay, not a Bayesian posterior.

## Goal

Add individual skill profiles with continuous observation tracking. A person's current skill level is a **weighted evidence estimate** derived from multiple observations over time, not a single assessment.

## Prerequisites

From the core restructure plan:
- `skills` table with slug-based identity
- Gap analysis functions in `Prism.Roles` that accept `skill_snapshot` maps (this plan provides a richer source)

## Key Design Decisions

1. **Weighted evidence model, not Bayesian.** The update formula is an exponentially weighted running average with recency decay. Call it what it is — no false precision.

2. **Unknown ≠ zero.** A missing profile entry means "we don't know this person's level." Gap analysis (from the core plan) already handles `:unknown` explicitly. This plan preserves that contract.

3. **Source weights differ.** Not all observations are equal:
   - Manager review: weight 1.0
   - Peer feedback: weight 0.8
   - Self-assessment: weight 0.6
   - AI inference: weight 0.5
   - Import (bulk/historical): weight 0.4
   Source weights are configurable per org.

4. **Staleness is computed at read time.** No background decay jobs. `last_observed_at` is stored; freshness is derived when queried. Stale entries are flagged, not silently decayed.

5. **Person identity uses external ID, not just email.** `IndividualProfile` has an `external_id` field (HRIS ID, employee number) as the primary dedup key, with `email` as a secondary identifier. This handles email changes, contractors, and external candidates.

6. **Incremental updates.** Profile entries store `weighted_sum` and `weight_total` for O(1) updates without loading observation history.

7. **Disagreement tracking.** Profile entries track `level_variance` — when multiple observations disagree, confidence should reflect that even if observation count is high.

## Schema Design

### Table: `individual_profiles`

```elixir
schema "individual_profiles" do
  field :name, :string
  field :email, :string
  field :external_id, :string       # HRIS ID, employee number, etc.
  field :tags, :map, default: %{}   # flexible grouping: %{"team" => "Data Eng", "department" => "Engineering"}

  belongs_to :organization, Organization
  belongs_to :user, User            # optional — person may not be a system user
  has_many :profile_entries, ProfileEntry

  timestamps()
end
```

Constraints:
- `unique_index([:organization_id, :external_id])` — primary dedup key
- `unique_index([:organization_id, :email])` — secondary dedup key
- `index([:organization_id])`

### Table: `profile_entries`

```elixir
schema "profile_entries" do
  field :current_level, :float          # weighted evidence estimate (0.0-5.0)
  field :confidence, :float             # 0.0-1.0, derived from count + variance
  field :observation_count, :integer
  field :weighted_sum, :float           # running weighted sum (for incremental update)
  field :weight_total, :float           # running total weight
  field :level_variance, :float         # variance across observations (disagreement)
  field :last_observed_at, :utc_datetime

  belongs_to :individual_profile, IndividualProfile
  belongs_to :skill, Skill
  has_many :observations, Observation

  timestamps()
end
```

Constraints:
- `unique_index([:individual_profile_id, :skill_id])` — one entry per skill per person
- `index([:skill_id])`

### Table: `observations`

```elixir
schema "observations" do
  field :observed_level, :integer       # 1-5
  field :evidence, :string              # free text: what was observed
  field :source, :string                # "self_assessment" | "manager_review" | "peer_feedback" | "ai_inference" | "import"
  field :context, :string               # optional: "Q1 code review", "project X retrospective"
  field :observed_at, :utc_datetime
  field :observed_by, :string           # who made the observation (name or email)

  belongs_to :profile_entry, ProfileEntry

  timestamps()
end
```

Constraints:
- `index([:profile_entry_id, :observed_at])` — chronological access
- Append-only: observations are never modified or deleted

## Update Formula

### Record observation (incremental)

```elixir
@default_source_weights %{
  "manager_review" => 1.0,
  "peer_feedback" => 0.8,
  "self_assessment" => 0.6,
  "ai_inference" => 0.5,
  "import" => 0.4
}

@decay_half_life_days 180  # observations lose half their weight every 6 months

def record_observation(profile_entry_id, attrs) do
  entry = Repo.get!(ProfileEntry, profile_entry_id)

  observation = %Observation{}
  |> Observation.changeset(Map.put(attrs, :profile_entry_id, profile_entry_id))
  |> Repo.insert!()

  source_weight = source_weight(observation.source)
  recency_weight = recency_weight(observation.observed_at)
  obs_weight = source_weight * recency_weight

  # Apply decay to existing running totals
  decay = compute_decay(entry.last_observed_at, observation.observed_at)

  new_weighted_sum = entry.weighted_sum * decay + observation.observed_level * obs_weight
  new_weight_total = entry.weight_total * decay + obs_weight
  new_level = new_weighted_sum / new_weight_total
  new_count = entry.observation_count + 1

  # Confidence: based on count and variance (not just count)
  new_variance = update_variance(entry, observation.observed_level, new_level)
  new_confidence = compute_confidence(new_count, new_variance)

  entry
  |> ProfileEntry.changeset(%{
    current_level: new_level,
    confidence: new_confidence,
    observation_count: new_count,
    weighted_sum: new_weighted_sum,
    weight_total: new_weight_total,
    level_variance: new_variance,
    last_observed_at: observation.observed_at
  })
  |> Repo.update!()
end

defp source_weight(source) do
  Map.get(@default_source_weights, source, 0.5)
end

defp recency_weight(observed_at) do
  days_ago = DateTime.diff(DateTime.utc_now(), observed_at, :day)
  :math.pow(0.5, days_ago / @decay_half_life_days)
end

defp compute_decay(last_observed_at, new_observed_at) do
  if last_observed_at do
    days_between = DateTime.diff(new_observed_at, last_observed_at, :day)
    :math.pow(0.5, days_between / @decay_half_life_days)
  else
    1.0
  end
end

defp compute_confidence(count, variance) do
  # Count contribution: diminishing returns, caps at ~0.8 with 10 observations
  count_factor = min(1.0, count / 10.0) * 0.8
  # Variance penalty: high disagreement reduces confidence
  variance_penalty = min(0.3, variance * 0.15)
  Float.round(min(1.0, max(0.0, count_factor - variance_penalty)), 2)
end
```

### Full recomputation (repair tool)

Available as `recompute_profile_entry/1` — loads all observations and recomputes from scratch. Used for:
- Migration / data repair
- After source weight configuration changes
- Debugging

Not the hot path.

## Integration with Gap Analysis

The core plan's gap analysis accepts `skill_snapshot :: %{skill_id => float()}`. This plan provides a richer source:

```elixir
def skill_snapshot(individual_profile_id, opts \\ []) do
  min_confidence = Keyword.get(opts, :min_confidence, 0.0)
  max_staleness_days = Keyword.get(opts, :max_staleness_days, nil)

  query = from pe in ProfileEntry,
    where: pe.individual_profile_id == ^individual_profile_id,
    where: pe.confidence >= ^min_confidence,
    select: {pe.skill_id, pe.current_level}

  query = if max_staleness_days do
    cutoff = DateTime.add(DateTime.utc_now(), -max_staleness_days, :day)
    from pe in query, where: pe.last_observed_at >= ^cutoff
  else
    query
  end

  Repo.all(query) |> Map.new()
end
```

This snapshot feeds directly into `Prism.Roles.individual_gap/2`. Skills not in the snapshot remain `:unknown` in gap results.

## Context Module: `Prism.People`

- `list_individual_profiles(org_id, opts)` — filter by tag dimensions
- `get_individual_profile(org_id, id)` / `get_by_external_id(org_id, external_id)`
- `upsert_individual_profile(org_id, attrs)` — create or update by external_id
- `record_observation(profile_entry_id, attrs)` — append observation + incremental update
- `record_observations_bulk(individual_profile_id, observations)` — batch observe
- `get_observation_history(profile_entry_id, opts)` — chronological observations
- `skill_snapshot(individual_profile_id, opts)` — current levels as a map (for gap analysis)
- `recompute_profile_entry(profile_entry_id)` — full recomputation from observations

## Implementation Order

### Step 1: Schema + migration
- Create: `IndividualProfile`, `ProfileEntry`, `Observation`
- Migration adds tables

### Step 2: CRUD
- `upsert_individual_profile/2`, `list_individual_profiles/2`
- Profile entry creation (auto-created on first observation for a skill)

### Step 3: Observation recording
- `record_observation/2` with incremental weighted update
- Source weights, recency decay, variance tracking
- Tests: multiple observations from different sources, verify level convergence

### Step 4: Skill snapshot + gap integration
- `skill_snapshot/2` with confidence and staleness filters
- Wire into existing `Prism.Roles.individual_gap/2`
- Tests: snapshot with filters, gap analysis using observation-derived data

### Step 5: Bulk operations
- `record_observations_bulk/2` — batch import
- `recompute_profile_entry/1` — repair tool
- CSV/spreadsheet import support

### Step 6: Plugin tools
- `observe_skill`, `view_profile`, `import_observations` tools
- Agent prompt for observation workflows

## Open Questions (deferred)

- **Audit trail**: Who can observe whom? Permissions model for sensitive employee data.
- **AI-generated scores governance**: Are AI observations advisory-only or authoritative?
- **Staleness decay strategy**: Currently read-time only. If orgs want automatic confidence degradation, add an optional periodic recomputation job.
- **HRIS integration**: Sync individual profiles from external HR systems. Shape depends on specific HRIS APIs.
