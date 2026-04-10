# Prism Lens System — Implementation Plan

## Step 1: Schema + Migration

Create 8 Ecto schemas in `apps/rho_frameworks/lib/rho_frameworks/frameworks/`:
- `lens.ex` — Lens
- `lens_axis.ex` — LensAxis
- `lens_variable.ex` — LensVariable
- `lens_classification.ex` — LensClassification
- `lens_score.ex` — LensScore
- `lens_axis_score.ex` — LensAxisScore
- `lens_variable_score.ex` — LensVariableScore
- `work_activity_tag.ex` — WorkActivityTag

Single migration: `priv/repo/migrations/20260409000001_create_lens_tables.exs`

Conventions (matching existing codebase):
- `@primary_key {:id, :binary_id, autogenerate: true}`
- `@foreign_key_type :binary_id`
- `timestamps(type: :utc_datetime)`
- `references(:table, type: :binary_id, on_delete: :delete_all)`
- Named unique constraints matching `<table>_<fields>_index` pattern

## Step 2: Scoring Engine

Create `apps/rho_frameworks/lib/rho_frameworks/lenses.ex` with:

**CRUD:**
- `create_lens(org_id, attrs)` — insert lens with org_id
- `create_axis(lens_id, attrs)` — insert axis with lens_id
- `create_variables(axis_id, var_attrs_list)` — bulk insert variables
- `create_classification(lens_id, attrs)` — insert classification
- `get_lens!(lens_id)` — fetch with preloads (axes → variables, classifications)

**Scoring:**
- `score(lens_id, target, variable_scores)` — full pipeline:
  1. Load lens with axes + variables
  2. For each axis (sorted by sort_order):
     - For each variable: compute raw → adjusted (inverse) → weighted
     - Sum weighted = composite
     - Classify band from thresholds
  3. For 2-axis lenses: look up classification matrix
  4. Persist LensScore + LensAxisScores + LensVariableScores

**Private helpers:**
- `classify_band/2` — threshold-based band assignment
- `classify_matrix/2` — 2-axis classification lookup

**Validations:**
- Axis changeset: `length(band_labels) == length(band_thresholds) + 1`
- Variable: weights within axis sum to 1.0 (±0.001 tolerance)
- LensScore: exactly one target FK set (skill_id xor role_profile_id)

## Step 3: ARIA Seed + Tests

- `seed_aria_lens(org_id)` — creates ARIA lens with 2 axes, 8 variables, 9 classifications
- Tests in `test/rho_frameworks/lenses_test.exs`:
  - Seed ARIA and verify structure
  - Score a role profile with known variable scores
  - Verify composite = sum of weighted scores
  - Verify band classification thresholds
  - Verify matrix classification lookup
