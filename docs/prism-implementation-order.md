# Prism Implementation Order

> Implementation sequence for the Prism workforce intelligence platform.
> See [skill-library-restructure-plan-v2.md](skill-library-restructure-plan-v2.md) for full design rationale, schema definitions, and code change details.

## Task Tracker

### Core Restructure (Steps 1–7)
- [ ] **Step 1** — DataTable schema switching (`data_table_schema_change` signal, mode indicator)
- [ ] **Step 2** — Ecto schemas + clean-slate migration (5 tables + `pg_trgm` extension)
- [ ] **Step 3** — `Prism.Catalog` context (library CRUD, dedup layers 1–3, `discover_skills`, `save_to_library`)
- [ ] **Step 4** — `Prism.Roles` context (`save_role_profile`, `load_role_profile`, `compare_role_profiles`)
- [ ] **Step 5** — Plugin tool swap (8 old → ~16 new tools, principle-based prompt)
- [ ] **Step 6** — LiveView + Router (rename Framework pages, add `SkillLibraryLive`, update routes)
- [ ] **Step 7** — Standard framework templates (bundle SFIA v8, `load_template` + `adopt_skills`)

### Observation Phases (10–11)
- [ ] **Phase 10.1** — Individual profile CRUD
- [ ] **Phase 10.2** — Observation system: `record_observation/2`, weighted evidence model (recency decay, confidence growth)
- [ ] **Phase 11** — Gap analysis: individual, team, org-wide + plugin tools + profile UI

### Lens Phases (12–14)
- [ ] **Phase 12.1** — Lens definition CRUD + seed ARIA lens
- [ ] **Phase 12.2** — Generic scoring algorithm: composites, bands, classification
- [ ] **Phase 13** — LLM scoring integration: `score_via_llm/2`, activity extraction, streaming
- [ ] **Phase 14.1** — Lens data queries (plain maps): scores_by_classification, scores_with_axes, etc.
- [ ] **Phase 14.2** — Lens Dashboard workspace: projection, component, SVG charts
- [ ] **Phase 14.3** — Multi-workspace split view
- [ ] **Phase 14.4** — Signal flow: lens_score_update, click-to-filter, agent observation

---

## Step 1: DataTable Schema Switching

> **Prerequisite** — must land first so that library-mode and role-mode saves work against the right columns.

- Add `data_table_schema_change` signal handler to `DataTableProjection`
- Store active schema + mode label in projection state
- Two schemas:
  - `Schemas.skill_library()` — columns: category, cluster, skill_name, skill_description, level, level_name, level_description
  - `Schemas.role_profile()` — columns: category, cluster, skill_name, required_level
- Mode indicator in data table UI
- `load_library` and `load_role_profile` publish schema change before streaming rows
- Warning on mode switch with unsaved edits

**Tests**: Signal changes schema in state, component renders correct columns per mode

---

## Step 2: Ecto Schemas + Migration

### 2.1 Clean-slate migration `20260408000001_prism_schema.exs`

5 tables in a single migration:

| Table | Purpose |
|-------|---------|
| `libraries` | Typed catalogs (name, description, type, immutable, derived_from) |
| `skills` | One row per skill concept (slug, name, description, category, cluster, status, proficiency_levels JSONB, source_skill_id FK) |
| `role_profiles` | What a role needs (name, description, role_family, seniority_level, seniority_label, source_role_profile_id FK, immutable) |
| `role_skills` | Join: skill + min_expected_level + weight (nullable, default 1) |
| `duplicate_dismissals` | "These two skills are intentionally different" (skill_a_id, skill_b_id, library_id) |

- Enable `pg_trgm` extension for trigram similarity in near-match detection
- Unique index on `(library_id, slug)` for skills
- No data migration needed — clean slate, no production data
- Delete old migration files, `mix ecto.reset`

### 2.2 Ecto schema modules

- `Prism.Library` (new)
- `Prism.Skill` (rewritten — normalized, proficiency_levels as embedded JSONB, no separate level table)
- `Prism.RoleProfile` (replaces Framework)
- `Prism.RoleSkill` (new join table)
- `Prism.DuplicateDismissal` (new)
- Changeset tests for each

---

## Step 3: Catalog Context — `Prism.Catalog`

> Core context for library operations, skill CRUD, and all three dedup layers.

### 3.1 Library CRUD
- `list_libraries/1`, `create_library/2`, `get_library!/2`
- `get_or_create_default_library/1` — funnels into single library by default
- `fork_library/4` — copy library (optional category filter), set `derived_from_id`
- `diff_against_source/2` — diff forked library against immutable parent

### 3.2 Skill upsert with continuous dedup

- `upsert_skill/2` — Layer 1 (slug match, auto-reuse) + Layer 2 (trigram near-match via `pg_trgm`)
- `upsert_skills_batch/3` — two-phase save:
  - **Phase A**: Save all skills. Exact slug matches auto-reuse. New skills created. Near-matches created but flagged.
  - **Phase B**: Return near-match pairs for review in the same session.
- `find_near_matches/2` — PostgreSQL `similarity()` with threshold 0.4, filtered by `DuplicateDismissal`
- `maybe_fill_proficiency_gaps/2` — first writer wins, fill gaps only

### 3.3 Dedup resolution
- `merge_skills/3` — merge duplicate skills, repoint all `RoleSkill` FKs in transaction
- `dismiss_duplicate/3` — mark pair as intentionally different
- `semantic_duplicate_scan/1` — Layer 3 async LLM scan, triggered after sessions adding >5 new skills

### 3.4 Discovery + search
- `discover_skills/2` — unified search across library + roles + standard templates
- `search_skills/2` — full-text search scoped to a library
- `browse_library/2` — list/filter skills by category/status

### 3.5 Save to library
- `save_to_library/1` — reads library-mode data table rows, groups by (category, cluster, skill_name), upserts skills as published with embedded JSONB levels
- `load_library/1` — denormalizes skills back to flat rows for data table

### 3.6 Standard framework templates
- `load_template/1` — load standard framework (e.g. SFIA v8) as immutable library from `priv/templates/`
- `adopt_skills/3` — cherry-pick individual skills from a standard into org library, track `source_skill_id` lineage

**Tests**: Slug dedup, near-match detection + dismissal filtering, two-phase batch save, merge repoints FKs, library round-trip save/load, discover_skills across sources

---

## Step 4: Roles Context — `Prism.Roles`

### 4.1 Save + Load role profile
- `save_role_profile/3` — reads role-mode rows, calls `upsert_skills_batch` (draft status), creates `RoleProfile` + `RoleSkill` entries, returns near-match pairs
- `load_role_profile/2` — denormalizes back to flat rows for data table
- `list_role_profiles/2`, `get_role_profile/2`, `delete_role_profile/2`

### 4.2 Comparison
- `compare_role_profiles/2` — shared skills, unique skills, level diffs

### 4.3 Gap analysis stubs
- `individual_gap/2` — one person vs one role profile (extension point for observation model)
- `team_gap/2` — N people vs one role profile

> **Note**: Career ladder is a query (`role_profiles WHERE role_family = X ORDER BY seniority_level`), not a standalone tool. Add UI when needed.

**Tests**: Save two roles with overlapping skills → verify library dedup, load back, comparison accuracy

---

## Step 5: Plugin Tool Swap — `Prism.Plugin`

Replace the 8 existing tools with ~16 new tools:

| New Tool | Replaces | Purpose |
|----------|----------|---------|
| `list_libraries` | — | List org's libraries with type, counts, immutable badge |
| `create_library` | — | Create new mutable library |
| `browse_library` | — | List skills by category/status in a library |
| `load_template` | — | Load standard framework as immutable library |
| `fork_library` | — | Fork library (optional category filter) |
| `adopt_skills` | — | Cherry-pick skills from standard into org library |
| `discover_skills` | `search_frameworks` | Unified search: library + roles + standards |
| `save_to_library` | `save_framework` (partial) | Save library-mode data table rows |
| `load_library` | — | Load library into data table (denormalized) |
| `save_role_profile` | `save_framework` (partial) | Save role-mode rows + create role |
| `load_role_profile` | `load_framework` | Load role into data table |
| `list_role_profiles` | `list_frameworks` | List role profiles |
| `delete_role_profile` | `delete_framework` | Delete role profile |
| `merge_skills` | — | Merge duplicate skills (called during review) |
| `dismiss_duplicate` | — | Mark pair as intentionally different |
| `compare_role_profiles` | `compare_frameworks` | Cross-reference role profiles |
| `add_proficiency_levels` | `add_proficiency_levels` | **No change** |

**Removed vs v1**: `consolidate_library` (continuous dedup replaces batch consolidation), `show_career_ladder` (query, not tool), `find_duplicates` (built into save flow + `merge_skills`/`dismiss_duplicate`)

Update `prompt_sections` with principle-based agent prompt (not 6 rigid workflow paths):

```
## Principles

1. DISCOVER BEFORE GENERATING: Call discover_skills(query) before generating skills.
   Reuse existing skill names verbatim where they match.
2. LIBRARY FIRST: Extend existing library. First session establishes it.
3. FRAMEWORK vs ROLE: "Create a skill framework for X" → save_to_library.
   "Create an X role" → save_role_profile.
4. HANDLE NEAR-MATCHES: After saving, review near-match pairs one at a time.
   Merge or dismiss.
5. INCREMENTAL IS NORMAL: Draft skills expected. Duplicates resolved incrementally.
6. STANDARDS AS REFERENCE: Load standards, offer to adopt or fork.
```

`proficiency_writer` agent: **no change**

**Tests**: Tool execution tests with mock data table rows

> **Milestone**: End-to-end "create framework → save to library → create role → discover existing skills" workflow is functional after this step.

---

## Step 6: LiveView + Router Updates

### 6.1 Rename existing views
- `FrameworkListLive` → `RoleProfileListLive` (add role_family/seniority grouping)
- `FrameworkShowLive` → `RoleProfileShowLive` (linked library skills)

### 6.2 New views
- `SkillLibraryLive` — browse/search org skill library, filter by status, immutable badge

### 6.3 Router
```
/orgs/:org_slug/libraries           ← list libraries
/orgs/:org_slug/libraries/:id       ← browse a library
/orgs/:org_slug/roles               ← list role profiles
/orgs/:org_slug/roles/:id           ← role profile detail
/orgs/:org_slug/chat                ← chat session
```

Nav: `Chat | Libraries | Roles | Settings | Members`

**Tests**: LiveView mount + event tests

---

## Step 7: Standard Framework Templates

- Bundle SFIA v8 in `priv/templates/sfia_v8.json` (seed data, not LLM-generated)
- Implement `load_template/1` — loads as immutable library
- Implement `adopt_skills/3` — cherry-pick from standard into org library
- Template versioning: load new versions alongside old

**Tests**: Load template → browse → adopt individual skills → verify lineage

---

## Phase 10: Individual Profiles + Observations — `Prism.People`

> References `Prism.Catalog` for skill lookups (not `Prism.SkillLibrary`).

### 10.1 Profile CRUD
- `list_individual_profiles/2` (filter by tag dimensions)
- `upsert_individual_profile/2` (by email)
- `get_individual_profile/2`, `get_individual_profile_by_email/2`

### 10.2 Observation system
- `record_observation/2` — append observation + weighted evidence model (recency decay, confidence growth)
- `record_observations_bulk/2` — batch reviews (N observations tagged with same context)
- `get_observation_history/2`

**Tests**: Weighted level update, confidence saturation at ~10 observations, recency decay

---

## Phase 11: Gap Analysis

> Gap functions live in `Prism.Roles` (not a separate `Prism.GapAnalysis` module).

- `individual_gap/2` — one person vs one role profile
- `team_gap/2` — N people vs one role profile (avg gap, pct meeting)
- `aggregate_gaps/2` — org-wide, filterable by tag dimensions (team, dept, location)
- Low-confidence flagging in gap results
- Plugin tools for gap queries
- Profile UI: skill snapshot, gap heatmap vs a role, observation history

**Tests**: Gap accuracy across confidence levels, team/org aggregation

---

## Phase 12: Lens System — Schema + Scoring Engine — `Prism.Lenses`

> References `Prism.Catalog` for skill lookups (not `Prism.SkillLibrary`).

### 12.1 Lens definition CRUD
- `create_lens/2`, `get_lens/2`, `list_lenses/1`
- `seed_aria_lens/1` — built-in ARIA template

### 12.2 Generic scoring algorithm
- `score/3` — compute per-axis composites, classify bands, lookup classification (2-axis), persist
- `compute_composite/1` — weighted sum with inverse support
- `classify_band/3` — N-band classification from thresholds

**Tests**: Composite with inverse variables, band classification, 2-axis matrix lookup, 3+ axis (no matrix)

---

## Phase 13: Lens — LLM Scoring Integration

- `score_via_llm/2` — trigger LLM scoring using lens prompt template
- Work activity extraction → tag activities per lens → score variables citing activities
- Streaming support for real-time scoring feedback

**Tests**: LLM scoring round-trip, streaming partial results

---

## Phase 14: Lens — Dashboard Data Queries + Visualization

### 14.1 Prism data queries (return plain maps, no rendering)
- `scores_by_classification/1` — aggregated counts per matrix cell
- `scores_with_axes/1` — all scores with per-axis composites
- `scores_by_group/2` — group by tag dimension
- `score_summary/1` — metric card data
- `score_detail/1`, `variable_breakdown/1` — detail drill-down
- `activity_breakdown/2` — work activities with lens-specific tags

### 14.2 Lens Dashboard workspace (rho_web)
- `LensDashboardProjection` — reduces lens signals into dashboard state
- `LensDashboardComponent` — root panel, selects sub-components by axis count
- Chart components (server-side SVG):
  - `LensMatrixComponent` (2-axis with classifications)
  - `LensScatterComponent` (2-axis)
  - `LensRadarComponent` (3+ axis)
  - `LensBarChartComponent` (1-axis)
  - `LensVariableBreakdownComponent`, `LensDetailPanelComponent`
  - `LensSummaryCards`

### 14.3 Multi-workspace split view
- `active_workspace_id` → `visible_workspace_ids` (ordered list)
- Dynamic grid: 1 panel = `1fr 6px 1fr`, 2 panels = `1fr 6px 1fr 6px 1fr`
- Ctrl+Click tab to split (vs Click to replace)
- Register `lens_dashboard` in workspace registry

### 14.4 Signal flow
- Agent scores role → `lens_score_update` signal → projection reduces into state → component renders
- User clicks classification cell → `lens_filter` event → filters update → signal back to agent

**Tests**: Projection reduces mock signals, component rendering, split view with DataTable + lens dashboard

---

## Critical Path

```
Step 1 (Schema Switching)
  → Step 2 (Schemas + Migration)
    → Step 3 (Prism.Catalog)
      → Step 4 (Prism.Roles)
        → Step 5 (Plugin Swap)
          → Step 6 (LiveViews)
          → Step 7 (Templates)

Step 4 (Prism.Roles) → Phase 10 (People/Observations) → Phase 11 (Gap Analysis)

Step 3 (Prism.Catalog) → Phase 12 (Lens Scoring) → Phase 13 (LLM Integration) → Phase 14 (Dashboard)
```

- Steps 6 and 7 can run in parallel after Step 5.
- Phases 10–11 (People) and 12–14 (Lenses) can run in parallel after their respective dependencies are stable.
- Lens and Observation tables are added in their own phases (not in the Step 2 migration).
