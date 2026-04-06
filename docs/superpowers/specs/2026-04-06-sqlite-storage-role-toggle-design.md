# SQLite Storage + Role Column + Toggle View — Design Spec

## Problem

The spreadsheet editor currently:
1. Has no persistent storage — data lost on page refresh
2. Has no `role` column — skills lose role context when accumulated
3. Has no way to browse/clone industry templates
4. Has no company scoping — no concept of "who owns this framework"

## Solution

1. SQLite database for persistent framework storage (Ecto + SQLite3 adapter)
2. Add `role` column to spreadsheet schema
3. Toggle view: "By Role" / "By Category"
4. Company context via URL param (demo auth)
5. Three tools: `list_frameworks`, `load_framework`, `save_framework`
6. Updated SKILL.md with all Phase 1 scenarios including persistence

## Dependencies

Add to `mix.exs`:

```elixir
{:ecto_sql, "~> 3.12"},
{:ecto_sqlite3, "~> 0.17"}
```

Run: `mix deps.get`

Add repo to `config/config.exs`:
```elixir
config :rho, Rho.SkillStore.Repo,
  database: Path.expand("priv/skill_store.db"),
  pool_size: 5

config :rho, ecto_repos: [Rho.SkillStore.Repo]
```

---

## SQLite Schema

```sql
companies (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  created_at  TEXT NOT NULL
)

frameworks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  company_id  TEXT REFERENCES companies(id),  -- NULL = industry template
  name        TEXT NOT NULL,
  type        TEXT NOT NULL DEFAULT 'company', -- 'industry' | 'company'
  source      TEXT,                            -- 'ai_generated' | 'imported' | 'cloned_from:{id}'
  row_count   INTEGER DEFAULT 0,              -- cached count, updated on save
  skill_count INTEGER DEFAULT 0,              -- cached unique skill count
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
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
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
)

CREATE INDEX idx_framework_rows_framework ON framework_rows(framework_id);
CREATE INDEX idx_framework_rows_role ON framework_rows(framework_id, role);
CREATE INDEX idx_framework_rows_skill ON framework_rows(framework_id, skill_name);
```

### Ecto Migration

```elixir
# priv/skill_store/migrations/20260406000000_create_tables.exs
defmodule Rho.SkillStore.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create table(:companies, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:frameworks) do
      add :company_id, references(:companies, type: :string, on_delete: :delete_all)
      add :name, :string, null: false
      add :type, :string, null: false, default: "company"
      add :source, :string
      add :row_count, :integer, default: 0
      add :skill_count, :integer, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:frameworks, [:company_id])
    create index(:frameworks, [:type])

    create table(:framework_rows) do
      add :framework_id, references(:frameworks, on_delete: :delete_all), null: false
      add :role, :string, default: ""
      add :category, :string, default: ""
      add :cluster, :string, default: ""
      add :skill_name, :string, null: false
      add :skill_description, :string, default: ""
      add :level, :integer, default: 0
      add :level_name, :string, default: ""
      add :level_description, :string, default: ""
      add :skill_code, :string, default: ""
      timestamps(type: :utc_datetime)
    end

    create index(:framework_rows, [:framework_id])
    create index(:framework_rows, [:framework_id, :role])
    create index(:framework_rows, [:framework_id, :skill_name])
  end
end
```

### Ecto Schemas

```elixir
# lib/rho/skill_store/company.ex
defmodule Rho.SkillStore.Company do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "companies" do
    field :name, :string
    has_many :frameworks, Rho.SkillStore.Framework, foreign_key: :company_id
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:id, :name])
    |> validate_required([:id, :name])
    |> unique_constraint(:id, name: :companies_pkey)
  end
end

# lib/rho/skill_store/framework.ex
defmodule Rho.SkillStore.Framework do
  use Ecto.Schema
  import Ecto.Changeset

  schema "frameworks" do
    field :name, :string
    field :type, :string, default: "company"
    field :source, :string
    field :row_count, :integer, default: 0
    field :skill_count, :integer, default: 0

    belongs_to :company, Rho.SkillStore.Company, type: :string
    has_many :rows, Rho.SkillStore.FrameworkRow

    timestamps(type: :utc_datetime)
  end

  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [:name, :type, :company_id, :source, :row_count, :skill_count])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["industry", "company"])
    |> foreign_key_constraint(:company_id)
  end
end

# lib/rho/skill_store/framework_row.ex
defmodule Rho.SkillStore.FrameworkRow do
  use Ecto.Schema
  import Ecto.Changeset

  schema "framework_rows" do
    field :role, :string, default: ""
    field :category, :string, default: ""
    field :cluster, :string, default: ""
    field :skill_name, :string
    field :skill_description, :string, default: ""
    field :level, :integer, default: 0
    field :level_name, :string, default: ""
    field :level_description, :string, default: ""
    field :skill_code, :string, default: ""

    belongs_to :framework, Rho.SkillStore.Framework

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:framework_id, :role, :category, :cluster, :skill_name,
                     :skill_description, :level, :level_name, :level_description, :skill_code])
    |> validate_required([:framework_id, :skill_name])
    |> foreign_key_constraint(:framework_id)
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

  # Auto-create company if it doesn't exist (upsert to avoid race condition)
  if company_id && company_id != "pulsifi_admin" do
    Rho.SkillStore.ensure_company(company_id)
  end

  socket =
    socket
    |> assign(:company_id, company_id)
    |> assign(:is_admin, is_admin)
    # ... existing assigns ...
end
```

The company_id is passed to the agent via mount context opts. The agent knows:
- `company_id == "pulsifi_admin"` → can save as `type='industry'`
- `company_id == "bank_abc"` → can only save as `type='company'`, can read industry templates
- `company_id == nil` → agent asks "Which company are you working for?"

### Passing Company Context to Agent

**Important:** `Rho.Mount.Context` does NOT have `company_id` or `is_admin` fields. These are passed via `opts` through `Session.ensure_started`:

```elixir
# In SpreadsheetLive.ensure_session (both clauses):
defp ensure_session(socket, nil) do
  new_sid = "sheet_#{System.unique_integer([:positive])}"
  {:ok, _pid} = Rho.Session.ensure_started(new_sid,
    agent_name: :spreadsheet,
    company_id: socket.assigns.company_id,
    is_admin: socket.assigns.is_admin
  )
  {new_sid, assign(socket, :session_id, new_sid)}
end

defp ensure_session(socket, sid) do
  {:ok, _pid} = Rho.Session.ensure_started(sid,
    agent_name: :spreadsheet,
    company_id: socket.assigns.company_id,
    is_admin: socket.assigns.is_admin
  )
  {sid, socket}
end
```

Mount tools access them via `context.opts`:
```elixir
# In spreadsheet mount tool execute functions:
company_id = context.opts[:company_id]
is_admin = context.opts[:is_admin] || false
```

This uses the existing `opts` passthrough — no changes to `Context` struct needed.

### Auto-Create Company (Race-Safe)

```elixir
def ensure_company(company_id) do
  %Company{}
  |> Company.changeset(%{id: company_id, name: company_id})
  |> Repo.insert(on_conflict: :nothing)
end
```

Uses `on_conflict: :nothing` — if two requests hit simultaneously with the same new company_id, one inserts and the other silently succeeds. No crash. Uses changeset (not direct struct) so validations run.

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

Three new tools added to the spreadsheet mount. All tools enforce company scoping — non-admin users can only see their own company's frameworks + industry templates.

### list_frameworks

```elixir
%{
  tool: ReqLLM.tool(
    name: "list_frameworks",
    description: "List available skill frameworks. Returns industry templates visible to all, plus company frameworks for the current company only.",
    parameter_schema: [
      type: [type: :string, required: false, doc: "'industry' or 'company'. Omit for both."]
    ]
  ),
  execute: fn args ->
    type_filter = args["type"]
    frameworks = Rho.SkillStore.list_frameworks_for(context.opts[:company_id], context.opts[:is_admin], type_filter)
    {:ok, Jason.encode!(frameworks)}
  end
}
```

**Company scoping logic in `SkillStore.list_frameworks_for/3`:**
- Admin: sees everything (all industry + all company frameworks)
- Non-admin: sees all industry templates + only own company's frameworks
- `type` filter further narrows within the visible set

Returns (using cached counts from `frameworks` table — NO N+1):
```json
[
  {"id": 1, "name": "AICB Future Skills", "type": "industry", "company_id": null,
   "row_count": 24650, "skill_count": 157, "created_at": "2026-04-06"},
  {"id": 2, "name": "Bank ABC Framework", "type": "company", "company_id": "bank_abc",
   "row_count": 200, "skill_count": 8, "roles": ["Data Analyst"], "created_at": "2026-04-06"}
]
```

For the `roles` array: computed via a single query:
```elixir
from(r in FrameworkRow,
  where: r.framework_id == ^id and r.role != "" and not is_nil(r.role),
  distinct: r.role,
  select: r.role
)
```

### load_framework

```elixir
%{
  tool: ReqLLM.tool(
    name: "load_framework",
    description: "Load a framework from the database into the spreadsheet. Replaces current spreadsheet content. Does NOT change ownership — just loads for viewing/editing.",
    parameter_schema: [
      framework_id: [type: :integer, required: true, doc: "Framework ID from list_frameworks"]
    ]
  ),
  execute: fn args ->
    framework_id = args["framework_id"]

    # Verify access: admin can load anything, non-admin can load industry + own company
    case Rho.SkillStore.get_framework(framework_id) do
      nil ->
        {:error, "Framework not found"}

      framework ->
        if can_access?(framework, context.opts[:company_id], context.opts[:is_admin]) do
          rows = Rho.SkillStore.get_framework_rows(framework_id)
          # Send rows to LiveView via the existing replace_all pattern
          # LiveView receives rows, assigns IDs, populates rows_map
          with_pid(session_id, fn pid ->
            send(pid, {:load_framework_rows, rows, framework})
            {:ok, "Loaded '#{framework.name}' — #{length(rows)} rows"}
          end)
        else
          {:error, "Access denied"}
        end
    end
  end
}
```

**`can_access?/3` helper** (in the spreadsheet mount module):
```elixir
defp can_access?(_framework, _company_id, true = _is_admin), do: true
defp can_access?(%{type: "industry"}, _company_id, _is_admin), do: true
defp can_access?(%{company_id: fco}, company_id, _is_admin), do: fco == company_id
```

**SpreadsheetLive handler for `:load_framework_rows`:**
Receives rows (maps without `:id`), assigns sequential IDs, populates `rows_map`, optionally sets `view_mode` based on whether roles exist.

### save_framework

```elixir
%{
  tool: ReqLLM.tool(
    name: "save_framework",
    description: "Save the current spreadsheet to the database. Creates new or updates existing framework.",
    parameter_schema: [
      name: [type: :string, required: true, doc: "Framework name"],
      type: [type: :string, required: false, doc: "'industry' (admin only) or 'company' (default)"],
      framework_id: [type: :integer, required: false, doc: "If provided, updates existing. If omitted, creates new."]
    ]
  ),
  execute: fn args ->
    type = args["type"] || "company"

    company_id = context.opts[:company_id]
    is_admin = context.opts[:is_admin] || false

    cond do
      type == "industry" and not is_admin ->
        {:error, "Only Pulsifi admin can save industry templates"}

      type == "company" and (company_id == nil or company_id == "") ->
        {:error, "Company context required. Open the editor with ?company=your_company_id"}

      true ->
        company_id = if type == "industry", do: nil, else: company_id

      # Get current spreadsheet rows from LiveView
      with_pid(session_id, fn pid ->
        ref = make_ref()
        send(pid, {:get_all_rows, {self(), ref}})

        receive do
          {^ref, {:ok, rows}} ->
            result = Rho.SkillStore.save_framework(%{
              id: args["framework_id"],
              name: args["name"],
              type: type,
              company_id: company_id,
              source: "spreadsheet_editor",
              rows: rows
            })

            case result do
              {:ok, framework} ->
                {:ok, "Saved '#{args["name"]}' (id: #{framework.id}) — #{length(rows)} rows"}
              {:error, reason} ->
                {:error, "Save failed: #{inspect(reason)}"}
            end

          after 5_000 -> {:error, "Spreadsheet did not respond in time"}
        end
      end)
    end
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

  # --- Companies ---

  def ensure_company(company_id) do
    %Company{}
    |> Company.changeset(%{id: company_id, name: company_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  # --- Frameworks ---

  def list_frameworks_for(company_id, is_admin, type_filter \\ nil) do
    query = from(f in Framework)

    # Company scoping
    query =
      if is_admin do
        query
      else
        where(query, [f], f.type == "industry" or f.company_id == ^company_id)
      end

    # Type filter
    query =
      if type_filter do
        where(query, [f], f.type == ^type_filter)
      else
        query
      end

    query = order_by(query, [f], [asc: f.type, asc: f.name])

    frameworks = Repo.all(query)
    framework_ids = Enum.map(frameworks, & &1.id)

    # Single query for ALL roles (no N+1)
    roles_by_framework =
      if framework_ids != [] do
        from(r in FrameworkRow,
          where: r.framework_id in ^framework_ids and r.role != "" and not is_nil(r.role),
          distinct: [r.framework_id, r.role],
          select: {r.framework_id, r.role},
          order_by: [r.framework_id, r.role]
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      else
        %{}
      end

    Enum.map(frameworks, fn f ->
      Map.from_struct(f)
      |> Map.drop([:__meta__, :rows, :company])
      |> Map.put(:roles, Map.get(roles_by_framework, f.id, []))
    end)
  end

  def get_framework(id) do
    Repo.get(Framework, id)
  end

  # --- Framework Rows ---

  def get_framework_rows(framework_id) do
    from(r in FrameworkRow,
      where: r.framework_id == ^framework_id,
      order_by: r.id
    )
    |> Repo.all()
    |> Enum.map(&row_to_map/1)
  end

  # --- Save ---

  def save_framework(attrs) do
    Repo.transaction(fn ->
      # Create or update framework record
      framework =
        case attrs[:id] do
          nil ->
            %Framework{}
            |> Framework.changeset(%{
              name: attrs.name,
              type: attrs.type,
              company_id: attrs.company_id,
              source: attrs[:source]
            })
            |> Repo.insert!()

          id ->
            framework = Repo.get!(Framework, id)
            # Delete existing rows (will be replaced)
            Repo.delete_all(from r in FrameworkRow, where: r.framework_id == ^id)
            # Update framework metadata (name, source may have changed)
            framework
            |> Framework.changeset(%{name: attrs.name, source: attrs[:source]})
            |> Repo.update!()
        end

      # Bulk insert rows (NOT one-by-one)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      row_maps =
        Enum.map(attrs.rows, fn row ->
          %{
            framework_id: framework.id,
            role: row[:role] || row["role"] || "",
            category: row[:category] || row["category"] || "",
            cluster: row[:cluster] || row["cluster"] || "",
            skill_name: row[:skill_name] || row["skill_name"] || "",
            skill_description: row[:skill_description] || row["skill_description"] || "",
            level: row[:level] || row["level"] || 0,
            level_name: row[:level_name] || row["level_name"] || "",
            level_description: row[:level_description] || row["level_description"] || "",
            skill_code: row[:skill_code] || row["skill_code"] || "",
            inserted_at: now,
            updated_at: now
          }
        end)

      # Batch insert in chunks of 500 (SQLite has variable limit)
      row_maps
      |> Enum.chunk_every(500)
      |> Enum.each(fn chunk ->
        Repo.insert_all(FrameworkRow, chunk)
      end)

      # Update cached counts
      row_count = length(row_maps)
      skill_count = row_maps |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length()

      # Use change/2 for internal computed data, not cast/4
      framework
      |> Ecto.Changeset.change(%{row_count: row_count, skill_count: skill_count})
      |> Repo.update!()
    end)
  end

  # --- Helpers ---

  defp row_to_map(%FrameworkRow{} = row) do
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

## SpreadsheetLive Handlers for Persistence

```elixir
# Handler for load_framework tool
def handle_info({:load_framework_rows, rows, framework}, socket) do
  # Convert to spreadsheet format with IDs
  {id_rows, next_id} =
    Enum.map_reduce(rows, 1, fn row, id ->
      row = Map.put(row, :id, id)
      {row, id + 1}
    end)

  rows_map = Map.new(id_rows, fn row -> {row.id, row} end)

  # Auto-detect view mode: if roles exist, use role view
  has_roles = Enum.any?(rows, fn r -> (r[:role] || "") != "" end)
  view_mode = if has_roles, do: :role, else: :category

  socket =
    socket
    |> assign(:rows_map, rows_map)
    |> assign(:next_id, next_id)
    |> assign(:view_mode, view_mode)
    |> assign(:loaded_framework_id, framework.id)
    |> assign(:loaded_framework_name, framework.name)

  {:noreply, socket}
end

# Handler for save_framework tool to read current rows
def handle_info({:get_all_rows, {caller_pid, ref}}, socket) do
  rows =
    socket.assigns.rows_map
    |> Map.values()
    |> Enum.sort_by(& &1[:id])
    |> Enum.map(fn row -> Map.drop(row, [:id]) end)

  send(caller_pid, {ref, {:ok, rows}})
  {:noreply, socket}
end
```

---

## SKILL.md Intent Updates

The `framework-editor` SKILL.md intent table covers all Phase 1 scenarios:

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
| "Load AICB" / "Use the banking framework" | **Load template** | `list_frameworks(type: "industry")` → find match → `load_framework(id)` → switch to appropriate view |
| "Load our company framework" / "Show what we have" | **Load company** | `list_frameworks(type: "company")` → auto-scoped to own company → show list or load |
| "Save this" / "Save as company framework" | **Save company** | `save_framework(name: X, type: "company")` |
| "Save this as industry template" (admin only) | **Save template** | Check is_admin → if yes: `save_framework(name: X, type: "industry")` → if no: "Only Pulsifi admin can create industry templates" |
| "Create framework for [role]" but existing found | **Duplicate detected** | Load `deduplication-workflow.md` → `list_frameworks` → check roles → ask: update/fresh/compare |
| First message, spreadsheet is empty | **Welcome** | Check context: offer "load existing, import file, or build from scratch?" |
| "Delete this framework" | **Not supported** | "I can't delete frameworks yet. You can create a new version or ask your admin." |
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
- Non-admin calling `list_frameworks` only sees industry + own company frameworks. Enforced server-side.
- On first message: if spreadsheet is empty, agent offers: "Want to load an existing framework, import a file, or build from scratch?"
- Before generating for a role: agent checks `list_frameworks` for existing frameworks with matching role names. If found, loads `deduplication-workflow.md` for guidance.
- After significant edits: agent reminds user to save. "You've made changes to the framework. Want to save?"

### New Reference Files

| File | Content |
|------|---------|
| `references/persistence-workflow.md` | Save/load flows. When to save (after generation, after import, after edits). How to name (suggest based on role/domain). Update vs create new (use framework_id for update, omit for new). |
| `references/template-workflow.md` | Browse templates: `list_frameworks(type: "industry")`. Load: `load_framework(id)`. Customize: user edits in spreadsheet. Save as company: `save_framework(type: "company")`. Admin: save as industry with `type: "industry"`. |
| `references/deduplication-workflow.md` | **Case 1:** Same skill, same def, diff roles → one entry, both roles reference it at different required levels. **Case 2:** Same skill, diff def → ask user: keep both variants, merge, or pick one. **Case 3:** Same role created again (detected via `list_frameworks` → matching role in existing framework) → ask: load existing and update, start fresh, or compare. **Case 4:** Clone industry template → load → edit → save as company → original preserved. |

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
- list_frameworks — see available industry templates and company frameworks (auto-scoped to your company)
- load_framework — load a framework into the spreadsheet for viewing/editing
- save_framework — save the spreadsheet to the database (creates new or updates existing)

Company context: {company_id}. Admin: {is_admin}.
```

---

## Application Changes

### Supervision Tree

Add `Rho.SkillStore.Repo` to `lib/rho/application.ex`:

```elixir
children = [
  Rho.SkillStore.Repo,    # NEW — before other children that might query
  # ... existing children ...
]
```

### Migration Runner

Run migrations at app startup (for dev convenience):

```elixir
# In application.ex start/2, after Repo starts:
Rho.SkillStore.Repo.Migrator.up()
```

Or manually: `mix ecto.migrate --repo Rho.SkillStore.Repo`

---

## Files Changed

### New Files

| File | Purpose |
|------|---------|
| `lib/rho/skill_store.ex` | Main module: list/get/save framework operations |
| `lib/rho/skill_store/repo.ex` | Ecto repo for SQLite |
| `lib/rho/skill_store/company.ex` | Company schema with changeset |
| `lib/rho/skill_store/framework.ex` | Framework schema with changeset + belongs_to |
| `lib/rho/skill_store/framework_row.ex` | Framework row schema with changeset + belongs_to |
| `priv/skill_store/migrations/20260406000000_create_tables.exs` | Ecto migration |
| `.agents/skills/framework-editor/references/persistence-workflow.md` | Save/load flows |
| `.agents/skills/framework-editor/references/template-workflow.md` | Template browse/clone flows |
| `.agents/skills/framework-editor/references/deduplication-workflow.md` | 4 de-duplication cases |

### Modified Files

| File | Change |
|------|--------|
| `mix.exs` | Add `{:ecto_sql, "~> 3.12"}`, `{:ecto_sqlite3, "~> 0.17"}` |
| `config/config.exs` | Add SkillStore.Repo config + ecto_repos |
| `lib/rho/application.ex` | Add SkillStore.Repo to supervision tree |
| `lib/rho_web/live/spreadsheet_live.ex` | view_mode, toggle event, role grouping, company_id from params, load/save handlers, render template |
| `lib/rho/mounts/spreadsheet.ex` | Add role to prompt/known_fields, add list/load/save/switch_view tools, update build_summary |
| `lib/rho_web/inline_css.ex` | Toggle button, role group header, role tag styles |
| `.rho.exs` | Pass company_id through to agent context |
| `.agents/skills/framework-editor/SKILL.md` | New intents for persistence + templates + dedup + welcome + delete |
| `.agents/skills/framework-editor/references/generate-workflow.md` | Add role field, save reminder |
| `.agents/skills/framework-editor/references/import-workflow.md` | Extract role from files, save after import |

---

## Scope

### In This Spec
- SQLite database with Ecto (companies, frameworks, framework_rows)
- Ecto schemas with proper changesets, belongs_to, validations
- Role column in spreadsheet schema
- Toggle view (By Role / By Category) with agent auto-switching
- Company context from URL param with auto-create (race-safe upsert)
- Company-scoped framework listing (non-admin sees own company + industry only)
- Three persistence tools (list/load/save) with access control
- Bulk insert for save (chunked insert_all, not row-by-row)
- Cached row_count/skill_count on frameworks table (no N+1)
- Updated SKILL.md with all 14 Phase 1 intents
- Three new reference workflow files
- Admin mode for creating industry templates

### Known Limitations (v1)

- **Large framework performance:** Loading FSF (24K rows) into LiveView assigns uses ~12MB. Initial render is slow due to full DOM diff. Collapsible groups help (collapsed content hidden via CSS). For v2, consider lazy-loading only expanded groups.
- **No concurrent edit protection:** If admin updates an industry template while HR has it loaded, HR's unsaved edits are lost on reload. Standard "last writer wins" — acceptable for demo.
- **No auto-save:** User must explicitly ask to save. Agent reminds after significant edits but doesn't auto-save.

### Not In This Spec
- Phase 2 role-skill selection UI
- External API integration (no calls to ds-agents)
- Real authentication (demo uses URL params)
- Framework versioning / change history
- Framework sharing between companies (community templates)
- Export to Excel
- Delete framework (agent handles gracefully: "not supported yet")
- Lazy loading for large frameworks (>5K rows)
