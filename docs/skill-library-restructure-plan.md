# Prism — Role Profiles & Typed Libraries

> **Scope**: Typed library system, role profiles, skill gap analysis, standard framework import, skill merging/dedup, and data migration.
> **Out of scope** (separate plans):
> - [Lens System](prism-lens-system-plan.md) — N-dimensional scoring framework (first lens: ARIA AI Readiness)
> - [Observation Model](prism-observation-model-plan.md) — Individual profiles, observations, and weighted evidence model
> **Deferred** (build extension points now, machinery later):
> - Library type-specific validation dispatch (add when second library type is real)
> - Psychometric scoring in Elixir (lives in Rust in ds-aether, leave it there)
> - Cross-dimension weighting (per-dimension gap reports are more useful for now)
> - Generic matching/scoring framework
> - Skill splitting (reverse of merge — rare, manual workflow is fine)
>
> **Design review**: See [prism-design-review.md](prism-design-review.md) and [prism-design-review-response.md](prism-design-review-response.md) for the discussion that shaped this revision.

## Goal

Restructure the flat `Framework → Skills` model into a **typed library system** with **role profiles**. Prism separates three concerns currently conflated in "Framework":

1. **Catalogs** (typed libraries) — what items exist in a domain and what proficiency/scoring looks like
2. **Role profiles** — the full picture of what a role *is* (purpose, accountabilities, work activities, context) and what skills a person needs to succeed (`RoleSkill` join)
3. **Gap analysis** — comparing a person's actual profile against a role profile's skill requirements

Prism lives as an umbrella app within Rho, plugging into the platform shell (`rho_web`) for auth, navigation, and shared UI.

## Current Model

```
Organization (1) → (*) Framework (1) → (*) Skill
```

A Framework is simultaneously "the skill catalog" and "what a role needs" — these are different concerns that should be separated.

## Target Model

```
Organization
  │
  ├── (*) Library                               ← typed catalogs (skill, psychometric, qualification, ...)
  │     ├── name, description, type
  │     ├── immutable (bool)                    ← true for standard frameworks (SFIA, ESCO)
  │     ├── derived_from (FK → Library)         ← tracks fork lineage
  │     └── (*) Skill                           ← items within a library (skills for now)
  │           ├── source_skill_id (FK → Skill)  ← per-skill fork lineage for reliable diff/upgrade
  │           └── proficiency_levels (JSONB)    ← level definitions embedded, not a separate table
  │
  ├── (*) RoleProfile                           ← what the role IS (authored or forked from template)
  │     ├── purpose, accountabilities, success_metrics, qualifications  ← optional rich fields
  │     ├── role_family, seniority_level, seniority_label
  │     ├── source_role_profile_id (FK → RoleProfile)  ← fork lineage (from template or cloned role)
  │     ├── immutable (bool)                   ← true for reference roles from standard templates
  │     ├── work_activities (JSONB)             ← embedded, not a separate table
  │     └── (*) RoleSkill (join)                ← skill + min_expected_level + weight
  │
  ├── (*) DuplicateDismissal                    ← "these two skills are intentionally different"
  │
  └── (future) IndividualProfile, Lenses        ← see separate plans
```

### Role Profile and Skill Requirements

There is no separate "success profile" stored in the system. The role profile's skill requirements (`RoleSkill` join) capture what skills a person needs and at what level. This is sufficient for the skill dimension. If psychometric or qualification dimensions arrive later, a multi-dimensional "success profile" concept can be revisited then.

### Key Design Decisions

1. **Multiple libraries per org, typed.** An org can have a "Technical Engineering Skills" library, a "Leadership Behaviors" library, and import SFIA as a third — each with its own taxonomy and proficiency scale. The `type` field (default `"skill"`) is an extension point for future library types (psychometric, qualification). No type-specific validation dispatch yet — just the discriminator field.

2. **Libraries are independent.** If two libraries both contain "SQL", those are different items. No cross-library identity. This avoids the coordination problem of "who owns the canonical SQL?" If cross-library linking is needed later, add an optional `canonical_id` or tagging system — don't bake it into the identity model.

3. **Standard libraries are immutable.** SFIA, ESCO, and other standard frameworks are loaded as immutable libraries. Nobody edits the standard — you **fork** it into a mutable working library. The immutable source serves as a reference for diffing, auditing, and upgrading when new versions release. See [Immutable Libraries & Forking](#immutable-libraries--forking).

4. **Proficiency levels are embedded JSONB on the skill row.** Instead of a separate `ProficiencyLevel` table, each skill stores its levels as a JSONB list of `%{level, level_name, level_description}` maps. This eliminates a table and joins — levels are always loaded with the skill. The current flat model (one row per skill×level) caused ~80% row duplication; embedding solves that without adding a join.

5. **RoleProfile describes the role; RoleSkill captures what a person needs.** Purpose, accountabilities, success metrics, and qualifications are first-class text fields on RoleProfile — not afterthoughts in a metadata blob. `RoleSkill` is a join that says which skills are needed and at what level. There is no separate "success profile" concept stored in the system.

6. **`source_skill_id` provides per-skill fork lineage.** When a library is forked, each copied skill gets a nullable FK pointing back to its source skill. This makes fork-diff/upgrade reliable even after renames or merges in the fork, unlike slug-based diffing which breaks when slugs diverge.

7. **Role profile rich fields are progressive, not mandatory.** Only `name` and at least one skill are required to save a role profile. All other fields (`purpose`, `accountabilities`, `success_metrics`, `qualifications`, `reporting_context`) default to nil and can be filled in later — either manually or via agent-assisted enrichment from the skill list. This avoids forcing users to write job descriptions when they came to build a skill framework.

8. **Skills have a normalized slug for identity.** The unique key is `(library_id, slug)` where `slug` is auto-generated from the skill name (lowercased, trimmed, hyphenated). `category` and `cluster` are organizational attributes, not part of identity — renaming a category doesn't create a duplicate skill.

9. **`save_role_profile` auto-upserts skills into a library.** In the bottom-up workflow, skills are created as **draft** entries (missing proficiency level descriptions) as a side effect of role creation. Draft skills are fully functional for role requirements but flagged for library review. This eliminates the "Skill 'X' not found in library" error.

10. **Draft skills** created via `save_role_profile` have `status: :draft`. They lack full proficiency level descriptions. The consolidation workflow surfaces drafts for completion. Skills saved directly via `save_to_library` are `status: :published`.

11. **Gap analysis is per-dimension.** Today that means per-library (skills only). When psychometric or qualification dimensions are added, each produces its own gap report with its own scoring logic. No cross-dimension weighting yet — per-dimension reports are more useful than a blended number.

12. **Skill merging is an explicit, interactive operation.** Duplicates are detected via tiered analysis (slug similarity, word overlap, optional LLM), resolved one pair at a time with user decisions, and permanently dismissed when confirmed as intentionally distinct. See [Skill Merging & Deduplication](#skill-merging--deduplication).

13. **Standard templates bundle skills AND role profiles.** Most standards (SFIA, ESCO, O*NET) define role→skill mappings alongside the skill taxonomy. `load_template` imports both as immutable reference data. `fork_library` deep-copies both, remapping `RoleSkill` FKs to the forked skills. This means Workflow A gives users a complete starting point — not just a skill list they have to manually wire to roles.

14. **Role profiles have fork lineage too.** `source_role_profile_id` (nullable FK) tracks which reference role a forked profile came from. Combined with `immutable` flag on role profiles, this enables diffing a customized role against its standard source — "you changed 3 skill levels and added 2 skills vs the SFIA reference."

15. **Skills are role-centric.** In every workflow, skills enter the system *through* or *alongside* role profiles. A skill with zero role references is either transient (roles coming next) or orphaned (flagged by consolidation). The library is the vocabulary; roles give skills purpose.

### What's deferred and why

- **Type-specific validation is complex with zero users** — psychometric profiles live in Rust (ds-aether). Building Elixir validation dispatch for a type that doesn't exist yet is premature.
- **Cross-dimension scoring needs real use cases** — how to weight "60% skill fit + 20% psychometric fit" is a product decision, not an engineering one.
- **Skill splitting** is the reverse of merge: "Data Engineering" is too broad, split into "ETL Development" and "Data Pipeline Architecture." This requires per-role judgment (which new skill applies to each role?) and is rare enough that the manual path works: create new skills, update role profiles, archive the old skill.

---

## Immutable Libraries & Forking

### The principle

**Standard frameworks are immutable. Customization is always a fork.**

When a company says "we use SFIA," the system loads SFIA as a read-only reference library. Any customization — renaming skills, rewriting proficiency descriptions, adding org-specific skills — happens in a forked mutable copy. The standard is the standard; you reference it or fork it, you don't edit it.

### Why this matters

- **The merge problem vanishes.** When SFIA v9 releases, load it as a new immutable library. Diff your fork against v9: "12 skills added, 3 descriptions changed, 2 retired." Selectively pull changes into your fork. No three-way merge.
- **Provenance is structural, not metadata.** `derived_from_id` is a hard FK link. "Where did this library come from?" is a query, not a string field someone might forget to fill.
- **Auditability is free.** "Show me everything we changed from the standard" = diff the fork against its parent.

### How it works

```
SFIA v8 (immutable)          ← loaded once, locked, nobody edits
    │
    ├── fork → "Acme Engineering Skills" (mutable)    ← org's working copy
    │           - adds 5 custom skills
    │           - rewrites 12 proficiency descriptions
    │           - archives 40 irrelevant skills
    │
    └── fork → "Acme Leadership Behaviors" (mutable)  ← different subset
                - only the leadership-related SFIA skills
                - customized for org culture
```

Role profiles reference skills in the **fork**, never in the immutable source. The source is a reference artifact — you can browse it, diff against it, but never modify it.

### Library categories

| Category | Immutable | `derived_from` | Example |
|----------|-----------|----------------|---------|
| Standard template | yes | nil | SFIA v8, ESCO subset |
| Fork of standard | no | → standard | "Acme Engineering Skills" (from SFIA v8) |
| Agent-generated | no | nil | Built via bottom-up role creation |
| Company import | no | nil | Imported from company spreadsheet |

### Standard framework templates

Standard libraries are **bundled seed data** stored as structured assets in `priv/templates/` (JSON/YAML), not generated by an LLM. This ensures accuracy and determinism.

Templates bundle **both skills and role profiles** — most standards (SFIA, ESCO, O*NET) define role→skill mappings alongside the skill taxonomy. Importing only skills throws away half the value.

```
load_template("sfia_v8")
  → creates Library(name: "SFIA v8", immutable: true, source_key: "sfia_v8")
  → bulk-inserts all skills + proficiency levels
  → bulk-inserts reference role profiles + role_skill mappings
  → returns: "Loaded SFIA v8: 97 skills across 6 categories, 24 reference role profiles"
```

Reference role profiles from templates are **also immutable** — they serve as starting points, not editable records. Users fork the library to get mutable copies of both skills and roles.

Multiple standards can coexist: SFIA v8, ESCO Data Engineering, CompTIA Security+. Each can be forked independently.

Start by bundling SFIA (the dominant standard in competency assessment). Add others as needed.

### Fork operation

```elixir
def fork_library(org_id, source_library_id, new_name, opts \\ []) do
  source = get_library!(org_id, source_library_id)
  categories = Keyword.get(opts, :categories, :all)
  include_roles = Keyword.get(opts, :include_roles, true)

  Ecto.Multi.new()
  |> Ecto.Multi.insert(:library, %Library{
    name: new_name,
    organization_id: source.organization_id,
    type: source.type,
    immutable: false,
    derived_from_id: source.id,
    description: "Derived from #{source.name}"
  })
  |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
    skills = list_skills(source.id, categories: categories)
    skill_id_map = Map.new(skills, fn skill ->
      copied = copy_skill(skill, lib.id, source_skill_id: skill.id)
      {skill.id, copied}
    end)
    {:ok, skill_id_map}
  end)
  |> Ecto.Multi.run(:role_profiles, fn _repo, %{library: _lib, skills: skill_id_map} ->
    if include_roles do
      source_roles = list_role_profiles_for_library(source.id, categories: categories)
      copied = Enum.map(source_roles, fn role ->
        copy_role_profile(role, org_id, skill_id_map)
      end)
      {:ok, copied}
    else
      {:ok, []}
    end
  end)
  |> Repo.transaction()
end
```

Key behaviors:
- **Subset fork**: Pass `categories: ["Software Development", "Data Management"]` to only copy relevant skills and the role profiles that reference them. Keeps the fork lean.
- **Full fork**: Omit categories to copy everything. User archives what they don't need later.
- **Skills are deep-copied**: `proficiency_levels` JSONB is copied along with all skill fields. `source_skill_id` tracks lineage back to the original. The fork is fully independent — edits to the fork don't touch the source.
- **Role profiles are deep-copied** by default: each copied role profile gets new `RoleSkill` entries pointing to the forked skills (via `skill_id_map`). Pass `include_roles: false` to fork skills only.
- **`list_role_profiles_for_library/2`**: returns role profiles whose `RoleSkill` entries reference skills in the given library. When category-filtered, only roles that have at least one skill in the selected categories are included, and their `RoleSkill` entries are filtered to the copied skills.

### Diff operation

```elixir
def diff_against_source(org_id, library_id) do
  lib = get_library!(org_id, library_id) |> Repo.preload(:derived_from)

  source_skills = list_skills(lib.derived_from_id) |> index_by(:id)
  fork_skills = list_skills(library_id) |> index_by_source_skill_id()

  %{
    added: Map.keys(fork_skills) -- Map.keys(source_skills),
    removed: Map.keys(source_skills) -- Map.keys(fork_skills),
    modified: find_modified(source_skills, fork_skills),
    unchanged: find_unchanged(source_skills, fork_skills)
  }
end
```

Enables the upgrade workflow: load SFIA v9 → diff your fork against v9 → review changes → selectively pull in.

### Immutability enforcement

The `immutable` flag is enforced at the context level. All write operations — `upsert_skill`, `save_to_library`, `merge_skills`, etc. — check the target library's `immutable` flag and reject writes with a clear error:

```elixir
defp ensure_mutable!(library) do
  if library.immutable do
    {:error, :immutable_library,
     "Cannot modify '#{library.name}' — it is a standard framework. " <>
     "Fork it with fork_library to create a mutable working copy."}
  else
    :ok
  end
end
```

### `derived_from` chain depth

Always exactly 0 or 1 level deep. Fork of a fork points to its immediate parent only. Deep lineage tracking is a version control problem, not a competency framework problem.

---

## Supported Workflows

The system supports four workflow patterns. All use the same tools and schema — they differ in the order of operations and the source of library data.

### Workflow A: Import standard framework

For orgs adopting SFIA, ESCO, or another standard taxonomy. The library exists *before* any role.

```
Session 1: "We use SFIA"
  load_template("sfia_v8")            → immutable library + reference role profiles created
  "Which categories are relevant?"    → user picks subset
  fork_library("SFIA v8", "Acme Engineering Skills", categories: [...])
                                      → mutable fork created with selected skills AND role profiles
  User reviews fork, optionally edits descriptions
  save_to_library()                   → persists edits

Session 2: "Customize the Data Engineer role"
  list_role_profiles()                → shows forked reference roles from SFIA
  load_role_profile("Data Engineer")  → pre-populated with SFIA's role→skill mapping
  Agent/user adjusts required_levels, adds/removes skills
  save_role_profile("Data Engineer", role_family: "Engineering", seniority: 3)
    → updates the forked role profile

Session 2 (alt): "Create a Platform Engineer role" (not in SFIA)
  browse_library("Acme Engineering Skills") → existing skills as vocabulary
  clone_role_skills([sre_id, devops_id])    → borrow from similar forked roles
  save_role_profile("Platform Engineer", ...)

Session 3+: Customize more forked roles, or create new ones from the library
```

### Workflow B: Import company framework

For orgs that already have a competency framework in a PDF, spreadsheet, Word doc, or pasted text. The source is often semi-structured — not a clean CSV. The agent uses LLM reasoning to parse the document into structured skill and role data.

```
Session 1: "Import our competency framework"
  Agent ingests source document via doc_ingest or fs_read
  LLM extracts:
    a) Skill catalog: categories, clusters, skill names, proficiency levels
    b) Role→skill mappings (if present): role names, required skills, expected levels

  Phase 1: Skills
    Agent streams parsed skills into data table (library mode)
    User reviews/edits extracted skills
    save_to_library()  → mutable library created, skills bulk-loaded (status: published)

  Phase 2: Roles (if role mappings were extracted)
    For each extracted role:
      Agent populates data table (role mode) with role's skill assignments
      User reviews/edits
      save_role_profile("Role Name", ...)
    Or: batch-save all roles without individual review if user trusts the extraction

Session 2+: Create roles from imported library (same as Workflow A Session 2+)
```

### Workflow C: Role-by-role, then consolidate (bottom-up)

The most natural workflow for orgs starting from scratch. Each session adds skills to the library.

```
Session 1: "Create a framework for Data Engineer"
  Agent calls browse_library() — library is empty (first role)
  Agent generates skills + proficiency levels in data table
  save_role_profile("Data Engineer", ...)
    → skills auto-upserted into library as drafts + role created

Session 2: "Now do ML Engineer"
  Agent calls browse_library() — sees existing skills from Session 1
  Agent generates skills, REUSING existing skill names where applicable
  Overlap: "SQL", "Python" already in library — kept as-is, new skills added as drafts
  save_role_profile("ML Engineer", ...) → new skills added to library + role created

Session 3: "Review our full library"
  consolidation_report() →
    "47 skills total. 4 likely duplicate pairs. 8 drafts need proficiency descriptions."
  Agent walks through duplicates one pair at a time (see Skill Merging section)
  User edits drafts, adds missing level descriptions
  save_to_library() → promotes drafts to published
```

### Workflow D: Hybrid

```
Sessions 1-3: Build roles for Data Engineer, ML Engineer, Data Analyst (bottom-up)
Session 4:    Consolidate library — merge duplicates, promote drafts, clean descriptions
Session 5+:   Create remaining roles by selecting from clean library (top-down role derivation)
```

### Key observations

All workflows follow the same rule: **roles reference library skills**. The difference is how skills and roles enter the system:
- Workflow A: forked from an immutable standard template (skills AND reference role profiles)
- Workflow B: bulk-imported from external data (skills + optional role mappings)
- Workflow C: built implicitly as a side effect of `save_role_profile` (skills as drafts, roles are the primary artifact)
- Workflow D: mix of C then A/B refinement

Note: in every workflow, skills enter the system *through* or *alongside* role profiles. A skill without any role reference is either transient (roles coming next) or orphaned (flagged by consolidation). The system is role-centric — skills are the vocabulary, roles give them purpose.

Either way, the library is the canonical source of truth.

### Duplicate prevention in bottom-up workflows

The biggest risk in bottom-up (Workflow C) is skill identity drift across sessions — the agent generates "SQL Programming" in session 1 and "SQL Querying" in session 2 for the same competency.

**Prevention is mandatory**: the agent workflow **must** call `browse_library()` before generating skills for a new role. The existing skill names are injected into the generation prompt as a controlled vocabulary:

```
Agent workflow (before generating skills):
  1. call browse_library(library_id)
     → returns: ["SQL", "Python", "Data Modeling", "ETL Design", ...]
  2. System prompt injection:
     "The following skills already exist in the library. Reuse these exact names
      where they apply. Only invent new names for genuinely new competencies:
      [skill list]"
  3. Agent generates skills, constrained by existing vocabulary
```

For the first role (empty library), there's nothing to match — that's fine. For every subsequent role, the agent works against the existing vocabulary. This doesn't eliminate all duplicates (subtle semantic overlap will still occur), but it catches the obvious naming inconsistencies that are the most common source.

### Library vs Role: two distinct actions, two data table schemas

The library and role profile are **separate editing sessions** with different data and different column layouts.

| Concept | Lives in | Example |
|---------|----------|---------|
| Skill definition | Library (`skills` table) | "SQL" — category: Technical, cluster: Data Engineering |
| Skill description | Library (`skills` table) | "Ability to write and optimize relational database queries" |
| Proficiency level definitions | Library (`proficiency_levels` table) | Level 3: "Writes complex joins and window functions, optimizes slow queries using EXPLAIN" |
| Required level for a role | Role Profile (`role_skills` join) | Senior Data Engineer needs SQL at level 4 |
| Whether skill is must-have or nice-to-have | Role Profile (`role_skills` join) | SQL is required; Graph Databases is optional |

### Two data table modes

The data table serves as the editing surface for both actions, driven by two `DataTable.Schema` definitions (already implemented in `RhoWeb.DataTable.Schemas`):

**Library mode** (building/editing the skill catalog):
```
| category | cluster | skill_name | skill_description | level | level_name | level_description |
```
- One row per skill×level combination (same as today)
- The agent generates skills + all proficiency level definitions
- Saved with `save_to_library`

**Role profile mode** (selecting skills + setting requirements):
```
| category | cluster | skill_name | required_level | required |
```
- One row per skill (NOT per level — no proficiency descriptions here)
- Pre-populated from the library: `load_library` fills in all available skills
- User/agent removes skills not needed for this role, sets required_level per skill
- `required` is a boolean: must-have vs nice-to-have
- Saved with `save_role_profile`

This separation is clean: library mode is about **defining what proficiency looks like**, role profile mode is about **specifying what this role needs**.

### Mode switching UX

Mode transitions must be explicit and clear:
- The data table UI shows the active mode prominently: "Editing: Skill Library" or "Editing: Role Profile — Senior Data Engineer"
- When switching modes with unsaved edits, the system warns: "You have unsaved library edits. Switch to role profile mode?"
- Schema switching is driven by signals: `load_library` publishes `data_table_schema_change` with `Schemas.skill_library()`, and `load_role_profile` publishes with `Schemas.role_profile()`

### The five save/load operations

| Action | DataTable schema | What happens |
|--------|-----------------|-------------|
| `save_to_library` | `Schemas.skill_library()` | Normalizes flat rows into skills + proficiency_levels (status: published) |
| `load_library` | `Schemas.skill_library()` | Denormalizes library into flat skill×level rows for editing |
| `save_role_profile` | `Schemas.role_profile()` | Auto-upserts skills as drafts + creates role profile + role_skill entries |
| `load_role_profile` | `Schemas.role_profile()` | Loads a role's skill selection + required levels for editing |
| `import_library` | — | Bulk-loads structured rows from CSV/template into a new mutable library |

### Proficiency level handling in bottom-up workflow

When `save_role_profile` auto-upserts a new skill:
- The skill is created with `status: :draft`
- If role-mode rows include proficiency levels (from the agent's generation), those are saved
- If no proficiency levels are provided (role mode only has `required_level`), the skill exists without level descriptions
- Draft skills are fully functional for role requirements — `required_level` is an integer, not a FK to proficiency_levels
- The consolidation workflow surfaces drafts: "8 skills need proficiency level descriptions"
- `save_to_library` promotes drafts to `status: :published` when level descriptions are added

---

## Skill Merging & Deduplication

### When duplicates arise

1. **Bottom-up naming drift**: Role A creates "SQL Programming", Role B creates "SQL Querying". Same competency, different slugs.
2. **Post-fork + bottom-up collision**: User forked SFIA (which has "Database Query Language"), then bottom-up adds "SQL" as a draft. Same concept, unlinked.
3. **Team consolidation**: Two departments built role profiles independently, creating parallel names for the same skills.
4. **Naming evolution**: Early roles used "Machine Learning", newer ones use "AI/ML". Both coexist.

Slug-based dedup catches exact name matches. Everything else requires detection + manual resolution.

### Duplicate detection (tiered)

```elixir
def find_duplicates(library_id, opts \\ []) do
  depth = Keyword.get(opts, :depth, :standard)  # :standard | :deep

  skills = list_skills(library_id)
  dismissed = list_dismissed_pairs(library_id)

  candidates =
    find_slug_prefix_overlaps(skills) ++
    find_word_overlap_in_category(skills)

  candidates = if depth == :deep do
    candidates ++ find_semantic_duplicates_via_llm(skills)
  else
    candidates
  end

  candidates
  |> deduplicate_pairs()
  |> reject_dismissed(dismissed)
  |> sort_by_confidence()
  |> enrich_with_role_references()
end
```

**Tier 1: Slug prefix overlap** (fast, high precision)
- "sql-programming" and "sql-querying" share prefix "sql"
- "data-analysis" and "data-analytics" share prefix "data-analy"

**Tier 2: Word overlap within same category** (fast, medium precision)
- Skills in same category: Jaccard similarity on tokenized names
- "SQL Programming" ∩ "SQL Development" → shared "sql", different qualifier

**Tier 3: LLM-assisted semantic matching** (slow, high recall, opt-in)
- "Stakeholder Management" vs "Client Relationship Management" — no word overlap but semantically similar
- Only triggered with `depth: :deep`

Each candidate pair returns:

```elixir
%{
  skill_a: %{id: ..., name: "SQL Programming", slug: "sql-programming"},
  skill_b: %{id: ..., name: "SQL Querying", slug: "sql-querying"},
  confidence: :high,          # :high | :medium | :low
  detection_method: :slug_prefix,
  roles_a: ["Data Engineer", "Analytics Engineer"],
  roles_b: ["ML Engineer"],
  level_conflict: false       # true if any shared role has different levels
}
```

### Merge operation

```elixir
def merge_skills(source_id, target_id, opts \\ []) do
  source = get_skill!(source_id) |> Repo.preload([:library, :proficiency_levels])
  target = get_skill!(target_id) |> Repo.preload([:library, :proficiency_levels])

  ensure_mutable!(source.library)
  ensure_mutable!(target.library)

  new_name = Keyword.get(opts, :new_name)
  conflict_strategy = Keyword.get(opts, :on_conflict, :keep_higher)

  source_refs = list_role_skills_for(source_id)
  target_refs = list_role_skills_for(target_id) |> index_by_role_id()

  {clean, conflicted} = Enum.split_with(source_refs, fn rs ->
    not Map.has_key?(target_refs, rs.role_profile_id)
  end)

  Ecto.Multi.new()
  |> Ecto.Multi.run(:repoint, fn _repo, _ ->
    # Clean: just repoint FK from source to target
    repoint_role_skills(clean, target_id)
    {:ok, length(clean)}
  end)
  |> Ecto.Multi.run(:conflicts, fn _repo, _ ->
    # Conflicted: role has both source and target skills
    results = Enum.map(conflicted, fn source_rs ->
      target_rs = target_refs[source_rs.role_profile_id]
      resolve_conflict(source_rs, target_rs, conflict_strategy)
    end)
    {:ok, results}
  end)
  |> Ecto.Multi.run(:levels, fn _repo, _ ->
    # Fill proficiency level gaps from source into target
    {:ok, merge_proficiency_levels(source_id, target_id)}
  end)
  |> Ecto.Multi.run(:rename, fn _repo, _ ->
    if new_name, do: rename_skill(target_id, new_name), else: {:ok, nil}
  end)
  |> Ecto.Multi.run(:delete, fn _repo, _ ->
    # Delete source skill (proficiency_levels cascade)
    delete_skill(source_id)
  end)
  |> Repo.transaction()
end
```

**The source is absorbed into the target. The target survives.**

#### RoleSkill conflict resolution

When a role references *both* the source and target skill, two `RoleSkill` rows would collapse into one. Resolution strategies:

| Strategy | Behavior | When to use |
|----------|----------|-------------|
| `:keep_higher` (default) | `max(source_level, target_level)` | Conservative — doesn't lower any bar |
| `:keep_target` | Target's level wins, source discarded | Target is authoritative (from standard) |
| `:flag` | Return conflicts without resolving | When levels differ significantly |

#### Proficiency level merging

Fill gaps only — never overwrite existing target descriptions:

```elixir
defp merge_proficiency_levels(source, target) do
  source_levels = Map.new(source.proficiency_levels, & {&1.level, &1})
  target_levels = Map.new(target.proficiency_levels, & {&1.level, &1})

  merged = Map.merge(source_levels, target_levels)  # target wins on conflict
  gaps = map_size(merged) - map_size(target_levels)

  update_skill_levels(target, merged |> Map.values() |> Enum.sort_by(& &1.level))
  %{filled: gaps, total: map_size(merged)}
end
```

#### Optional rename on merge

Sometimes neither original name is right. "SQL Programming" + "SQL Querying" should merge into just "SQL":

```elixir
merge_skills(source_id, target_id, new_name: "SQL")
```

If `new_name` is provided, the target skill is renamed (slug regenerated) after merge. Rename checks for slug collision with other skills in the same library.

### Dismissal mechanism

When the user says "keep these separate," that decision persists so `find_duplicates` won't re-flag the same pair.

```elixir
def dismiss_duplicate(library_id, skill_a_id, skill_b_id) do
  # Always store with smaller ID first for consistent lookup
  {id_a, id_b} = if skill_a_id < skill_b_id, do: {skill_a_id, skill_b_id}, else: {skill_b_id, skill_a_id}

  %DuplicateDismissal{}
  |> DuplicateDismissal.changeset(%{library_id: library_id, skill_a_id: id_a, skill_b_id: id_b})
  |> Repo.insert(on_conflict: :nothing)
end
```

### The consolidation workflow (interactive, not batch)

The critical UX decision: **one pair at a time**, not a spreadsheet of all duplicates. Each decision changes the state, so later decisions depend on earlier ones.

```
Agent calls: consolidation_report(library_id)
→ "Library has 47 skills. Found:
   - 4 likely duplicate pairs (2 high confidence, 2 medium)
   - 12 draft skills needing proficiency descriptions
   - 2 orphan skills (not used by any role)
   Start with duplicate resolution?"

User: "yes"

--- Pair 1 (high confidence) ---
Agent: "'SQL Programming' and 'SQL Querying' appear to be the same skill.
   • SQL Programming — used by: Data Engineer (level 4), Analytics Engineer (level 3)
   • SQL Querying — used by: ML Engineer (level 4)
   Options:
   (a) Merge into 'SQL Programming'
   (b) Merge into 'SQL Querying'
   (c) Merge into a new name
   (d) Keep separate — these are intentionally different"

User: "c, call it SQL"

Agent calls: merge_skills(sql_programming_id, sql_querying_id, new_name: "SQL")
→ "'SQL' now referenced by 3 roles. Filled 2 missing proficiency levels from source.
   Data Engineer: level 4, Analytics Engineer: level 3, ML Engineer: level 4."

--- Pair 2 (medium confidence) ---
Agent: "'Data Analysis' and 'Statistical Analysis' — same skill or different?
   • Data Analysis — used by: Data Engineer, Business Analyst
   • Statistical Analysis — used by: ML Engineer, Research Scientist
   Note: descriptions differ — Data Analysis focuses on exploratory work,
   Statistical Analysis focuses on hypothesis testing."

User: "keep separate"

Agent calls: dismiss_duplicate(library_id, data_analysis_id, statistical_analysis_id)
→ "Got it, marked as intentionally distinct. Won't flag again."

--- After duplicates ---
Agent: "Duplicates resolved. Next: 12 draft skills need proficiency descriptions.
   Highest priority: 'Python' (used by 5 roles). Add proficiency descriptions?"

--- Draft completion by priority ---
Drafts sorted by role reference count. Most-used skills first.
Agent can generate draft descriptions, user reviews and edits.
save_to_library() promotes edited drafts to published.
```

### Prevention vs. cure layers

| Layer | Mechanism | Coverage |
|-------|-----------|----------|
| Prevention | Agent `browse_library` before generation, constrained vocabulary | Catches obvious naming inconsistencies |
| Detection (standard) | Slug prefix overlap + word overlap in category | Catches near-misses post-hoc |
| Detection (deep) | LLM-assisted semantic matching (opt-in) | Catches semantic duplicates |
| Resolution | `merge_skills` with conflict handling + proficiency gap fill | Fixes what was found |
| Memory | `dismiss_duplicate` persists "intentionally different" decisions | Stops re-flagging |

---

## Schema Design

### Table: `libraries`

```elixir
schema "libraries" do
  field :name, :string              # "Technical Engineering Skills", "Leadership Behaviors"
  field :description, :string       # what this library covers
  field :type, :string, default: "skill"  # "skill" | (future: "psychometric", "qualification", ...)
  field :immutable, :boolean, default: false  # true for standard frameworks (SFIA, ESCO)
  field :source_key, :string        # "sfia_v8", "esco" — identifies bundled template (nil for custom)
  field :metadata, :map, default: %{}     # type-specific config (no dispatch yet, extension point)

  belongs_to :organization, Organization
  belongs_to :derived_from, Library       # FK to parent library (nil = original)
  has_many :skills, Skill

  timestamps()
end
```

Constraints:
- `unique_index([:organization_id, :name])` — unique library names within org
- `index([:organization_id, :type])` — fast type filtering
- `index([:derived_from_id])` — find all forks of a library

### Table: `skills`

```elixir
schema "skills" do
  field :slug, :string              # normalized identity key (auto-generated from name)
  field :name, :string              # e.g., "SQL", "Stakeholder Management"
  field :description, :string       # 1-sentence competency boundary
  field :category, :string          # e.g., "Technical", "Leadership"
  field :cluster, :string           # e.g., "Data Engineering", "Strategy"
  field :status, :string, default: "draft"  # "draft" | "published" | "archived"

  field :sort_order, :integer
  field :metadata, :map, default: %{}
  field :proficiency_levels, {:array, :map}, default: []
    # embedded JSONB, each entry: %{level: integer, level_name: string, level_description: string}

  belongs_to :library, Library
  belongs_to :source_skill, Skill      # FK for per-skill fork lineage (nullable)
  has_many :role_skills, RoleSkill

  timestamps()
end
```

Constraints:
- `unique_index([:library_id, :slug])` — no duplicate skills within a library
- `index([:library_id, :category])` — fast category lookups
- `index([:library_id, :status])` — fast draft/published/archived filtering
- `index([:source_skill_id])` — find all forks of a skill

Slug generation:
```elixir
defp generate_slug(name) do
  name
  |> String.downcase()
  |> String.trim()
  |> String.replace(~r/[^a-z0-9]+/, "-")
  |> String.trim("-")
end
```

### Table: `role_profiles` (replaces `frameworks`)

```elixir
schema "role_profiles" do
  # Identity (required)
  field :name, :string            # "Senior Data Engineer"

  # Classification (optional)
  field :role_family, :string     # "Engineering", "Product", "Design"
  field :seniority_level, :integer  # 1=Junior, 2=Mid, 3=Senior, 4=Staff, 5=Principal
  field :seniority_label, :string   # "Senior", "Staff" (display name)

  # Rich role description (all optional — progressive enrichment)
  field :description, :string       # overview paragraph
  field :purpose, :string           # why this role exists
  field :accountabilities, :string  # what outcomes this person owns
  field :success_metrics, :string   # how performance is measured (KPIs)
  field :qualifications, :string    # education, certifications, experience requirements
  field :reporting_context, :string # who this role reports to, who reports to it

  # Planning
  field :headcount, :integer, default: 1  # planning headcount for this role
  field :metadata, :map, default: %{}

  field :work_activities, {:array, :map}, default: []
    # embedded JSONB, each entry: %{description: string, frequency: string, time_allocation: float}

  # Fork lineage
  field :immutable, :boolean, default: false  # true for reference roles from standard templates
  belongs_to :source_role_profile, RoleProfile  # FK for fork lineage (nullable)

  belongs_to :organization, Organization
  belongs_to :created_by, User
  has_many :role_skills, RoleSkill

  timestamps()
end
```

Constraints:
- `unique_index([:organization_id, :name])` — unique role names within org
- `index([:source_role_profile_id])` — find all forks of a role profile
- `index([:organization_id, :role_family])`

Note: Rich text fields (`purpose`, `accountabilities`, `success_metrics`, `qualifications`, `reporting_context`) are plain text columns. All are optional — a role profile can be saved with just a name and skills. The agent can later enrich these fields by reading the skill list and generating drafts.

### Table: `role_skills` (join)

```elixir
schema "role_skills" do
  field :min_expected_level, :integer  # required proficiency level (1-5)
  field :weight, :float, default: 1.0  # relative importance within role
  field :required, :boolean, default: true  # must-have vs nice-to-have

  belongs_to :role_profile, RoleProfile
  belongs_to :skill, Skill

  timestamps()
end
```

Constraints:
- `unique_index([:role_profile_id, :skill_id])` — one entry per skill per role
- `index([:skill_id])` — find all roles requiring a skill

### Table: `duplicate_dismissals`

```elixir
schema "duplicate_dismissals" do
  belongs_to :library, Library
  belongs_to :skill_a, Skill      # always the smaller ID
  belongs_to :skill_b, Skill      # always the larger ID

  timestamps()
end
```

Constraints:
- `unique_index([:library_id, :skill_a_id, :skill_b_id])` — one dismissal per pair per library
- `index([:library_id])` — fast lookup for filtering `find_duplicates`

---

## Gap Analysis

Gap analysis compares **role requirements** against a simple skill snapshot. It does not require the full observation model — it works with any source of "person has skill X at level Y" data.

### Input: Skill Snapshot

A skill snapshot is a simple map of `%{skill_id => current_level}`. It can come from:
- Manual entry (user provides levels during a session)
- CSV/spreadsheet import
- Future: the observation model (see separate plan)

```elixir
@type skill_snapshot :: %{skill_id() => float()}
```

### Individual Gap

```elixir
def individual_gap(skill_snapshot, role_profile_id) do
  role = Repo.get!(RoleProfile, role_profile_id) |> Repo.preload(role_skills: :skill)

  Enum.map(role.role_skills, fn rs ->
    current = Map.get(skill_snapshot, rs.skill_id, :unknown)
    gap = if current == :unknown, do: :unknown, else: rs.min_expected_level - current

    %{
      skill_id: rs.skill_id,
      skill_name: rs.skill.name,
      category: rs.skill.category,
      cluster: rs.skill.cluster,
      required_level: rs.min_expected_level,
      current_level: current,
      gap: gap,
      positive_gap: if(gap == :unknown, do: :unknown, else: max(gap, 0)),
      required: rs.required,
      weight: rs.weight
    }
  end)
end
```

Key decisions:
- **Unknown ≠ zero**: Missing skills return `:unknown`, not `0`. Downstream consumers must handle this explicitly.
- **Positive gap**: `max(required - current, 0)` — surplus skills don't cancel out deficits.
- **Weight preserved**: `role_skills.weight` is included so consumers can compute weighted gaps.

### Team Gap Aggregation

```elixir
def team_gap(snapshots_by_person, role_profile_id) do
  individual_gaps = Enum.map(snapshots_by_person, fn {person_id, snapshot} ->
    {person_id, individual_gap(snapshot, role_profile_id)}
  end)

  all_entries = individual_gaps |> Enum.flat_map(fn {_, gaps} -> gaps end)

  aggregate = all_entries
  |> Enum.group_by(& &1.skill_id)
  |> Enum.map(fn {skill_id, entries} ->
    known_entries = Enum.reject(entries, & &1.current_level == :unknown)
    unknown_count = length(entries) - length(known_entries)

    %{
      skill_id: skill_id,
      skill_name: hd(entries).skill_name,
      required_level: hd(entries).required_level,
      known_count: length(known_entries),
      unknown_count: unknown_count,
      pct_meeting: if(known_entries == [], do: :unknown,
        else: Float.round(Enum.count(known_entries, & &1.positive_gap == 0) / length(known_entries) * 100, 1)),
      avg_positive_gap: if(known_entries == [], do: :unknown,
        else: Float.round(Enum.sum(Enum.map(known_entries, & &1.positive_gap)) / length(known_entries), 2)),
      weighted_avg_gap: if(known_entries == [], do: :unknown,
        else: weighted_gap_avg(known_entries))
    }
  end)

  %{individual_gaps: individual_gaps, aggregate: aggregate}
end

defp weighted_gap_avg(entries) do
  total_weight = Enum.sum(Enum.map(entries, & &1.weight))
  if total_weight == 0, do: 0.0,
    else: Float.round(
      Enum.sum(Enum.map(entries, fn e -> e.positive_gap * e.weight end)) / total_weight, 2)
end
```

Key decisions:
- **Unknown entries excluded from averages** but reported as `unknown_count` so consumers know data is incomplete.
- **`pct_meeting` uses only known entries** — "60% of people we have data for meet the requirement" not "60% of all people."
- **Weighted average uses `role_skills.weight`** — critical skills count more in aggregate metrics.

---

## Context Module Split

The single `frameworks.ex` is split into three context modules:

**`Prism.Library`** — Library + Skill operations:
- `list_libraries(org_id, opts)` — filter by type, exclude immutable
- `get_library(org_id, id)` / `get_library!(org_id, id)`
- `create_library(org_id, attrs)` — create a new mutable library
- `get_or_create_default_library(org_id)` — returns the org's default skill library, creating one if needed
- `load_template(source_key)` — load a bundled standard framework as an immutable library with reference role profiles
- `fork_library(org_id, source_library_id, new_name, opts)` — fork a library (subset by categories), deep-copy skills AND role profiles (pass `include_roles: false` to skip)
- `list_role_profiles_for_library(library_id, opts)` — role profiles whose skills reference this library (used by fork to determine which roles to copy)
- `diff_against_source(org_id, library_id)` — diff a fork against its immutable parent
- `import_library(org_id, structured_rows, opts)` — bulk-load from pre-parsed rows (LLM parsing of PDFs/docs happens in agent layer before this call)
- `list_skills(library_id, opts)` — filter by category, cluster, status
- `get_skill(library_id, id)` / `get_skill!(library_id, id)`
- `upsert_skill(library_id, attrs)` — create or update by slug within a library (enforces mutability)
- `upsert_skills_with_levels(library_id, rows)` — bulk import from data table
- `search_skills(library_id, query, opts)` — search scoped to a library
- `search_skills_across(org_id, query, opts)` — search across all org libraries, results tagged with source library and referencing roles
- `find_duplicates(library_id, opts)` — tiered dedup detection (standard or deep), excludes dismissed pairs
- `merge_skills(source_id, target_id, opts)` — absorb source into target, repoint references, fill proficiency gaps
- `dismiss_duplicate(library_id, skill_a_id, skill_b_id)` — persist "intentionally different" decision
- `consolidation_report(library_id)` — prioritized: duplicate pairs → draft skills (by role count) → orphan skills

**`Prism.Roles`** — Role Profile operations:
- `list_role_profiles(org_id, opts)` — filter by role_family, seniority
- `get_role_profile(org_id, id)` / `get_role_profile!(org_id, id)`
- `save_role_profile(org_id, attrs, role_rows)` — auto-upserts skills into a library + creates profile + role_skills (only `name` required; all rich fields optional)
- `delete_role_profile(org_id, name)`
- `compare_role_profiles(org_id, profile_names)` — shared skills, unique skills, level diffs
- `career_ladder(org_id, role_family)` — profiles ordered by seniority with skill diffs
- `find_similar_roles(org_id, query, opts)` — find role profiles by name/family/description similarity, returns skill overlap preview
- `clone_role_skills(org_id, role_profile_ids)` — union skill selections from one or more roles, keeps highest required_level on overlap

**`Prism.GapAnalysis`** — Gap analysis (consumes skill snapshots, not the observation model):
- `individual_gap(skill_snapshot, role_profile_id)` — gaps for one person vs one role
- `team_gap(snapshots_by_person, role_profile_id)` — aggregate gaps for a group

---

## Migration Strategy

**Clean slate** — no production data exists. Delete the DB and create a single migration with the full target schema.

1. Delete old migration files and DB (`priv/rho_dev.db*`)
2. Create one migration `20260408000001_prism_schema.exs` that creates all tables: `libraries`, `skills`, `role_profiles`, `role_skills`, `duplicate_dismissals`
3. `mix ecto.reset`

No data migration module, no phased rollout, no old table preservation.

---

## Code Changes by File

### `apps/prism/` (currently `apps/rho_frameworks/`) — Schema & Context

> **App rename**: `rho_frameworks` → `prism`. Module namespace: `Prism.*` (was `RhoFrameworks.*`). The rename is a separate step — all code changes below use the new names.

| File | Change |
|------|--------|
| `frameworks/library.ex` | **New** — Library schema (name, description, type, immutable, source_key, derived_from, metadata, belongs_to org, has_many skills) |
| `frameworks/skill.ex` | **Rewrite** — new schema with `slug`, `name`, `description`, `status` (draft/published/archived), embedded `proficiency_levels` JSONB (list of level maps), `source_skill_id` FK (tracks fork lineage), belongs_to library (not org). Remove level fields. |
| `frameworks/framework.ex` | **Rename to** `frameworks/role_profile.ex` — add `role_family`, `seniority_level`, `seniority_label`, `purpose`, `accountabilities`, `success_metrics`, `qualifications`, `reporting_context`, embedded `work_activities` JSONB (list of activity maps), `immutable` bool (for reference roles from templates), `source_role_profile_id` FK (fork lineage). All rich fields optional. Change has_many from skills to role_skills. |
| `frameworks/role_skill.ex` | **New** — join table with min_expected_level, weight, required |
| `frameworks/duplicate_dismissal.ex` | **New** — persists "intentionally different" dedup decisions |
| `frameworks.ex` | **Delete** — replaced by `library.ex` and `roles.ex`. |
| `library.ex` | **New** — library CRUD, skills, proficiency levels, consolidation, fork, diff, import, merge, dedup |
| `roles.ex` | **New** — role profiles, role skills, work activities, career ladders |
| `gap_analysis.ex` | **New** — gap analysis functions (works with skill snapshots) |
| `accounts/organization.ex` | Update has_many: add `:libraries`, `:role_profiles`. Remove `:frameworks`. |
| `accounts/user.ex` | Update has_many: `:role_profiles` (was `:frameworks`) |
| `plugin.ex` | **Major rewrite** — tools change from framework-centric to library+role-centric. See detail below. |

### Plugin Restructure (`plugin.ex`)

> **Pre-work completed:** The DataTable abstraction already separated generic table infrastructure from domain logic. `Prism.Plugin` now uses `DT.read_rows/1`, `DT.stream_rows_progressive/4`, and `DT.publish_event/4` from `Rho.Stdlib.Plugins.DataTable`.

Current 8 tools (7 framework + `add_proficiency_levels`) → new tool set:

| Old Tool | New Tool(s) | Notes |
|----------|-------------|-------|
| `save_framework` | `save_to_library` / `save_role_profile` | Two separate actions. `save_to_library` normalizes library-mode rows (status: published). `save_role_profile` auto-upserts skills as drafts + creates role. Both take a `library` parameter. |
| `load_framework` | `load_role_profile` | Loads a role profile's skills into data table. Switches to role profile schema. |
| `list_frameworks` | `list_role_profiles` | Lists role profiles with role_family/seniority grouping |
| `delete_framework` | `delete_role_profile` | Deletes a role profile + its role_skill links. Library skills are preserved. |
| `search_frameworks` | `search_skills` | Searches within a specific library |
| `compare_frameworks` | `compare_role_profiles` | Compares role profiles — shared skills, unique skills, level diffs |
| `find_duplicates` | `find_duplicates` | Tiered detection (standard/deep) against a specific library, excludes dismissed pairs |
| `add_proficiency_levels` | `add_proficiency_levels` | **No change** |
| — | `list_libraries` | **New** — list org's libraries with type, skill counts, immutable flag, derived_from |
| — | `create_library` | **New** — create a new mutable library (name, type, description) |
| — | `load_template` | **New** — load a standard framework (SFIA, ESCO) as an immutable library |
| — | `fork_library` | **New** — fork an immutable library into a mutable working copy (optional category filter) |
| — | `diff_library` | **New** — diff a fork against its immutable source |
| — | `import_library` | **New** — bulk-load pre-parsed rows into a new mutable library (agent handles LLM parsing of PDFs/docs upstream) |
| — | `browse_library` | **New** — list skills by category/cluster, optionally filtered by status |
| — | `merge_skills` | **New** — absorb one skill into another, repoint all references |
| — | `dismiss_duplicate` | **New** — mark two skills as intentionally different |
| — | `consolidate_library` | **New** — prioritized report: duplicates → drafts → orphans |
| — | `save_to_library` | **New** — saves library-mode rows without creating a role profile |
| — | `load_library` | **New** — loads a library's skills into data table (library mode) |
| — | `show_career_ladder` | **New** — progression for a role family with skill diffs |
| — | `gap_analysis` | **New** — individual or team gap analysis against a role profile |
| — | `find_similar_roles` | **New** — find existing role profiles similar to a given name/description, with skill overlap preview |
| — | `clone_role_skills` | **New** — copy skill selection from existing role(s) as starting template for a new role |
| — | `search_skills_cross_library` | **New** — search skills across all org libraries by keyword/category |

### `apps/rho_web/` — LiveViews & Router

| File | Change |
|------|--------|
| `projections/data_table_projection.ex` | **Minor** — add `data_table_schema_change` signal handler to update stored schema in state. Add mode indicator label. |
| `live/framework_list_live.ex` | **Rename to** `role_profile_list_live.ex` — calls `list_role_profiles`. Group by role_family. Cards show name, seniority, skill count, purpose snippet. |
| `live/framework_show_live.ex` | **Rewrite as** `role_profile_show_live.ex` — structured role profile view (see UI layout below). |
| `live/skill_library_live.ex` | **New** — browse/search the org's skill library. Filter by status (draft/published/archived). Shows cross-role usage per skill. Indicates immutable libraries as read-only. |
| `live/skill_search_live.ex` | **New** — cross-library skill search with library/category/status filters. Shows which roles use each skill. |
| `router.ex` | Update routes — see updated route table below. |

### Updated Routes

```
/orgs/:org_slug/libraries                    ← list org's libraries (name, type, skill count, draft count, immutable badge)
/orgs/:org_slug/libraries/:id                ← browse a library: skills by category/cluster, status filter
/orgs/:org_slug/roles                        ← list role profiles, grouped by role_family
/orgs/:org_slug/roles/:id                    ← role profile detail (description + success profile + activities)
/orgs/:org_slug/skills/search                ← cross-library skill search
/orgs/:org_slug/chat                         ← chat session (editing surface)
```

Nav update: `Chat | Libraries | Roles | Settings | Members`

### Role Profile Show Page Layout

The role profile detail page leads with the role description (what the role *is*), followed by the success profile (what a person *needs*). Rich description fields are only shown if populated (progressive enrichment — a role saved with just name + skills shows the skills section first).

```
┌─ Role Description ─────────────────────────────┐
│ Purpose                                         │  ← shown only if populated
│ Accountabilities                                │
│ Success Metrics                                 │
│ Qualifications                                  │
│ Reporting Context                               │
├─ Success Profile: Skills ───────────────────────┤
│ Must-have skills (grouped by category/cluster)  │
│   Skill Name          Required Level   Weight   │
│   ─────────           ──────────────   ──────   │
│   SQL                 4 (Advanced)     1.0      │
│   Python              4 (Advanced)     1.0      │
│ Nice-to-have skills                             │
│   Graph Databases     2 (Basic)        0.5      │
├─ Work Activities ───────────────────────────────┤
│ Activity              Frequency    Time %        │
│ ────────              ─────────    ──────        │
│ Write ETL pipelines   daily        40%           │
│ Code reviews          daily        15%           │
└─────────────────────────────────────────────────┘
Actions: [Edit in Chat] [Compare Roles] [View Career Ladder] [Enrich Description]
```

### Skill Discovery for New Roles

When building a new role, the system helps find relevant skills by looking at existing roles — not just browsing a flat library.

**Similar role lookup (`find_similar_roles`):**
- Input: role name, role_family, or free-text description
- Matches against existing role profiles by name similarity, role_family, and seniority range
- Returns: matching roles with skill overlap preview (skill count, shared categories)
- Example: "Data Engineer" → finds Senior Data Engineer, ML Engineer, Analytics Engineer with skill overlap counts

**Clone from existing roles (`clone_role_skills`):**
- Input: one or more role profile IDs
- When one role: copies its full skill selection as a starting template
- When multiple roles: unions their skills, keeps the highest required_level where they overlap
- Output: pre-populated data table in role profile mode, ready for the user to add/remove/adjust

**Cross-library skill search (`search_skills_cross_library`):**
- Input: keyword, optional category filter
- Searches across all org libraries (not scoped to one)
- Results include: skill name, library name, status, which roles reference it
- Useful when the user knows a skill exists somewhere but not which library it's in

**Agent workflow integration:**
```
User: "Create a role profile for Platform Engineer"

Agent intake:
  1. call find_similar_roles("Platform Engineer")
     → "Found 3 similar roles: Senior SRE (42 skills), DevOps Engineer (38 skills), Backend Engineer (55 skills)"
  2. "Would you like to start from one of these, merge skills from several, or build from scratch?"

  If borrow: call clone_role_skills([sre_id, devops_id])
     → data table pre-populated with union of skills
     → agent helps user prune irrelevant skills, adjust levels, add missing ones

  If scratch: standard bottom-up workflow
```

### Two table modes via `DataTable.Schema`

Already implemented in `RhoWeb.DataTable.Schemas`:

**Library mode** (`Schemas.skill_library()`):
- Columns: `category, cluster, skill_name, skill_description, level, level_name, level_description`
- Group by: `[:category, :cluster]`

**Role profile mode** (`Schemas.role_profile()`):
- Columns: `category, cluster, skill_name, required_level, required`
- Group by: `[:category, :cluster]`

**Schema switching:** When `load_library` or `load_role_profile` is called, the tool publishes a `data_table_schema_change` signal with the appropriate schema and a mode label. The `DataTableProjection` stores the active schema and label in state alongside `rows_map`.

### Config (`.rho.exs`)

| Section | Change |
|---------|--------|
| `data_table` agent system prompt | Major update — see below |
| `proficiency_writer` agent | **No change** |

#### Updated data table agent workflow

```
Phase 1: Intake (enhanced)
  - Gather: industry, role/job family, purpose, proficiency levels, must-include skills
  - Detect workflow intent:
    a) "Create a framework for [role]" → bottom-up path
    b) "We use SFIA" / "Import our skill taxonomy" → import path
    c) "Build our org library" → top-down generation path
    d) "Create [role] from our existing library" → top-down role derivation
    e) "Deduplicate / consolidate our library" → consolidation path
    f) "Create [role] like [existing role]" → similar role derivation path
  - Check existing libraries: call list_libraries() — if org already has libraries,
    ask which to use or offer to create a new one
  - If no library and no import intent: proceed with bottom-up (Workflow C)

--- Import path (b) ---
Phase 2: Identify source
  - Standard framework: call load_template("sfia_v8") → immutable library created
    - "Which categories are relevant?" → user picks subset
    - call fork_library(source_id, "Org Name Skills", categories: [...])
  - Company document (PDF, Word, spreadsheet, pasted text):
    - Agent ingests source via doc_ingest or fs_read
    - LLM parses semi-structured content into:
      a) Skill catalog: categories, clusters, skill names, proficiency levels
      b) Role→skill mappings (if present): role names, required skills, expected levels
Phase 3: Review skills — parsed skills in data table (library mode), user reviews/edits
Phase 4: Save skills — call save_to_library to persist
Phase 5: Review roles (if role mappings extracted)
  - For each extracted role, show skill assignments in data table (role mode)
  - User reviews/edits, or batch-saves all roles if trusting the extraction
Phase 6: Save roles — call save_role_profile for each role

--- Bottom-up path (a) ---
Phase 2: Vocabulary check
  - MANDATORY: call browse_library(library_id) to get existing skill names
  - Inject existing names into generation prompt as controlled vocabulary
  - call find_similar_roles(role_name)
  - If matches found: "Found 3 similar roles. Start from one, merge several, or build fresh?"
  - If borrow: call clone_role_skills([selected_ids]) → data table pre-populated
    - Skip to Phase 3b (curate pre-populated skills)
  - If fresh: continue to Phase 2b
Phase 2b: Skeleton generation — constrained by existing vocabulary
Phase 3: Proficiency generation via sub-agents (unchanged)
Phase 3b: Curate — if started from clone, user adds/removes/adjusts skills
Phase 4: Save as role
  - Only require: name + skills. Optionally ask for role_family, seniority.
  - Call save_role_profile (replaces save_framework)
  - Report: X skills saved, Y new to library (draft), Z already existed
  - If draft_count > threshold: "Consider running consolidation to review drafts."

--- Top-down generation path (c) ---
Phase 2: Library generation
Phase 3: Proficiency generation (same sub-agent delegation)
Phase 4: Save to library
  - Call save_to_library (no role profile, status: published)

--- Top-down role derivation (d) ---
Phase 2: Load library (optionally filtered by category)
Phase 3: Curate — remove unneeded skills, set required_levels
Phase 4: Save as role (same as bottom-up Phase 4)

--- Consolidation path (e) ---
Phase 2: Analyze — call consolidation_report(library_id)
Phase 3: Interactive resolution
  - Duplicate pairs: one at a time (merge / rename / dismiss)
  - Draft completion: by priority (most-used skills first)
  - Orphan review: archive or keep
Phase 4: Save — call save_to_library to persist changes

--- Similar role derivation (f) ---
Phase 2: call find_similar_roles() or user picks from list
Phase 3: call clone_role_skills([role_ids]) — merge if multiple
Phase 4: Curate in data table — add/remove/adjust levels
Phase 5: Save as role (same Phase 4 as bottom-up)
```

---

## Core Implementation Detail

### Core normalization function

```elixir
def upsert_skills_from_rows(library_id, flat_rows, opts \\ []) do
  status = Keyword.get(opts, :status, "draft")
  library = get_library!(library_id)
  ensure_mutable!(library)

  flat_rows
  |> Enum.group_by(fn row -> {row.category, row.cluster, row.skill_name} end)
  |> Enum.map(fn {{cat, cluster, name}, rows} ->
    skill = upsert_skill(library_id, %{
      category: cat, cluster: cluster, name: name,
      description: hd(rows).skill_description,
      status: status
    })

    levels = rows
    |> Enum.reject(& &1.level == 0)
    |> Enum.map(fn row ->
      %{level: row.level, level_name: row.level_name,
        level_description: row.level_description}
    end)
    |> Enum.sort_by(& &1.level)

    skill = if levels != [], do: update_skill_levels(skill, levels), else: skill
    {skill, levels}
  end)
end
```

### Save to library

```elixir
def save_to_library(library_id, flat_rows) do
  Ecto.Multi.new()
  |> Ecto.Multi.run(:skills, fn _repo, _ ->
    {:ok, upsert_skills_from_rows(library_id, flat_rows, status: "published")}
  end)
  |> Repo.transaction()
end
```

### Save role profile (auto-upserts skills as drafts)

```elixir
def save_role_profile(org_id, attrs, role_rows, opts \\ []) do
  library_id = Keyword.get_lazy(opts, :library_id, fn ->
    get_or_create_default_library(org_id).id
  end)

  Ecto.Multi.new()
  |> Ecto.Multi.run(:skills, fn _repo, _ ->
    pairs = Enum.map(role_rows, fn row ->
      skill = upsert_skill(library_id, %{
        category: row.category, cluster: row.cluster, name: row.skill_name,
        description: Map.get(row, :skill_description, ""),
        status: "draft"
      })
      {skill, row}
    end)
    {:ok, pairs}
  end)
  |> Ecto.Multi.run(:role_profile, fn repo, _ ->
    %RoleProfile{}
    |> RoleProfile.changeset(Map.put(attrs, :organization_id, org_id))
    |> repo.insert(on_conflict: :replace_all, conflict_target: [:organization_id, :name])
  end)
  |> Ecto.Multi.run(:role_skills, fn repo, %{skills: pairs, role_profile: profile} ->
    entries = Enum.map(pairs, fn {skill, row} ->
      %{
        role_profile_id: profile.id,
        skill_id: skill.id,
        min_expected_level: row.required_level,
        required: Map.get(row, :required, true),
        weight: Map.get(row, :weight, 1.0)
      }
    end)
    {count, _} = repo.insert_all(RoleSkill, entries, on_conflict: :nothing)
    {:ok, count}
  end)
  |> Repo.transaction()
end
```

Note: `upsert_skill` does NOT overwrite an existing published skill's status back to draft. The upsert is: create as draft if new, leave status unchanged if existing. Skills are scoped to `library_id`, not `org_id` — the library is the identity boundary.

### Career ladder query

```elixir
def career_ladder(org_id, role_family) do
  from(rp in RoleProfile,
    where: rp.organization_id == ^org_id and rp.role_family == ^role_family,
    order_by: rp.seniority_level,
    preload: [role_skills: :skill]
  )
  |> Repo.all()
  |> Enum.map(fn profile ->
    skill_names = Enum.map(profile.role_skills, & &1.skill.name) |> MapSet.new()
    Map.put(profile, :skill_set, skill_names)
  end)
  |> add_progressive_diffs()
end

defp add_progressive_diffs(profiles) do
  profiles
  |> Enum.reduce({MapSet.new(), []}, fn profile, {prev_skills, acc} ->
    new_skills = MapSet.difference(profile.skill_set, prev_skills)
    dropped_skills = MapSet.difference(prev_skills, profile.skill_set)
    entry = Map.merge(profile, %{new_skills: new_skills, dropped_skills: dropped_skills})
    {profile.skill_set, [entry | acc]}
  end)
  |> elem(1)
  |> Enum.reverse()
end
```

---

## DataTable ↔ Library Normalization

The data table works with flat rows. Normalization happens at save time.

### Save to library: Library-mode data table → DB

`save_to_library()`:

1. Read all data table rows via `DT.read_rows/1`
2. Group rows by `(category, cluster, skill_name)` → each group = one skill
3. For each skill group:
   a. **Upsert Skill** by slug (status: published)
   b. **Update skill's `proficiency_levels` JSONB** (skip level=0 placeholders)
4. Return save report: `X skills saved (Y new, Z updated)`

### Save role profile: Role-mode data table → DB

`save_role_profile("Senior Data Engineer", role_family: "Engineering", seniority: 3)`:

1. Read all data table rows via `DT.read_rows/1`
2. Upsert each skill by slug — creates as draft if missing, keeps existing unchanged
3. Create `RoleProfile` record (only `name` required; role_family + seniority optional)
4. For each row: create `RoleSkill` entry
5. Return save report:
   - `Role profile 'Senior Data Engineer' created with X skills`
   - `Y required, Z nice-to-have`
   - `A skills added to library (draft), B already existed`
   - Nudge if warranted: `"Library has N draft skills. Consider consolidation."`

### Load: DB → DataTable (denormalize)

`load_role_profile("Senior Data Engineer")`:

1. Publish `data_table_schema_change` with `Schemas.role_profile()` and label "Role Profile — Senior Data Engineer"
2. Fetch role profile with preloaded role_skills → skills
3. For each role_skill, emit one row:
   ```
   %{category: skill.category, cluster: skill.cluster,
     skill_name: skill.name, required_level: rs.min_expected_level,
     required: rs.required}
   ```
4. Stream to data table via `DT.stream_rows_progressive/4`

### Consolidate: Interactive, not batch

`consolidation_report(library_id)`:

1. Query all skills in library, with proficiency levels and referencing role profiles
2. Run `find_duplicates(library_id)` — tiered detection, excludes dismissed pairs
3. Build prioritized action report:
   - **Duplicate pairs** (by confidence: high → medium → low), with role references per skill
   - **Draft skills** needing proficiency descriptions, sorted by role reference count (most-used first)
   - **Orphan skills** referenced by 0 roles
4. Return structured report — the agent walks through actions interactively (see Skill Merging section)
5. After resolution: user calls `save_to_library()` to persist edits and promote drafts

---

## Implementation Order

> **Pre-work completed:** The DataTable abstraction refactored the old "spreadsheet" into a generic, schema-driven data table. See `docs/data-table-abstraction-plan.md`.

### Step 1: Schema switching in DataTableProjection
- Add `data_table_schema_change` signal handler to `DataTableProjection`
- Store active schema and mode label in projection state alongside `rows_map`
- `DataTableComponent` reads schema from state (fallback to `Schemas.skill_library()`)
- Add mode indicator to data table UI
- **Tests**: Signal changes schema in state, component renders new columns, mode label displayed

### Step 2: New Ecto schemas + migration
- Create schema modules: `Library` (new, with immutable + derived_from), `Skill` (rewrite, with archived status + `proficiency_levels` JSONB + `source_skill_id` FK), `RoleProfile` (with optional rich fields + `work_activities` JSONB), `RoleSkill`, `DuplicateDismissal`
- Create migration that adds all new tables (including `libraries`, `duplicate_dismissals`)
- **Tests**: Schema changeset tests for each module. Library immutability flag. RoleProfile with only name (all rich fields nil).

### Step 3: Library CRUD + immutability + fork
- `create_library/2`, `get_or_create_default_library/1`, `list_libraries/2`
- `load_template/1` — load bundled standard framework as immutable library + reference role profiles
- `fork_library/4` — deep-copy skills AND role profiles with optional category filter, `skill_id_map` remapping
- `list_role_profiles_for_library/2` — find role profiles referencing a library's skills (used by fork)
- `copy_role_profile/3` — deep-copy a role profile with remapped skill FKs
- `diff_against_source/2` — diff fork vs immutable parent
- `import_library/3` — bulk-load from structured rows (skills + optional role mappings)
- Immutability enforcement: `ensure_mutable!/1` guard on all write operations (skills AND role profiles)
- Implement `upsert_skills_from_rows/2` with status parameter (scoped to library_id)
- Implement `upsert_skill/2` with slug generation and `upsert_proficiency_level/2`
- **Tests**: Library CRUD, immutability enforcement (writes rejected on immutable), fork creates independent copy of both skills and role profiles, forked role_skills point to forked skills (not source), diff accuracy, flat rows → correct skill dedup by slug, draft vs published vs archived status

### Step 4: Save + Load role profile
- `save_role_profile/3` — uses `upsert_skill` (draft) + creates profile + role_skills. Only name required.
- `load_role_profile/2` — denormalizes back to flat rows with mode label
- `list_role_profiles/2`, `delete_role_profile/2`
- **Tests**: Save two roles with overlapping skills, verify library dedup by slug, load back. Save with only name (no rich fields). Nudge message when draft threshold exceeded.

### Step 5: Skill merging + dedup + consolidation
- `find_duplicates/2` — tiered detection (slug prefix, word overlap), exclude dismissed pairs
- `merge_skills/3` — repoint RoleSkills, resolve conflicts (keep_higher default), merge `proficiency_levels` JSONB, optional rename
- `dismiss_duplicate/3` — persist "intentionally different"
- `consolidation_report/1` — prioritized: duplicates → drafts (by role count) → orphans
- `save_to_library/2` — normalizes library-mode rows (status: published)
- `browse_library/2` — list/search library skills, filter by status
- `career_ladder/2` — role family progression query
- `compare_role_profiles/2` — adapted from existing compare logic
- **Tests**: Merge repoints references correctly, conflict resolution (keep_higher), proficiency level gap fill, dismissed pairs excluded from detection, consolidation report prioritization, career ladder ordering

### Step 6: Gap analysis
- `individual_gap/2` — skill snapshot vs role profile, unknown ≠ zero
- `team_gap/2` — aggregate with unknown tracking and weighted averages
- **Tests**: Gap with unknowns, positive gap (no negative cancellation), weighted averages

### Step 7: Plugin tool swap
- Replace 8 existing `Prism.Plugin` tools with new tool set (see Plugin Restructure table)
- Add import, fork, diff, merge, dismiss tools
- Update `prompt_sections` to describe modes, controlled vocabulary, and consolidation workflow
- **Tests**: Tool execution tests with mock data table rows

### Step 8: LiveView + Router updates
- Rename `FrameworkListLive` → `RoleProfileListLive`
- Rename `FrameworkShowLive` → `RoleProfileShowLive` (progressive: only show populated rich fields)
- Add `SkillLibraryLive` — browse/search with status filter, immutable badge for standard libraries
- Update router: `/frameworks` → `/roles`, add `/libraries`, `/skills/search`
- **Tests**: LiveView mount + event tests

### Step 9: Standard framework templates + agent prompt
- Bundle SFIA v8 as structured data in `priv/templates/sfia_v8.json` — includes skills, proficiency levels, AND role profile→skill mappings
- Template format: `%{skills: [...], role_profiles: [%{name, role_family, seniority_level, skill_refs: [%{skill_slug, min_expected_level, weight}]}]}`
- Update `.rho.exs` data table agent system prompt with new workflow detection, mandatory `browse_library`, controlled vocabulary injection
- Update Workflow A prompt to show forked reference roles as starting points
- Update tool references throughout
- `proficiency_writer` agent: **no change**

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Skill dedup merges intentionally different skills | Slug-based identity is per-library (not per-org). Two libraries can independently define "SQL". Within a library, slug merge is correct. Post-hoc duplicates resolved via interactive merge with user confirmation. |
| Skill identity drift across sessions | Prevention: agent must `browse_library` before generating, constrained vocabulary in prompt. Detection: tiered `find_duplicates`. Resolution: `merge_skills`. Memory: `dismiss_duplicate`. |
| Merge breaks role profile references | Merge repoints all RoleSkill FKs in a transaction. Conflicts (same role has both skills) resolved by keeping higher level. Merge report details every change. |
| Immutable library accidentally modified | `ensure_mutable!` guard on every write operation. Compile-time guarantee: all context functions that modify skills call this guard. |
| Fork diverges too far from source | `diff_against_source` makes divergence visible. User can selectively pull changes from new standard versions. |
| SFIA template data becomes outdated | Templates are versioned by source_key (`sfia_v8`, `sfia_v9`). New versions are loaded alongside old ones, not replacing them. |
| DataTable mode switching confuses user | Explicit mode indicator label. Warning on switch with unsaved edits. Schema switch driven by clear user action (load_library / load_role_profile). |
| Role profile rich fields create friction | All optional — only `name` required. Progressive enrichment: agent can generate drafts from skill list later. UI hides empty sections. |
| Consolidation overwhelm (too many items) | Prioritized, interactive, one action at a time. Duplicates by confidence, drafts by role count. Incremental saves — user doesn't have to do everything at once. |
| Agent prompts reference old tool names | Update prompts in Step 9. Old tool names will fail explicitly. |
| Bottom-up creates messy library initially | Expected and by design. Draft status makes this explicit. Consolidation step is the answer. System nudges after threshold. |
| User edits library during consolidation, breaking role profile links | Role profiles link to skills by FK, not by name. Editing a skill's description updates it everywhere. |
| Career ladder seniority_level values vary by org | Seniority is just an integer for ordering. Orgs set their own scale. |
| Slug collisions | Unlikely for real skill names. If "SQL" and "sql" both appear in the same library, they merge — which is correct behavior. Different libraries are independent. |
| Library proliferation | `get_or_create_default_library` funnels into a single library by default. Multi-library UI only appears when org has >1 library. Standard libraries are separate by design (immutable). |
| Multi-library role profiles | A role profile's skills can come from multiple libraries (RoleSkill doesn't constrain by library). This is fine — practical for orgs with specialized libraries. |
| Dismissed pair becomes a real duplicate later | Dismissals can be reviewed and removed. `consolidation_report` can optionally include dismissed pairs for re-review. |

---

## Future Integration Points

This plan provides the foundation for several follow-on capabilities:

### → New Library Types (when psychometric integration is real)
- Add `type: "psychometric"` library with RIASEC interest profiles, work styles (16 dims), work values (6 dims)
- Add `type: "qualification"` library for education, certifications, experience requirements
- Type-specific validation dispatch: `Prism.LibraryItem.Validator` with clauses per type
- Scoring dispatch: `Prism.Scoring` module with `do_gap("skill", ...)`, `do_gap("psychometric", ...)` etc.
- Psychometric scoring logic stays in Rust (ds-aether) — Elixir calls it via API or port
- See [prism-design-review.md](prism-design-review.md) for the full multi-dimensional vision

### → Full RequirementSets (when multiple library types exist)
- `RoleSkill` is the first dimension. When additional dimensions arrive (psychometric, qualification), add parallel join tables or a polymorphic `RequirementSet` (type + config + library_id) → `Requirement` (item + threshold)
- Cross-dimension weighting: product decision, not engineering — defer until real use cases exist

### → Lens System Plan (`prism-lens-system-plan.md`)
- First concrete lens: **ARIA AI Readiness** (2-axis: AI Impact × Adaptability)
- N-dimensional scoring framework with configurable axes and variables
- LLM scoring integration
- Lens dashboard workspace panel with interactive visualizations
- `WorkActivityTag` for lens-specific activity categorization
- Depends on: skills, role_profiles, work_activities from this plan

### → Observation Model Plan (`prism-observation-model-plan.md`)
- `IndividualProfile` + `ProfileEntry` + `Observation` schemas
- Weighted evidence model (not "Bayesian" — it's a weighted running average with recency decay)
- Source-specific weights (self-assessment, manager review, peer feedback, AI inference)
- Unknown vs zero distinction (consistent with gap analysis in this plan)
- Staleness tracking via `last_observed_at` + read-time freshness computation
- Depends on: skills from this plan; feeds into gap analysis and lens scoring

### → Standard Framework Library Expansion
- Bundle additional standards: ESCO (EU competencies), O*NET (US occupational data), CompTIA
- Template versioning: load new versions alongside old, diff-based upgrade path
- Community-contributed templates: export/import portable library format
