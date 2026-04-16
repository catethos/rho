# Versioned Role Frameworks — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add versioned role framework support to the skill store — schema migration, versioned save with plan/execute, and data-aware welcome flow.

**Architecture:** Ecto migration adds nullable columns (role_name, year, version, is_default, description) to frameworks table. New `save_role_framework` function handles versioned saves. New `save_framework` tool uses two-phase plan/execute pattern (same as merge_roles). Welcome flow uses new `get_company_overview` tool backed by `get_company_roles_summary` query. Industry templates (FSF) are untouched — new columns stay NULL.

**Tech Stack:** Elixir, Ecto, SQLite3, Phoenix LiveView

**Spec:** `docs/superpowers/specs/2026-04-08-company-framework-model-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `priv/skill_store/migrations/20260408000000_add_versioning.exs` | Create | Ecto migration — add columns, backfill, add unique index |
| `lib/rho/skill_store/framework.ex` | Modify | Ecto schema — add new fields, update changeset |
| `lib/rho/skill_store.ex` | Modify | Add `save_role_framework`, `get_company_roles_summary`, `set_default_version`, update `list_frameworks_for` |
| `lib/rho/mounts/spreadsheet.ex` | Modify | Rewrite `save_framework_tool`, add `get_company_overview_tool` |
| `lib/rho_web/live/spreadsheet_live.ex` | Modify | Add `handle_info` for `:spreadsheet_save_plan` |
| `.agents/skills/framework-editor/SKILL.md` | Modify | Update Save/Welcome intents, add `get_company_overview` to tools |
| `.agents/skills/framework-editor/references/persistence-workflow.md` | Modify | Rewrite save/load flows for versioning |
| `test/rho/skill_store_test.exs` | Modify | Add tests for new functions |
| `test/rho/mounts/spreadsheet_save_test.exs` | Create | Tests for save_framework plan/execute tool |

---

### Task 1: Schema Migration

**Files:**
- Create: `priv/skill_store/migrations/20260408000000_add_versioning.exs`
- Modify: `lib/rho/skill_store/framework.ex`

- [ ] **Step 1: Create the migration file**

Create `priv/skill_store/migrations/20260408000000_add_versioning.exs`:

```elixir
defmodule Rho.SkillStore.Repo.Migrations.AddVersioning do
  use Ecto.Migration

  def change do
    alter table(:frameworks) do
      add :role_name, :string
      add :year, :integer
      add :version, :integer
      add :is_default, :boolean
      add :description, :string
    end

    create unique_index(:frameworks, [:company_id, :role_name, :year, :version],
      name: :frameworks_company_role_year_version_index,
      where: "type = 'company'"
    )

    # Backfill existing company frameworks using Elixir (more robust than raw SQL)
    flush()

    repo = Rho.SkillStore.Repo
    frameworks = repo.all(from(f in "frameworks", where: f.type == "company", select: %{id: f.id, name: f.name, inserted_at: f.inserted_at}))

    for fw <- frameworks do
      # Infer role_name: strip year + underscores, title case
      role_name =
        fw.name
        |> String.replace(~r/_?\d{4}/, "")
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(" ")
        |> String.trim()

      # Infer year from name or inserted_at
      year =
        case Regex.run(~r/(\d{4})/, fw.name) do
          [_, y] -> String.to_integer(y)
          _ ->
            case fw.inserted_at do
              <<y::binary-size(4), _::binary>> -> String.to_integer(y)
              _ -> 2026
            end
        end

      slug = role_name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
      new_name = "#{slug}_#{year}_v1"

      repo.query!("UPDATE frameworks SET role_name = ?1, year = ?2, version = 1, is_default = 1, name = ?3 WHERE id = ?4",
        [role_name, year, new_name, fw.id])
    end
  end
end
```

- [ ] **Step 2: Update Ecto schema**

In `lib/rho/skill_store/framework.ex`, replace the entire file:

```elixir
defmodule Rho.SkillStore.Framework do
  use Ecto.Schema
  import Ecto.Changeset

  schema "frameworks" do
    field(:name, :string)
    field(:type, :string, default: "company")
    field(:source, :string)
    field(:row_count, :integer, default: 0)
    field(:skill_count, :integer, default: 0)
    field(:role_name, :string)
    field(:year, :integer)
    field(:version, :integer)
    field(:is_default, :boolean)
    field(:description, :string)

    belongs_to(:company, Rho.SkillStore.Company, type: :string)
    has_many(:rows, Rho.SkillStore.FrameworkRow)

    timestamps(type: :utc_datetime)
  end

  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [
      :name, :type, :company_id, :source, :row_count, :skill_count,
      :role_name, :year, :version, :is_default, :description
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["industry", "company"])
    |> maybe_validate_company_fields()
    |> foreign_key_constraint(:company_id)
  end

  defp maybe_validate_company_fields(changeset) do
    if get_field(changeset, :type) == "company" do
      changeset
      |> validate_required([:role_name, :year, :version])
    else
      changeset
    end
  end
end
```

- [ ] **Step 3: Run migration**

Run: `mix ecto.migrate --repo Rho.SkillStore.Repo`
Expected: migration runs, backfills existing data.

- [ ] **Step 4: Verify migration**

Run: `sqlite3 priv/skill_store.db "SELECT id, name, role_name, year, version, is_default, type FROM frameworks;"`
Expected:
```
90|Future Skills Framework (FSF)...||||||industry
91|data_scientist_2025_v1|Data Scientist|2025|1|1|company
92|risk_analyst_2026_v1|Risk Analyst|2026|1|1|company
```

- [ ] **Step 5: Run existing tests**

Run: `mix test test/rho/skill_store_test.exs --trace`
Expected: some tests may fail because `save_framework` now creates records without the new required fields for company type. We'll fix this in the next step.

- [ ] **Step 6: Fix existing test helper**

The existing `save_framework/1` in `skill_store.ex` doesn't pass `role_name`, `year`, `version` for company type. Since we keep `save_framework/1` for backwards compat (and industry templates), we need to make `changeset` only require new fields when creating NEW company frameworks, not when the old function is used.

Actually — the better fix is: `save_framework/1` doesn't use the changeset's `validate_required` for company fields. It uses `Ecto.Changeset.change/2` for internal updates and `Framework.changeset` only for the initial insert. Let me check...

Looking at `skill_store.ex:125`: it calls `Framework.changeset(%{name, type, company_id, source})` for new frameworks. This will fail validation because `role_name`, `year`, `version` are required for company type.

Fix: make `maybe_validate_company_fields` only validate when the fields are being SET (i.e., when using the new `save_role_framework`). For the old `save_framework`, skip the validation.

Replace `maybe_validate_company_fields` with:

```elixir
  defp maybe_validate_company_fields(changeset) do
    type = get_field(changeset, :type)
    role_name = get_change(changeset, :role_name)

    # Only validate new versioning fields when they're explicitly being set
    # This preserves backwards compat with save_framework/1 (no versioning fields)
    if type == "company" and role_name != nil do
      changeset
      |> validate_required([:role_name, :year, :version])
    else
      changeset
    end
  end
```

- [ ] **Step 7: Run tests again**

Run: `mix test test/rho/skill_store_test.exs --trace`
Expected: all existing tests pass.

- [ ] **Step 8: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add priv/skill_store/migrations/20260408000000_add_versioning.exs lib/rho/skill_store/framework.ex
git commit -m "feat: add versioning columns to frameworks table

Add role_name, year, version, is_default, description columns (nullable).
Backfill existing company frameworks. Add unique index on
(company_id, role_name, year, version) for company type.
Update Ecto schema with conditional validation."
```

---

### Task 2: `save_role_framework` + `get_company_roles_summary` + `set_default_version`

**Files:**
- Modify: `lib/rho/skill_store.ex`
- Modify: `test/rho/skill_store_test.exs`

- [ ] **Step 1: Write tests for `save_role_framework`**

Add to `test/rho/skill_store_test.exs`:

```elixir
  describe "save_role_framework/1" do
    test "creates first version with is_default=true" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "spreadsheet_editor",
          rows: [
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 1}),
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 2})
          ]
        })

      assert fw.role_name == "Data Scientist"
      assert fw.year == 2026
      assert fw.version == 1
      assert fw.is_default == true
      assert fw.name == "data_scientist_2026_v1"
      assert fw.row_count == 2
      assert fw.skill_count == 1
    end

    test "creates second version as draft (is_default=false)" do
      SkillStore.ensure_company("test_co")

      {:ok, _v1} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, v2} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})]
        })

      assert v2.version == 2
      assert v2.is_default == false
      assert v2.name == "data_scientist_2026_v2"
    end

    test "update mode overwrites existing rows" do
      SkillStore.ensure_company("test_co")

      {:ok, v1} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, updated} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :update,
          existing_id: v1.id,
          source: "test",
          rows: [
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 1}),
            full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})
          ]
        })

      assert updated.id == v1.id
      rows = SkillStore.get_framework_rows(v1.id)
      assert length(rows) == 2
    end

    test "normalizes role_name to title case" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "data scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "data scientist", skill_name: "Python", level: 1})]
        })

      assert fw.role_name == "Data Scientist"
    end
  end

  describe "get_company_roles_summary/1" do
    test "returns roles grouped with default and version history" do
      SkillStore.ensure_company("test_co")

      {:ok, _} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2025,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, _} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 1}),
            full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})
          ]
        })

      {:ok, _} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Risk Analyst",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Risk Analyst", skill_name: "Risk Mgmt", level: 1})]
        })

      summary = SkillStore.get_company_roles_summary("test_co")
      assert length(summary) == 2

      ds = Enum.find(summary, &(&1.role_name == "Data Scientist"))
      assert ds.default.year == 2025
      assert ds.default.version == 1
      assert length(ds.versions) == 2

      ra = Enum.find(summary, &(&1.role_name == "Risk Analyst"))
      assert ra.default.year == 2026
      assert ra.default.version == 1
    end
  end

  describe "set_default_version/1" do
    test "flips is_default in transaction" do
      SkillStore.ensure_company("test_co")

      {:ok, v1} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2025,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, v2} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})]
        })

      assert v1.is_default == true
      assert v2.is_default == false

      {:ok, _} = SkillStore.set_default_version(v2.id)

      v1_reloaded = SkillStore.get_framework(v1.id)
      v2_reloaded = SkillStore.get_framework(v2.id)
      assert v1_reloaded.is_default == false
      assert v2_reloaded.is_default == true
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rho/skill_store_test.exs --trace`
Expected: new tests fail — `save_role_framework`, `get_company_roles_summary`, `set_default_version` undefined.

- [ ] **Step 3: Implement `save_role_framework`**

Add to `lib/rho/skill_store.ex` after the existing `save_framework/1` function:

```elixir
  def save_role_framework(attrs) do
    role_name = title_case(attrs.role_name || "")
    company_id = attrs.company_id
    year = attrs.year
    action = attrs.action

    case action do
      :create ->
        # Compute next version for this (company_id, role_name, year)
        next_version =
          from(f in Framework,
            where:
              f.company_id == ^company_id and f.role_name == ^role_name and
                f.year == ^year and f.type == "company",
            select: max(f.version)
          )
          |> Repo.one()
          |> case do
            nil -> 1
            max_v -> max_v + 1
          end

        # Check if first-ever version of this role_name (across all years)
        is_first =
          from(f in Framework,
            where:
              f.company_id == ^company_id and f.role_name == ^role_name and
                f.type == "company",
            select: count(f.id)
          )
          |> Repo.one() == 0

        name = generate_name(role_name, year, next_version)

        Repo.transaction(fn ->
          framework =
            %Framework{}
            |> Framework.changeset(%{
              name: name,
              type: "company",
              company_id: company_id,
              source: attrs[:source],
              role_name: role_name,
              year: year,
              version: next_version,
              is_default: is_first,
              description: attrs[:description] || ""
            })
            |> Repo.insert!()

          insert_rows(framework, attrs.rows)
          update_counts(framework, attrs.rows)
        end)

      :update ->
        existing_id = attrs.existing_id

        Repo.transaction(fn ->
          framework = Repo.get!(Framework, existing_id)
          Repo.delete_all(from(r in FrameworkRow, where: r.framework_id == ^existing_id))

          framework
          |> Framework.changeset(%{
            source: attrs[:source],
            description: attrs[:description] || framework.description
          })
          |> Repo.update!()

          insert_rows(framework, attrs.rows)
          update_counts(framework, attrs.rows)
        end)
    end
  end

  defp generate_name(role_name, year, version) do
    slug =
      role_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    "#{slug}_#{year}_v#{version}"
  end

  defp title_case(str) do
    str
    |> String.split(~r/[\s_]+/)
    |> Enum.map(fn word ->
      case String.downcase(word) do
        "" -> ""
        w -> String.upcase(String.first(w)) <> String.slice(w, 1..-1//1)
      end
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp insert_rows(framework, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row_maps =
      Enum.map(rows, fn row ->
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
    |> Enum.each(fn chunk -> Repo.insert_all(FrameworkRow, chunk) end)

    row_maps
  end

  defp update_counts(framework, rows) when is_list(rows) do
    row_count = length(rows)
    skill_count = rows |> Enum.map(&((&1[:skill_name] || &1["skill_name"]) || "")) |> Enum.uniq() |> length()

    framework
    |> Ecto.Changeset.change(%{row_count: row_count, skill_count: skill_count})
    |> Repo.update!()
  end
```

Note: refactor the existing `save_framework/1` to use `insert_rows` and `update_counts` helpers too, since they share the same logic. Replace lines 142-174 of the existing `save_framework` with:

```elixir
      row_maps = insert_rows(framework, attrs.rows)
      update_counts(framework, row_maps)
```

Wait — `insert_rows` returns `row_maps` which are maps with atom keys. But `update_counts` takes the original `rows` list. Let me fix: `update_counts` should work with the `row_maps` output.

Actually, simpler: just make `update_counts` accept `row_maps`:

```elixir
  defp update_counts(framework, row_maps) when is_list(row_maps) do
    row_count = length(row_maps)
    skill_names = Enum.map(row_maps, fn r -> r[:skill_name] || r["skill_name"] || "" end)
    skill_count = skill_names |> Enum.uniq() |> length()

    framework
    |> Ecto.Changeset.change(%{row_count: row_count, skill_count: skill_count})
    |> Repo.update!()
  end
```

And refactor existing `save_framework/1` to use the shared helpers. Replace lines 142-174:

```elixir
      row_maps = insert_rows(framework, attrs.rows)
      update_counts(framework, row_maps)
```

- [ ] **Step 4: Implement `get_company_roles_summary`**

Add to `lib/rho/skill_store.ex`:

```elixir
  def get_company_roles_summary(company_id) do
    frameworks =
      from(f in Framework,
        where: f.company_id == ^company_id and f.type == "company" and not is_nil(f.role_name),
        order_by: [asc: f.role_name, desc: f.year, desc: f.version]
      )
      |> Repo.all()

    frameworks
    |> Enum.group_by(& &1.role_name)
    |> Enum.map(fn {role_name, versions} ->
      default = Enum.find(versions, hd(versions), & &1.is_default)

      %{
        role_name: role_name,
        default: %{
          id: default.id,
          year: default.year,
          version: default.version,
          skill_count: default.skill_count,
          row_count: default.row_count,
          description: default.description,
          inserted_at: default.inserted_at
        },
        versions:
          Enum.map(versions, fn v ->
            %{
              id: v.id,
              year: v.year,
              version: v.version,
              is_default: v.is_default,
              skill_count: v.skill_count,
              inserted_at: v.inserted_at
            }
          end)
      }
    end)
    |> Enum.sort_by(& &1.role_name)
  end
```

- [ ] **Step 5: Implement `set_default_version`**

Add to `lib/rho/skill_store.ex`:

```elixir
  def set_default_version(framework_id) do
    framework = Repo.get!(Framework, framework_id)

    Repo.transaction(fn ->
      # Unset old default for this company+role_name
      from(f in Framework,
        where:
          f.company_id == ^framework.company_id and
            f.role_name == ^framework.role_name and
            f.is_default == true
      )
      |> Repo.update_all(set: [is_default: false])

      # Set new default
      framework
      |> Ecto.Changeset.change(%{is_default: true})
      |> Repo.update!()
    end)
  end
```

- [ ] **Step 6: Update `list_frameworks_for` to include new fields**

In `lib/rho/skill_store.ex`, update the `Enum.map` at the end of `list_frameworks_for` (line 52-56). The `Map.from_struct(f) |> Map.drop([:__meta__, :rows, :company])` already includes all fields from the schema, so the new fields (`role_name`, `year`, `version`, `is_default`, `description`) are automatically included. No code change needed here.

Verify by checking the test output — the response should now include the new fields.

- [ ] **Step 7: Run all tests**

Run: `mix test test/rho/skill_store_test.exs --trace`
Expected: all tests pass (old + new).

- [ ] **Step 8: Compile check**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 9: Commit**

```bash
git add lib/rho/skill_store.ex test/rho/skill_store_test.exs
git commit -m "feat: add save_role_framework, get_company_roles_summary, set_default_version

Versioned save with auto-naming and is_default management.
Company roles summary for welcome flow.
Refactored save_framework to share insert_rows/update_counts helpers."
```

---

### Task 3: LiveView handler for save plan

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex`

- [ ] **Step 1: Add the `spreadsheet_save_plan` handler**

In `lib/rho_web/live/spreadsheet_live.ex`, after the existing `handle_info({:spreadsheet_merge_plan, ...})` handler, add:

```elixir
  def handle_info({:spreadsheet_save_plan, {caller_pid, ref}, year, company_id}, socket) do
    rows =
      socket.assigns.rows_map
      |> Map.values()
      |> Enum.sort_by(& &1[:id])
      |> Enum.map(fn row -> Map.drop(row, [:id]) end)

    # Group rows by role
    roles_grouped =
      rows
      |> Enum.group_by(fn row -> row[:role] || "" end)
      |> Enum.reject(fn {role, _} -> role == "" end)

    # For each role, compute stats and check DB for existing
    role_plans =
      Enum.map(roles_grouped, fn {role_name, role_rows} ->
        skill_names = role_rows |> Enum.map(& &1[:skill_name]) |> Enum.uniq()

        # Check if this role+year exists
        existing =
          Rho.SkillStore.Repo.one(
            from(f in Rho.SkillStore.Framework,
              where:
                f.company_id == ^company_id and
                  f.role_name == ^role_name and
                  f.year == ^year and
                  f.type == "company",
              order_by: [desc: f.version],
              limit: 1
            )
          )

        # Check if first-ever version of this role
        any_exists =
          Rho.SkillStore.Repo.exists?(
            from(f in Rho.SkillStore.Framework,
              where:
                f.company_id == ^company_id and
                  f.role_name == ^role_name and
                  f.type == "company"
            )
          )

        base = %{
          role_name: role_name,
          skill_count: length(skill_names),
          row_count: length(role_rows),
          is_first_role: !any_exists
        }

        if existing do
          Map.merge(base, %{
            status: "exists",
            existing: %{
              id: existing.id,
              year: existing.year,
              version: existing.version,
              created_at: existing.inserted_at
            }
          })
        else
          Map.put(base, :status, "new")
        end
      end)

    # Check for empty-role rows (mismatch)
    empty_role_rows = Enum.filter(rows, fn row -> (row[:role] || "") == "" end)

    mismatches =
      if empty_role_rows != [] do
        [%{role: "", count: length(empty_role_rows), note: "rows with no role assigned"}]
      else
        []
      end

    plan = %{
      year: year,
      roles: role_plans,
      mismatches: mismatches,
      total_rows: length(rows)
    }

    send(caller_pid, {ref, {:ok, plan}})
    {:noreply, socket}
  end
```

- [ ] **Step 2: Compile check**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex
git commit -m "feat: add spreadsheet_save_plan handler for versioned save"
```

---

### Task 4: Rewrite `save_framework_tool` with plan/execute

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex`
- Create: `test/rho/mounts/spreadsheet_save_test.exs`

- [ ] **Step 1: Write tests**

Create `test/rho/mounts/spreadsheet_save_test.exs`:

```elixir
defmodule Rho.Mounts.SpreadsheetSaveTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "save_framework tool" do
    test "tool is present in tools list" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "save_framework" in tool_names
    end

    test "rejects plan mode without year" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "plan"})
      assert {:error, _} = result
    end

    test "rejects execute mode without decisions" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "execute", "year" => 2026})
      assert {:error, _} = result
    end

    test "rejects company save without company_id" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: nil, is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "plan", "year" => 2026})
      assert {:error, _} = result
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rho/mounts/spreadsheet_save_test.exs --trace`
Expected: first test passes (tool exists), others may behave differently with old tool.

- [ ] **Step 3: Replace `save_framework_tool`**

In `lib/rho/mounts/spreadsheet.ex`, replace the entire `save_framework_tool` function (lines 989-1053) with:

```elixir
  defp save_framework_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "save_framework",
          description:
            "Save the current spreadsheet to the database. Uses two-phase flow: " <>
              "call with mode 'plan' first to get a save plan, then 'execute' to apply. " <>
              "For industry templates (admin only), use type 'industry' to bypass versioning.",
          parameter_schema: [
            mode: [
              type: :string,
              required: true,
              doc: "'plan' (preview save plan) or 'execute' (apply save)"
            ],
            type: [
              type: :string,
              required: false,
              doc: "'company' (default, versioned) or 'industry' (admin only, no versioning)"
            ],
            year: [
              type: :integer,
              required: false,
              doc: "Framework year (required for company type, default: current year)"
            ],
            decisions: [
              type: :string,
              required: false,
              doc:
                ~s(JSON array for execute mode: [{"role_name":"Data Scientist","action":"create"},{"role_name":"Risk Analyst","action":"update","existing_id":92}])
            ],
            description: [
              type: :string,
              required: false,
              doc: "Optional note for this version"
            ],
            name: [
              type: :string,
              required: false,
              doc: "Framework name (only for industry type)"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        type = args["type"] || "company"
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        cond do
          type == "industry" ->
            if is_admin do
              save_industry_template(session_id, args, company_id)
            else
              {:error, "Only admin can save industry templates"}
            end

          company_id == nil or company_id == "" ->
            {:error, "Company context required. Open the editor with ?company=your_company_id"}

          true ->
            mode = args["mode"] || "plan"
            year = args["year"]

            case mode do
              "plan" ->
                if year == nil do
                  {:error, "year is required for plan mode"}
                else
                  execute_save_plan(session_id, year, company_id)
                end

              "execute" ->
                decisions_raw = args["decisions"]

                if decisions_raw == nil do
                  {:error, "decisions is required for execute mode. Call with mode 'plan' first."}
                else
                  decisions =
                    case Jason.decode(decisions_raw) do
                      {:ok, list} when is_list(list) -> list
                      _ -> []
                    end

                  if decisions == [] do
                    {:error, "No valid decisions. Pass a JSON array."}
                  else
                    execute_save(
                      session_id,
                      agent_id,
                      year || DateTime.utc_now().year,
                      company_id,
                      decisions,
                      args["description"] || ""
                    )
                  end
                end

              _ ->
                {:error, "mode must be 'plan' or 'execute'"}
            end
        end
      end
    }
  end

  defp save_industry_template(session_id, args, _company_id) do
    name = args["name"]

    if name == nil or name == "" do
      {:error, "name is required for industry templates"}
    else
      with_pid(session_id, fn pid ->
        ref = make_ref()
        send(pid, {:get_all_rows, {self(), ref}})

        receive do
          {^ref, {:ok, rows}} ->
            case Rho.SkillStore.save_framework(%{
                   id: args["framework_id"],
                   name: name,
                   type: "industry",
                   company_id: nil,
                   source: "spreadsheet_editor",
                   rows: rows
                 }) do
              {:ok, framework} ->
                {:ok, "Saved industry template '#{name}' (id: #{framework.id}) — #{length(rows)} rows"}

              {:error, reason} ->
                {:error, "Save failed: #{inspect(reason)}"}
            end
        after
          5_000 -> {:error, "Spreadsheet did not respond in time"}
        end
      end)
    end
  end

  defp execute_save_plan(session_id, year, company_id) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:spreadsheet_save_plan, {self(), ref}, year, company_id})

      receive do
        {^ref, {:ok, plan}} ->
          {:ok, Jason.encode!(plan)}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end

  defp execute_save(session_id, _agent_id, year, company_id, decisions, description) do
    with_pid(session_id, fn pid ->
      # Re-read latest rows
      ref = make_ref()
      send(pid, {:get_all_rows, {self(), ref}})

      receive do
        {^ref, {:ok, rows}} ->
          rows_by_role = Enum.group_by(rows, fn row -> row[:role] || "" end)

          results =
            Enum.map(decisions, fn decision ->
              role_name = decision["role_name"]

              action =
                case decision["action"] do
                  "create" -> :create
                  "update" -> :update
                  _ -> :create
                end

              existing_id = decision["existing_id"]
              role_rows = Map.get(rows_by_role, role_name, [])

              if role_rows == [] do
                {:error, "No rows found for role '#{role_name}'"}
              else
                Rho.SkillStore.save_role_framework(%{
                  company_id: company_id,
                  role_name: role_name,
                  year: year,
                  action: action,
                  existing_id: existing_id,
                  description: description,
                  source: "spreadsheet_editor",
                  rows: role_rows
                })
              end
            end)

          successes = Enum.filter(results, &match?({:ok, _}, &1))
          failures = Enum.filter(results, &match?({:error, _}, &1))

          summary =
            successes
            |> Enum.map(fn {:ok, fw} ->
              "#{fw.role_name} #{fw.year} v#{fw.version} (#{fw.row_count} rows)"
            end)
            |> Enum.join(", ")

          case {successes, failures} do
            {[], fails} ->
              {:error, "All saves failed: #{inspect(fails)}"}

            {_, []} ->
              {:ok, "Saved #{length(successes)} role(s): #{summary}"}

            {_, fails} ->
              {:ok,
               "Saved #{length(successes)} role(s): #{summary}. " <>
                 "#{length(fails)} failed: #{inspect(fails)}"}
          end
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/rho/mounts/spreadsheet_save_test.exs --trace`
Expected: all 4 tests pass.

- [ ] **Step 5: Run all tests**

Run: `mix test --trace`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex test/rho/mounts/spreadsheet_save_test.exs
git commit -m "feat: rewrite save_framework tool with two-phase plan/execute

Plan mode: server-side grouping by role, checks DB for existing versions.
Execute mode: saves each role via save_role_framework.
Industry template save bypasses versioning (admin only).
Replaces old save_framework tool that saved all rows as one record."
```

---

### Task 5: `get_company_overview` tool

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex`

- [ ] **Step 1: Add to tools list**

In `lib/rho/mounts/spreadsheet.ex`, in the `tools/2` function, add `get_company_overview_tool(context)` after `save_framework_tool(session_id, context)`:

```elixir
      save_framework_tool(session_id, context),
      get_company_overview_tool(context),
      switch_view_tool(context),
```

- [ ] **Step 2: Implement the tool**

Add after `save_framework_tool`:

```elixir
  defp get_company_overview_tool(context) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_company_overview",
          description:
            "Get an overview of the company's skill frameworks — roles, default versions, " <>
              "version history, and available industry templates. Use on first message or " <>
              "when user asks 'what do we have'.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        company_id = context.opts[:company_id]
        is_admin = context.opts[:is_admin] || false

        if company_id == nil or company_id == "" do
          {:ok,
           Jason.encode!(%{
             company: nil,
             roles: [],
             industry_templates:
               Rho.SkillStore.list_frameworks_for(nil, false, "industry")
               |> Enum.map(&Map.take(&1, [:id, :name, :skill_count, :row_count]))
           })}
        else
          roles_summary = Rho.SkillStore.get_company_roles_summary(company_id)

          industry_templates =
            Rho.SkillStore.list_frameworks_for(company_id, is_admin, "industry")
            |> Enum.map(&Map.take(&1, [:id, :name, :skill_count, :row_count]))

          {:ok,
           Jason.encode!(%{
             company: company_id,
             roles: roles_summary,
             industry_templates: industry_templates
           })}
        end
      end
    }
  end
```

- [ ] **Step 3: Compile and run tests**

Run: `mix compile --warnings-as-errors && mix test --trace`

- [ ] **Step 4: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add get_company_overview tool for welcome flow"
```

---

### Task 6: Update SKILL.md + persistence-workflow.md

**Files:**
- Modify: `.agents/skills/framework-editor/SKILL.md`
- Modify: `.agents/skills/framework-editor/references/persistence-workflow.md`

- [ ] **Step 1: Update SKILL.md intent detection table**

Replace the Save, Save template, Load company, and Welcome rows:

Find:
```
| "Save this" | **Save** | `save_framework(name, type)` |
| "Save as industry template" (admin) | **Save template** | Check admin → `save_framework(type: "industry")` |
```

Replace with:
```
| "Save this" | **Save** | Call `save_framework(mode: "plan", year: CURRENT_YEAR)` to get save plan. Present plan to user (roles, versions, new vs update). On approval, call `save_framework(mode: "execute", year: Y, decisions: "[...]")`. |
| "Save as industry template" (admin) | **Save template** | Check admin → `save_framework(type: "industry", name: "...")` (bypasses versioning) |
```

Find:
```
| "Load our framework" / "Show what we have" | **Load company** | `list_frameworks(type: "company")` → show/load |
```

Replace with:
```
| "Load our framework" / "Show what we have" | **Load company** | `get_company_overview` → show roles with default versions and history → user picks role to load |
```

Find:
```
| First message, empty spreadsheet | **Welcome** | Offer: load existing, import, or build |
```

Replace with:
```
| First message, empty spreadsheet | **Welcome** | Call `get_company_overview` → present company roles (with default/draft versions) + industry templates + capabilities. See Welcome Flow in spec. |
```

- [ ] **Step 2: Update Available Tools section**

In the "Persistence" section, add `get_company_overview` and update `save_framework`:

```markdown
### Persistence
- `get_company_overview` — get company's role frameworks (defaults + versions) and industry templates. Use on first message and when user asks "what do we have".
- `list_frameworks` — list all visible frameworks (industry + company). Returns flat list with role_name, year, version, is_default fields.
- `search_framework_roles` — browse roles in a framework (skill counts + sample skills)
- `load_framework` — load a framework into the spreadsheet (replaces content)
- `load_framework_roles` — load specific roles from a framework
- `save_framework` — save spreadsheet to database. Two-phase: mode "plan" returns save plan, mode "execute" applies it. For industry templates, use type "industry" (admin only).
- `switch_view` — toggle between "By Role" and "By Category" view
```

- [ ] **Step 3: Rewrite persistence-workflow.md**

Replace the entire content of `.agents/skills/framework-editor/references/persistence-workflow.md`:

```markdown
# Persistence Workflow

## Save Flow (Versioned)

1. User says "save this" or agent detects significant edits
2. Call `save_framework(mode: "plan", year: CURRENT_YEAR)` — returns:
   - Roles found in spreadsheet (grouped by role column)
   - For each role: new (first-ever → auto-default) or exists (update vs new version?)
   - Mismatches (rows with empty or unexpected role values)
3. Present the save plan to user:
   - "Saving 2 roles for year 2026: Data Scientist (new, will be default), Risk Analyst (exists — update v1 or create v2?)"
4. User confirms (may adjust year, choose update vs new version per role)
5. Call `save_framework(mode: "execute", year: Y, decisions: "[...]")`
   - Each decision: `{"role_name": "X", "action": "create"|"update", "existing_id": N}`
6. Confirm: "Saved 2 roles: Data Scientist 2026 v1 (default), Risk Analyst 2026 v2 (draft)"

## Admin: Industry Template Save

1. Only if is_admin is true
2. Call `save_framework(type: "industry", name: "...")` — bypasses versioning
3. Saves all rows as one industry template

## Load Flow

1. User says "load our framework" or "show what we have"
2. Call `get_company_overview` → shows roles with default versions + history
3. User picks a role → load with `load_framework(id)`
4. Auto-detect view mode (role view if roles exist)
5. Confirm: "Loaded Data Scientist 2026 v1 — 140 rows"

## Set Default Version

1. User says "set Data Scientist 2025 v1 as default"
2. Agent identifies the framework ID
3. System flips is_default in a transaction

## When to Remind About Saving

- After generating a new framework (skeleton + proficiency levels done)
- After importing from a file
- After making 5+ edits in a session
- When user says "done" or "finished"
```

- [ ] **Step 4: Commit**

```bash
git add .agents/skills/framework-editor/SKILL.md .agents/skills/framework-editor/references/persistence-workflow.md
git commit -m "docs: update SKILL.md and persistence-workflow for versioned save flow"
```

---

### Task 7: Integration verification

**Files:** None — verification only.

- [ ] **Step 1: Run full test suite**

Run: `mix test --trace`
Expected: all tests pass.

- [ ] **Step 2: Compile check**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 3: Verify migration on fresh DB**

```bash
rm priv/skill_store.db
mix ecto.create --repo Rho.SkillStore.Repo
mix ecto.migrate --repo Rho.SkillStore.Repo
sqlite3 priv/skill_store.db "PRAGMA table_info(frameworks);"
```

Expected: all new columns present (role_name, year, version, is_default, description).

Note: after this step, re-seed the FSF data if needed for demo testing.

- [ ] **Step 4: Start server and test welcome flow**

```bash
RHO_WEB_ENABLED=true mix phx.server
```

Open `http://localhost:4001/spreadsheet?company=bank_abc`. First message should trigger `get_company_overview` and show role summary.

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Schema migration + Ecto schema | migration file, framework.ex |
| 2 | save_role_framework + get_company_roles_summary + set_default_version | skill_store.ex, tests |
| 3 | LiveView save plan handler | spreadsheet_live.ex |
| 4 | Rewrite save_framework tool (plan/execute) | spreadsheet.ex, tests |
| 5 | get_company_overview tool | spreadsheet.ex |
| 6 | SKILL.md + persistence-workflow.md | prompt/doc files |
| 7 | Integration verification | none |

## What's NOT in this plan (Phase 2)

- Append mode for load_framework / load_framework_roles
- Multi-tab import
- Company view (computed summary tool)
- Version comparison
- File explorer sidebar UI
