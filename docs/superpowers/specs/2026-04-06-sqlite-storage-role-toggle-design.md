# SQLite Storage + Role Column + Toggle View — Design Spec

## Problem

The spreadsheet editor currently:
1. Has no persistent storage — data lost on page refresh
2. Has no `role` column — skills lose role context when accumulated
3. Has no way to browse/clone industry templates
4. Has no company scoping — no concept of "who owns this framework"

## Solution

1. SQLite database for persistent framework storage (Ecto + SQLite adapter)
2. Add `role` column to spreadsheet schema
3. Toggle view: "By Role" / "By Category"
4. Company context via URL param (demo auth)
5. Three tools: `list_frameworks`, `load_framework`, `save_framework`
6. Updated SKILL.md with all Phase 1 scenarios including persistence

## SQLite Schema

```sql
companies (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  created_at  TEXT DEFAULT (datetime('now'))
)

frameworks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  company_id  TEXT REFERENCES companies(id),  -- NULL = industry template
  name        TEXT NOT NULL,
  type        TEXT NOT NULL DEFAULT 'company', -- 'industry' | 'company'
  source      TEXT,                            -- 'ai_generated' | 'imported' | 'cloned_from:{id}'
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now'))
)

framework_rows (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  framework_id      INTEGER NOT NULL REFERENCES frameworks(id) ON DELETE CASCADE,
  role              TEXT DEFAULT '',
  category          TEXT DEFAULT '',
  cluster           TEXT DEFAULT '',
  skill_name        TEXT NOT NULL,
  skill_description TEXT DEFAULT '',
  level             INTEGER DEFAULT 0,
  level_name        TEXT DEFAULT '',
  level_description TEXT DEFAULT '',
  skill_code        TEXT DEFAULT '',
  created_at        TEXT DEFAULT (datetime('now')),
  updated_at        TEXT DEFAULT (datetime('now'))
)

CREATE INDEX idx_framework_rows_framework ON framework_rows(framework_id);
CREATE INDEX idx_framework_rows_role ON framework_rows(framework_id, role);
CREATE INDEX idx_framework_rows_skill ON framework_rows(framework_id, skill_name);
```

### Ecto Schemas

```elixir
# lib/rho/skill_store/company.ex
defmodule Rho.SkillStore.Company do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "companies" do
    field :name, :string
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

# lib/rho/skill_store/framework.ex
defmodule Rho.SkillStore.Framework do
  use Ecto.Schema

  schema "frameworks" do
    field :company_id, :string
    field :name, :string
    field :type, :string, default: "company"
    field :source, :string
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end

# lib/rho/skill_store/framework_row.ex
defmodule Rho.SkillStore.FrameworkRow do
  use Ecto.Schema

  schema "framework_rows" do
    field :framework_id, :integer
    field :role, :string, default: ""
    field :category, :string, default: ""
    field :cluster, :string, default: ""
    field :skill_name, :string
    field :skill_description, :string, default: ""
    field :level, :integer, default: 0
    field :level_name, :string, default: ""
    field :level_description, :string, default: ""
    field :skill_code, :string, default: ""
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
```

### Repo

```elixir
# lib/rho/skill_store/repo.ex
defmodule Rho.SkillStore.Repo do
  use Ecto.Repo, otp_app: :rho, adapter: Ecto.Adapters.SQLite3
end
```

Config:
```elixir
# config/config.exs
config :rho, Rho.SkillStore.Repo,
  database: "priv/skill_store.db"
```

### Seed Data

No pre-loaded templates. Pulsifi admin creates industry templates using the same chatbot (upload FSF Excel → save as industry template).

---

## Company Context (Demo Auth)

### URL Parameter

```
/spreadsheet                         → no company, agent asks "Which company?"
/spreadsheet?company=pulsifi_admin   → Pulsifi admin (can create industry templates)
/spreadsheet?company=bank_abc        → Company HR for Bank ABC
```

### How It Flows

SpreadsheetLive reads `company` from params in `mount/3`:

```elixir
def mount(params, _session, socket) do
  company_id = params["company"]
  is_admin = company_id == "pulsifi_admin"

  socket =
    socket
    |> assign(:company_id, company_id)
    |> assign(:is_admin, is_admin)
    # ... existing assigns ...
end
```

The company_id is passed to the agent via mount context. The agent knows:
- `company_id == "pulsifi_admin"` → can save as `type='industry'`
- `company_id == "bank_abc"` → can only save as `type='company'`, can read industry templates
- `company_id == nil` → agent asks "Which company are you working for?"

### Auto-Create Company

When a new company_id appears that doesn't exist in `companies` table, auto-create it:

```elixir
Rho.SkillStore.ensure_company(company_id, company_id)
```

---

## Role Column

### Schema Change

```
Current:  id, category, cluster, skill_name, skill_description, level, level_name, level_description
New:      id, role, category, cluster, skill_name, skill_description, level, level_name, level_description
```

### Known Fields Update

In `spreadsheet_live.ex`:
```elixir
@known_fields ~w(id role category cluster skill_name skill_description level level_name level_description)
```

In `spreadsheet.ex` prompt section:
```
You have a spreadsheet with columns:
id, role, category, cluster, skill_name, skill_description, level, level_name, level_description.

The "role" field identifies which job role this skill belongs to.
- Set role when generating/importing skills for a specific role
- Leave empty for company-wide skills not tied to a role
```

---

## Toggle View

### Assign

```elixir
|> assign(:view_mode, :role)  # :role | :category
```

### Event Handler

```elixir
def handle_event("switch_view", %{"mode" => mode}, socket) do
  view_mode = if mode == "category", do: :category, else: :role
  {:noreply, assign(socket, :view_mode, view_mode)}
end
```

### Grouping

```elixir
defp group_rows(rows_map, :category) do
  # Existing: category → cluster → rows
  rows_map |> Map.values() |> Enum.sort_by(& &1[:id]) |> group_by_category()
end

defp group_rows(rows_map, :role) do
  # New: role → category → cluster → rows
  rows_map
  |> Map.values()
  |> Enum.sort_by(& &1[:id])
  |> Enum.group_by(fn row -> row[:role] || "Unassigned" end)
  |> Enum.sort_by(fn {role, _} -> if role in ["", "Unassigned"], do: "zzz", else: role end)
  |> Enum.map(fn {role, role_rows} ->
    {role, group_by_category(role_rows)}
  end)
end
```

### Render

**Toolbar toggle:**
```heex
<div class="ss-view-toggle">
  <button class={"ss-toggle-btn" <> if(@view_mode == :role, do: " ss-toggle-active", else: "")}
    phx-click="switch_view" phx-value-mode="role">By Role</button>
  <button class={"ss-toggle-btn" <> if(@view_mode == :category, do: " ss-toggle-active", else: "")}
    phx-click="switch_view" phx-value-mode="category">By Category</button>
</div>
```

**Role view:** outer role group → existing category → cluster → table (3 levels).

**Category view:** existing category → cluster → table with ROLE column added to thead/tbody.

### Agent View Switching

New tool `switch_view` in spreadsheet mount:
```elixir
# Publishes signal to switch the LiveView's view_mode
switch_view_tool(context)
```

---

## Persistence Tools

Three new tools added to the spreadsheet mount:

### list_frameworks

```elixir
%{
  tool: ReqLLM.tool(
    name: "list_frameworks",
    description: "List available skill frameworks. Filter by type (industry/company) and/or company_id.",
    parameter_schema: [
      type: [type: :string, required: false, doc: "'industry' or 'company'. Omit for all."],
      company_id: [type: :string, required: false, doc: "Filter by company. Omit for all."]
    ]
  ),
  execute: fn args ->
    frameworks = Rho.SkillStore.list_frameworks(args)
    {:ok, Jason.encode!(frameworks)}
  end
}
```

Returns:
```json
[
  {"id": 1, "name": "AICB Future Skills", "type": "industry", "company_id": null, "row_count": 24650, "roles": ["Direct Sales", "Banca", ...], "skill_count": 157, "created_at": "2026-04-06"},
  {"id": 2, "name": "Bank ABC Framework", "type": "company", "company_id": "bank_abc", "row_count": 200, "roles": ["Data Analyst"], "skill_count": 8, "created_at": "2026-04-06"}
]
```

### load_framework

```elixir
%{
  tool: ReqLLM.tool(
    name: "load_framework",
    description: "Load a framework from the database into the spreadsheet. Replaces current spreadsheet content.",
    parameter_schema: [
      framework_id: [type: :integer, required: true, doc: "Framework ID from list_frameworks"]
    ]
  ),
  execute: fn args ->
    # Read rows from SQLite
    rows = Rho.SkillStore.get_framework_rows(args["framework_id"])
    # Publish signal to replace spreadsheet content
    Comms.publish("rho.session.#{session_id}.events.spreadsheet_replace_all", %{rows: rows, ...})
    framework = Rho.SkillStore.get_framework(args["framework_id"])
    {:ok, "Loaded '#{framework.name}' — #{length(rows)} rows"}
  end
}
```

Load is JUST load. Does not change the framework's type or ownership. The user decides what to do next (browse, edit, save as new).

### save_framework

```elixir
%{
  tool: ReqLLM.tool(
    name: "save_framework",
    description: "Save the current spreadsheet to the database. Creates new or updates existing framework.",
    parameter_schema: [
      name: [type: :string, required: true, doc: "Framework name"],
      type: [type: :string, required: false, doc: "'industry' or 'company'. Default: 'company'"],
      framework_id: [type: :integer, required: false, doc: "If provided, updates existing. If omitted, creates new."]
    ]
  ),
  execute: fn args ->
    # Read current spreadsheet rows from LiveView
    rows = get_spreadsheet_rows(session_id)
    # Determine type (agent decides based on company context)
    type = args["type"] || "company"
    company_id = if type == "industry", do: nil, else: context.company_id

    result = Rho.SkillStore.save_framework(%{
      id: args["framework_id"],
      name: args["name"],
      type: type,
      company_id: company_id,
      source: "spreadsheet_editor",
      rows: rows
    })

    {:ok, "Saved '#{args["name"]}' — #{length(rows)} rows"}
  end
}
```

---

## Rho.SkillStore Module

```elixir
# lib/rho/skill_store.ex
defmodule Rho.SkillStore do
  alias Rho.SkillStore.{Repo, Framework, FrameworkRow, Company}
  import Ecto.Query

  def ensure_company(id, name) do
    case Repo.get(Company, id) do
      nil -> Repo.insert!(%Company{id: id, name: name})
      company -> company
    end
  end

  def list_frameworks(filters \\ %{}) do
    query = from f in Framework, select: f
    query = if filters["type"], do: where(query, [f], f.type == ^filters["type"]), else: query
    query = if filters["company_id"], do: where(query, [f], f.company_id == ^filters["company_id"]), else: query

    Repo.all(query)
    |> Enum.map(fn f ->
      rows = Repo.all(from r in FrameworkRow, where: r.framework_id == ^f.id)
      %{
        id: f.id,
        name: f.name,
        type: f.type,
        company_id: f.company_id,
        row_count: length(rows),
        skill_count: rows |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length(),
        roles: rows |> Enum.map(& &1.role) |> Enum.reject(&(&1 in ["", nil])) |> Enum.uniq(),
        created_at: f.created_at
      }
    end)
  end

  def get_framework(id), do: Repo.get!(Framework, id)

  def get_framework_rows(framework_id) do
    Repo.all(from r in FrameworkRow, where: r.framework_id == ^framework_id, order_by: r.id)
    |> Enum.map(&row_to_map/1)
  end

  def save_framework(attrs) do
    Repo.transaction(fn ->
      framework =
        case attrs[:id] do
          nil ->
            Repo.insert!(%Framework{
              name: attrs.name,
              type: attrs.type,
              company_id: attrs.company_id,
              source: attrs[:source]
            })

          id ->
            framework = Repo.get!(Framework, id)
            # Delete old rows, replace with new
            Repo.delete_all(from r in FrameworkRow, where: r.framework_id == ^id)
            framework
        end

      # Insert new rows
      rows = Enum.map(attrs.rows, fn row ->
        %FrameworkRow{
          framework_id: framework.id,
          role: row[:role] || "",
          category: row[:category] || "",
          cluster: row[:cluster] || "",
          skill_name: row[:skill_name] || "",
          skill_description: row[:skill_description] || "",
          level: row[:level] || 0,
          level_name: row[:level_name] || "",
          level_description: row[:level_description] || "",
          skill_code: row[:skill_code] || ""
        }
      end)

      Enum.each(rows, &Repo.insert!/1)
      framework
    end)
  end

  defp row_to_map(row) do
    %{
      role: row.role,
      category: row.category,
      cluster: row.cluster,
      skill_name: row.skill_name,
      skill_description: row.skill_description,
      level: row.level,
      level_name: row.level_name,
      level_description: row.level_description,
      skill_code: row.skill_code
    }
  end
end
```

---

## SKILL.md Intent Updates

The `framework-editor` SKILL.md intent table expands to cover all Phase 1 scenarios:

### Existing Intents (file + generation)

| Signal | Intent | Action |
|--------|--------|--------|
| No files, describes a role/domain | **Generate** | Load `generate-workflow.md` |
| Uploads Excel/CSV + "import" | **Import** | Load `import-workflow.md` |
| Uploads file + "enhance"/"add levels" | **Enhance** | Load `import-workflow.md` then `enhance-workflow.md` |
| Uploads file + "like this"/"based on" | **Reference** | Load `reference-workflow.md` |
| Already has data + edit request | **Edit** | Use spreadsheet tools directly |

### New Intents (persistence + templates)

| Signal | Intent | Action |
|--------|--------|--------|
| "Show me available templates" / "What industry frameworks exist?" | **Browse templates** | `list_frameworks(type: "industry")` → show list to user |
| "Load AICB" / "Use the banking framework" | **Load template** | `list_frameworks(type: "industry")` → find match → `load_framework(id)` |
| "Load our company framework" / "Show what we have" | **Load company** | `list_frameworks(type: "company", company_id: X)` → show list or load |
| "Save this" / "Save as company framework" | **Save company** | `save_framework(name: X, type: "company")` |
| "Save this as industry template" (admin only) | **Save template** | Check is_admin → `save_framework(name: X, type: "industry")` |
| "Create framework for [role]" but role already exists in DB | **Duplicate detected** | `list_frameworks` → check for existing role → ask: update/fresh/compare |
| Ambiguous | **Ask** | "Would you like to import, generate, or load an existing framework?" |

### Context-Aware Behavior

The agent receives company context from mount context:
```
Company: {company_id}
Admin: {is_admin}
```

Rules:
- If `is_admin`: can save as `type='industry'`. Agent offers this option when saving.
- If not admin: can only save as `type='company'`. Never offer "save as industry template."
- On first message: if spreadsheet is empty, agent offers: "Want to load an existing framework, import a file, or build from scratch?"
- Before generating: agent checks `list_frameworks` for existing frameworks with matching role names.

### New Reference Files

| File | Content |
|------|---------|
| `references/persistence-workflow.md` | Save/load/list/clone flows. When to save, how to name, update vs create new. |
| `references/template-workflow.md` | Browse templates, load, customize, save as company. Admin: create templates. |
| `references/deduplication-workflow.md` | The 4 de-duplication cases. How to detect, what to ask the user, how to resolve. |

---

## Updated Spreadsheet Mount Prompt Section

```
You have a spreadsheet with columns:
id, role, category, cluster, skill_name, skill_description, level, level_name, level_description.

The "role" field identifies which job role this skill belongs to.
- Set role when generating/importing skills for a specific role
- Leave empty for company-wide skills not tied to a role

You can toggle the view between "By Role" and "By Category" using switch_view.

You can persist frameworks using:
- list_frameworks — see available industry templates and company frameworks
- load_framework — load a framework into the spreadsheet
- save_framework — save the spreadsheet to the database

Company context: {company_id}. Admin: {is_admin}.
```

---

## Files Changed

### New Files

| File | Purpose |
|------|---------|
| `lib/rho/skill_store.ex` | Main module: list/get/save framework operations |
| `lib/rho/skill_store/repo.ex` | Ecto repo for SQLite |
| `lib/rho/skill_store/company.ex` | Company schema |
| `lib/rho/skill_store/framework.ex` | Framework schema |
| `lib/rho/skill_store/framework_row.ex` | Framework row schema |
| `priv/skill_store/migrations/*_create_tables.exs` | Ecto migration |
| `.agents/skills/framework-editor/references/persistence-workflow.md` | Save/load flows |
| `.agents/skills/framework-editor/references/template-workflow.md` | Template browse/clone flows |
| `.agents/skills/framework-editor/references/deduplication-workflow.md` | 4 de-duplication cases |

### Modified Files

| File | Change |
|------|--------|
| `lib/rho_web/live/spreadsheet_live.ex` | view_mode assign, toggle event, role grouping, company_id from params, render template (toggle + role groups) |
| `lib/rho/mounts/spreadsheet.ex` | Add role to prompt/known_fields, add list_frameworks/load_framework/save_framework/switch_view tools, update build_summary with roles |
| `lib/rho_web/inline_css.ex` | Toggle button styles, role group header styles, role tag |
| `lib/rho/application.ex` | Add SkillStore.Repo to supervision tree |
| `config/config.exs` | Add SkillStore.Repo config |
| `.rho.exs` | Pass company_id through to agent context |
| `.agents/skills/framework-editor/SKILL.md` | New intents for persistence + templates + de-duplication |
| `.agents/skills/framework-editor/references/generate-workflow.md` | Add role field to generated rows |
| `.agents/skills/framework-editor/references/import-workflow.md` | Extract role from files, save after import |

---

## Scope

### In This Spec
- SQLite database with Ecto (companies, frameworks, framework_rows)
- Role column in spreadsheet schema
- Toggle view (By Role / By Category) with agent auto-switching
- Company context from URL param
- Three persistence tools (list/load/save)
- Updated SKILL.md with all Phase 1 scenarios
- Three new reference workflow files (persistence, templates, deduplication)
- Pulsifi admin mode for creating industry templates

### Not In This Spec
- Phase 2 role-skill selection UI
- External API integration (no calls to ds-agents)
- Real authentication (demo uses URL params)
- Framework versioning / change history
- Framework sharing between companies (community templates)
- Export to Excel
