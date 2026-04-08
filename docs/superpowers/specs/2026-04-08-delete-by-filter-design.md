# delete_by_filter Tool

**Date:** 2026-04-08
**Branch:** `skill_framework`

---

## Problem

Agent calls `get_table` (returns ALL rows as JSON) to find row IDs for deletion. This bloats LLM context, causes DeepSeek v3.1 structured output failures (garbage token output), and wastes turns. "Delete all Power Skills" should be one tool call, not 6+ get_table calls followed by a delete_rows call.

## Solution

New `delete_by_filter` tool in `spreadsheet.ex`. Single-field filter, server-side delete. No new LiveView handlers — reuses existing patterns.

---

## Tool Design

```
delete_by_filter(field: "category", value: "Power Skills")
```

**Server-side logic:**
1. Send `{:spreadsheet_get_table, filter}` to LiveView (existing handler) → gets matching rows with IDs
2. Extract IDs from matching rows
3. Publish `publish_spreadsheet_event(:delete_rows, %{ids: [...]})` (existing signal)
4. Return: `"Deleted 75 row(s) where category = 'Power Skills' (15 skills removed)"`

**Parameters:**
- `field` (string, required) — column name to filter by (e.g., "category", "skill_name", "role", "cluster")
- `value` (string, required) — value to match

**Returns:** summary with row count and unique skill count removed.

**Error cases:**
- No matching rows: `"No rows found where category = 'Power Skills'"`
- Empty field/value: `"field and value are required"`

## Files to Change

| File | Action |
|------|--------|
| `lib/rho/mounts/spreadsheet.ex` | Add `delete_by_filter_tool` to tools list + implement |
| `.agents/skills/framework-editor/SKILL.md` | Add to Available Tools section |
| `test/rho/mounts/spreadsheet_delete_filter_test.exs` | Test tool presence + empty params rejection |
