# Plan: Eliminate Flat-Row Denormalization + Grouped Skill DataTable

## Problem

Skills are structured (skill with nested `proficiency_levels`), but the DataTable forces everything into flat `skill × level` rows. This creates a wasteful round-trip:

**structured → flatten → display → read back flat → unflatten**

~120 lines of flatten/unflatten code exist solely to bridge this mismatch (`denormalize_library`, `upsert_skills_from_rows`, template flattening). Additionally, `fork_library` and `combine_libraries` are the same operation with duplicated logic, and slug generation is duplicated between `Library` context and `Skill.changeset`.

---

## Phase 1: New `:skill_library` Schema — Structured, Not Flat

### Files
- `apps/rho_web/lib/rho_web/data_table/schema.ex`
- `apps/rho_web/lib/rho_web/data_table/schemas.ex`

### Schema Struct Changes (`schema.ex`)

Add `children_key` and `child_columns` to the `Schema` struct:

```elixir
defstruct title: "Data Table",
          empty_message: "No data yet",
          columns: [],
          child_columns: [],
          children_key: nil,
          group_by: []
```

Update `known_field_names/1` and `column_defaults/1` to include child column fields.

### New Skill Library Schema (`schemas.ex`)

Replace the current `skill_library` schema (which has `level`, `level_name`, `level_description` as top-level columns) with a two-tier schema:

- **Skill row** (parent): `category`, `cluster`, `skill_name`, `skill_description` — all editable
- **Proficiency level row** (child): `level`, `level_name`, `level_description` — editable, visually nested under parent

```elixir
def skill_library do
  %Schema{
    title: "Skill Framework Editor",
    empty_message: "No data — ask the assistant to generate a skill framework",
    group_by: [:category, :cluster],
    children_key: :proficiency_levels,
    columns: [
      %Column{key: :category, label: "Category", editable: false, css_class: "dt-col-cat"},
      %Column{key: :cluster, label: "Cluster", editable: false, css_class: "dt-col-cluster"},
      %Column{key: :skill_name, label: "Skill", css_class: "dt-col-skill"},
      %Column{key: :skill_description, label: "Description", type: :textarea, css_class: "dt-col-desc"}
    ],
    child_columns: [
      %Column{key: :level, label: "Lvl", type: :number, css_class: "dt-col-lvl"},
      %Column{key: :level_name, label: "Level Name", css_class: "dt-col-lvlname"},
      %Column{key: :level_description, label: "Level Description", type: :textarea, css_class: "dt-col-lvldesc"}
    ]
  }
end
```

The `:role_profile` schema stays unchanged — role profile rows are genuinely flat (`skill_name` + `required_level`).

---

## Phase 2: DataTableComponent — Render Parent + Expandable Children

### File
- `apps/rho_web/lib/rho_web/components/data_table_component.ex`

### Rendering

Within each group (category → cluster), render skills as **parent rows**. Each parent row:

- Shows skill-level columns (`skill_name`, `skill_description`)
- Has a toggle chevron to expand/collapse its proficiency levels
- When expanded, renders child rows underneath (indented) with `level`, `level_name`, `level_description`

Both parent and child rows use the existing `editable_cell` — no new edit machinery needed.

When `schema.children_key` is `nil`, behavior is identical to today (flat table).

### Edit Events for Child Rows

Child cells need a compound ID so `save_edit` can update the correct nested entry:

- ID format: `"#{parent_row_id}:child:#{child_index}"`
- `start_edit` — parse compound IDs, support child cells
- `save_edit` — when editing a child field, update the nested `proficiency_levels` list inside the parent row in-place

### Key Changes

- `data_table_rows/1` — detect `children_key` on schema; if present, render parent+child structure
- `save_edit` — when editing a child field, update the nested map inside the parent row's `proficiency_levels` list
- `start_edit` — support compound IDs for child cells
- Add expand/collapse state tracking per parent row (reuse existing `collapsed` MapSet)

---

## Phase 3: DataTableProjection — Handle Structured Rows

### File
- `apps/rho_web/lib/rho_web/projections/data_table_projection.ex`

### Changes

- `known_fields` must include both parent and child field names
- `reduce_rows_delta` — accept structured rows (skill maps with `proficiency_levels` as a nested list) directly; no flattening
- `apply_optimistic_edit` — support edits to child fields by updating the nested `proficiency_levels` list in-place
- Add `reduce_child_edit` path for when `row_id` is a compound `{parent_id, child_index}`

---

## Phase 4: Eliminate `denormalize_library` / `upsert_skills_from_rows`

### File
- `apps/rho_frameworks/lib/rho_frameworks/library.ex`

### Deletions

1. **Delete `denormalize_library/2`** (~30 lines) — no longer needed; `load_library` will pass structured skill maps directly

2. **Delete `upsert_skills_from_rows/3`** (~55 lines) — `save_to_library` will accept structured skill maps instead of flat rows

### Replacements

3. **Replace `save_to_library/2`** — accept a list of structured skill maps and upsert directly:

```elixir
def save_to_library(library_id, skills) do
  Ecto.Multi.new()
  |> Ecto.Multi.run(:skills, fn _repo, _ ->
    results =
      Enum.map(skills, fn skill_map ->
        {:ok, skill} = upsert_skill(library_id, %{
          category: skill_map[:category] || skill_map["category"] || "",
          cluster: skill_map[:cluster] || skill_map["cluster"] || "",
          name: skill_map[:skill_name] || skill_map["skill_name"],
          description: skill_map[:skill_description] || skill_map["skill_description"] || "",
          proficiency_levels: skill_map[:proficiency_levels] || skill_map["proficiency_levels"] || [],
          status: "published"
        })
        skill
      end)
    {:ok, results}
  end)
  |> Repo.transaction()
end
```

4. **Simplify `load_template_data/1`** in `library_tools.ex` — remove the flatten-to-rows step; pass skills as structured maps with nested `proficiency_levels` directly to `Library.load_template`

---

## Phase 5: Update Tools Layer

### File: `apps/rho_frameworks/lib/rho_frameworks/tools/library_tools.ex`

- **`load_library` tool** — call `Library.list_skills(library_id, opts)` directly and map to structured skill maps (with `proficiency_levels` inline); pass through `%Rho.Effect.Table{rows: skills}` instead of calling `denormalize_library`

- **`save_to_library` tool** — `DT.read_rows` now returns structured skill maps (with nested `proficiency_levels`); pass them directly to `Library.save_to_library/2`

- **`load_template` tool** — remove the flatten step in `load_template_data/1`; template JSON → structured maps → `Library.load_template`

### File: `apps/rho_frameworks/lib/rho_frameworks/tools/role_tools.ex`

- **No changes** — role profile rows are genuinely flat (`skill_name` + `required_level`), so the `:role_profile` schema stays as-is

---

## Phase 6: Unify `fork_library` + `combine_libraries`

### File
- `apps/rho_frameworks/lib/rho_frameworks/library.ex`

### Rationale

`fork_library(org_id, src, name)` is `combine_libraries(org_id, [src], name)` with one input. They share 80% of their logic (`copy_skill`, skill-id remapping) but are implemented independently.

### Replace Both With

```elixir
def derive_library(org_id, source_library_ids, new_name, opts \\ [])
    when is_list(source_library_ids) do
  categories = Keyword.get(opts, :categories, :all)
  include_roles = Keyword.get(opts, :include_roles, true)
  description = Keyword.get(opts, :description)

  sources = Enum.map(source_library_ids, &get_library!(org_id, &1))

  desc = description ||
    case sources do
      [single] -> "Derived from #{single.name}"
      many -> "Combined from: #{Enum.map_join(many, ", ", & &1.name)}"
    end

  Ecto.Multi.new()
  |> Ecto.Multi.insert(:library, fn _ ->
    Library.changeset(%Library{}, %{
      name: new_name,
      organization_id: org_id,
      type: hd(sources).type,
      immutable: false,
      derived_from_id: hd(sources).id,
      description: desc
    })
  end)
  |> Ecto.Multi.run(:skills, fn _repo, %{library: lib} ->
    all_skills =
      Enum.flat_map(sources, fn src ->
        list_skills(src.id, skills_filter_opts(categories))
      end)

    # Slug-based dedup across sources, keep first seen
    {copied, _seen} =
      Enum.reduce(all_skills, {[], %{}}, fn skill, {acc, slugs} ->
        slug = Skill.slugify(skill.name)
        case Map.get(slugs, slug) do
          nil ->
            {:ok, new_skill} = copy_skill(skill, lib.id, source_skill_id: skill.id)
            {[new_skill | acc], Map.put(slugs, slug, skill.description)}
          existing_desc when existing_desc == skill.description ->
            {acc, slugs}
          _different_desc ->
            counter = Enum.count(slugs, fn {k, _} -> String.starts_with?(k, slug <> "-") end) + 2
            disambiguated_name = "#{skill.name} (#{counter})"
            {:ok, new_skill} = copy_skill(%{skill | name: disambiguated_name}, lib.id, source_skill_id: skill.id)
            {[new_skill | acc], Map.put(slugs, Skill.slugify(disambiguated_name), skill.description)}
        end
      end)

    {:ok, Map.new(Enum.reverse(copied), &{&1.source_skill_id, &1})}
  end)
  |> Ecto.Multi.run(:role_profiles, fn _repo, %{skills: skill_id_map} ->
    if include_roles do
      source_roles =
        Enum.flat_map(sources, fn src ->
          list_role_profiles_for_library(src.id, skills_filter_opts(categories))
        end)
      copied = Enum.map(source_roles, fn role ->
        {:ok, rp} = copy_role_profile(role, org_id, skill_id_map, fork_name: new_name)
        rp
      end)
      {:ok, copied}
    else
      {:ok, []}
    end
  end)
  |> Repo.transaction()
end
```

### Tools Layer

- `fork_library` tool calls `derive_library(org_id, [source_id], name, opts)`
- `combine_libraries` tool calls `derive_library(org_id, ids, name, opts)`
- Tool names and descriptions stay the same — this is an internal refactor

---

## Phase 7: Consolidate Slug Generation

### File: `apps/rho_frameworks/lib/rho_frameworks/frameworks/skill.ex`

Make slug generation a public function:

```elixir
def slugify(name) do
  name
  |> String.downcase()
  |> String.trim()
  |> String.replace(~r/[^a-z0-9]+/, "-")
  |> String.trim("-")
end
```

The private `generate_slug` changeset callback calls this internally.

### File: `apps/rho_frameworks/lib/rho_frameworks/library.ex`

Delete the private `slugify/1` function. Replace all call sites with `Skill.slugify/1`.

---

## Phase 8: Tests

- **Update `library_test.exs`** — replace `denormalize_library` and `upsert_skills_from_rows` tests with structured-input versions of `save_to_library`
- **Update DataTable component tests** (if any) — verify parent/child rendering and child cell editing
- **Add `derive_library` tests** — verify both single-source (fork) and multi-source (combine) cases work identically to the old separate functions
- **Run full suite:** `mix test` across all apps

---

## Code Impact Summary

| Change | Lines Removed | Lines Added | Net |
|---|---|---|---|
| Delete `denormalize_library` | ~30 | 0 | -30 |
| Delete `upsert_skills_from_rows` | ~55 | 0 | -55 |
| Simplify `save_to_library` | ~5 | ~8 | +3 |
| Simplify `load_template_data` flatten | ~30 | ~5 | -25 |
| Unify fork + combine → `derive_library` | ~75 | ~50 | -25 |
| Consolidate slug | ~10 | ~5 | -5 |
| DataTable grouped rendering | 0 | ~50 | +50 |
| Schema struct changes | 0 | ~10 | +10 |
| Projection child-edit support | 0 | ~25 | +25 |
| **Total** | **~205** | **~153** | **~-52** |

Less code, no more flatten/unflatten round-trips, and the DataTable natively understands hierarchical skill data.
