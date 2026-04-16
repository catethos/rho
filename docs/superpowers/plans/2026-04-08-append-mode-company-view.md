# Append Mode + Company View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable loading multiple frameworks into one spreadsheet (append mode) and add a computed company view tool that summarizes all roles.

**Architecture:** Add an `append` boolean parameter to `load_framework` and `load_framework_roles` tools. When true, new rows merge into the existing `rows_map` with IDs continuing from `next_id` instead of resetting. Company view is a read-only tool that queries all default frameworks and computes shared skills across roles.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/SQLite

**Spec reference:** `docs/superpowers/specs/2026-04-08-company-framework-model-design.md` — Plans [4], [5], [6]

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/rho/mounts/spreadsheet.ex` | Modify | Add `append` param to both load tools, add `get_company_view` tool |
| `lib/rho_web/live/spreadsheet_live.ex` | Modify | Handle `append: true` in `load_framework_rows` message |
| `lib/rho/skill_store.ex` | Modify | Add `get_company_view/1` query |
| `test/rho/mounts/spreadsheet_load_test.exs` | Create | Tests for append mode load + company view tool |
| `.agents/skills/framework-editor/SKILL.md` | Modify | Update tool docs for append param, add company view intent |
| `.agents/skills/framework-editor/references/persistence-workflow.md` | Modify | Add append/multi-load section |

---

### Task 1: Append Mode — LiveView Handler

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex:642-662`

The current `handle_info({:load_framework_rows, rows, framework}, socket)` always resets IDs from 1 and replaces `rows_map`. We need it to accept an `append` option and conditionally merge.

- [ ] **Step 1: Write the failing test**

Create `test/rho/mounts/spreadsheet_load_test.exs`:

```elixir
defmodule Rho.Mounts.SpreadsheetLoadTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  defp make_context(session_id) do
    %{
      session_id: session_id,
      agent_id: "test_agent",
      workspace: "/tmp",
      agent_name: :spreadsheet,
      opts: %{company_id: "test_co", is_admin: false}
    }
  end

  describe "load_framework tool" do
    test "tool has append parameter" do
      context = make_context("test_load_append")
      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "load_framework" end)

      param_names =
        tool.tool.parameter_schema["properties"]
        |> Map.keys()

      assert "append" in param_names
    end
  end

  describe "load_framework_roles tool" do
    test "tool has append parameter" do
      context = make_context("test_load_roles_append")
      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "load_framework_roles" end)

      param_names =
        tool.tool.parameter_schema["properties"]
        |> Map.keys()

      assert "append" in param_names
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rho/mounts/spreadsheet_load_test.exs -v`
Expected: FAIL — `"append"` not in parameter names

- [ ] **Step 3: Update LiveView handler to accept append option**

In `lib/rho_web/live/spreadsheet_live.ex`, replace the current handler (lines 642-662) with:

```elixir
  def handle_info({:load_framework_rows, rows, framework}, socket) do
    handle_info({:load_framework_rows, rows, framework, append: false}, socket)
  end

  def handle_info({:load_framework_rows, rows, framework, opts}, socket) do
    append = Keyword.get(opts, :append, false)

    start_id = if append, do: socket.assigns.next_id, else: 1

    {id_rows, next_id} =
      Enum.map_reduce(rows, start_id, fn row, id ->
        {Map.put(row, :id, id), id + 1}
      end)

    new_rows_map = Map.new(id_rows, fn row -> {row.id, row} end)

    rows_map =
      if append do
        Map.merge(socket.assigns.rows_map, new_rows_map)
      else
        new_rows_map
      end

    all_rows = Map.values(rows_map)
    has_roles = Enum.any?(all_rows, fn r -> (r[:role] || "") != "" end)
    view_mode = if has_roles, do: :role, else: :category

    socket =
      socket
      |> assign(:rows_map, rows_map)
      |> assign(:next_id, next_id)
      |> assign(:view_mode, view_mode)

    {:noreply, socket}
  end
```

Note: The dead `loaded_framework_id` / `loaded_framework_name` assigns are removed — they were never read anywhere.

- [ ] **Step 4: Run test to verify handler compiles**

Run: `mix compile --warnings-as-errors`
Expected: Compiles cleanly

- [ ] **Step 5: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex test/rho/mounts/spreadsheet_load_test.exs
git commit -m "feat: LiveView handler supports append mode for load_framework_rows"
```

---

### Task 2: Append Mode — Tool Parameters

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex` — `load_framework_tool/2` (lines 947-987) and `load_framework_roles_tool/2` (lines 989-1047)

- [ ] **Step 1: Add append parameter to `load_framework_tool`**

In `lib/rho/mounts/spreadsheet.ex`, update `load_framework_tool/2`:

Tool description change:
```
"Load a framework from the database into the spreadsheet. " <>
  "By default replaces current content. Set append=true to add rows " <>
  "to existing spreadsheet (for loading multiple roles together)."
```

Add to `parameter_schema` after `framework_id`:
```elixir
            append: [
              type: :boolean,
              required: false,
              doc: "If true, append rows to existing spreadsheet instead of replacing. Default: false."
            ]
```

In the execute function, extract `append` and pass it in the message:
```elixir
        append = args["append"] == true
```

Change the send line:
```elixir
                send(pid, {:load_framework_rows, rows, framework, append: append})
                {:ok, "Loaded '#{framework.name}' — #{length(rows)} rows#{if append, do: " (appended)", else: ""}"}
```

- [ ] **Step 2: Add append parameter to `load_framework_roles_tool`**

Same pattern. Update description:
```
"Load specific roles from a framework into the spreadsheet. Use after " <>
  "search_framework_roles — pass exact role names from the search results. " <>
  "By default replaces current content. Set append=true to add to existing rows."
```

Add same `append` parameter to schema. Extract `append = args["append"] == true` in execute. Update send:
```elixir
                send(pid, {:load_framework_rows, rows, framework, append: append})
```

Update success message similarly.

- [ ] **Step 3: Run tests**

Run: `mix test test/rho/mounts/spreadsheet_load_test.exs -v`
Expected: PASS — both tools now have `append` parameter

- [ ] **Step 4: Run full compile check**

Run: `mix compile --warnings-as-errors`
Expected: Clean

- [ ] **Step 5: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add append parameter to load_framework and load_framework_roles tools"
```

---

### Task 3: Remove Dead Assigns

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex:51-52`

- [ ] **Step 1: Remove dead assigns from mount**

In `lib/rho_web/live/spreadsheet_live.ex`, delete these two lines from `mount/3` (around lines 51-52):
```elixir
      |> assign(:loaded_framework_id, nil)
      |> assign(:loaded_framework_name, nil)
```

- [ ] **Step 2: Verify no other code reads these assigns**

Run: `mix compile --warnings-as-errors`
Expected: Clean compile (these assigns are write-only, never read)

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex
git commit -m "chore: remove dead loaded_framework_id/name assigns"
```

---

### Task 4: Company View — SkillStore Query

**Files:**
- Modify: `lib/rho/skill_store.ex`
- Test: `test/rho/mounts/spreadsheet_load_test.exs`

The company view computes a cross-role summary: total roles, total unique skills, shared skills across roles. It queries all `is_default=true` company frameworks and their rows.

- [ ] **Step 1: Write the failing test**

Add to `test/rho/mounts/spreadsheet_load_test.exs`:

```elixir
  describe "get_company_view tool" do
    test "tool is present in tools list" do
      context = make_context("test_company_view")
      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "get_company_view" in tool_names
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rho/mounts/spreadsheet_load_test.exs -v`
Expected: FAIL — `"get_company_view"` not in tool names

- [ ] **Step 3: Add `get_company_view/1` to SkillStore**

In `lib/rho/skill_store.ex`, add after `get_company_roles_summary/1` (around line 257):

```elixir
  def get_company_view(company_id) do
    # Get all default company frameworks
    frameworks =
      from(f in Framework,
        where: f.company_id == ^company_id and f.type == "company" and f.is_default == true,
        order_by: [asc: f.role_name]
      )
      |> Repo.all()

    if frameworks == [] do
      %{
        company: company_id,
        total_roles: 0,
        total_unique_skills: 0,
        roles: [],
        shared_skills: [],
        shared_count: 0
      }
    else
      framework_ids = Enum.map(frameworks, & &1.id)

      # Get all rows for default frameworks
      rows =
        from(r in FrameworkRow,
          where: r.framework_id in ^framework_ids,
          select: %{
            framework_id: r.framework_id,
            skill_name: r.skill_name,
            category: r.category
          },
          distinct: [r.framework_id, r.skill_name]
        )
        |> Repo.all()

      # Group skills by framework_id
      skills_by_framework =
        rows
        |> Enum.group_by(& &1.framework_id)
        |> Map.new(fn {fid, rs} -> {fid, MapSet.new(rs, & &1.skill_name)} end)

      # Build role summaries
      roles =
        Enum.map(frameworks, fn f ->
          skills = Map.get(skills_by_framework, f.id, MapSet.new())

          %{
            role: f.role_name,
            year: f.year,
            version: f.version,
            skill_count: MapSet.size(skills)
          }
        end)

      # Find shared skills (present in ALL roles)
      all_skill_sets = Map.values(skills_by_framework)

      shared_skills =
        case all_skill_sets do
          [] ->
            []

          [first | rest] ->
            Enum.reduce(rest, first, &MapSet.intersection/2)
            |> MapSet.to_list()
            |> Enum.sort()
        end

      all_unique_skills =
        all_skill_sets
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)
        |> MapSet.size()

      %{
        company: company_id,
        total_roles: length(frameworks),
        total_unique_skills: all_unique_skills,
        roles: roles,
        shared_skills: shared_skills,
        shared_count: length(shared_skills)
      }
    end
  end
```

- [ ] **Step 4: Run compile**

Run: `mix compile --warnings-as-errors`
Expected: Clean

- [ ] **Step 5: Commit**

```bash
git add lib/rho/skill_store.ex test/rho/mounts/spreadsheet_load_test.exs
git commit -m "feat: add get_company_view query to SkillStore"
```

---

### Task 5: Company View — Spreadsheet Tool

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex` — add `get_company_view_tool/1` and register in `tools/2`

- [ ] **Step 1: Add `get_company_view_tool` function**

In `lib/rho/mounts/spreadsheet.ex`, add after `get_company_overview_tool/1`:

```elixir
  defp get_company_view_tool(context) do
    %{
      tool:
        ReqLLM.tool(
          name: "get_company_view",
          description:
            "Get a computed cross-role summary of the company's skill framework. " <>
              "Shows total roles, total unique skills, shared skills across all roles, " <>
              "and per-role breakdowns. Uses default versions only.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        company_id = context.opts[:company_id]

        if is_nil(company_id) or company_id == "" do
          {:error, "No company specified. Open with ?company=your_company to use this tool."}
        else
          view = Rho.SkillStore.get_company_view(company_id)
          {:ok, Jason.encode!(view, pretty: true)}
        end
      end
    }
  end
```

- [ ] **Step 2: Register in `tools/2`**

In `lib/rho/mounts/spreadsheet.ex`, add `get_company_view_tool(context)` to the tools list (line ~59, after `get_company_overview_tool(context)`):

```elixir
      get_company_overview_tool(context),
      get_company_view_tool(context),
      switch_view_tool(context)
```

- [ ] **Step 3: Run tests**

Run: `mix test test/rho/mounts/spreadsheet_load_test.exs -v`
Expected: PASS — `"get_company_view"` now in tool names

- [ ] **Step 4: Run full test suite**

Run: `mix test`
Expected: All passing

- [ ] **Step 5: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add get_company_view tool for cross-role summary"
```

---

### Task 6: Update SKILL.md and Persistence Workflow

**Files:**
- Modify: `.agents/skills/framework-editor/SKILL.md`
- Modify: `.agents/skills/framework-editor/references/persistence-workflow.md`

- [ ] **Step 1: Update SKILL.md**

In `.agents/skills/framework-editor/SKILL.md`, update the intent detection table — add after the "Load company" row:

```markdown
| "Load both Data Scientist and Risk Analyst" / "Show all roles together" | **Multi-load** | `get_company_overview` → user picks roles → `load_framework(id)` for first, then `load_framework(id, append: true)` for rest. Switch to Role view. |
| "Show company view" / "Summary across all roles" | **Company view** | Call `get_company_view` → present cross-role summary (total roles, shared skills, per-role breakdowns) |
```

In the "Available Tools" → "Persistence" section, update `load_framework` and `load_framework_roles` descriptions:

```markdown
- `load_framework` — load a framework into the spreadsheet (replaces content by default, set `append: true` to add to existing rows)
- `load_framework_roles` — load only specific roles from a framework (replaces by default, set `append: true` to add to existing rows)
- `get_company_view` — computed cross-role summary: total roles, unique skills, shared skills across all default versions
```

- [ ] **Step 2: Update persistence-workflow.md**

In `.agents/skills/framework-editor/references/persistence-workflow.md`, add a new section after "Load Flow":

```markdown
## Multi-Role Load (Append Mode)

1. User says "load Data Scientist and Risk Analyst together" or "show all our roles"
2. Call `get_company_overview` → present available roles
3. For the first role: `load_framework(id)` (replaces)
4. For each additional role: `load_framework(id, append: true)` (adds to existing)
5. Switch to Role view: `switch_view(mode: "role")`
6. Confirm: "Loaded 2 roles — 280 rows total. Viewing by role."

## Company View

1. User says "show company view" or "summary across all roles"
2. Call `get_company_view` → returns computed summary
3. Present: total roles, unique skills, shared skills, per-role breakdowns
4. This is read-only — doesn't change the spreadsheet
```

- [ ] **Step 3: Commit**

```bash
git add .agents/skills/framework-editor/SKILL.md .agents/skills/framework-editor/references/persistence-workflow.md
git commit -m "docs: update SKILL.md and persistence workflow for append mode + company view"
```

---

### Task 7: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All passing

- [ ] **Step 2: Run compile check**

Run: `mix compile --warnings-as-errors`
Expected: Clean

- [ ] **Step 3: Verify tool registration**

Quick sanity check — start an IEx session:
```bash
mix run -e '
  ctx = %{session_id: "check", agent_id: "a", workspace: "/tmp", agent_name: :spreadsheet, opts: %{company_id: "test", is_admin: false}}
  tools = Rho.Mounts.Spreadsheet.tools([], ctx)
  names = Enum.map(tools, & &1.tool.name)
  IO.inspect(names, label: "tools")
  IO.puts("append tools ok: #{("load_framework" in names) and ("get_company_view" in names)}")
'
```
Expected: `append tools ok: true`

- [ ] **Step 4: Final commit if any loose changes**

```bash
git status
```
