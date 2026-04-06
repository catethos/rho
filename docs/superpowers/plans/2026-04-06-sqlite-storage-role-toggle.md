# SQLite Storage + Role Column + Toggle View — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent SQLite storage for skill frameworks with company scoping, a `role` column, and a toggle view (By Role / By Category) to the spreadsheet editor.

**Architecture:** Ecto + SQLite3 for persistence (3 tables: companies, frameworks, framework_rows). The spreadsheet mount gets 4 new tools (list/load/save/switch_view). Company context flows from URL params through Session.ensure_started opts to mount tools. The SKILL.md gains persistence + template intents.

**Tech Stack:** Ecto + ecto_sqlite3, Phoenix LiveView, Rho mount system, agentskills.io SKILL.md

**Spec:** `docs/superpowers/specs/2026-04-06-sqlite-storage-role-toggle-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `lib/rho/skill_store/repo.ex` | Ecto repo for SQLite |
| `lib/rho/skill_store/company.ex` | Company schema + changeset |
| `lib/rho/skill_store/framework.ex` | Framework schema + changeset + belongs_to |
| `lib/rho/skill_store/framework_row.ex` | FrameworkRow schema + changeset + belongs_to |
| `lib/rho/skill_store.ex` | Business logic: ensure_company, list/get/save framework |
| `priv/skill_store/migrations/20260406000000_create_tables.exs` | Ecto migration |
| `test/rho/skill_store_test.exs` | Tests for SkillStore module |
| `.agents/skills/framework-editor/references/persistence-workflow.md` | Save/load agent instructions |
| `.agents/skills/framework-editor/references/template-workflow.md` | Template browse/clone agent instructions |
| `.agents/skills/framework-editor/references/deduplication-workflow.md` | De-duplication case handling |

### Modified Files

| File | Change |
|------|--------|
| `mix.exs` | Add ecto_sql + ecto_sqlite3 deps |
| `config/config.exs` | Add SkillStore.Repo config + ecto_repos |
| `lib/rho/application.ex` | Add Repo to supervision tree + auto-migrate |
| `lib/rho/mounts/spreadsheet.ex` | Add role to known_fields/prompt, add 4 new tools, update build_summary, add can_access? |
| `lib/rho_web/live/spreadsheet_live.ex` | Add view_mode/company_id/is_admin assigns, toggle event, role grouping, load/save handlers, update ensure_session, update render |
| `lib/rho_web/inline_css.ex` | Toggle button + role group + role tag styles |
| `.rho.exs` | No change needed (company_id flows via opts, not config) |
| `.agents/skills/framework-editor/SKILL.md` | Add persistence + template + dedup intents |
| `.agents/skills/framework-editor/references/generate-workflow.md` | Add role field instructions |
| `.agents/skills/framework-editor/references/import-workflow.md` | Add role extraction + save reminder |

---

## Task 1: Dependencies + Ecto Repo + Migration

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Create: `lib/rho/skill_store/repo.ex`
- Create: `priv/skill_store/migrations/20260406000000_create_tables.exs`
- Modify: `lib/rho/application.ex`

- [ ] **Step 1: Add deps to mix.exs**

Add to the `deps` function:

```elixir
{:ecto_sql, "~> 3.12"},
{:ecto_sqlite3, "~> 0.17"}
```

- [ ] **Step 2: Run deps.get**

Run: `mix deps.get`
Expected: ecto_sql and ecto_sqlite3 fetched

- [ ] **Step 3: Create Repo module**

```elixir
# lib/rho/skill_store/repo.ex
defmodule Rho.SkillStore.Repo do
  use Ecto.Repo, otp_app: :rho, adapter: Ecto.Adapters.SQLite3
end
```

- [ ] **Step 4: Add Repo config**

In `config/config.exs`, add:

```elixir
config :rho, Rho.SkillStore.Repo,
  database: Path.expand("priv/skill_store.db"),
  pool_size: 5

config :rho, ecto_repos: [Rho.SkillStore.Repo]
```

- [ ] **Step 5: Create migration**

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
      add :company_id, references(:companies, type: :string, on_delete: :nilify_all)
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

- [ ] **Step 6: Add Repo to supervision tree + auto-migrate**

In `lib/rho/application.ex`, add `Rho.SkillStore.Repo` as the FIRST child in the children list:

```elixir
children = [
  Rho.SkillStore.Repo,
  # ... existing children ...
```

After `Supervisor.start_link`, add auto-migration:

```elixir
{:ok, pid} = Supervisor.start_link(children, opts)

# Auto-run migrations for dev convenience
Ecto.Migrator.run(Rho.SkillStore.Repo, :up, all: true,
  prefix: nil,
  migration_source: "schema_migrations",
  migrations_paths: [Path.join(:code.priv_dir(:rho), "skill_store/migrations")]
)
```

- [ ] **Step 7: Verify**

Run: `mix compile --warnings-as-errors`
Expected: compiles. The SQLite DB file `priv/skill_store.db` is created on first run.

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock config/config.exs lib/rho/skill_store/repo.ex priv/skill_store/migrations/ lib/rho/application.ex
git commit -m "feat: add Ecto + SQLite3 for SkillStore persistence"
```

---

## Task 2: Ecto Schemas

**Files:**
- Create: `lib/rho/skill_store/company.ex`
- Create: `lib/rho/skill_store/framework.ex`
- Create: `lib/rho/skill_store/framework_row.ex`

- [ ] **Step 1: Create Company schema**

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
```

- [ ] **Step 2: Create Framework schema**

```elixir
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
```

- [ ] **Step 3: Create FrameworkRow schema**

```elixir
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

- [ ] **Step 4: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rho/skill_store/company.ex lib/rho/skill_store/framework.ex lib/rho/skill_store/framework_row.ex
git commit -m "feat: add Ecto schemas for Company, Framework, FrameworkRow"
```

---

## Task 3: SkillStore Business Logic + Tests

**Files:**
- Create: `lib/rho/skill_store.ex`
- Create: `test/rho/skill_store_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/rho/skill_store_test.exs
defmodule Rho.SkillStoreTest do
  use ExUnit.Case

  alias Rho.SkillStore

  setup do
    # Clean DB before each test
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.FrameworkRow)
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Framework)
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Company)
    :ok
  end

  describe "ensure_company/1" do
    test "creates a new company" do
      assert {:ok, company} = SkillStore.ensure_company("test_co")
      assert company.id == "test_co"
      assert company.name == "test_co"
    end

    test "is idempotent (no crash on duplicate)" do
      assert {:ok, _} = SkillStore.ensure_company("test_co")
      assert {:ok, _} = SkillStore.ensure_company("test_co")
    end
  end

  describe "save_framework/1 + get_framework_rows/1" do
    test "creates new framework with rows" do
      SkillStore.ensure_company("test_co")

      {:ok, framework} =
        SkillStore.save_framework(%{
          name: "Test Framework",
          type: "company",
          company_id: "test_co",
          source: "test",
          rows: [
            %{role: "Data Analyst", category: "Technical", cluster: "Programming",
              skill_name: "Python", skill_description: "Coding", level: 1,
              level_name: "Novice", level_description: "Basic scripts"},
            %{role: "Data Analyst", category: "Technical", cluster: "Programming",
              skill_name: "Python", skill_description: "Coding", level: 2,
              level_name: "Developing", level_description: "Builds pipelines"}
          ]
        })

      assert framework.id != nil
      assert framework.row_count == 2
      assert framework.skill_count == 1

      rows = SkillStore.get_framework_rows(framework.id)
      assert length(rows) == 2
      assert hd(rows).skill_name == "Python"
      assert hd(rows).role == "Data Analyst"
    end

    test "updates existing framework (replaces rows)" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "V1", type: "company", company_id: "test_co",
          rows: [%{skill_name: "SQL", role: "DA"}]
        })

      {:ok, fw2} =
        SkillStore.save_framework(%{
          id: fw.id, name: "V2", type: "company", company_id: "test_co",
          rows: [%{skill_name: "Python", role: "DE"}, %{skill_name: "SQL", role: "DE"}]
        })

      assert fw2.id == fw.id
      assert fw2.name == "V2"
      rows = SkillStore.get_framework_rows(fw.id)
      assert length(rows) == 2
    end
  end

  describe "list_frameworks_for/3" do
    setup do
      SkillStore.ensure_company("co_a")
      SkillStore.ensure_company("co_b")

      SkillStore.save_framework(%{name: "AICB", type: "industry", company_id: nil,
        rows: [%{skill_name: "Risk Mgmt"}]})
      SkillStore.save_framework(%{name: "Co A Framework", type: "company", company_id: "co_a",
        rows: [%{skill_name: "Python", role: "DA"}]})
      SkillStore.save_framework(%{name: "Co B Framework", type: "company", company_id: "co_b",
        rows: [%{skill_name: "SQL", role: "DE"}]})
      :ok
    end

    test "admin sees everything" do
      frameworks = SkillStore.list_frameworks_for(nil, true)
      assert length(frameworks) == 3
    end

    test "company user sees industry + own company only" do
      frameworks = SkillStore.list_frameworks_for("co_a", false)
      names = Enum.map(frameworks, & &1.name)
      assert "AICB" in names
      assert "Co A Framework" in names
      refute "Co B Framework" in names
    end

    test "type filter works" do
      frameworks = SkillStore.list_frameworks_for("co_a", false, "industry")
      assert length(frameworks) == 1
      assert hd(frameworks).name == "AICB"
    end

    test "includes roles in response" do
      frameworks = SkillStore.list_frameworks_for("co_a", false, "company")
      assert hd(frameworks).roles == ["DA"]
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rho/skill_store_test.exs`
Expected: FAIL — `Rho.SkillStore` not defined

- [ ] **Step 3: Write SkillStore module**

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

    query =
      if is_admin do
        query
      else
        where(query, [f], f.type == "industry" or f.company_id == ^(company_id || ""))
      end

    query =
      if type_filter do
        where(query, [f], f.type == ^type_filter)
      else
        query
      end

    query = order_by(query, [f], [asc: f.type, asc: f.name])

    Repo.all(query)
    |> Enum.map(fn f ->
      roles = get_framework_roles(f.id)

      Map.from_struct(f)
      |> Map.drop([:__meta__, :rows, :company])
      |> Map.put(:roles, roles)
    end)
  end

  def get_framework(id), do: Repo.get(Framework, id)

  defp get_framework_roles(framework_id) do
    from(r in FrameworkRow,
      where: r.framework_id == ^framework_id and r.role != "" and not is_nil(r.role),
      distinct: r.role,
      select: r.role,
      order_by: r.role
    )
    |> Repo.all()
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
            Repo.delete_all(from r in FrameworkRow, where: r.framework_id == ^id)

            framework
            |> Framework.changeset(%{name: attrs.name, source: attrs[:source]})
            |> Repo.update!()
        end

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

      row_maps
      |> Enum.chunk_every(500)
      |> Enum.each(fn chunk ->
        Repo.insert_all(FrameworkRow, chunk)
      end)

      row_count = length(row_maps)
      skill_count = row_maps |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length()

      framework
      |> Framework.changeset(%{row_count: row_count, skill_count: skill_count})
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

- [ ] **Step 4: Run tests**

Run: `mix test test/rho/skill_store_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rho/skill_store.ex test/rho/skill_store_test.exs
git commit -m "feat: add SkillStore module with CRUD operations and tests"
```

---

## Task 4: Role Column + Toggle View in SpreadsheetLive

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex`
- Modify: `lib/rho/mounts/spreadsheet.ex`
- Modify: `lib/rho_web/inline_css.ex`

- [ ] **Step 1: Add role to known_fields in spreadsheet mount**

In `lib/rho/mounts/spreadsheet.ex`, update `@known_fields`:

From:
```elixir
@known_fields ~w(id category cluster skill_name skill_description level level_name level_description)
```

To:
```elixir
@known_fields ~w(id role category cluster skill_name skill_description level level_name level_description)
```

Also in `lib/rho_web/live/spreadsheet_live.ex`, update the same:
```elixir
@known_fields ~w(id role category cluster skill_name skill_description level level_name level_description)
```

- [ ] **Step 2: Update spreadsheet mount prompt section**

In `lib/rho/mounts/spreadsheet.ex`, update `prompt_sections/2`:

Change the column listing to include `role`:
```
You have a spreadsheet with columns:
id, role, category, cluster, skill_name, skill_description, level, level_name, level_description.

The "role" field identifies which job role this skill belongs to.
- Set role when generating/importing skills for a specific role
- Leave empty for company-wide skills not tied to a role
```

Also update the row format example to include `role`:
```
{"role": "Data Analyst", "category": "...", "cluster": "...", "skill_name": "...", "skill_description": "...", "level": 0, "level_name": "", "level_description": "⏳ Pending..."}
```

- [ ] **Step 3: Add view_mode and company assigns to SpreadsheetLive mount**

In `lib/rho_web/live/spreadsheet_live.ex`, in `mount/3`, add after existing assigns:

```elixir
|> assign(:view_mode, :role)
|> assign(:company_id, params["company"])
|> assign(:is_admin, params["company"] == "pulsifi_admin")
|> assign(:loaded_framework_id, nil)
|> assign(:loaded_framework_name, nil)
```

And auto-create company:
```elixir
company_id = params["company"]
if company_id && company_id != "pulsifi_admin" do
  Rho.SkillStore.ensure_company(company_id)
end
```

- [ ] **Step 4: Add toggle event handler**

```elixir
def handle_event("switch_view", %{"mode" => mode}, socket) do
  view_mode = if mode == "category", do: :category, else: :role
  {:noreply, assign(socket, :view_mode, view_mode)}
end
```

- [ ] **Step 5: Add role grouping function**

Rename existing `group_preserving_order/1` to `group_by_category/1`. Then update `group_rows`:

```elixir
defp group_rows(rows_map) when map_size(rows_map) == 0, do: []

defp group_rows(rows_map, view_mode \\ :role)

defp group_rows(rows_map, :category) do
  rows_map |> Map.values() |> Enum.sort_by(& &1[:id]) |> group_by_category()
end

defp group_rows(rows_map, :role) do
  rows_map
  |> Map.values()
  |> Enum.sort_by(& &1[:id])
  |> Enum.group_by(fn row ->
    r = row[:role] || ""
    if r == "", do: "Unassigned", else: r
  end)
  |> Enum.sort_by(fn {role, _} -> if role == "Unassigned", do: "zzz", else: role end)
  |> Enum.map(fn {role, role_rows} ->
    {role, group_by_category(role_rows)}
  end)
end
```

Update the call in `render/1`:
```elixir
grouped = group_rows(assigns.rows_map, assigns.view_mode)
```

- [ ] **Step 6: Update render template — toolbar toggle**

In the toolbar section, after the cost display, add:

```heex
<div class="ss-view-toggle">
  <button
    class={"ss-toggle-btn" <> if(@view_mode == :role, do: " ss-toggle-active", else: "")}
    phx-click="switch_view"
    phx-value-mode="role"
  >
    By Role
  </button>
  <button
    class={"ss-toggle-btn" <> if(@view_mode == :category, do: " ss-toggle-active", else: "")}
    phx-click="switch_view"
    phx-value-mode="category"
  >
    By Category
  </button>
</div>
```

- [ ] **Step 7: Update render template — role view vs category view**

This is the largest change. The table area needs to branch on `@view_mode`:

**For `:role` view** — wrap the existing category→cluster groups inside a role group:

```heex
<%= if @view_mode == :role do %>
  <%= for {role, categories} <- @grouped do %>
    <% role_id = "role-" <> slug(role) %>
    <div id={role_id} class={"ss-group ss-role-group" <> if(MapSet.member?(@collapsed, role_id), do: " ss-collapsed", else: "")}>
      <div class="ss-group-header ss-role-header" phx-click="toggle_group" phx-value-group={role_id}>
        <span class="ss-chevron"></span>
        <span class="ss-group-name"><%= role %></span>
        <span class="ss-group-count"><%= count_role_rows(categories) %> rows</span>
      </div>
      <div class={"ss-group-content" <> if(MapSet.member?(@collapsed, role_id), do: " ss-hidden", else: "")}>
        <%!-- Reuse existing category → cluster → table rendering --%>
        <%= render_category_groups(assigns, categories) %>
      </div>
    </div>
  <% end %>
<% else %>
  <%!-- Existing category view, but add ROLE column to table --%>
  <%= for {category, clusters} <- @grouped do %>
    <%!-- ... existing category/cluster rendering with role column added ... --%>
  <% end %>
<% end %>
```

For category view, add a ROLE column to the table:
- `<th class="ss-th ss-th-role">Role</th>` in thead
- `<td class="ss-td ss-td-role"><span class="ss-role-tag"><%= row[:role] || "" %></span></td>` in tbody

Add helper:
```elixir
defp count_role_rows(categories) do
  Enum.reduce(categories, 0, fn {_cat, clusters}, acc ->
    acc + count_group_rows(clusters)
  end)
end
```

- [ ] **Step 8: Add CSS for toggle and role groups**

In `lib/rho_web/inline_css.ex`, add:

```css
/* Toggle */
.ss-view-toggle {
  display: inline-flex; gap: 2px; background: var(--bg-surface);
  border: 1px solid var(--border); border-radius: 6px; padding: 2px; margin-left: 8px;
}
.ss-toggle-btn {
  padding: 3px 10px; border: none; border-radius: 4px; font-size: 11px;
  cursor: pointer; background: transparent; color: var(--fg-muted);
}
.ss-toggle-active { background: var(--teal); color: white; }

/* Role group */
.ss-role-group { margin-bottom: 4px; }
.ss-role-header {
  font-size: 14px; font-weight: 600; padding: 6px 8px;
  background: rgba(31, 111, 235, 0.08); border-left: 3px solid var(--teal);
}

/* Role tag in category view */
.ss-role-tag {
  display: inline-block; font-size: 10px; padding: 1px 6px;
  background: rgba(31, 111, 235, 0.1); color: var(--teal);
  border-radius: 8px;
}
.ss-th-role { width: 120px; }
```

- [ ] **Step 9: Update ensure_session to pass company context**

In `lib/rho_web/live/spreadsheet_live.ex`, update both `ensure_session` clauses:

```elixir
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

- [ ] **Step 10: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex lib/rho/mounts/spreadsheet.ex lib/rho_web/inline_css.ex
git commit -m "feat: add role column, toggle view (By Role / By Category), company context"
```

---

## Task 5: Persistence Tools (list/load/save/switch_view)

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex`
- Modify: `lib/rho_web/live/spreadsheet_live.ex`

- [ ] **Step 1: Add tools to spreadsheet mount tools/2**

In `lib/rho/mounts/spreadsheet.ex`, add to the tool list:

```elixir
list_frameworks_tool(context),
load_framework_tool(session_id, context),
save_framework_tool(session_id, context),
switch_view_tool(context),
```

- [ ] **Step 2: Implement list_frameworks_tool**

```elixir
defp list_frameworks_tool(context) do
  %{
    tool:
      ReqLLM.tool(
        name: "list_frameworks",
        description:
          "List available skill frameworks. Returns industry templates visible to all, " <>
            "plus company frameworks for the current company only.",
        parameter_schema: [
          type: [type: :string, required: false, doc: "'industry' or 'company'. Omit for both."]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args ->
      company_id = context.opts[:company_id]
      is_admin = context.opts[:is_admin] || false
      type_filter = args["type"]

      frameworks = Rho.SkillStore.list_frameworks_for(company_id, is_admin, type_filter)
      {:ok, Jason.encode!(frameworks)}
    end
  }
end
```

- [ ] **Step 3: Implement load_framework_tool**

```elixir
defp load_framework_tool(session_id, context) do
  %{
    tool:
      ReqLLM.tool(
        name: "load_framework",
        description:
          "Load a framework from the database into the spreadsheet. Replaces current " <>
            "spreadsheet content. Does NOT change ownership.",
        parameter_schema: [
          framework_id: [type: :integer, required: true, doc: "Framework ID from list_frameworks"]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args ->
      framework_id = args["framework_id"]
      company_id = context.opts[:company_id]
      is_admin = context.opts[:is_admin] || false

      case Rho.SkillStore.get_framework(framework_id) do
        nil ->
          {:error, "Framework not found"}

        framework ->
          if can_access?(framework, company_id, is_admin) do
            rows = Rho.SkillStore.get_framework_rows(framework_id)

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
end
```

- [ ] **Step 4: Implement save_framework_tool**

```elixir
defp save_framework_tool(session_id, context) do
  %{
    tool:
      ReqLLM.tool(
        name: "save_framework",
        description:
          "Save the current spreadsheet to the database. Creates new or updates existing.",
        parameter_schema: [
          name: [type: :string, required: true, doc: "Framework name"],
          type: [type: :string, required: false, doc: "'industry' (admin only) or 'company' (default)"],
          framework_id: [type: :integer, required: false, doc: "If provided, updates existing. If omitted, creates new."]
        ],
        callback: fn _args -> :ok end
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
          save_company_id = if type == "industry", do: nil, else: company_id

          with_pid(session_id, fn pid ->
            ref = make_ref()
            send(pid, {:get_all_rows, {self(), ref}})

            receive do
              {^ref, {:ok, rows}} ->
                case Rho.SkillStore.save_framework(%{
                  id: args["framework_id"],
                  name: args["name"],
                  type: type,
                  company_id: save_company_id,
                  source: "spreadsheet_editor",
                  rows: rows
                }) do
                  {:ok, framework} ->
                    {:ok, "Saved '#{args["name"]}' (id: #{framework.id}) — #{length(rows)} rows"}

                  {:error, reason} ->
                    {:error, "Save failed: #{inspect(reason)}"}
                end

            after
              5_000 -> {:error, "Spreadsheet did not respond in time"}
            end
          end)
      end
    end
  }
end
```

- [ ] **Step 5: Implement switch_view_tool and can_access?**

```elixir
defp switch_view_tool(context) do
  session_id = context[:session_id]

  %{
    tool:
      ReqLLM.tool(
        name: "switch_view",
        description: "Switch the spreadsheet view mode. Use 'role' to group by role, 'category' to group by skill category.",
        parameter_schema: [
          mode: [type: :string, required: true, doc: "'role' or 'category'"]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args ->
      mode = args["mode"]

      with_pid(session_id, fn pid ->
        send(pid, {:switch_view, mode})
        {:ok, "Switched to #{mode} view"}
      end)
    end
  }
end

defp can_access?(_framework, _company_id, true = _is_admin), do: true
defp can_access?(%{type: "industry"}, _company_id, _is_admin), do: true
defp can_access?(framework, company_id, _is_admin) do
  Map.get(framework, :company_id) == company_id
end
```

- [ ] **Step 6: Add SpreadsheetLive handlers**

In `lib/rho_web/live/spreadsheet_live.ex`, add:

```elixir
# Load framework rows from DB into spreadsheet
def handle_info({:load_framework_rows, rows, framework}, socket) do
  {id_rows, next_id} =
    Enum.map_reduce(rows, 1, fn row, id ->
      {Map.put(row, :id, id), id + 1}
    end)

  rows_map = Map.new(id_rows, fn row -> {row.id, row} end)

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

# Read all rows for save_framework tool
def handle_info({:get_all_rows, {caller_pid, ref}}, socket) do
  rows =
    socket.assigns.rows_map
    |> Map.values()
    |> Enum.sort_by(& &1[:id])
    |> Enum.map(fn row -> Map.drop(row, [:id]) end)

  send(caller_pid, {ref, {:ok, rows}})
  {:noreply, socket}
end

# Agent-triggered view switch
def handle_info({:switch_view, mode}, socket) do
  view_mode = if mode == "category", do: :category, else: :role
  {:noreply, assign(socket, :view_mode, view_mode)}
end
```

- [ ] **Step 7: Update build_summary to include roles**

In `lib/rho/mounts/spreadsheet.ex`, update `build_summary/1`:

```elixir
defp build_summary(rows) do
  roles =
    rows
    |> Enum.map(fn r -> r[:role] || r.role end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()

  # ... existing category/cluster logic ...

  %{
    total_rows: length(rows),
    total_categories: length(categories),
    total_skills: rows |> Enum.map(& &1.skill_name) |> Enum.uniq() |> length(),
    total_roles: length(roles),
    roles: roles,
    categories: categories
  }
end
```

- [ ] **Step 8: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex lib/rho_web/live/spreadsheet_live.ex
git commit -m "feat: add persistence tools (list/load/save) and switch_view to spreadsheet mount"
```

---

## Task 6: Update SKILL.md + Reference Files

**Files:**
- Modify: `.agents/skills/framework-editor/SKILL.md`
- Modify: `.agents/skills/framework-editor/references/generate-workflow.md`
- Modify: `.agents/skills/framework-editor/references/import-workflow.md`
- Create: `.agents/skills/framework-editor/references/persistence-workflow.md`
- Create: `.agents/skills/framework-editor/references/template-workflow.md`
- Create: `.agents/skills/framework-editor/references/deduplication-workflow.md`

- [ ] **Step 1: Update SKILL.md intent table**

Add new intents to the intent detection table:

| Signal | Intent | Action |
|--------|--------|--------|
| "Show templates" / "What frameworks exist?" | **Browse templates** | `list_frameworks(type: "industry")` → show list |
| "Load AICB" / "Use banking framework" | **Load template** | `list_frameworks` → find → `load_framework(id)` |
| "Load our framework" / "Show what we have" | **Load company** | `list_frameworks(type: "company")` → show/load |
| "Save this" | **Save** | `save_framework(name, type)` |
| "Save as industry template" (admin) | **Save template** | Check admin → `save_framework(type: "industry")` |
| "Create for [role]" but exists | **Duplicate** | Load `deduplication-workflow.md` |
| First message, empty spreadsheet | **Welcome** | Offer: load existing, import, or build |
| "Delete this framework" | **Not supported** | "I can't delete frameworks yet" |

Add company context section:
```
## Company Context
Company: {context.opts.company_id}
Admin: {context.opts.is_admin}

Rules:
- Admin can save as industry template. Non-admin cannot.
- Non-admin sees only industry + own company frameworks in list_frameworks.
- Before generating for a role, check list_frameworks for existing role matches.
- After significant edits, remind user to save.
```

Add persistence tools to the tool reference:
```
### Persistence
- list_frameworks — see available industry templates and company frameworks
- load_framework — load a framework into the spreadsheet
- save_framework — save spreadsheet to database
- switch_view — toggle between "By Role" and "By Category" view
```

- [ ] **Step 2: Update generate-workflow.md**

Add to skeleton generation phase:
```
When adding skeleton rows, include the role field:
{"role": "[role name or empty]", "category": "...", ...}

If the user specified a role (e.g., "Build skills for Data Analyst"),
set role="Data Analyst" on all generated rows.
If no role specified, set role="" (company-wide).

After generating, switch to Role view if role was specified:
switch_view(mode: "role")
```

Add save reminder at end:
```
After generation is complete, remind the user:
"Framework generated with [N] skills. Want to save it? You can say 'save this'
or continue editing first."
```

- [ ] **Step 3: Update import-workflow.md**

Add role extraction:
```
When importing files:
- Check if the source has role/job information (column named "Role", "Job Role", etc.)
- If yes: set role field per skill based on the mapping
- If no: set role="" (company-wide library)
- For industry frameworks with role-skill mapping matrices (like FSF):
  read the mapping, create one row per skill × role combination
```

Add save reminder:
```
After import is complete, remind user to save:
"Imported [N] rows. Save as [company/industry] framework?"
```

- [ ] **Step 4: Create persistence-workflow.md**

```markdown
# Persistence Workflow

## Save Flow
1. User says "save this" or agent detects significant edits
2. Check context: admin or company user?
3. Ask for framework name if not obvious (suggest based on roles/domain)
4. If updating existing: `save_framework(name, framework_id: existing_id)`
5. If creating new: `save_framework(name, type: "company")`
6. Admin saving template: `save_framework(name, type: "industry")`
7. Confirm: "Saved '[name]' with [N] rows"

## Load Flow
1. User says "load our framework" or "show templates"
2. Call `list_frameworks` (auto-scoped to company + industry)
3. Present list with names, types, skill counts, roles
4. User picks one → `load_framework(framework_id)`
5. Auto-detect view mode (role view if roles exist)
6. Confirm: "Loaded '[name]' — [N] rows. You can edit and save changes."

## When to Remind About Saving
- After generating a new framework (skeleton + proficiency levels done)
- After importing from a file
- After making 5+ edits in a session
- When user says "done" or "finished"
```

- [ ] **Step 5: Create template-workflow.md**

```markdown
# Template Workflow

## Browse Templates
1. Call `list_frameworks(type: "industry")`
2. Present: "Available industry templates: [list with skill counts]"
3. If none exist: "No industry templates yet. Upload a framework file
   or ask Pulsifi admin to create one."

## Load Template
1. `load_framework(framework_id)` — loads into spreadsheet
2. Switch to Category view (templates usually have many roles)
3. "Loaded [template name]. You can browse, edit, and save as your company framework."

## Clone + Customize
1. Load template into spreadsheet
2. User edits (add/remove skills, change descriptions, assign roles)
3. Save as company framework: `save_framework(name, type: "company")`
4. Original template is untouched in DB

## Admin: Create Industry Template
1. Only if is_admin is true
2. User uploads file or generates framework
3. "Save as industry template? This will be visible to all companies."
4. `save_framework(name, type: "industry")`
```

- [ ] **Step 6: Create deduplication-workflow.md**

```markdown
# De-duplication Workflow

Before generating skills for a role, check for existing data:

## Detection
1. Call `list_frameworks(type: "company")` to check own company frameworks
2. Check if any framework's `roles` array contains the requested role name
3. If found: proceed to resolution. If not: proceed with generation.

## Case 1: Same skill, same definition, different roles
- Both roles define "Communication" the same way
- Action: one entry in library, both roles reference it
- Agent: "Communication already exists for Data Analyst. I'll reuse the same
  definition for Project Manager. The required proficiency level can differ."

## Case 2: Same skill name, different definitions
- "Python" for DA = analytics, for DE = distributed systems
- Agent asks: "Both roles need 'Python' but with different focus:
  a) Keep one generic definition
  b) Create two variants: 'Python (Analytics)' and 'Python (Engineering)'
  c) Keep the first, adjust the second"
- User decides

## Case 3: Same role created again (user forgot)
- Agent found existing framework with matching role
- Agent: "I found an existing framework '[name]' from [date] with [N] skills
  for [role]. Do you want to:
  - Load and update it
  - Start fresh (create new)
  - Compare: generate new alongside old"
- User decides → agent loads existing or generates new

## Case 4: Industry template + company customization
- Company loaded AICB template and edited it
- Original AICB preserved as industry template
- Company version saved separately
- If user loads AICB again, they get the original (not their edits)
- Agent: "You have a customized version. Load your version or the original template?"
```

- [ ] **Step 7: Commit**

```bash
git add .agents/skills/framework-editor/
git commit -m "feat: update SKILL.md with persistence/template/dedup intents and reference files"
```

---

## Task 7: Integration Testing

**Files:**
- No new files

- [ ] **Step 1: Compile and run all tests**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All tests pass

- [ ] **Step 2: Manual smoke test — SQLite persistence**

1. Start: `RHO_WEB_ENABLED=true mix phx.server`
2. Open `http://localhost:4001/spreadsheet?company=pulsifi_admin`
3. Upload FSF Excel → "Save as industry template named AICB"
4. Verify: agent calls `save_framework(name: "AICB", type: "industry")`
5. Open new tab: `http://localhost:4001/spreadsheet?company=bank_abc`
6. Type: "Show available templates"
7. Verify: agent calls `list_frameworks` → shows AICB
8. Type: "Load AICB"
9. Verify: framework loads into spreadsheet

- [ ] **Step 3: Manual smoke test — toggle view**

1. With loaded framework, click "By Role" / "By Category" toggle
2. Verify: grouping changes correctly
3. Type: "Build skills for Data Analyst"
4. Verify: agent sets role="Data Analyst" on generated rows
5. Toggle to Category view → verify role tags appear on rows

- [ ] **Step 4: Manual smoke test — company scoping**

1. Open `http://localhost:4001/spreadsheet?company=bank_abc`
2. Generate framework → save as "Bank ABC Skills"
3. Open `http://localhost:4001/spreadsheet?company=fintech_xyz`
4. Type "show our frameworks" → should NOT see Bank ABC's framework
5. Type "show templates" → should see AICB (industry = visible to all)

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration test fixes for SQLite storage + toggle view"
```

---

## Summary

| Task | Component | Dependencies |
|------|-----------|-------------|
| 1 | Deps + Repo + Migration | None |
| 2 | Ecto Schemas | Task 1 |
| 3 | SkillStore Module + Tests | Task 2 |
| 4 | Role Column + Toggle View | None (parallel with 1-3) |
| 5 | Persistence Tools | Tasks 3 + 4 |
| 6 | SKILL.md + Reference Files | Task 5 |
| 7 | Integration Testing | All |

**Parallelizable:** Tasks 1-3 (SQLite layer) can be done in parallel with Task 4 (UI changes). They merge at Task 5.
