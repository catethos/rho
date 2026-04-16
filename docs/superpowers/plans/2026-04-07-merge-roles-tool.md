# merge_roles Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `merge_roles` tool that deterministically merges two loaded roles into one, replacing LLM-driven dedup.

**Architecture:** Two-phase tool (plan/execute) in spreadsheet.ex. Plan phase reads rows_map via synchronous pid messaging to compute set differences. Execute phase publishes delete + update events via signal bus. No LLM calls — pure Elixir set operations.

**Tech Stack:** Elixir, signal bus (Comms.publish), LiveView pid messaging

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/rho/mounts/spreadsheet.ex` | Modify | Add `merge_roles_tool` + helper functions |
| `lib/rho_web/live/spreadsheet_live.ex` | Modify | Add `handle_info` for `:spreadsheet_merge_plan` message |
| `.agents/skills/framework-editor/SKILL.md` | Modify | Update Consolidate intent to reference `merge_roles` |
| `test/rho/mounts/spreadsheet_merge_test.exs` | Create | Test plan + execute logic |

---

### Task 1: Add LiveView handler for merge plan reads

The merge tool needs to read `rows_map` from the LiveView process. Add a synchronous handler following the same pattern as `get_table`.

**Files:**
- Modify: `lib/rho_web/live/spreadsheet_live.ex:267-271`

- [ ] **Step 1: Add the handler**

In `lib/rho_web/live/spreadsheet_live.ex`, after the existing `handle_info({:spreadsheet_get_table, ...})` handler (line 271), add:

```elixir
  def handle_info({:spreadsheet_merge_plan, {caller_pid, ref}, primary_role, secondary_role}, socket) do
    rows = Map.values(socket.assigns.rows_map)

    primary_skills =
      rows
      |> Enum.filter(&(&1[:role] == primary_role))
      |> Enum.group_by(&(&1[:skill_name]))

    secondary_skills =
      rows
      |> Enum.filter(&(&1[:role] == secondary_role))
      |> Enum.group_by(&(&1[:skill_name]))

    primary_skill_names = MapSet.new(Map.keys(primary_skills))
    secondary_skill_names = MapSet.new(Map.keys(secondary_skills))

    shared = MapSet.intersection(primary_skill_names, secondary_skill_names)
    primary_only = MapSet.difference(primary_skill_names, secondary_skill_names)
    secondary_only = MapSet.difference(secondary_skill_names, primary_skill_names)

    # IDs to delete: secondary rows where skill_name is shared with primary
    ids_to_delete =
      rows
      |> Enum.filter(fn row ->
        row[:role] == secondary_role and MapSet.member?(shared, row[:skill_name])
      end)
      |> Enum.map(& &1[:id])

    # IDs to rename: all rows that will remain (primary + secondary-only)
    ids_to_rename =
      rows
      |> Enum.filter(fn row ->
        row[:role] == primary_role or
          (row[:role] == secondary_role and MapSet.member?(secondary_only, row[:skill_name]))
      end)
      |> Enum.map(& &1[:id])

    plan = %{
      shared_skills: MapSet.to_list(shared) |> Enum.sort(),
      shared_count: MapSet.size(shared),
      primary_only: MapSet.to_list(primary_only) |> Enum.sort(),
      primary_only_count: MapSet.size(primary_only),
      secondary_only: MapSet.to_list(secondary_only) |> Enum.sort(),
      secondary_only_count: MapSet.size(secondary_only),
      rows_to_delete: length(ids_to_delete),
      rows_to_rename: length(ids_to_rename),
      rows_after_merge: length(ids_to_rename),
      delete_ids: ids_to_delete,
      rename_ids: ids_to_rename
    }

    send(caller_pid, {ref, {:ok, plan}})
    {:noreply, socket}
  end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: clean compilation.

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/live/spreadsheet_live.ex
git commit -m "feat: add spreadsheet_merge_plan handler in LiveView"
```

---

### Task 2: Implement merge_roles tool in spreadsheet.ex

**Files:**
- Modify: `lib/rho/mounts/spreadsheet.ex:38-55` (tool list), append new functions

- [ ] **Step 1: Add tool to the tools list**

In `lib/rho/mounts/spreadsheet.ex`, in the `tools/2` function, add `merge_roles_tool(session_id, context)` after `delete_rows_tool(context)` (around line 49):

```elixir
      delete_rows_tool(context),
      merge_roles_tool(session_id, context),
      replace_all_tool(context),
```

- [ ] **Step 2: Implement the tool**

Add this function after `delete_rows_tool` (after line 610):

```elixir
  defp merge_roles_tool(session_id, context) do
    agent_id = context[:agent_id]

    %{
      tool:
        ReqLLM.tool(
          name: "merge_roles",
          description:
            "Merge two roles into one. Use mode 'plan' first to see the merge plan, " <>
              "then mode 'execute' to apply it. The primary role's skills are kept for " <>
              "shared skills; unique secondary skills are added. All rows renamed to new_role_name.",
          parameter_schema: [
            primary_role: [
              type: :string,
              required: true,
              doc: "The role to keep as the base (its proficiency levels are preferred for shared skills)"
            ],
            secondary_role: [
              type: :string,
              required: true,
              doc: "The role to merge in (duplicates removed, unique skills kept)"
            ],
            new_role_name: [
              type: :string,
              required: true,
              doc: "Name for the merged role, e.g. 'Risk Analyst'"
            ],
            mode: [
              type: :string,
              required: true,
              doc: "Either 'plan' (preview changes) or 'execute' (apply changes)"
            ],
            exclude_skills: [
              type: :string,
              required: false,
              doc: "JSON array of secondary-only skill names to exclude from merge, e.g. [\"Model Validation\"]"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        primary_role = args["primary_role"] || ""
        secondary_role = args["secondary_role"] || ""
        new_role_name = args["new_role_name"] || ""
        mode = args["mode"] || "plan"

        exclude =
          case Jason.decode(args["exclude_skills"] || "[]") do
            {:ok, list} when is_list(list) -> MapSet.new(list)
            _ -> MapSet.new()
          end

        if primary_role == "" or secondary_role == "" or new_role_name == "" do
          {:error, "primary_role, secondary_role, and new_role_name are all required"}
        else
          case mode do
            "plan" ->
              execute_merge_plan(session_id, primary_role, secondary_role, new_role_name)

            "execute" ->
              execute_merge(session_id, agent_id, primary_role, secondary_role, new_role_name, exclude)

            _ ->
              {:error, "mode must be 'plan' or 'execute'"}
          end
        end
      end
    }
  end

  defp execute_merge_plan(session_id, primary_role, secondary_role, new_role_name) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:spreadsheet_merge_plan, {self(), ref}, primary_role, secondary_role})

      receive do
        {^ref, {:ok, plan}} ->
          # Return plan without internal IDs — agent doesn't need them
          result = %{
            primary_role: primary_role,
            secondary_role: secondary_role,
            new_role_name: new_role_name,
            shared_skills: plan.shared_skills,
            shared_count: plan.shared_count,
            primary_only: plan.primary_only,
            primary_only_count: plan.primary_only_count,
            secondary_only: plan.secondary_only,
            secondary_only_count: plan.secondary_only_count,
            rows_to_delete: plan.rows_to_delete,
            rows_to_keep: plan.rows_after_merge,
            rows_after_merge: plan.rows_after_merge
          }

          {:ok, Jason.encode!(result)}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end

  defp execute_merge(session_id, agent_id, primary_role, secondary_role, new_role_name, exclude) do
    with_pid(session_id, fn pid ->
      ref = make_ref()
      send(pid, {:spreadsheet_merge_plan, {self(), ref}, primary_role, secondary_role})

      receive do
        {^ref, {:ok, plan}} ->
          # Additional IDs to delete: excluded secondary-only skills
          exclude_ids =
            if MapSet.size(exclude) > 0 do
              # Re-read rows to find IDs of excluded skills
              ref2 = make_ref()
              send(pid, {:spreadsheet_get_table, {self(), ref2}, nil})

              receive do
                {^ref2, {:ok, rows}} ->
                  rows
                  |> Enum.filter(fn row ->
                    row[:role] == secondary_role and MapSet.member?(exclude, row[:skill_name])
                  end)
                  |> Enum.map(& &1[:id])
              after
                5_000 -> []
              end
            else
              []
            end

          all_delete_ids = plan.delete_ids ++ exclude_ids

          # 1. Delete duplicate + excluded rows
          if all_delete_ids != [] do
            publish_spreadsheet_event(session_id, agent_id, :delete_rows, %{ids: all_delete_ids})
          end

          # 2. Rename remaining rows to new_role_name
          rename_ids = plan.rename_ids -- exclude_ids

          if rename_ids != [] do
            changes =
              Enum.map(rename_ids, fn id ->
                %{"id" => id, "field" => "role", "value" => new_role_name}
              end)

            publish_spreadsheet_event(session_id, agent_id, :update_cells, %{changes: changes})
          end

          final_count = length(rename_ids)
          deleted_count = length(all_delete_ids)

          # Count unique skills remaining
          skill_count =
            plan.primary_only_count + plan.shared_count +
              (plan.secondary_only_count - MapSet.size(exclude))

          {:ok,
           Jason.encode!(%{
             deleted_rows: deleted_count,
             renamed_rows: final_count,
             final_skill_count: skill_count,
             final_row_count: final_count,
             new_role_name: new_role_name
           })}
      after
        5_000 -> {:error, "Spreadsheet did not respond in time"}
      end
    end)
  end
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: clean compilation.

- [ ] **Step 4: Commit**

```bash
git add lib/rho/mounts/spreadsheet.ex
git commit -m "feat: add merge_roles tool with plan/execute modes

Deterministic role merging via set operations on rows_map.
Plan mode returns shared/unique skills breakdown.
Execute mode deletes duplicates and renames remaining rows.
Supports exclude_skills to drop specific secondary-only skills."
```

---

### Task 3: Write tests for merge_roles

**Files:**
- Create: `test/rho/mounts/spreadsheet_merge_test.exs`

- [ ] **Step 1: Create test file**

```elixir
defmodule Rho.Mounts.SpreadsheetMergeTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "merge_roles tool" do
    test "tool is present in tools list" do
      context = %{
        session_id: "test_merge",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "merge_roles" in tool_names
    end

    test "rejects empty required fields" do
      context = %{
        session_id: "test_merge",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "merge_roles" end)

      result = tool.execute.(%{"primary_role" => "", "secondary_role" => "B", "new_role_name" => "C", "mode" => "plan"})
      assert {:error, _} = result
    end

    test "rejects invalid mode" do
      context = %{
        session_id: "test_merge",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "merge_roles" end)

      result = tool.execute.(%{"primary_role" => "A", "secondary_role" => "B", "new_role_name" => "C", "mode" => "invalid"})
      assert {:error, "mode must be 'plan' or 'execute'"} = result
    end
  end
end
```

- [ ] **Step 2: Run tests**

Run: `mix test test/rho/mounts/spreadsheet_merge_test.exs --trace`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add test/rho/mounts/spreadsheet_merge_test.exs
git commit -m "test: add merge_roles tool tests"
```

---

### Task 4: Update SKILL.md Consolidate intent

**Files:**
- Modify: `.agents/skills/framework-editor/SKILL.md`

- [ ] **Step 1: Update the Consolidate intent row**

Find the Consolidate row in the intent detection table (added in a previous commit):

```markdown
| "Merge these roles" / "Consolidate" / "Remove duplicates across roles" | **Consolidate** | Use spreadsheet tools directly: `get_table` to read, identify duplicates, `delete_rows` to remove, `update_cells` to rename. Do NOT delegate. |
```

Replace with:

```markdown
| "Merge these roles" / "Consolidate" / "Remove duplicates across roles" | **Consolidate** | Ask user which role is primary (base). Call `merge_roles(mode: "plan")` to get merge plan. Present shared/unique skills breakdown to user. On approval, call `merge_roles(mode: "execute")`. If user wants to exclude specific secondary-only skills, pass them in `exclude_skills`. |
```

- [ ] **Step 2: Commit**

```bash
git add .agents/skills/framework-editor/SKILL.md
git commit -m "docs: update Consolidate intent to reference merge_roles tool"
```

---

### Task 5: Integration verification

**Files:** None — verification only.

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 2: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Verify tool shows up**

Start server and verify `merge_roles` appears in tools:

```bash
RHO_WEB_ENABLED=true mix phx.server
```

Then test that the spreadsheet session has the merge_roles tool by checking the agent's available tools.

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | LiveView handler for merge plan reads | `spreadsheet_live.ex` |
| 2 | merge_roles tool (plan + execute) | `spreadsheet.ex` |
| 3 | Tests | `spreadsheet_merge_test.exs` |
| 4 | Update SKILL.md Consolidate intent | `SKILL.md` |
| 5 | Integration verification | None |
