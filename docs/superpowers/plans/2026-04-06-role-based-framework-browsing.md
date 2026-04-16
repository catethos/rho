# Role-Based Framework Browsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add browse-then-load tools so users can search industry framework roles and load only the ones they need, instead of loading the entire framework.

**Architecture:** Two new SkillStore query functions (`get_framework_role_directory/1`, `get_framework_rows_for_roles/2`) exposed as two new spreadsheet mount tools (`search_framework_roles`, `load_framework_roles`). The agent itself does the role-matching reasoning — no embedding or search infra needed.

**Tech Stack:** Elixir, Ecto (SQLite), existing Rho.Mount + Rho.SkillStore patterns.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/rho/skill_store.ex` | Modify | Add `get_framework_role_directory/1` and `get_framework_rows_for_roles/2` |
| `test/rho/skill_store_test.exs` | Modify | Add tests for the two new query functions |
| `lib/rho/mounts/spreadsheet.ex` | Modify | Add `search_framework_roles` and `load_framework_roles` tool definitions |
| `.agents/skills/framework-editor/SKILL.md` | Modify | Add new intent detection row + update tool reference |

---

### Task 1: SkillStore query — `get_framework_role_directory/1`

**Files:**
- Modify: `test/rho/skill_store_test.exs`
- Modify: `lib/rho/skill_store.ex`

- [ ] **Step 1: Write the failing test**

Add to `test/rho/skill_store_test.exs` after the `list_frameworks_for/3` describe block:

```elixir
describe "get_framework_role_directory/1" do
  test "returns distinct roles with skill counts and top skills" do
    SkillStore.ensure_company("co_a")

    {:ok, fw} =
      SkillStore.save_framework(%{
        name: "Industry FW",
        type: "industry",
        company_id: nil,
        rows: [
          full_row(%{role: "Risk Analyst", category: "Core", skill_name: "Risk Assessment", level: 1}),
          full_row(%{role: "Risk Analyst", category: "Core", skill_name: "Risk Assessment", level: 2}),
          full_row(%{role: "Risk Analyst", category: "Core", skill_name: "Credit Analysis", level: 1}),
          full_row(%{role: "Risk Analyst", category: "Technical", skill_name: "Basel Compliance", level: 1}),
          full_row(%{role: "Compliance Officer", category: "Core", skill_name: "AML", level: 1}),
          full_row(%{role: "Compliance Officer", category: "Core", skill_name: "Policy Review", level: 1}),
          full_row(%{role: "", skill_name: "Communication", level: 1})
        ]
      })

    directory = SkillStore.get_framework_role_directory(fw.id)

    # Should not include empty-role rows
    roles = Enum.map(directory, & &1.role)
    refute "" in roles

    # Check Risk Analyst entry
    ra = Enum.find(directory, &(&1.role == "Risk Analyst"))
    assert ra.skill_count == 3
    assert length(ra.top_skills) == 3
    assert "Risk Assessment" in ra.top_skills
    assert "Credit Analysis" in ra.top_skills
    assert "Basel Compliance" in ra.top_skills

    # Check Compliance Officer entry
    co = Enum.find(directory, &(&1.role == "Compliance Officer"))
    assert co.skill_count == 2
  end

  test "returns empty list for framework with no roles" do
    {:ok, fw} =
      SkillStore.save_framework(%{
        name: "No Roles FW",
        type: "industry",
        company_id: nil,
        rows: [full_row(%{role: "", skill_name: "Communication", level: 1})]
      })

    assert SkillStore.get_framework_role_directory(fw.id) == []
  end

  test "caps top_skills at 5" do
    {:ok, fw} =
      SkillStore.save_framework(%{
        name: "Big Role FW",
        type: "industry",
        company_id: nil,
        rows:
          for name <- ~w(A B C D E F G) do
            full_row(%{role: "Analyst", category: "Core", skill_name: name, level: 1})
          end
      })

    [entry] = SkillStore.get_framework_role_directory(fw.id)
    assert entry.skill_count == 7
    assert length(entry.top_skills) == 5
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rho/skill_store_test.exs --seed 0`
Expected: FAIL — `get_framework_role_directory/1` is undefined.

- [ ] **Step 3: Implement `get_framework_role_directory/1`**

Add to `lib/rho/skill_store.ex` after the `get_framework_rows/1` function (around line 70):

```elixir
def get_framework_role_directory(framework_id) do
  # Get distinct roles with skill counts
  role_stats =
    from(r in FrameworkRow,
      where: r.framework_id == ^framework_id and r.role != "" and not is_nil(r.role),
      group_by: r.role,
      select: {r.role, count(fragment("DISTINCT ?", r.skill_name))},
      order_by: r.role
    )
    |> Repo.all()

  if role_stats == [] do
    []
  else
    role_names = Enum.map(role_stats, &elem(&1, 0))

    # Get top 5 skill names per role, ordered by category then skill_name
    skills_by_role =
      from(r in FrameworkRow,
        where:
          r.framework_id == ^framework_id and r.role in ^role_names,
        distinct: [r.role, r.skill_name],
        select: {r.role, r.skill_name},
        order_by: [r.role, r.category, r.skill_name]
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(role_stats, fn {role, skill_count} ->
      top_skills =
        skills_by_role
        |> Map.get(role, [])
        |> Enum.take(5)

      %{role: role, skill_count: skill_count, top_skills: top_skills}
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rho/skill_store_test.exs --seed 0`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rho/skill_store.ex test/rho/skill_store_test.exs
git commit -m "feat: add get_framework_role_directory/1 query

Returns distinct roles with skill counts and top 5 sample skill names,
for browse-before-load flow on large industry frameworks."
```

---

### Task 2: SkillStore query — `get_framework_rows_for_roles/2`

**Files:**
- Modify: `test/rho/skill_store_test.exs`
- Modify: `lib/rho/skill_store.ex`

- [ ] **Step 1: Write the failing test**

Add to `test/rho/skill_store_test.exs` after the `get_framework_role_directory/1` describe block:

```elixir
describe "get_framework_rows_for_roles/2" do
  test "returns only rows matching the given roles" do
    {:ok, fw} =
      SkillStore.save_framework(%{
        name: "Multi Role FW",
        type: "industry",
        company_id: nil,
        rows: [
          full_row(%{role: "Risk Analyst", skill_name: "Risk Assessment", level: 1}),
          full_row(%{role: "Risk Analyst", skill_name: "Risk Assessment", level: 2}),
          full_row(%{role: "Compliance Officer", skill_name: "AML", level: 1}),
          full_row(%{role: "Trader", skill_name: "Execution", level: 1}),
          full_row(%{role: "", skill_name: "Communication", level: 1})
        ]
      })

    rows = SkillStore.get_framework_rows_for_roles(fw.id, ["Risk Analyst", "Compliance Officer"])
    assert length(rows) == 3

    roles = Enum.map(rows, & &1.role) |> Enum.uniq() |> Enum.sort()
    assert roles == ["Compliance Officer", "Risk Analyst"]
  end

  test "returns empty list when no roles match" do
    {:ok, fw} =
      SkillStore.save_framework(%{
        name: "FW",
        type: "industry",
        company_id: nil,
        rows: [full_row(%{role: "Trader", skill_name: "Execution", level: 1})]
      })

    assert SkillStore.get_framework_rows_for_roles(fw.id, ["Risk Analyst"]) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rho/skill_store_test.exs --seed 0`
Expected: FAIL — `get_framework_rows_for_roles/2` is undefined.

- [ ] **Step 3: Implement `get_framework_rows_for_roles/2`**

Add to `lib/rho/skill_store.ex` after `get_framework_role_directory/1`:

```elixir
def get_framework_rows_for_roles(framework_id, role_names) when is_list(role_names) do
  from(r in FrameworkRow,
    where: r.framework_id == ^framework_id and r.role in ^role_names,
    order_by: r.id
  )
  |> Repo.all()
  |> Enum.map(&row_to_map/1)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rho/skill_store_test.exs --seed 0`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rho/skill_store.ex test/rho/skill_store_test.exs
git commit -m "feat: add get_framework_rows_for_roles/2 query

Filtered row loading — returns only rows matching the given role names,
for loading specific roles instead of entire frameworks."
```

---

### Task 3: Spreadsheet mount — `search_framework_roles` tool

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex`

- [ ] **Step 1: Add the tool to the tools list**

In `lib/rho/mounts/spreadsheet.ex`, update the `tools/2` function (line 39-55) to include the new tool. Add after `list_frameworks_tool(context)`:

```elixir
search_framework_roles_tool(context),
```

So the list becomes:

```elixir
def tools(_mount_opts, %{session_id: session_id} = context) do
  [
    get_table_tool(session_id),
    get_table_summary_tool(session_id),
    get_uploaded_file_tool(session_id),
    update_cells_tool(context),
    add_rows_tool(context),
    add_proficiency_levels_tool(session_id, context),
    delete_rows_tool(context),
    replace_all_tool(context),
    import_from_file_tool(context),
    list_frameworks_tool(context),
    search_framework_roles_tool(context),
    load_framework_tool(session_id, context),
    load_framework_roles_tool(session_id, context),
    save_framework_tool(session_id, context),
    switch_view_tool(context)
  ]
end
```

- [ ] **Step 2: Implement `search_framework_roles_tool/1`**

Add after `list_frameworks_tool/1` (after line 438):

```elixir
defp search_framework_roles_tool(context) do
  %{
    tool:
      ReqLLM.tool(
        name: "search_framework_roles",
        description:
          "Get a directory of all roles in a framework with skill counts and sample skill names. " <>
            "Use this to browse large industry frameworks before loading — lets you pick specific " <>
            "roles instead of loading everything.",
        parameter_schema: [
          framework_id: [
            type: :integer,
            required: true,
            doc: "Framework ID from list_frameworks"
          ]
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
            directory = Rho.SkillStore.get_framework_role_directory(framework_id)
            {:ok, Jason.encode!(%{framework: framework.name, roles: directory})}
          else
            {:error, "Access denied"}
          end
      end
    end
  }
end
```

- [ ] **Step 3: Run compile to check for errors**

Run: `mix compile --warnings-as-errors`
Expected: Compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add search_framework_roles tool

Lightweight role directory for browse-before-load flow. Returns role names,
skill counts, and top 5 sample skills per role."
```

---

### Task 4: Spreadsheet mount — `load_framework_roles` tool

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex`

- [ ] **Step 1: Implement `load_framework_roles_tool/2`**

Add after `search_framework_roles_tool/1`:

```elixir
defp load_framework_roles_tool(session_id, context) do
  %{
    tool:
      ReqLLM.tool(
        name: "load_framework_roles",
        description:
          "Load specific roles from a framework into the spreadsheet. Use after " <>
            "search_framework_roles — pass exact role names from the search results. " <>
            "Replaces current spreadsheet content.",
        parameter_schema: [
          framework_id: [
            type: :integer,
            required: true,
            doc: "Framework ID from list_frameworks"
          ],
          roles_json: [
            type: :string,
            required: true,
            doc: ~s(JSON array of role names, e.g. ["Risk Analyst", "Credit Risk Manager"])
          ]
        ],
        callback: fn _args -> :ok end
      ),
    execute: fn args ->
      framework_id = args["framework_id"]
      company_id = context.opts[:company_id]
      is_admin = context.opts[:is_admin] || false

      roles =
        case Jason.decode(args["roles_json"] || "[]") do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      if roles == [] do
        {:error, "No roles specified. Pass roles_json as a JSON array of role name strings."}
      else
        case Rho.SkillStore.get_framework(framework_id) do
          nil ->
            {:error, "Framework not found"}

          framework ->
            if can_access?(framework, company_id, is_admin) do
              rows = Rho.SkillStore.get_framework_rows_for_roles(framework_id, roles)

              with_pid(session_id, fn pid ->
                send(pid, {:load_framework_rows, rows, framework})
                {:ok, "Loaded #{length(roles)} role(s) from '#{framework.name}' — #{length(rows)} rows"}
              end)
            else
              {:error, "Access denied"}
            end
        end
      end
    end
  }
end
```

- [ ] **Step 2: Run compile to check for errors**

Run: `mix compile --warnings-as-errors`
Expected: Compiles without errors.

- [ ] **Step 3: Run the full test suite**

Run: `mix test --seed 0`
Expected: All tests PASS (no regressions).

- [ ] **Step 4: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add load_framework_roles tool

Filtered framework loading — loads only rows for selected roles instead of
the entire framework. Paired with search_framework_roles for browse-then-load."
```

---

### Task 5: Update framework-editor SKILL.md

**Files:**
- Modify: `.agents/skills/framework-editor/SKILL.md`

- [ ] **Step 1: Add new intent detection row**

In `.agents/skills/framework-editor/SKILL.md`, update the Intent Detection table (lines 19-34). Add a new row after the "Load AICB" row (line 28) and before the "Load our framework" row:

Replace the existing "Load AICB" row:
```
| "Load AICB" / "Use banking framework" | **Load template** | `list_frameworks` → find → `load_framework(id)` |
```

With two rows:
```
| "Load AICB" / "Use banking framework" (small or full load) | **Load template** | `list_frameworks` → find → `load_framework(id)` |
| "Skills for Risk Analyst" / "What roles match?" + industry framework | **Browse roles** | `list_frameworks` → `search_framework_roles(id)` → present top 5 matches → user picks → `load_framework_roles(id, roles)` |
```

- [ ] **Step 2: Add the new tools to the Available Tools section**

In the `### Persistence` section (lines 95-98), add the new tools:

Replace:
```
### Persistence
- `list_frameworks` — see available industry templates and company frameworks
- `load_framework` — load a framework into the spreadsheet
- `save_framework` — save spreadsheet to database
- `switch_view` — toggle between "By Role" and "By Category" view
```

With:
```
### Persistence
- `list_frameworks` — see available industry templates and company frameworks
- `search_framework_roles` — browse roles in a framework (skill counts + sample skills). Use for large industry frameworks instead of loading everything.
- `load_framework` — load an entire framework into the spreadsheet
- `load_framework_roles` — load only specific roles from a framework. Use after `search_framework_roles`.
- `save_framework` — save spreadsheet to database
- `switch_view` — toggle between "By Role" and "By Category" view
```

- [ ] **Step 3: Verify the SKILL.md is valid**

Run: `head -10 .agents/skills/framework-editor/SKILL.md`
Expected: YAML frontmatter is intact, no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add .agents/skills/framework-editor/SKILL.md
git commit -m "feat: update framework-editor skill with browse-then-load intent

Adds 'Browse roles' intent detection for role-specific industry framework
queries. Documents search_framework_roles and load_framework_roles tools."
```

---

### Task 6: Manual smoke test

- [ ] **Step 1: Start the server**

```bash
RHO_WEB_ENABLED=true mix phx.server
```

- [ ] **Step 2: Open the spreadsheet editor**

Open: `http://localhost:4001/spreadsheet?company=bank_abc`

- [ ] **Step 3: Test the browse-then-load flow**

Type: "I need skills for Risk Analyst, we're a bank"

Expected agent behavior:
1. Calls `list_frameworks` to find industry frameworks
2. Calls `search_framework_roles` on the relevant framework
3. Presents top role matches with skill previews
4. Waits for user to pick roles
5. Calls `load_framework_roles` with selected roles
6. Spreadsheet shows only the selected roles' rows
