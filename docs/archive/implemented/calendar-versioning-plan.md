# Calendar Versioning for Skill Libraries

## Problem

Libraries have no version concept. When a standard framework (e.g. SFIA) gets updated, or an org publishes a revision of their custom library, there is no way to:

1. Track which edition of a library a role profile was built against
2. Compare two editions of the same library side-by-side
3. Publish a snapshot and continue working on the next edition
4. Know if a role's skill requirements are stale relative to the current library

The current `immutable` + `fork` pattern handles **distribution** (standard → working copy) but not **evolution over time** of the same library.

## Design: Version as a Library Lifecycle Stage

Version format: `YYYY.N` where N auto-increments per year (e.g. `2026.1`, `2026.2`). A library progresses through editions:

```
[Library "Engineering Skills"]
  └─ v2026.1 (published, immutable)
  └─ v2026.2 (published, immutable)
  └─ v2027.1 (published, immutable)
  └─ draft   (mutable, working copy)
```

Each published version is a frozen snapshot. At most one draft exists at a time. Publishing the draft creates a new immutable version and optionally opens a fresh draft.

### Core Invariant

**One draft per (org, library name).** Multiple published versions may coexist. The unique constraint becomes `(organization_id, name, version)` where `version` is `NULL` for drafts.

## Schema Changes

### Migration: `add_library_versioning`

```elixir
alter table(:libraries) do
  add :version, :string          # "2026.04" or NULL for draft
  add :published_at, :utc_datetime
  add :superseded_by_id, references(:libraries, type: :binary_id, on_delete: :nilify_all)
end

# Drop old unique index, create new one
drop unique_index(:libraries, [:organization_id, :name])
create unique_index(:libraries, [:organization_id, :name, :version],
  name: :libraries_org_name_version_index
)
create index(:libraries, [:organization_id, :name, :published_at])

# Role profiles: track which library version they were built against
alter table(:role_profiles) do
  add :library_id, references(:libraries, type: :binary_id, on_delete: :nilify_all)
  add :library_version, :string  # snapshot of version at build time
end
```

### Schema: `Library`

New fields:

| Field | Type | Purpose |
|-------|------|---------|
| `version` | `string \| nil` | CalVer tag. `nil` = draft |
| `published_at` | `utc_datetime \| nil` | When this version was frozen |
| `superseded_by_id` | `binary_id \| nil` | Points to next version |

### Schema: `RoleProfile`

New fields:

| Field | Type | Purpose |
|-------|------|---------|
| `library_id` | `binary_id \| nil` | Which library the role was built against |
| `library_version` | `string \| nil` | Snapshot of version at save time |

## Phase 1: Schema + Publish/Draft Lifecycle

**Goal:** Add versioning fields, publish workflow, version-aware queries. No tool changes yet — existing tools work against "latest or draft" by default.

### Step 1.1 — Migration

Create `20260413000001_add_library_versioning.exs`:
- Add columns to `libraries` and `role_profiles`
- Rebuild unique index
- Backfill: existing libraries get `version: NULL` (treated as drafts)

### Step 1.2 — Library Schema

Update `Library` schema and changeset:
- Add `version`, `published_at`, `superseded_by_id` fields
- Add `belongs_to :superseded_by`
- Changeset validates `version` format: `~r/^\d{4}\.\d+$/` when present
- Unique constraint references new index name

### Step 1.3 — RoleProfile Schema

Update `RoleProfile` schema:
- Add `library_id`, `library_version` fields
- Changeset casts both

### Step 1.4 — Library Context: Publish Workflow

New functions in `RhoFrameworks.Library`:

```elixir
@doc """
Publish the current draft as a versioned snapshot.
Freezes the library (immutable: true), stamps version + published_at.
Returns {:ok, published_library}.
"""
def publish_version(org_id, library_id, version_tag, opts \\ [])

@doc """
Create a new draft from the latest published version.
Deep-copies all skills. Returns {:ok, draft_library}.
Fails if a draft already exists for this library name.
"""
def create_draft_from_latest(org_id, library_name, opts \\ [])

@doc """
List all published versions of a library by name, newest first.
"""
def list_versions(org_id, library_name)

@doc """
Get the latest published version of a library by name.
"""
def get_latest_version(org_id, library_name)

@doc """
Get the current draft for a library name, or nil.
"""
def get_draft(org_id, library_name)

@doc """
Resolve a library by name + optional version.
nil version → draft if exists, else latest published.
"""
def resolve_library(org_id, library_name, version \\ nil)

@doc """
Diff two versions of the same library. Returns added/removed/modified skills.
"""
def diff_versions(org_id, library_name, version_a, version_b)
```

Update existing functions:
- `list_libraries/2` — add `version` and `published_at` to select; add option `only: :latest | :drafts | :all` (default `:latest` — shows latest published + any drafts)
- `get_or_create_default_library/1` — returns draft (version: nil)
- `library_summary/1` — include `version` in output
- `ensure_mutable!/1` — still checks `immutable` flag (published versions are immutable)

### Step 1.5 — Roles Context: Version Pinning

Update `Roles.save_role_profile/4`:
- Accept `library_id` in opts (already exists as param from tool)
- When saving, look up the library and stamp `library_id` + `library_version` on the role profile
- If library is a draft (version: nil), stamp `library_version: "draft"`

New function:
```elixir
@doc """
Check if a role profile's skills are current relative to the latest
published library version. Returns {:ok, :current} | {:stale, diff}.
"""
def check_version_currency(org_id, role_profile_id)
```

## Phase 2: Tool + Agent Integration

**Goal:** Agents can publish versions, work with drafts, and understand version context.

### Step 2.1 — Library Tools

Update existing tools:
- `:list_libraries` — include `version` and `published_at` in output
- `:load_library` — add optional `version:` param; default loads draft, falls back to latest
- `:browse_library` — add `version` to output
- `:fork_library` — record source version in `derived_from` metadata
- `:diff_library` — support diffing between versions (not just fork-vs-source)

New tools:
```
:publish_library_version
  params: library_id (required), version_tag (optional, e.g. "2026.1" — auto-generated if omitted), notes (optional)
  effect: freezes library, stamps version + published_at

:create_library_draft
  params: library_name (required)
  effect: deep-copies latest published version into new draft

:list_library_versions
  params: library_name (required)
  returns: [{version, published_at, skill_count, superseded_by}]

:diff_library_versions
  params: library_name (required), version_a (required), version_b (required)
  returns: {added: [...], removed: [...], modified: [...]}
```

### Step 2.2 — Role Tools

Update `:save_role_profile`:
- Stamp `library_version` from the library being saved against
- Include `library_version` in success message

New tool:
```
:check_role_currency
  params: role_profile_id (required)
  returns: {:current | :stale, details}
  — compares role's pinned library_version against latest published
```

### Step 2.3 — Plugin Prompt Sections

Update `RhoFrameworks.Plugin.prompt_sections/2`:
- `library_summary` includes version info: `"Engineering Skills v2026.1 (42 skills, published)"`
- Add note: "Use publish_library_version to freeze a snapshot. Roles pin to the library version they were saved against."

### Step 2.4 — DataTable Schema

No changes to `DataTableSchemas` — version is library-level metadata, not a column in the skill table.

## Phase 3: Web Layer

**Goal:** Version badges, version history, and diff UI in LiveViews.

### Step 3.1 — SkillLibraryLive (List)

- Show version badge next to library name: `v2026.1` or `DRAFT`
- Group by library name, show latest version + draft indicator
- Filter: "Show all versions" toggle

### Step 3.2 — SkillLibraryShowLive (Detail)

- Version badge in header
- "Version History" sidebar or tab: list of published versions with dates
- "Compare Versions" action: select two versions → diff view
- "Publish" button (for drafts): opens modal with version input (defaults to next YYYY.N)
- "Create Draft" button (for published): starts new draft from this version

### Step 3.3 — RoleProfileShowLive (Detail)

- Show "Built against: Engineering Skills v2026.1" with staleness indicator
- If stale: "Update available — library is now v2026.3" with action to review diff

## Impact Summary

| Area | Files Changed | Complexity |
|------|--------------|------------|
| Migration | 1 new | Low |
| Library schema | `library.ex` | Low |
| RoleProfile schema | `role_profile.ex` | Low |
| Library context | `library.ex` | **High** — ~6 new functions, ~4 updated |
| Roles context | `roles.ex` | Medium — 1 new function, 1 updated |
| LibraryTools | `library_tools.ex` | **High** — 4 new tools, ~5 updated |
| RoleTools | `role_tools.ex` | Low — 1 new tool, 1 updated |
| Plugin | `plugin.ex` | Low — prompt section update |
| DataTableSchemas | none | None |
| SkillLibraryLive | 2 LiveViews | Medium |
| RoleProfileLive | 1 LiveView | Low |
| Lenses | none | None — scores link to skill_id directly |

### What Doesn't Change

- **Skill schema** — skills belong to a library; versioning is at library level
- **DataTable schemas** — table columns stay the same
- **Lens scoring** — scores reference `skill_id` directly, not library version
- **Fork/combine workflows** — still work, just gain version awareness
- **Immutability pattern** — published versions become immutable automatically

### Risks & Considerations

1. **SQLite NULL uniqueness** — SQLite treats each NULL as unique in unique indexes, so `(org_id, name, NULL)` won't enforce "one draft per name" at the DB level. Enforce in application code.

2. **Skill identity across versions** — When publishing creates a frozen snapshot with new skill records, `role_skills` still point to the old version's skill IDs. Need to decide: do published versions share skill records (same IDs) or get copies?
   - **Recommendation:** Published versions share the same skill records (owned by the library). Skills are frozen when the library is published. A new draft copies skills (new IDs) so edits don't affect published versions. This matches the existing fork pattern.

3. **Migration for existing data** — All existing libraries become drafts (version: NULL). Users can publish them to create the first versioned snapshot.

4. **Template loading** — Templates (e.g. SFIA v8) could auto-assign a version from their `source_key` metadata. The "v8" in "sfia_v8" maps naturally to a CalVer or semver tag.

5. **Version auto-generation** — The `next_version_tag/2` function auto-computes the next `YYYY.N` by finding the highest N for the current year and incrementing. Version tag is optional when publishing.
