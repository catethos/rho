# Spreadsheet Agent — Handoff Guide

**Branch:** `skill_framework`
**Status:** 10/10 scenarios tested and passing (see `docs/experiments/2026-04-07-company-flow-testing.md`)
**Model:** Haiku 4.5 (`openrouter:anthropic/claude-haiku-4.5`)

---

## Summary

The spreadsheet agent is a skill framework editor that lets users build, import, edit, and manage competency frameworks through a chat interface + live spreadsheet. It supports multi-company access control, versioned saves, industry template browsing, and AI-generated proficiency levels.

### What to take

| Category | Files | Portable? |
|----------|-------|-----------|
| **Agent skills/prompts** | `.agents/skills/framework-editor/` | Yes — pure markdown, zero code dependency |
| **Agent config** | `.rho.exs` (spreadsheet section) | Yes — model, mounts, system prompt |
| **Spreadsheet tools** | `lib/rho/mounts/spreadsheet.ex` (1592 lines) | Yes — depends only on SkillStore + LiveView pid messaging |
| **DB layer** | `lib/rho/skill_store.ex` (436 lines) | Yes — self-contained Ecto module |
| **DB schemas** | `lib/rho/skill_store/{framework,framework_row,company,repo}.ex` | Yes — standard Ecto schemas |
| **DB migrations** | `priv/skill_store/migrations/` (2 files) | Yes |
| **LiveView** | `lib/rho_web/live/spreadsheet_live.ex` (1720 lines) | Needs adaptation — tightly coupled to Rho's signal bus + session system |
| **Core architecture** | `lib/rho/agent/worker.ex`, `lib/rho/session.ex` | 9 lines changed — concept needed, not code |

---

## Section 1: Agent Skills (Prompt Layer)

**Directory:** `.agents/skills/framework-editor/`

This is the agent's "brain" — all workflow logic lives in markdown files that the agent loads at runtime via `read_resource`. No code changes needed to use these.

### SKILL.md — Intent Detection

The main skill file. Maps user messages to workflows:

| Signal | Intent | Action |
|--------|--------|--------|
| No files, describes a role | Generate | Load `generate-workflow.md` |
| Uploads file + "import" | Import | Load `import-workflow.md` |
| Uploads file + "enhance"/"add levels" | Enhance | Load `enhance-workflow.md` |
| Uploads file + "like this"/"based on" | Reference | Load `reference-workflow.md` |
| "Use FSF as reference" (DB template) | Reference (DB) | Load `reference-workflow.md`, use `search_framework_roles` only, do NOT load |
| "Show templates" | Browse | `list_frameworks(type: "industry")` |
| "Load AICB" (full load) | Load template | `load_framework(id)` |
| "Skills for Risk Analyst" + framework | Browse roles | `search_framework_roles` → user picks → `load_framework_roles` |
| "Merge these roles" | Consolidate | `merge_roles(mode: "plan")` → approve → `merge_roles(mode: "execute")` |
| "Load our framework" | Load company | `get_company_overview` → user picks |
| "Load both X and Y" | Multi-load | First `load_framework(id)`, then `load_framework(id, append: true)` |
| "Save this" | Save | `save_framework(mode: "plan")` → present plan → WAIT for approval → `save_framework(mode: "execute")` |
| "Set as default" | Set default | `set_default_version(framework_id)` |
| "Show company view" | Company view | `get_company_view` → cross-role summary |
| First message | Welcome | `get_company_overview` → present roles + templates |

### Reference Workflows (12 files)

| File | Purpose |
|------|---------|
| `generate-workflow.md` | From-scratch generation: intake → skeleton → approval → proficiency levels |
| `import-workflow.md` | Excel/CSV import: parse → column mapping → import |
| `enhance-workflow.md` | Add proficiency levels to imported skills |
| `reference-workflow.md` | Use template as inspiration (NOT direct load) — handles both file uploads and DB templates |
| `persistence-workflow.md` | Save/load/version management flows |
| `deduplication-workflow.md` | Handle duplicate skills across roles |
| `template-workflow.md` | Industry template admin save |
| `dreyfus-model.md` | 5-level proficiency model reference |
| `proficiency-prompt.md` | Prompt for proficiency level generation |
| `quality-rubric.md` | Behavioral indicator quality rules |
| `column-mapping.md` | Standard column names and mapping rules |

---

## Section 2: Spreadsheet Tools (Mount)

**File:** `lib/rho/mounts/spreadsheet.ex` (1592 lines)

This is a mount implementing `@behaviour Rho.Mount`. It provides 21 tools to the agent. The tools communicate with the LiveView via direct pid messaging (for reads) and the signal bus (for writes).

### Tool Inventory

**Spreadsheet CRUD:**
| Tool | Type | What it does |
|------|------|-------------|
| `get_table` | Read (sync) | Read rows with optional filter (`filter_field`, `filter_value`) |
| `get_table_summary` | Read (sync) | Grouped summary: categories, clusters, skill counts |
| `add_rows` | Write (signal) | Add rows from JSON array. Streams in batches of 5. |
| `update_cells` | Write (signal) | Update specific cells by row ID |
| `delete_rows` | Write (signal) | Delete rows by ID array |
| `delete_by_filter` | Write (signal) | Delete rows matching field value(s). Supports AND with `field2`/`value2`. |
| `replace_all` | Write (signal) | Replace entire spreadsheet content |
| `switch_view` | Write (msg) | Toggle between "role" and "category" view |

**File handling:**
| Tool | What it does |
|------|-------------|
| `get_uploaded_file` | Read parsed file content (paginated, supports sheets) |
| `import_from_file` | Bulk import from parsed file via Python (openpyxl/pdfplumber) |

**Proficiency generation:**
| Tool | What it does |
|------|-------------|
| `add_proficiency_levels` | Add proficiency level rows for a skill (manual JSON) |
| `generate_proficiency_levels` | Server-side parallel LLM generation — sends skills to `proficiency_model` (gpt-oss-120b), streams results into spreadsheet |

**Framework persistence:**
| Tool | What it does |
|------|-------------|
| `list_frameworks` | List visible frameworks (industry + company), scoped by company_id |
| `search_framework_roles` | Browse roles in a framework (skill counts + sample skills) |
| `load_framework` | Load framework into spreadsheet. `append: true` to merge. |
| `load_framework_roles` | Load specific roles from a framework. `append: true` to merge. |
| `save_framework` | Two-phase: `mode: "plan"` returns save plan, `mode: "execute"` applies. Versioned. |
| `set_default_version` | Set a framework version as default for its role |
| `get_company_overview` | Company's roles with default versions + industry templates |
| `get_company_view` | Computed cross-role summary: shared skills, unique skills |
| `merge_roles` | Two-phase role merge: plan/execute with deduplication |

### Communication Pattern

Tools talk to the LiveView two ways:

**Reads (synchronous):** Tool sends a message to the LiveView pid, waits for reply.
```elixir
# In tool execute function:
send(pid, {:spreadsheet_get_table, {self(), ref}, filter})
receive do
  {^ref, {:ok, rows}} -> ...
end
```

**Writes (signal bus):** Tool publishes a signal, LiveView subscribes and handles.
```elixir
# In tool execute function:
Rho.Comms.publish("rho.session.#{session_id}.events.rows_delta", %{rows: rows})

# LiveView subscribes in mount:
Rho.Comms.subscribe("rho.session.#{session_id}.events.*")
```

### Key Implementation Detail: `generate_proficiency_levels`

This tool does server-side parallel LLM calls — it doesn't delegate to a sub-agent. It:
1. Takes a JSON array of skills
2. Builds a prompt per skill using `proficiency-prompt.md`
3. Calls `proficiency_model` (configurable, default gpt-oss-120b) in parallel via `Task.async_stream`
4. Parses each response into 5 proficiency level rows
5. Streams rows into the spreadsheet via signal bus

This avoids sub-agent overhead and is much faster than the old delegation approach.

---

## Section 3: Database Layer

**Files:**
- `lib/rho/skill_store.ex` — all queries (436 lines)
- `lib/rho/skill_store/framework.ex` — Framework schema
- `lib/rho/skill_store/framework_row.ex` — FrameworkRow schema
- `lib/rho/skill_store/company.ex` — Company schema
- `lib/rho/skill_store/repo.ex` — Ecto.Repo (SQLite3)
- `priv/skill_store/migrations/` — 2 migration files

### Schema

```
companies
  id          STRING (PK, e.g. "bank_abc")
  name        STRING

frameworks
  id          INTEGER (PK, auto)
  company_id  STRING (FK → companies, nullable for industry templates)
  name        STRING (auto-generated: "data_scientist_2026_v1")
  type        STRING ("industry" | "company")
  source      STRING
  role_name   STRING (nullable — NULL for industry templates)
  year        INTEGER (nullable)
  version     INTEGER (nullable, auto-incremented per company+role+year)
  is_default  BOOLEAN (nullable, one per company+role_name)
  description STRING (nullable)
  row_count   INTEGER
  skill_count INTEGER

framework_rows
  id                INTEGER (PK, auto)
  framework_id      INTEGER (FK → frameworks)
  role              STRING
  category          STRING
  cluster           STRING
  skill_name        STRING (required)
  skill_description STRING
  level             INTEGER (0 = placeholder)
  level_name        STRING
  level_description STRING
  skill_code        STRING (passthrough from industry templates)
```

### Key Query Functions

| Function | What it does |
|----------|-------------|
| `list_frameworks_for(company_id, is_admin, type_filter)` | Scoped framework list with role counts (single query, no N+1) |
| `get_framework_rows(framework_id)` | All rows for a framework |
| `get_framework_rows_for_roles(framework_id, roles)` | Rows filtered by role names |
| `save_role_framework(attrs)` | Versioned save — auto-increments version, sets is_default for first version |
| `get_company_roles_summary(company_id)` | Grouped by role: default version + all versions |
| `get_company_view(company_id)` | Cross-role summary with shared skills (MapSet intersection) |
| `set_default_version(framework_id)` | Transactional default flip |

### Versioning Model

- `name` is auto-generated: `{role_name}_{year}_v{version}` (slug format)
- First-ever version of a role → `is_default = true` automatically
- Subsequent versions → `is_default = false` (draft) until user explicitly promotes
- `action: "update"` overwrites in place (same id/version)
- `action: "create"` creates new version (version auto-incremented)
- Unique constraint: `(company_id, role_name, year, version)` for company type

---

## Section 4: LiveView (UI)

**File:** `lib/rho_web/live/spreadsheet_live.ex` (1720 lines)

Two-panel layout: spreadsheet table (left) + agent chat (right).

### Key Assigns

| Assign | Type | Purpose |
|--------|------|---------|
| `rows_map` | `%{integer => map}` | All visible rows, keyed by integer ID |
| `next_id` | `integer` | Next available row ID |
| `view_mode` | `:role \| :category` | Current grouping mode |
| `company_id` | `string` | From URL `?company=X` |
| `is_admin` | `boolean` | `company == "pulsifi_admin"` |
| `group_summary` | `list` | Collapsed group headers for bulk imports |
| `collapsed` | `MapSet` | Which groups are collapsed |
| `bulk_total` | `integer` | Total rows in ETS (for bulk imports) |

### Message Handlers the Tools Depend On

These `handle_info` clauses are called by the spreadsheet mount tools. Your new LiveView must implement these:

```elixir
# Sync read — tool sends request, waits for reply
{:spreadsheet_get_table, {caller_pid, ref}, filter}
{:spreadsheet_get_table_summary, {caller_pid, ref}}
{:get_all_rows, {caller_pid, ref}}

# Save flow — tool requests rows grouped by role
{:spreadsheet_save_plan, {caller_pid, ref}, year, company_id}

# Framework loading
{:load_framework_rows, rows, framework}                    # replace mode
{:load_framework_rows, rows, framework, append: true}      # append mode

# Bulk import (for large files)
{:bulk_import_rows, rows}

# View switch
{:switch_view, mode}
```

### Signal Handlers

Writes come through the signal bus. The LiveView subscribes to `rho.session.#{session_id}.events.*` and dispatches:

| Signal type | Handler | What it does |
|-------------|---------|-------------|
| `rows_delta` | `handle_rows_delta/2` | Insert new rows into `rows_map` |
| `replace_all` | `handle_replace_all/1` | Clear all rows |
| `update_cells` | `handle_update_cells/2` | Update specific cells in `rows_map` |
| `delete_rows` | `handle_delete_rows/2` | Remove rows from `rows_map` |

---

## Section 5: Core Architecture Change (9 lines)

The mount context (`context.opts`) needs to carry custom data from the LiveView (like `company_id`, `is_admin`). Without this, tools can't scope queries by company.

### What was changed

**`lib/rho/session.ex`** — passes extra opts from caller to Worker:
```elixir
# Before:
worker_opts = [agent_id: ..., session_id: ..., workspace: ..., agent_name: ..., role: :primary, depth: 0]

# After:
worker_opts = [agent_id: ..., session_id: ..., workspace: ..., agent_name: ..., role: :primary, depth: 0,
  extra_opts: Keyword.drop(opts, [:workspace, :agent_name])]
```

**`lib/rho/agent/worker.ex`** — stores and merges extra_opts into mount context:
```elixir
# New field in struct:
extra_opts: %{}

# In init:
extra_opts = Keyword.get(opts, :extra_opts, []) |> Enum.into(%{})

# In build_context:
opts: Map.merge(state.extra_opts, Enum.into(opts, %{}))
```

### What your architecture needs

A mechanism for the session caller (LiveView, API endpoint, etc.) to pass arbitrary key-value pairs that end up in `context.opts` for mount callbacks. The spreadsheet mount reads `context.opts[:company_id]` and `context.opts[:is_admin]` from this.

---

## Section 6: Agent Config

**File:** `.rho.exs` (spreadsheet section)

```elixir
spreadsheet: [
  model: "openrouter:anthropic/claude-haiku-4.5",
  proficiency_model: "openrouter:openai/gpt-oss-120b",
  description: "Skill framework editor with guided intake and parallel generation",
  skills: [],
  default_skills: ["framework-editor"],
  python_deps: ["openpyxl", "pdfplumber", "chardet", "Pillow"],
  system_prompt: """
  You are a skill framework editor assistant.
  Use the framework-editor skill to guide your workflow.
  For simple edits, use spreadsheet tools directly.
  """,
  mounts: [:spreadsheet, :skills],
  reasoner: :structured,
  max_steps: 50
]
```

Key config:
- `model` — main agent model (Haiku 4.5, switched from DeepSeek v3.1 due to JSON format issues)
- `proficiency_model` — used by `generate_proficiency_levels` for parallel LLM calls
- `default_skills: ["framework-editor"]` — auto-loads SKILL.md into system prompt
- `reasoner: :structured` — agent responds in JSON action/action_input format
- `mounts: [:spreadsheet, :skills]` — spreadsheet tools + skill loading

---

## Tested Scenarios

All 10 scenarios pass. Full results with demo scripts (exact user messages to replicate) in `docs/experiments/2026-04-07-company-flow-testing.md`.

| # | Scenario | Status |
|---|----------|--------|
| 1 | Browse template → pick role → save | PASS |
| 2 | Multi-role select + merge | PASS |
| 3 | Load → edit → versioned save | PASS |
| 4 | Generate from scratch (one role) | PASS |
| 5 | Multi-role from scratch (3 roles) | PASS |
| 6 | Template as reference | PASS (with issues) |
| 7 | Multi-sheet Excel import + enhance | PASS |
| 8 | Load → edit → save update in place | PASS |
| 9 | Fully structured Excel import (100% match) | PASS |
| 10 | Access control (multi-company) | PASS |

## Known Issues

| Issue | Severity | Notes |
|-------|----------|-------|
| Finch pool exhaustion | Medium | Hits 1-5x per session, auto-recovers. Root cause: metadata fetch on stream connections. |
| Reference workflow still tries `get_uploaded_file` on DB templates | Low | Falls back gracefully |
| Agent sometimes skips skeleton review phase | Low | Prompt improvement needed |
| Title-case normalization: "HR Manager" → "Hr Manager" | Low | Cosmetic bug in `save_role_framework` |
