# Prism — Role Profiles & Typed Libraries (v2)

> **Revision**: Incorporates continuous dedup architecture, unified skill discovery, adopt-or-fork model for external frameworks, and principle-based agent workflows (replacing rigid workflow paths).
>
> **Scope**: Typed library system, role profiles, continuous dedup, standard framework import, skill merging, and data migration.
> **Out of scope** (separate plans):
> - [Lens System](../archive/research/prism-lens-system-plan.md) — N-dimensional scoring framework
> - [Observation Model](../archive/research/prism-observation-model-plan.md) — Individual profiles and weighted evidence model
> **Deferred** (build extension points now, machinery later):
> - Library type-specific validation dispatch (add when second library type is real)
> - Psychometric scoring in Elixir (lives in Rust in ds-aether)
> - Cross-dimension weighting
> - Skill splitting (reverse of merge — rare, manual workflow)

## Goal

Restructure the flat `Framework → Skills` model into a **typed library system** with **role profiles**. Prism separates three concerns currently conflated in "Framework":

1. **Libraries** (typed catalogs) — what items exist in a domain and what proficiency/scoring looks like
2. **Role profiles** — what skills a person needs to succeed in a role (`RoleSkill` join)
3. **Gap analysis** — comparing a person's actual profile against a role profile's skill requirements

The core design challenge: **the library doesn't exist before the roles**. Users create skill frameworks role-by-role across many sessions, and the canonical library *emerges* as a deduplicated union of all those sessions. The architecture must make this bottom-up accumulation natural and duplicates cheap to resolve.

## Current Model

```
Organization (1) → (*) Framework (1) → (*) Skill
```

A Framework is simultaneously "the skill catalog" and "what a role needs." Each skill×level combination is a separate row — "Python" with 5 levels = 5 rows, causing ~80% row duplication. Skills cannot be shared across frameworks.

## Target Model

```
Organization
  │
  ├── (*) Library                               ← typed catalogs
  │     ├── name, description, type
  │     ├── immutable (bool)                    ← true for standard frameworks (SFIA, ESCO)
  │     ├── derived_from (FK → Library)         ← tracks fork lineage
  │     └── (*) Skill                           ← one row per skill concept
  │           ├── slug, name, description, category, cluster
  │           ├── status (draft | published | archived)
  │           ├── source_skill_id (FK → Skill)  ← per-skill fork lineage
  │           └── proficiency_levels (JSONB)    ← embedded, not a separate table
  │
  ├── (*) RoleProfile                           ← what the role needs
  │     ├── name, description, role_family, seniority_level, seniority_label
  │     ├── source_role_profile_id (FK)         ← fork lineage
  │     ├── immutable (bool)                    ← true for reference roles from templates
  │     └── (*) RoleSkill (join)                ← skill + min_expected_level + weight
  │
  └── (*) DuplicateDismissal                    ← "these two skills are intentionally different"
```

---

## Key Design Decisions

1. **Multiple libraries per org, typed.** An org can have separate libraries for different domains. The `type` field (default `"skill"`) is an extension point for future library types. No type-specific validation dispatch yet.

2. **Libraries are independent.** If two libraries both contain "SQL", those are different items. No cross-library identity. Avoids the coordination problem of canonical ownership.

3. **Standard libraries are immutable.** SFIA, ESCO, etc. are loaded as immutable libraries. Customization is always a fork. See [Immutable Libraries & Forking](#immutable-libraries--forking).

4. **Proficiency levels are embedded JSONB.** Each skill stores levels as a JSONB list of `%{level, level_name, level_description}`. Eliminates the separate table and the ~80% row duplication.

5. **`source_skill_id` provides per-skill fork lineage.** When a library is forked or a skill is adopted from a standard, the FK tracks origin. Enables reliable diff/upgrade even after renames.

6. **Skills have a normalized slug for identity.** Unique key is `(library_id, slug)`. Auto-generated from name. Category and cluster are organizational, not identity.

7. **`save_role_profile` auto-upserts skills as drafts.** In bottom-up workflows, skills are created as draft entries (may lack proficiency descriptions) as a side effect of role creation. Draft skills are fully functional for role requirements but flagged for library review.

8. **Dedup is continuous, not batch.** Three layers handle deduplication at different times and costs. See [Continuous Dedup Architecture](#continuous-dedup-architecture).

9. **`DuplicateDismissal` is load-bearing.** Without it, every consolidation re-surfaces pairs the user already decided are intentionally different. Small table, prevents real frustration.

10. **External frameworks: adopt or fork.** Users can cherry-pick individual skills from a standard (adopt) or fork the entire library. Adopt is the common case. See [External Frameworks](#external-frameworks-adopt-or-fork).

11. **Skill discovery is unified search.** Before generating skills, the agent searches across the org's library, existing roles, and standard frameworks simultaneously. See [Skill Discovery](#skill-discovery).

12. **Weight on RoleSkill is nullable with default 1.** Cheap insurance for future weighted scoring without pre-building the scoring machinery.

13. **Gap analysis is per-dimension.** Today that means skills only. When psychometric or qualification dimensions arrive, each produces its own gap report.

14. **Agent workflows are principle-based, not rigid paths.** The agent prompt describes principles ("discover before generating", "reuse existing names") rather than a decision tree. The system handles any order of operations.

### What's deferred and why

- **Rich role profile fields** (`purpose`, `accountabilities`, `success_metrics`, `qualifications`, `reporting_context`, `work_activities`) — add when someone requests role description features. Start with just `description`.
- **Type-specific validation** — no psychometric library type exists yet.
- **Cross-dimension scoring** — product decision, not engineering.
- **Career ladder as a first-class feature** — it's a query (`role_profiles WHERE role_family = X ORDER BY seniority_level`), not a schema concern. Add the UI when needed.
- **`required` boolean on RoleSkill** — must-have vs nice-to-have is a refinement. Start with all skills required.

---

## The Two Distinct Actions

The system supports two fundamentally different editing actions that use the same data table surface:

**"Create a skill framework for Data Engineer"** = generate the **vocabulary**. Define skills, categories, proficiency level descriptions. Heavy content-creation work. Output: detailed skills with level definitions saved to the library.

**"Create a Data Engineer role"** = select **requirements**. Pick skills from the existing library, set target levels. A curation/selection task.

The current system conflates these into one "Framework." The restructure separates them:

| Action | DataTable schema | Generates | Saves via |
|--------|-----------------|-----------|-----------|
| Build skill framework | Library mode (skill×level rows) | Skills + proficiency descriptions | `save_to_library` (status: published) |
| Create role profile | Role profile mode (skill + required_level) | Skill selection + levels | `save_role_profile` (auto-upserts drafts) |

### Two data table modes

**Library mode** (`Schemas.skill_library()`):
```
| category | cluster | skill_name | skill_description | level | level_name | level_description |
```
- One row per skill×level combination (same as today's editing format)
- Saved with `save_to_library` → normalizes into skills + embedded JSONB levels

**Role profile mode** (`Schemas.role_profile()`):
```
| category | cluster | skill_name | required_level |
```
- One row per skill (no proficiency descriptions)
- Saved with `save_role_profile` → creates role + role_skills + auto-upserts skills as drafts

---

## Continuous Dedup Architecture

### The problem

Users create skill frameworks session-by-session. Each session generates skills independently. The canonical library is the deduplicated union of all sessions. Duplicates are inevitable because:

1. LLMs don't perfectly constrain to existing vocabulary
2. Different sessions use different names for the same concept ("SQL Programming" vs "SQL Querying")
3. Semantic overlap isn't visible from names alone ("CI/CD Pipeline Management" vs "Build and Release Engineering")

### The convergence dynamic

Dedup cost per session **decreases over time** as the library stabilizes:

```
Session 1:  30 skills generated, 0 reused, 0 near-matches     → library: 30
Session 2:  35 generated, 12 reused, 5 near-matches resolved   → library: ~48
Session 3:  28 generated, 18 reused, 3 near-matches resolved   → library: ~55
Session 5:  25 generated, 22 reused, 1 near-match              → library: ~58
Session 10: 20 generated, 19 reused, 0 near-matches            → library: ~59
```

Early sessions establish vocabulary. Later sessions mostly reuse. The library converges — it never "finishes," but it gets increasingly stable.

### Three-layer dedup

```
            PREVENTION                        DETECTION                      RESOLUTION
      ┌──────────────────┐          ┌───────────────────────────┐     ┌──────────────────┐
      │  discover_skills │  Save    │  Layer 1: slug match      │     │  auto-reuse      │
  ───►│  (agent prompt)  │────────►│  Layer 2: trigram match    │────►│  suggest + merge │
      │                  │          │                            │     │  or dismiss      │
      └──────────────────┘          └───────────┬────────────────┘     └──────────────────┘
                                                │ async
                                    ┌───────────▼────────────────┐     ┌──────────────────┐
                                    │  Layer 3: LLM semantic     │────►│  review queue     │
                                    │  (background, triggered)   │     │  (1 pair at a time)│
                                    └────────────────────────────┘     └──────────────────┘
                                                                            │
                                                                  ┌─────────▼──────────┐
                                                                  │ DuplicateDismissal  │
                                                                  │ (memory: don't      │
                                                                  │  re-ask decided)    │
                                                                  └────────────────────┘
```

### Layer 1: Write-time exact dedup (free, synchronous)

Every skill upsert checks for slug match within the library.

```elixir
def upsert_skill(library_id, attrs) do
  slug = generate_slug(attrs.name)

  case Repo.get_by(Skill, library_id: library_id, slug: slug) do
    %Skill{} = existing ->
      maybe_fill_proficiency_gaps(existing, attrs[:proficiency_levels])
      {:ok, existing}

    nil ->
      # Check Layer 2 before creating
      near_match_or_create(library_id, attrs, slug)
  end
end
```

Catches: "Data Modeling" = "data modeling" = "Data-Modeling". ~30-40% of cross-session overlaps.

### Layer 2: Write-time near-match suggestion (cheap, synchronous)

Before creating a new skill, check for similar names using PostgreSQL trigram similarity.

```elixir
defp near_match_or_create(library_id, attrs, slug) do
  candidates = find_near_matches(library_id, attrs.name)

  case candidates do
    [] -> create_skill(library_id, Map.put(attrs, :slug, slug))
    matches -> {:near_matches, matches, attrs}
  end
end

def find_near_matches(library_id, name) do
  dismissed = list_dismissed_pairs(library_id)

  from(s in Skill,
    where: s.library_id == ^library_id,
    where: fragment("similarity(lower(?), lower(?)) > 0.4", s.name, ^name),
    order_by: fragment("similarity(lower(?), lower(?)) DESC", s.name, ^name),
    limit: 5
  )
  |> Repo.all()
  |> reject_dismissed(dismissed, name)
end
```

Catches: "SQL Programming" ↔ "SQL Querying", "Python Development" ↔ "Python Programming". ~40-50% of remaining duplicates.

### Two-phase save

The agent generates skills in a batch. Near-match warnings shouldn't interrupt the creation flow. Save uses two phases:

**Phase A**: Save all skills. Exact slug matches auto-reuse. New skills created. Near-matches created but flagged.

**Phase B**: Immediately after save, surface near-match pairs for review in the same session.

```elixir
def upsert_skills_batch(library_id, rows, opts \\ []) do
  status = Keyword.get(opts, :status, "draft")

  {reused, created, review_pairs} =
    Enum.reduce(rows, {[], [], []}, fn row, {reused, created, pairs} ->
      slug = generate_slug(row.skill_name)

      case Repo.get_by(Skill, library_id: library_id, slug: slug) do
        %Skill{} = existing ->
          maybe_fill_proficiency_gaps(existing, row)
          {[existing | reused], created, pairs}

        nil ->
          near = find_near_matches(library_id, row.skill_name)
          skill = create_skill!(library_id, row, status: status)

          case near do
            [] -> {reused, [skill | created], pairs}
            [best | _] -> {reused, [skill | created], [{skill, best} | pairs]}
          end
      end
    end)

  {:ok, %{
    reused_count: length(reused),
    created_count: length(created),
    review_pairs: review_pairs
  }}
end
```

The agent then handles review pairs conversationally:

```
Agent: "Saved 35 skills to library. 18 matched existing, 12 new, 5 need review.

        1/5: 'SQL Querying' (new) looks similar to 'SQL Programming' (existing, used by Data Engineer)
             → Merge into one? Which name? Or keep separate?"

User: "merge, call it SQL"

Agent: calls merge_skills(sql_querying_id, sql_programming_id, new_name: "SQL")
       "Done. 4 more to review..."
```

### Layer 3: Background semantic scan (LLM, async, triggered)

A process that scans for semantic duplicates that string matching misses.

```elixir
def semantic_duplicate_scan(library_id) do
  skills = list_skills(library_id, status: [:draft, :published])
  dismissed = list_dismissed_pairs(library_id)

  # Batch skill names + descriptions into LLM calls
  # At <5000 skills this is ~100k tokens — trivial cost
  skills
  |> Enum.chunk_every(100)
  |> Enum.flat_map(fn batch ->
    prompt = """
    These are skills in a competency library. Identify pairs that likely
    refer to the same competency despite different names.
    Return only pairs you're confident about.

    #{Enum.map(batch, &"- #{&1.name}: #{&1.description}") |> Enum.join("\n")}
    """
    parse_duplicate_pairs(llm_call(prompt))
  end)
  |> Enum.reject(fn {a, b} -> dismissed?(dismissed, a, b) end)
  |> save_to_review_queue(library_id)
end
```

**When triggered:**
- After a framework-creation session that added >5 new skills
- Manually via `consolidate_library` tool
- Never needs to scan all-vs-all — only new skills against existing

**Cost at realistic scale:** A library of 5000 skills is ~100k tokens. A few dollars, 30 seconds. No need for embeddings or vector DBs.

### Proficiency level merging on exact match

When the same skill (by slug) appears in two framework-creation sessions, proficiency descriptions may differ. Resolution: **first writer wins, fill gaps only**.

```elixir
defp maybe_fill_proficiency_gaps(%Skill{proficiency_levels: existing} = skill, new_levels)
     when is_list(new_levels) and new_levels != [] do
  existing_map = Map.new(existing, &{&1.level, &1})
  new_map = Map.new(new_levels, &{&1.level, &1})

  # New levels fill gaps, never overwrite existing descriptions
  merged = Map.merge(new_map, existing_map)

  if map_size(merged) > map_size(existing_map) do
    update_skill_levels(skill, merged |> Map.values() |> Enum.sort_by(& &1.level))
  else
    {:ok, skill}
  end
end

defp maybe_fill_proficiency_gaps(skill, _), do: {:ok, skill}
```

### DuplicateDismissal: the dedup memory

Prevents re-surfacing pairs the user already decided are intentionally different.

```elixir
def dismiss_duplicate(library_id, skill_a_id, skill_b_id) do
  {id_a, id_b} = if skill_a_id < skill_b_id,
    do: {skill_a_id, skill_b_id},
    else: {skill_b_id, skill_a_id}

  %DuplicateDismissal{}
  |> DuplicateDismissal.changeset(%{library_id: library_id, skill_a_id: id_a, skill_b_id: id_b})
  |> Repo.insert(on_conflict: :nothing)
end
```

Both Layer 2 (near-match) and Layer 3 (semantic scan) filter out dismissed pairs before surfacing.

---

## Skill Discovery

Before generating skills for a new framework, the agent should know what already exists. This is the best **prevention** layer — not a rigid constraint, but a prompt guideline the agent follows.

### Unified search across three sources

```elixir
def discover_skills(org_id, query) do
  library = get_default_library(org_id)

  %{
    # What the org already has
    library_matches: search_skills(library.id, query),

    # What similar roles in the org use
    from_roles: skills_from_similar_roles(org_id, query),

    # What standard frameworks define
    from_standards: search_standard_templates(query)
  }
end

defp skills_from_similar_roles(org_id, query) do
  from(rp in RoleProfile,
    where: rp.organization_id == ^org_id,
    where: fragment("similarity(lower(?), lower(?)) > 0.3", rp.name, ^query),
    preload: [role_skills: :skill],
    limit: 5
  )
  |> Repo.all()
  |> Enum.map(fn rp ->
    %{role_name: rp.name, skill_count: length(rp.role_skills),
      skills: Enum.map(rp.role_skills, & &1.skill.name)}
  end)
end
```

The agent uses this before generation:

```
User: "Create a skill framework for ML Engineer"

Agent:
  1. calls discover_skills(org_id, "ML Engineer")
     → library_matches: ["Python", "SQL", "Data Modeling", ...] (from earlier sessions)
     → from_roles: "Data Engineer uses: SQL, Python, Data Modeling, ETL Design, ..."
     → from_standards: "SFIA has: Machine Learning, Data Science, ..."

  2. Generates skills, reusing existing names where applicable
     "Python" already exists → reuse. "TensorFlow" is new → create.

  3. save_to_library() or save_role_profile()
     → Layer 1 catches exact matches
     → Layer 2 catches near-matches
     → Library grows incrementally
```

### Agent prompt principle (not a rigid workflow)

```
Before generating skills for a framework or role, call discover_skills to see
what already exists. Reuse existing skill names verbatim where they match the
concept. Only create new skill names for genuinely new competencies.

After saving, review any near-match pairs surfaced by the system.
```

This replaces the six rigid workflow paths from v1. The agent handles any order of operations — import then customize, bottom-up then consolidate, or any mix — because the dedup layers catch issues regardless of workflow.

---

## External Frameworks: Adopt or Fork

### Two modes for using standards

**Adopt** (common case): Cherry-pick individual skills from a standard into the org's library.

```
User: "Add SFIA's data engineering skills to our library"

Agent:
  1. browse_template("sfia_v8", category: "Data Management")
     → shows 15 skills with proficiency levels
  2. User picks 8 relevant skills
  3. adopt_skills(org_library_id, sfia_library_id, skill_ids)
     → copies selected skills into org library
     → source_skill_id tracks lineage to SFIA original
```

```elixir
def adopt_skills(target_library_id, source_library_id, skill_ids) do
  target = get_library!(target_library_id)
  ensure_mutable!(target)

  Enum.map(skill_ids, fn skill_id ->
    source_skill = get_skill!(source_library_id, skill_id)
    copy_skill(source_skill, target_library_id, source_skill_id: source_skill.id)
  end)
end
```

**Fork** (full copy): Copy an entire library (or category subset) as a mutable working copy. For orgs that want their own version of the standard.

```elixir
def fork_library(org_id, source_library_id, new_name, opts \\ []) do
  source = get_library!(source_library_id)
  categories = Keyword.get(opts, :categories, :all)

  Ecto.Multi.new()
  |> Ecto.Multi.insert(:library, %Library{
    name: new_name,
    organization_id: org_id,
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
  |> Repo.transaction()
end
```

### Standard framework templates

Bundled seed data in `priv/templates/` (JSON), not LLM-generated. Templates include skills with proficiency levels.

```elixir
def load_template(source_key) do
  data = read_template_file(source_key)

  Ecto.Multi.new()
  |> Ecto.Multi.insert(:library, %Library{
    name: data.name,
    immutable: true,
    source_key: source_key,
    type: "skill"
  })
  |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
    {:ok, bulk_insert_skills(lib.id, data.skills)}
  end)
  |> Repo.transaction()
end
```

### Diff operation

For forked libraries, diff against the immutable parent:

```elixir
def diff_against_source(org_id, library_id) do
  lib = get_library!(org_id, library_id) |> Repo.preload(:derived_from)
  source_skills = list_skills(lib.derived_from_id) |> index_by(:id)
  fork_skills = list_skills(library_id) |> index_by_source_skill_id()

  %{
    added: fork_skills not in source,
    removed: source_skills not in fork,
    modified: changed descriptions/levels,
    unchanged: identical skills
  }
end
```

### Immutability enforcement

```elixir
defp ensure_mutable!(library) do
  if library.immutable do
    {:error, :immutable_library,
     "Cannot modify '#{library.name}' — it is a standard framework. " <>
     "Fork it or adopt individual skills into a mutable library."}
  else
    :ok
  end
end
```

---

## Merge Operation

When dedup identifies two skills as duplicates, merge absorbs one into the other:

```elixir
def merge_skills(source_id, target_id, opts \\ []) do
  source = get_skill!(source_id) |> Repo.preload(:library)
  target = get_skill!(target_id) |> Repo.preload(:library)
  ensure_mutable!(target.library)

  new_name = Keyword.get(opts, :new_name)

  Ecto.Multi.new()
  |> Ecto.Multi.run(:repoint, fn _repo, _ ->
    # Move all RoleSkill references from source to target
    repoint_role_skills(source_id, target_id)
  end)
  |> Ecto.Multi.run(:levels, fn _repo, _ ->
    # Fill proficiency level gaps from source into target
    {:ok, merge_proficiency_levels(source_id, target_id)}
  end)
  |> Ecto.Multi.run(:rename, fn _repo, _ ->
    if new_name, do: rename_skill(target_id, new_name), else: {:ok, nil}
  end)
  |> Ecto.Multi.run(:delete, fn _repo, _ ->
    delete_skill(source_id)
  end)
  |> Repo.transaction()
end
```

**The source is absorbed into the target. The target survives.** All RoleSkill FKs are repointed. Proficiency level gaps are filled from source (never overwriting target's existing descriptions).

### RoleSkill conflict resolution

When a role references both source and target skill, the merge creates a conflict. Resolution: keep the higher required level (conservative default).

```elixir
defp repoint_role_skills(source_id, target_id) do
  source_refs = list_role_skills_for(source_id)
  target_refs = list_role_skills_for(target_id) |> index_by_role_id()

  {clean, conflicted} = Enum.split_with(source_refs, fn rs ->
    not Map.has_key?(target_refs, rs.role_profile_id)
  end)

  # Clean: just repoint FK
  Enum.each(clean, &update_role_skill(&1, skill_id: target_id))

  # Conflicted: keep higher level, delete source entry
  Enum.each(conflicted, fn source_rs ->
    target_rs = target_refs[source_rs.role_profile_id]
    if source_rs.min_expected_level > target_rs.min_expected_level do
      update_role_skill(target_rs, min_expected_level: source_rs.min_expected_level)
    end
    delete_role_skill(source_rs)
  end)
end
```

---

## Schema Design

### Table: `libraries`

```elixir
schema "libraries" do
  field :name, :string
  field :description, :string
  field :type, :string, default: "skill"
  field :immutable, :boolean, default: false
  field :source_key, :string        # "sfia_v8" — identifies bundled template (nil for custom)
  field :metadata, :map, default: %{}

  belongs_to :organization, Organization
  belongs_to :derived_from, Library
  has_many :skills, Skill

  timestamps()
end
```

Constraints:
- `unique_index([:organization_id, :name])`
- `index([:organization_id, :type])`
- `index([:derived_from_id])`

### Table: `skills`

```elixir
schema "skills" do
  field :slug, :string
  field :name, :string
  field :description, :string
  field :category, :string
  field :cluster, :string
  field :status, :string, default: "draft"  # "draft" | "published" | "archived"
  field :sort_order, :integer
  field :metadata, :map, default: %{}
  field :proficiency_levels, {:array, :map}, default: []
    # each: %{level: integer, level_name: string, level_description: string}

  belongs_to :library, Library
  belongs_to :source_skill, Skill      # fork lineage (nullable)
  has_many :role_skills, RoleSkill

  timestamps()
end
```

Constraints:
- `unique_index([:library_id, :slug])`
- `index([:library_id, :category])`
- `index([:library_id, :status])`
- `index([:source_skill_id])`

Slug generation:
```elixir
defp generate_slug(name) do
  name |> String.downcase() |> String.trim()
  |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
```

### Table: `role_profiles`

```elixir
schema "role_profiles" do
  field :name, :string
  field :description, :string           # overview (optional)
  field :role_family, :string           # "Engineering", "Product" (optional)
  field :seniority_level, :integer      # ordering key (optional)
  field :seniority_label, :string       # "Senior", "Staff" (optional)
  field :headcount, :integer, default: 1
  field :metadata, :map, default: %{}

  field :immutable, :boolean, default: false
  belongs_to :source_role_profile, RoleProfile  # fork lineage (nullable)

  belongs_to :organization, Organization
  belongs_to :created_by, User
  has_many :role_skills, RoleSkill

  timestamps()
end
```

Constraints:
- `unique_index([:organization_id, :name])`
- `index([:source_role_profile_id])`
- `index([:organization_id, :role_family])`

### Table: `role_skills`

```elixir
schema "role_skills" do
  field :min_expected_level, :integer
  field :weight, :float, default: 1.0   # nullable, for future weighted scoring

  belongs_to :role_profile, RoleProfile
  belongs_to :skill, Skill

  timestamps()
end
```

Constraints:
- `unique_index([:role_profile_id, :skill_id])`
- `index([:skill_id])`

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
- `unique_index([:library_id, :skill_a_id, :skill_b_id])`
- `index([:library_id])`

---

## Context Modules

Two modules (not three — gap analysis is a function, not a module until it has a data source):

### `Prism.Catalog` — Library + Skill operations

- `list_libraries(org_id, opts)` — filter by type, exclude immutable
- `get_library!(org_id, id)`
- `create_library(org_id, attrs)`
- `get_or_create_default_library(org_id)`
- `load_template(source_key)` — load standard as immutable library
- `fork_library(org_id, source_library_id, new_name, opts)` — deep-copy with optional category filter
- `adopt_skills(target_library_id, source_library_id, skill_ids)` — cherry-pick from standard
- `diff_against_source(org_id, library_id)` — diff fork vs parent
- `import_library(org_id, structured_rows, opts)` — bulk-load from CSV
- `list_skills(library_id, opts)` — filter by category, cluster, status
- `upsert_skill(library_id, attrs)` — slug dedup + near-match detection
- `upsert_skills_batch(library_id, rows, opts)` — two-phase save with near-match pairs
- `search_skills(library_id, query)`
- `discover_skills(org_id, query)` — unified search: library + roles + standards
- `find_near_matches(library_id, name)` — trigram similarity, excludes dismissed
- `merge_skills(source_id, target_id, opts)` — absorb + repoint + fill levels
- `dismiss_duplicate(library_id, skill_a_id, skill_b_id)`
- `semantic_duplicate_scan(library_id)` — async LLM scan
- `save_to_library(library_id, flat_rows)` — normalize library-mode rows (published)

### `Prism.Roles` — Role Profile operations

- `list_role_profiles(org_id, opts)` — filter by role_family, seniority
- `get_role_profile!(org_id, id)`
- `save_role_profile(org_id, attrs, role_rows, opts)` — auto-upserts skills as drafts
- `delete_role_profile(org_id, id)`
- `compare_role_profiles(org_id, profile_ids)` — shared skills, unique, level diffs
- `career_ladder(org_id, role_family)` — profiles ordered by seniority with skill diffs
- `individual_gap(skill_snapshot, role_profile_id)` — gaps for one person vs one role
- `team_gap(snapshots_by_person, role_profile_id)` — aggregate gaps

---

## Core Implementation Detail

### Save to library (library-mode data table → DB)

```elixir
def save_to_library(library_id, flat_rows) do
  library = get_library!(library_id)
  ensure_mutable!(library)

  flat_rows
  |> Enum.group_by(fn row -> {row.category, row.cluster, row.skill_name} end)
  |> Enum.map(fn {{cat, cluster, name}, rows} ->
    skill = upsert_skill(library_id, %{
      category: cat, cluster: cluster, name: name,
      description: hd(rows).skill_description,
      status: "published"
    })

    levels = rows
    |> Enum.reject(& &1.level == 0)
    |> Enum.map(fn row ->
      %{level: row.level, level_name: row.level_name,
        level_description: row.level_description}
    end)
    |> Enum.sort_by(& &1.level)

    if levels != [], do: update_skill_levels(skill, levels)
    skill
  end)
end
```

### Save role profile (role-mode data table → DB)

```elixir
def save_role_profile(org_id, attrs, role_rows, opts \\ []) do
  library_id = Keyword.get_lazy(opts, :library_id, fn ->
    get_or_create_default_library(org_id).id
  end)

  Ecto.Multi.new()
  |> Ecto.Multi.run(:skills, fn _repo, _ ->
    # Two-phase: upsert all, collect near-match pairs
    {:ok, result} = upsert_skills_batch(library_id, role_rows, status: "draft")
    {:ok, result}
  end)
  |> Ecto.Multi.run(:role_profile, fn repo, _ ->
    %RoleProfile{}
    |> RoleProfile.changeset(Map.put(attrs, :organization_id, org_id))
    |> repo.insert(on_conflict: :replace_all, conflict_target: [:organization_id, :name])
  end)
  |> Ecto.Multi.run(:role_skills, fn repo, %{skills: skill_result, role_profile: profile} ->
    entries = Enum.map(skill_result.all_skills, fn {skill, row} ->
      %{
        role_profile_id: profile.id,
        skill_id: skill.id,
        min_expected_level: row.required_level,
        weight: Map.get(row, :weight, 1.0)
      }
    end)
    {count, _} = repo.insert_all(RoleSkill, entries, on_conflict: :nothing)
    {:ok, count}
  end)
  |> Repo.transaction()
end
```

Note: `upsert_skill` does NOT overwrite published status back to draft. Create as draft if new, leave unchanged if existing.

---

## Plugin Tools

Current 8 tools → **13 tools** (composable, not one-per-operation):

| Tool | Replaces | Purpose |
|------|----------|---------|
| `list_libraries` | — | List org's libraries with type, counts, immutable badge |
| `create_library` | — | Create new mutable library |
| `browse_library` | — | List skills by category/status in a library |
| `load_template` | — | Load standard framework as immutable library |
| `fork_library` | — | Fork library (optional category filter) |
| `adopt_skills` | — | Cherry-pick skills from standard into org library |
| `discover_skills` | `search_frameworks` | Unified search: library + roles + standards |
| `save_to_library` | `save_framework` (partial) | Save library-mode data table rows |
| `save_role_profile` | `save_framework` (partial) | Save role-mode rows + create role |
| `load_role_profile` | `load_framework` | Load role into data table |
| `list_role_profiles` | `list_frameworks` | List role profiles |
| `delete_role_profile` | `delete_framework` | Delete role profile |
| `merge_skills` | — | Merge duplicate skills (called during review) |
| `dismiss_duplicate` | — | Mark pair as intentionally different |
| `compare_role_profiles` | `compare_frameworks` | Cross-reference role profiles |
| `add_proficiency_levels` | `add_proficiency_levels` | **No change** |

`find_duplicates` is removed as a standalone tool — dedup is now continuous (built into save flow + background scan). The agent interacts with dedup through the review pairs returned by save and through `merge_skills`/`dismiss_duplicate`.

---

## Agent Prompt Principles

Replace the six rigid workflow paths with principles the agent follows in any order:

```
## Principles

1. DISCOVER BEFORE GENERATING: Before generating skills for a new framework or role,
   call discover_skills(query) to see what exists in the library, similar roles,
   and standard frameworks. Reuse existing skill names verbatim where they match.

2. LIBRARY FIRST: If the org has an existing library, generate skills that extend it.
   If the org has no library, the first framework creation session establishes it.

3. FRAMEWORK vs ROLE: "Create a skill framework for X" = generate skills with
   proficiency descriptions → save_to_library. "Create an X role" = select skills
   from library + set required levels → save_role_profile.

4. HANDLE NEAR-MATCHES: After saving, the system may return near-match pairs.
   Walk through them one at a time: merge (pick a name), or dismiss (keep separate).

5. INCREMENTAL IS NORMAL: The library grows session by session. Draft skills are
   expected. Duplicates are caught and resolved incrementally. Don't try to make
   the library perfect in one session.

6. STANDARDS AS REFERENCE: When the user mentions SFIA, ESCO, or another standard,
   load it as a reference. Offer to adopt individual skills or fork the whole library.
```

### How workflows emerge from principles

| User says | Agent does |
|-----------|-----------|
| "Create a skill framework for Data Engineer" | discover → generate skills+levels → save_to_library → review near-matches |
| "Create a Data Engineer role" | discover → select from library → save_role_profile |
| "We use SFIA" | load_template → browse → adopt or fork |
| "Import our spreadsheet" | import_library → review in data table → save_to_library |
| "Clean up our library" | semantic_duplicate_scan → merge/dismiss pairs → done |
| "Create ML Engineer like our Data Engineer" | load Data Engineer → adjust → save_role_profile |

Same tools, same principles, different entry points. No branching logic needed.

---

## DataTable ↔ Library Normalization

### Save to library: Library-mode → DB

1. Read data table rows via `DT.read_rows/1`
2. Group by `(category, cluster, skill_name)` → each group = one skill
3. Upsert each skill (published), embed proficiency levels as JSONB
4. Return: `"X skills saved (Y new, Z updated, N near-matches to review)"`
5. If near-matches: walk through pairs interactively

### Save role profile: Role-mode → DB

1. Read data table rows via `DT.read_rows/1`
2. Upsert each skill as draft (exact slug match → reuse)
3. Create RoleProfile + RoleSkill entries
4. Return: `"Role 'X' created with Y skills (Z new to library as draft)"`
5. If near-matches from batch upsert: walk through pairs

### Load: DB → DataTable

`load_role_profile(name)`:
1. Publish `data_table_schema_change` with `Schemas.role_profile()`
2. Fetch role profile with preloaded role_skills → skills
3. Emit one row per role_skill
4. Stream via `DT.stream_rows_progressive/4`

`load_library(library_id)`:
1. Publish `data_table_schema_change` with `Schemas.skill_library()`
2. Fetch all skills with proficiency levels
3. Expand each skill into one row per level
4. Stream via `DT.stream_rows_progressive/4`

---

## LiveView & Router

| File | Change |
|------|--------|
| `projections/data_table_projection.ex` | Add `data_table_schema_change` signal handler |
| `live/framework_list_live.ex` | Rename to `role_profile_list_live.ex` — group by role_family |
| `live/framework_show_live.ex` | Rewrite as `role_profile_show_live.ex` — skills + description |
| `live/skill_library_live.ex` | **New** — browse/search library, filter by status, immutable badge |
| `router.ex` | Update routes |

### Routes

```
/orgs/:org_slug/libraries                    ← list libraries
/orgs/:org_slug/libraries/:id                ← browse a library
/orgs/:org_slug/roles                        ← list role profiles
/orgs/:org_slug/roles/:id                    ← role profile detail
/orgs/:org_slug/chat                         ← chat session
```

Nav: `Chat | Libraries | Roles | Settings | Members`

---

## Migration Strategy

**Clean slate** — no production data. Single migration with the full target schema.

1. Delete old migration files and DB
2. Create `20260408000001_prism_schema.exs` with all tables
3. `mix ecto.reset`

---

## Implementation Order

### Step 1: Schema switching in DataTableProjection
- `data_table_schema_change` signal handler
- Store active schema + mode label in projection state
- Mode indicator in data table UI

### Step 2: Ecto schemas + migration
- `Library`, `Skill` (rewrite), `RoleProfile`, `RoleSkill`, `DuplicateDismissal`
- Single migration with all tables
- PostgreSQL `pg_trgm` extension for trigram similarity

### Step 3: Catalog context — Library CRUD + dedup layers
- Library CRUD, `load_template`, `fork_library`, `adopt_skills`, `diff_against_source`
- `upsert_skill` with slug dedup + near-match detection (Layers 1+2)
- `upsert_skills_batch` with two-phase save
- `merge_skills`, `dismiss_duplicate`
- `discover_skills` unified search
- `save_to_library`
- `semantic_duplicate_scan` (Layer 3, async)

### Step 4: Roles context — Save/Load role profiles
- `save_role_profile` with batch skill upsert + near-match pairs
- `load_role_profile`, `list_role_profiles`, `delete_role_profile`
- `compare_role_profiles`

### Step 5: Plugin tool swap
- Replace 8 tools with ~13 new tools
- Update `prompt_sections` with principles (not workflow paths)
- `proficiency_writer` agent: **no change**

### Step 6: LiveView + Router
- Rename Framework pages → RoleProfile pages
- Add SkillLibraryLive
- Update router

### Step 7: Standard framework templates
- Bundle SFIA v8 in `priv/templates/sfia_v8.json`
- Implement `load_template` + `adopt_skills`

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Skill identity drift across sessions | Three-layer dedup: slug match (auto), trigram near-match (suggest), LLM semantic (async). Library converges over time. |
| Near-match interrupts creation flow | Two-phase save: create first, review after. Never blocks the save. |
| Merge breaks role references | Merge repoints all RoleSkill FKs in a transaction. Conflicts resolved by keeping higher level. |
| Dismissed pair becomes real duplicate | Dismissals can be re-reviewed. Semantic scan can optionally include dismissed pairs. |
| Immutable library accidentally modified | `ensure_mutable!` guard on every write operation. |
| Agent ignores discover_skills principle | Dedup layers catch issues regardless. Prevention is best-effort; cure is guaranteed. |
| Library proliferation | `get_or_create_default_library` funnels into single library by default. |
| Trigram similarity too noisy | Threshold tuning (0.4 default). Dismissed pairs filter out false positives permanently. |
| LLM semantic scan cost | At <5000 skills, ~100k tokens per full scan. A few dollars. Triggered, not scheduled. |
| DataTable mode switching confusion | Explicit mode indicator. Warning on switch with unsaved edits. |
| Bottom-up creates messy library initially | By design. Draft status makes it explicit. Continuous dedup cleans incrementally. |

---

## Future Integration Points

### → Gap Analysis (when observation model exists)
- `individual_gap(skill_snapshot, role_profile_id)` — already defined in `Prism.Roles`
- `team_gap(snapshots_by_person, role_profile_id)` — aggregate with weighted averages
- Skill snapshot is a simple `%{skill_id => level}` — can come from manual entry, CSV, or future observation model

### → Rich Role Profiles (when requested)
- Add fields: `purpose`, `accountabilities`, `success_metrics`, `qualifications`, `reporting_context`
- Add `work_activities` JSONB
- All optional, progressive enrichment
- Agent-assisted generation from skill list

### → Career Ladders (when UI is built)
- Query: `role_profiles WHERE role_family = X ORDER BY seniority_level`
- Skill diff between adjacent levels
- No schema changes needed — it's a view over existing data

### → New Library Types
- `type: "psychometric"`, `type: "qualification"`
- Type-specific validation dispatch
- Scoring logic stays in Rust (ds-aether)

### → Standard Framework Expansion
- Bundle ESCO, O*NET, CompTIA
- Template versioning: load new versions alongside old
- Diff-based upgrade path for forks
