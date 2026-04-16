# merge_roles Tool — Server-Side Role Consolidation

**Date:** 2026-04-07
**Branch:** `skill_framework`
**Context:** Scenario 2 tape review showed the LLM doing algorithmic dedup by staring at JSON — 10+ get_table calls, missed duplicates, multi-pass renames. Need a deterministic tool.

---

## Problem

When a user loads two roles from an industry framework and wants to merge them into one (e.g., Credit Risk + Risk Modelling → Risk Analyst), the agent currently:
1. Calls `get_table` 10+ times to read all rows
2. Tries to visually identify duplicates from JSON
3. Misses duplicates, needs user to point them out
4. Deletes in multiple passes, renames in multiple passes
5. Burns ~200k+ tokens on what is a simple set operation

## Solution

A two-phase `merge_roles` tool in `spreadsheet.ex` that operates on in-memory `rows_map`.

---

## Tool Design

### Phase 1: Plan

```
merge_roles(
  primary_role: "Credit Risk",
  secondary_role: "Risk Modelling and Validation",
  new_role_name: "Risk Analyst",
  mode: "plan"
)
```

**Server-side logic (no LLM):**
1. Read all rows from `rows_map` in the LiveView process
2. Group rows by `{role, skill_name}` to get unique skills per role
3. Categorize:
   - **Shared skills** — `skill_name` exists in both roles. Keep primary's rows, mark secondary's for deletion.
   - **Primary-only** — skills only in primary role. Keep as-is.
   - **Secondary-only** — skills only in secondary role. Candidates to keep (user decides).
4. Return JSON plan:

```json
{
  "primary_role": "Credit Risk",
  "secondary_role": "Risk Modelling and Validation",
  "new_role_name": "Risk Analyst",
  "shared_skills": ["Critical Thinking", "Problem-Solving", "Risk Management"],
  "shared_count": 22,
  "primary_only": ["Credit Scoring", "Loan Portfolio Analysis"],
  "primary_only_count": 5,
  "secondary_only": ["Model Validation", "Backtesting", "Stress Testing"],
  "secondary_only_count": 7,
  "rows_to_delete": 110,
  "rows_to_keep": 175,
  "rows_after_merge": 175
}
```

Agent presents this to user: "I'll keep 22 shared skills from Credit Risk, keep 5 Credit Risk-only skills, and propose 7 unique skills from Risk Modelling. 110 duplicate rows will be removed. All rows renamed to Risk Analyst. Want to proceed, or exclude any secondary-only skills?"

### Phase 2: Execute

```
merge_roles(
  primary_role: "Credit Risk",
  secondary_role: "Risk Modelling and Validation",
  new_role_name: "Risk Analyst",
  mode: "execute",
  exclude_skills: "[\"Model Validation\"]"   # optional — skills from secondary_only to drop
)
```

**Server-side logic:**
1. Re-compute the same grouping (rows_map may have changed between plan and execute)
2. Collect IDs to delete: all secondary-role rows where `skill_name` exists in primary role
3. If `exclude_skills` provided: also collect IDs for those secondary-only skills
4. Delete all collected rows via single `publish_spreadsheet_event(:rows_delta, %{op: :delete})`
5. Rename all remaining rows to `new_role_name` via `publish_spreadsheet_event(:rows_delta, %{op: :update})`
6. Return summary:

```json
{
  "deleted_rows": 115,
  "renamed_rows": 170,
  "final_skill_count": 29,
  "final_row_count": 170,
  "new_role_name": "Risk Analyst"
}
```

---

## Interaction with Existing Tools

- `merge_roles(mode: "plan")` is read-only — no mutations
- `merge_roles(mode: "execute")` mutates rows_map via events (same mechanism as `delete_rows` + `update_cells`)
- Between plan and execute, user can still use `delete_rows` to manually remove specific skills they don't want
- After merge, user can use `update_cells`, `add_rows` etc. for further edits
- `save_framework` works as before after merge

## SKILL.md Update

Update the Consolidate intent row to reference the tool:

```
| "Merge these roles" / "Consolidate" / "Remove duplicates across roles" | **Consolidate** | Call `merge_roles(mode: "plan")` to get merge plan. Present plan to user. On approval, call `merge_roles(mode: "execute")`. If user wants to exclude specific skills, pass them in `exclude_skills`. |
```

## What This Replaces

- LLM scanning JSON for duplicates (10+ `get_table` calls)
- Partial deletes that miss rows
- Multi-pass rename operations
- The entire "eyeball dedup" anti-pattern

## Files to Change

| File | Action |
|------|--------|
| `lib/rho/mounts/spreadsheet.ex` | Add `merge_roles_tool` with plan/execute modes |
| `lib/rho_web/live/spreadsheet_live.ex` | Add `handle_info` for `:spreadsheet_merge_roles` message |
| `.agents/skills/framework-editor/SKILL.md` | Update Consolidate intent to reference `merge_roles` tool |
| `test/rho/mounts/spreadsheet_merge_test.exs` | Tests for plan + execute logic |
