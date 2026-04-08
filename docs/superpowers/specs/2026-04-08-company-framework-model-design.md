# Company Framework Model — Versioned Role Frameworks

**Date:** 2026-04-08
**Branch:** `skill_framework`

---

## Problem

The current data model has one `frameworks` table with `type: industry | company`. All company frameworks are flat — no relationship between roles, no versioning, user-defined names that get messy. This causes:

1. No way to see "bank_abc's full skill framework" (all roles together)
2. No versioning — `data_scientist_2025` and `data_scientist_2026` are unrelated records
3. Naming chaos — users can name frameworks anything
4. Saving a multi-role spreadsheet back to individual role records is unsupported
5. No "company view" across roles

## Solution

Add `role_name`, `year`, `version`, `is_default`, and `description` to the frameworks table. Auto-generate framework names. Make save role-aware and version-aware.

---

## Data Model

### Schema Migration

Add columns to `frameworks` table (all nullable — no defaults at column level):

```
role_name   TEXT                       -- e.g., "Data Scientist", "Risk Analyst". NULL for industry templates.
year        INTEGER                    -- framework year (user-provided). NULL for industry templates.
version     INTEGER                    -- auto-incremented per company+role_name+year. NULL for industry templates.
is_default  BOOLEAN                    -- user-chosen active version, one per (company_id, role_name). NULL for industry templates.
description TEXT                       -- optional user note, e.g., "added MLOps skills"
```

All columns nullable so industry templates (FSF) keep NULLs cleanly. Company frameworks always populate these fields. Enforced in application code (`save_role_framework` validates non-null for company type), not DB constraints.

**`is_default`** — the version the company actively uses. Only one per `(company_id, role_name)`. Flipped in a transaction:

```elixir
Repo.transaction(fn ->
  # Unset old default for this company+role_name
  from(f in Framework,
    where: f.company_id == ^company_id and f.role_name == ^role_name and f.is_default == true)
  |> Repo.update_all(set: [is_default: false])

  # Set new default
  Repo.update!(framework, %{is_default: true})
end)
```

- First version of a role: auto-set `is_default = true`
- Subsequent versions: `is_default = false` (draft until user explicitly sets it)
- User says "set this as default" to switch
- No `is_latest` concept — user controls when to promote a version

**`name` is auto-generated on save**, never user-editable: `{role_name}_{year}_v{version}` (lowercase, spaces→underscores)
- `data_scientist_2025_v1`
- `data_scientist_2025_v2`
- `risk_analyst_2026_v1`

Unique constraint: `(company_id, role_name, year, version)` — no duplicates. `role_name` is normalized to title case on save ("data scientist" → "Data Scientist") to prevent case-sensitivity duplicates. SQLite treats NULLs as distinct in unique indexes, so industry templates (all NULLs) won't conflict. If migrating to Postgres later, use a partial unique index: `WHERE type = 'company'`.

**Query for default versions:**
```sql
SELECT * FROM frameworks WHERE company_id = ? AND is_default = true
```

**Ecto schema update** (`lib/rho/skill_store/framework.ex`):
```elixir
field(:role_name, :string)          # nullable — NULL for industry templates
field(:year, :integer)              # nullable
field(:version, :integer)           # nullable
field(:is_default, :boolean)        # nullable
field(:description, :string)        # nullable
```
Update `changeset/2` to cast new fields. For company type, validate `role_name`, `year`, `version` are present. Keep `validate_inclusion(:type, ["industry", "company"])`.

### How Existing Data Migrates

| Current record | After migration |
|------|------|
| id=90, name="FSF...", type=industry | Unchanged. All new columns stay NULL. Industry templates don't use versioning. |
| id=91, name="data_scientist_2025", type=company, company_id=bank_abc | role_name="Data Scientist", year=2025, version=1, is_default=true, name→"data_scientist_2025_v1" |
| id=92, name="risk_analyst_2026", type=company, company_id=bank_abc | role_name="Risk Analyst", year=2026, version=1, is_default=true, name→"risk_analyst_2026_v1" |

Migration strategy:
1. Add all new columns as nullable (no defaults) — existing rows get NULLs
2. For each existing company framework (`type = 'company'`):
   - Infer `role_name` from the framework's existing `name` field (strip year, convert to title case)
   - Infer `year` from the name if it contains a 4-digit year, otherwise use `inserted_at` year
   - Set `version=1`, `is_default=true`
   - Auto-generate `name` → `{role_name}_{year}_v1`
3. Industry templates (`type = 'industry'`): leave all new columns as NULL
4. Log a warning if `framework_rows` contain mixed `role` values for manual review

### Example DB State After Growth

```
id  | company_id | role_name        | year | version | is_default | name
91  | bank_abc   | Data Scientist   | 2025 | 1       | true       | data_scientist_2025_v1  ← default (user-chosen)
93  | bank_abc   | Data Scientist   | 2025 | 2       | false      | data_scientist_2025_v2
94  | bank_abc   | Data Scientist   | 2026 | 1       | false      | data_scientist_2026_v1  ← draft, not yet default
92  | bank_abc   | Risk Analyst     | 2026 | 1       | true       | risk_analyst_2026_v1   ← default
95  | bank_abc   | Software Engineer| 2026 | 1       | true       | software_engineer_2026_v1 ← default
```

User controls which version is default. New versions are drafts until explicitly promoted.

---

## Save Flow (Multi-Role, Versioned)

### Two-phase save (plan/execute) — same pattern as `merge_roles`

Save uses a server-side tool with plan/execute modes. The LLM does NOT group rows or check versions — the tool does all the algorithmic work and returns a structured plan.

#### Phase 1: `save_framework(mode: "plan", year: 2026)`

Tool reads rows_map from LiveView, groups by `role` column, checks DB for each role, returns:

```json
{
  "year": 2026,
  "roles": [
    {
      "role_name": "Data Scientist",
      "skill_count": 28,
      "row_count": 140,
      "status": "new",
      "is_first_role": true
    },
    {
      "role_name": "Risk Analyst",
      "skill_count": 31,
      "row_count": 155,
      "status": "exists",
      "existing": {"year": 2026, "version": 1, "created_at": "2026-04-08"}
    }
  ],
  "mismatches": []
}
```

- `status: "new"` — no existing framework for this role_name
- `status: "exists"` — same role_name+year exists, user chooses update vs new version
- `is_first_role: true` — first-ever version of this role_name (checked across ALL years), will be auto-set as default
- `mismatches` — if rows have unexpected role values (see Mismatch Handling below)

#### Agent presents the plan:

**Clean case (no mismatches):**
```
Save plan for year 2026:
- Data Scientist → 2026 v1 (new, 28 skills) — will be set as default
- Risk Analyst → 2026 v1 already exists (31 skills). Update or new version?
```

**Mismatch case:**
```
I found rows with mixed role names:
- 150 rows with role="Risk Analyst"
- 5 rows with role="Credit Risk" (leftover from merge?)

How should I save these?
a) Save as 2 separate role frameworks (Risk Analyst + Credit Risk)
b) Rename all to "Risk Analyst" and save as one
c) Rename all to "Credit Risk" and save as one
```

User decides — no silent auto-rename.

#### Phase 2: `save_framework(mode: "execute", year: 2026, decisions: "...")`

After user confirms, agent calls execute with the user's decisions:

```json
{
  "mode": "execute",
  "year": 2026,
  "decisions": [
    {"role_name": "Data Scientist", "action": "create"},
    {"role_name": "Risk Analyst", "action": "update", "existing_id": 92}
  ],
  "description": "added MLOps skills"
}
```

- `action: "create"` — creates new version. Function internally checks if first-ever version for this role_name (across all years) and sets `is_default=true` if so, `is_default=false` otherwise (draft).
- `action: "update"` — overwrites existing framework_id in place. No version/default changes.

#### Year defaults
- Default: current year, asked ONCE for all roles (not per-role)
- If user loaded an older framework (e.g., loaded 2025 v1 and edited it), tool uses the loaded year as default
- User can override: "save as 2026" or "keep it as 2025"

#### Description
- Agent does NOT ask for notes by default
- User can volunteer: "save with note: added MLOps skills"
- Passed in execute phase, stored in `description` field

---

## Welcome Flow

### First message, empty spreadsheet

Agent calls `get_company_overview` tool (new) → returns grouped role data. Agent presents:

#### Has company frameworks:
```
Welcome! Here's bank_abc's skill framework:

Your roles:
- Data Scientist — 2025 v1 (26 skills) [default]
  - Other versions: 2025 v2, 2026 v1 (draft)
- Risk Analyst — 2026 v1 (31 skills) [default]

Industry templates:
- FSF Malaysian Financial Sector (157 roles)

I can help you:
- Load and edit an existing role framework
- Create a new role framework
- Browse industry templates for reference
- Import from Excel/CSV/PDF
- Generate AI proficiency levels
- View all roles together (company view)

What would you like to work on?
```

#### No company frameworks:
```
Welcome! No skill frameworks yet for bank_abc.

Industry templates available:
- FSF Malaysian Financial Sector (157 roles)

I can help you get started:
- Browse industry template roles
- Create a new role framework from scratch
- Import from Excel/CSV/PDF

What would you like to do?
```

---

## Multi-Framework Load (Append Mode)

### Load single role
`load_framework(id)` — same as now, replaces spreadsheet.

### Load multiple roles (company view)
New parameter on both tools:
- `load_framework(id, append: true)` — appends company framework rows
- `load_framework_roles(id, roles, append: true)` — appends industry template roles

Both add rows to existing spreadsheet instead of replacing. Enables:
- "Load Data Scientist AND Risk Analyst together" (company frameworks)
- "Also load Data Science roles from FSF" (industry template, after loading company data)

### "Load company framework"
Agent interprets as: load all `is_default=true` frameworks for this company using append mode. Shows in "By Role" view.

### Save after append/multi-role load
Save uses the two-phase plan/execute flow. It groups rows by `role` column and saves each as its own framework. It does NOT trace rows back to their source framework ID — the `role` column is the identity. This keeps the logic simple and handles cases where users edit role names or move skills between roles.

---

## Multi-Tab Import

### Flow
1. User uploads `bank_abc_skills.xlsx` with tabs: "Data Scientist", "Risk Analyst", "Software Engineer"
2. Backend parses all tabs (already supported by openpyxl)
3. Agent detects multiple sheets: "I found 3 role tabs. I'll import all into the spreadsheet — you can review before saving."
4. Agent imports each tab with `role` = tab name
5. User reviews in "By Role" view, edits as needed
6. "Save" → triggers multi-role save flow (asks year, version per role)

### Single-tab Excel
- Same as today — agent imports, asks for role name if not obvious

---

## Company View (Computed)

### "Show me our company framework"
Agent queries all `is_default=true` company frameworks, computes:

```json
{
  "company": "bank_abc",
  "total_roles": 3,
  "total_unique_skills": 52,
  "roles": [
    {"role": "Data Scientist", "year": 2026, "version": 1, "skill_count": 28},
    {"role": "Risk Analyst", "year": 2026, "version": 1, "skill_count": 31},
    {"role": "Software Engineer", "year": 2026, "version": 1, "skill_count": 22}
  ],
  "shared_skills": ["Communication", "Critical Thinking", "Digital Fluency"],
  "shared_count": 15
}
```

This is a read tool, not a save — no new records created.

---

## Version Comparison

### "Compare Data Scientist 2025 vs 2026"

Requires a dedicated `compare_versions` tool (not merge_roles — different semantics). merge_roles compares skill names across roles; version comparison needs field-level diffs within the same role (description changes, level wording changes, added/removed skills).

**To be designed when sub-project 7 is prioritized.** Not covered by existing tools.

---

## Implementation Priority

```
[1] Schema Migration          ← foundation, everything depends on this
    ↓
[2] Multi-Role Save           ← core behavior change (versioned, interactive)
    ↓
[3] Welcome Flow              ← uses new schema, SKILL.md only
[4] Multi-Framework Load      ← append mode parameter
    ↓
[5] Multi-Tab Import          ← needs append + multi-role save
[6] Company View              ← computed summary tool
[7] Version Comparison        ← dedicated compare_versions tool (to be designed)
```

Sub-projects 1-4 are the core. 5-7 are extensions.

---

## Code Changes Required

### `save_framework_tool` rewrite (`lib/rho/mounts/spreadsheet.ex`)

Current tool takes `(name, type, framework_id)` and saves all rows as one framework. Needs complete rewrite to two-phase plan/execute.

**New tool parameter schema:**
```
save_framework(
  mode: "plan" | "execute",       # required
  type: "company" | "industry",   # optional, default "company"
  year: integer,                   # required for company type (default: current year)
  decisions: string,               # JSON array, required for execute mode
  description: string              # optional
)
```

**If `type: "industry"`:** bypasses versioning entirely. Calls existing `save_framework/1` for admin template saves. Requires admin permission. No plan/execute needed — just saves all rows as one industry framework (existing behavior).

**If `type: "company"` (default):**

**Plan mode:** reads rows_map from LiveView via `{:spreadsheet_save_plan, ...}` message, groups by role, checks DB, returns structured plan JSON. No mutations. Always re-reads latest rows_map (user may have edited between plan and execute).

**Execute mode:** re-reads rows_map (latest state), takes user's decisions, calls `save_role_framework` per role. Mutations in transaction.

Note: `loaded_framework_id` and `loaded_framework_name` assigns in LiveView are currently dead code (assigned but never read). Can be repurposed or removed.

### `save_role_framework` (`lib/rho/skill_store.ex`)

New function alongside existing `save_framework/1` (kept for industry templates):

```elixir
save_role_framework(%{
  company_id: "bank_abc",
  role_name: "Data Scientist",
  year: 2026,
  action: :create | :update,
  existing_id: nil | integer,     # framework id to overwrite (action: :update only)
  description: "",
  source: "spreadsheet_editor",
  rows: [...]
})
```

- `:create` — compute next version for `(company_id, role_name, year)`, create record. Internally checks if first-ever version of this `role_name` across ALL years (`SELECT COUNT(*) FROM frameworks WHERE company_id = ? AND role_name = ? AND type = 'company'`). If count=0, set `is_default=true`. If count>0, set `is_default=false` (draft).
- `:update` — delete old rows for `existing_id`, re-insert. No version/default changes.
- Auto-generate `name` from `(role_name, year, version)`.
- Normalize `role_name` to title case on save (e.g., "data scientist" → "Data Scientist") to avoid case-sensitivity duplicates in the unique constraint.

### `get_company_roles_summary` + `get_company_overview` tool

New query in `skill_store.ex`:
```elixir
get_company_roles_summary(company_id) -> [
  %{role_name: "Data Scientist", 
    default: %{id: 91, year: 2025, version: 1, skill_count: 26, ...}, 
    versions: [%{id: 91, year: 2025, version: 1}, %{id: 93, year: 2025, version: 2}, ...]},
  %{role_name: "Risk Analyst", 
    default: %{id: 92, year: 2026, version: 1, skill_count: 31, ...}, 
    versions: [...]}
]
```

New tool in `spreadsheet.ex`: `get_company_overview` — calls `get_company_roles_summary`, also queries industry templates, returns combined JSON. Used by welcome flow.

### `list_frameworks_for` response shape (`lib/rho/skill_store.ex`)

Add new fields to response: `role_name`, `year`, `version`, `is_default`, `description`. Existing consumers continue to work (new fields are additive).

### Append mode (`lib/rho/mounts/spreadsheet.ex` + `lib/rho_web/live/spreadsheet_live.ex`)

Add `append` parameter to both `load_framework` and `load_framework_roles` tools.

LiveView handler changes for append:
- Current: `assign(:rows_map, rows_map)` — replaces entire map
- Append: `Map.merge(socket.assigns.rows_map, new_rows_map)` — merges
- Current: `assign(:next_id, next_id)` — resets to 1
- Append: start from `socket.assigns.next_id` — continues counting
- `loaded_framework_id` / `loaded_framework_name` — dead assigns, remove or ignore

New LiveView handler: `{:append_framework_rows, rows, framework}` alongside existing `{:load_framework_rows, ...}`.

### Multi-tab import clarification

Agent-driven loop, not a single tool call:
1. Agent calls `get_uploaded_file(filename, sheet: "Data Scientist")` → gets rows for tab 1
2. Agent calls `add_rows(rows_json: [...])` with `role: "Data Scientist"` on each row
3. Repeat for each tab

This is serial but works with existing tools. A `import_multi_tab` server-side tool can be added later for performance.

### `skill_code` field

Exists in `framework_rows` schema. Intentionally unchanged — it's a passthrough field from FSF data. No impact on versioning or role management.

### SKILL.md + Workflow Doc Updates

These prompt/doc files must be updated to match the new tool signatures:

| File | Changes needed |
|------|---------------|
| `.agents/skills/framework-editor/SKILL.md` | "Save" intent: `save_framework(name, type)` → `save_framework(mode: "plan", year: ...)`. "Save template" intent: add `type: "industry"`. "Load company" intent: reference `get_company_overview` + versioned loading. "Welcome" intent: call `get_company_overview`. "Available Tools" section: add `get_company_overview`, update `save_framework` description, add `append` parameter on load tools. |
| `references/persistence-workflow.md` | Full rewrite — save flow is now two-phase plan/execute with versioning. Load flow needs version awareness + append mode. |
| `references/template-workflow.md` | Admin save: `save_framework(type: "industry")` still works (bypass versioning). Clone+customize: save triggers versioned flow. |
| `references/deduplication-workflow.md` | `list_frameworks` references need version awareness — check by `role_name`, not just `name`. |

---

## What Stays Unchanged

- Industry templates (FSF) — no versioning, no role_name, no is_default
- Spreadsheet UI — no frontend changes, "By Role" view already works
- Existing tools (get_table, delete_rows, merge_roles, etc.)
- framework_rows table — no schema change
- Existing `save_framework/1` — kept for backwards compat, new `save_role_framework/1` added alongside

## Edge Cases

| Case | Behavior |
|------|----------|
| No company_id (opened without ?company=) | Welcome says: "No company specified. Open with ?company=your_company to manage your frameworks." Industry template browsing still works. |
| User saves with role="" (no role column) | Reject and ask for role name. Every company framework needs a role. |
| User renames role in spreadsheet before save | New role name = new framework. Agent confirms: "I see 'ML Engineer' — this is a new role, not an update to 'Data Scientist'. Create new?" |
| User deletes all rows for a role before save | Skip that role. Don't delete the existing framework — user might want it later. |
| 10+ versions of same role | Show default + "9 other versions. Say 'show history' to see all." |
| Two users editing same role simultaneously | Last save wins. No locking (out of scope). |
| Rows have mixed role values in spreadsheet | Save plan detects and presents mismatch to user. User chooses: save as separate roles, or rename all to one role. No silent auto-rename. |
| User says "set as default" for a draft version | Transaction: unset old default for this role_name, set new one. |
| No default exists for a role (data corruption) | Agent picks highest year+version as fallback, sets it as default. |

## Future UI Enhancement (Not in Scope)

File explorer sidebar:
```
📁 bank_abc
├── 📁 Data Scientist
│   ├── 📄 2025 v1 (26 skills) ⭐ default
│   └── 📄 2026 v1 (28 skills) draft
├── 📁 Risk Analyst
│   └── 📄 2026 v1 (31 skills) ⭐ default
```

This uses the same data model — just a UI layer on top. Can be added later without schema changes.

Other future enhancements:
- Delete/archive old non-default versions (cleanup)
- `import_multi_tab` server-side tool (batch import instead of agent-driven loop)
