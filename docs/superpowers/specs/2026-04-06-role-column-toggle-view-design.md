# Role Column + Toggle View — Design Spec

## Problem

The spreadsheet editor has no concept of roles. When a user builds skill frameworks role-by-role, all skills go into a flat Category → Cluster grouping. There's no way to see "which skills belong to Data Analyst" vs "which skills belong to Data Engineer." This mirrors the production problem where role-skill links are lost when skills accumulate into the company framework.

## Solution

1. Add `role` column to the spreadsheet schema
2. Add a toggle in the toolbar: **"By Role"** / **"By Category"**
3. Agent auto-switches the view based on user intent
4. Smart defaults based on context

## Schema Change

```
Current:  id, category, cluster, skill_name, skill_description, level, level_name, level_description
New:      id, role, category, cluster, skill_name, skill_description, level, level_name, level_description
```

One row = one skill × one proficiency level × one role.

The `role` field:
- Set by the agent when generating/importing skills for a specific role
- Can be empty string `""` or `"Unassigned"` for company-wide skills without a role
- Editable by the user (inline click-to-edit, same as other fields)
- Used for grouping in Role view

## View Modes

### Role View (group by: role → category → cluster)

```
▼ Data Analyst (40 rows)
  ▼ Technical Skills (25 rows)
    ▸ Programming (10 rows)
    ▸ Analytics (15 rows)
  ▸ Communication (15 rows)
▼ Data Engineer (35 rows)
  ...
▸ Unassigned (0 rows)
```

Three-level nesting: role → category → cluster → table rows.

### Category View (group by: category → cluster, role shown as column)

```
▼ Technical Skills (50 rows)
  ▼ Programming (20 rows)
    ID  ROLE            SKILL    DESCRIPTION      LVL  ...
    1   Data Analyst    Python   Statistical...    1    ...
    11  Data Engineer   Python   Distributed...    1    ...
  ▸ Analytics (15 rows)
▸ Communication (25 rows)
```

Two-level nesting: category → cluster → table rows (with role column visible in the table).

## Files Changed

### Modified Files

| File | Change |
|------|--------|
| `lib/rho_web/live/spreadsheet_live.ex` | Add `view_mode` assign, toggle event handler, two grouping functions, updated render template |
| `lib/rho/mounts/spreadsheet.ex` | Add `role` to prompt section, row format docs, `build_summary` includes roles |
| `lib/rho_web/inline_css.ex` | Toggle button styles, role group header styles, role tag in category view |
| `.agents/skills/framework-editor/SKILL.md` | Update intent table to set role field, add view switching instructions |
| `.agents/skills/framework-editor/references/generate-workflow.md` | Add: set `role` field on generated rows |
| `.agents/skills/framework-editor/references/import-workflow.md` | Add: extract role from uploaded file if available |

### No New Files

All changes are modifications to existing files.

## Component Specifications

### 1. SpreadsheetLive — View Mode State

Add to `mount/3` assigns:

```elixir
|> assign(:view_mode, :role)  # :role or :category
```

Add event handler:

```elixir
def handle_event("switch_view", %{"mode" => mode}, socket) do
  view_mode = if mode == "category", do: :category, else: :role
  {:noreply, assign(socket, :view_mode, view_mode)}
end
```

### 2. SpreadsheetLive — Grouping Functions

The current `group_rows/1` groups by category → cluster. Add a new function for role view and make grouping mode-aware:

```elixir
defp group_rows(rows_map, :category) do
  # Current behavior: category → cluster → rows
  # Same as existing group_rows/1
  rows_map |> Map.values() |> Enum.sort_by(& &1[:id]) |> group_by_category()
end

defp group_rows(rows_map, :role) do
  # New: role → category → cluster → rows
  rows_map |> Map.values() |> Enum.sort_by(& &1[:id]) |> group_by_role()
end
```

`group_by_role/1` groups into three levels:

```elixir
defp group_by_role(rows) do
  rows
  |> Enum.group_by(fn row -> row[:role] || "Unassigned" end)
  |> Enum.sort_by(fn {role, _} -> if role == "Unassigned", do: "zzz", else: role end)
  |> Enum.map(fn {role, role_rows} ->
    categories = group_by_category(role_rows)
    {role, categories}
  end)
end
```

Rename existing `group_preserving_order/1` to `group_by_category/1` for clarity.

### 3. SpreadsheetLive — Render Template

Update `render/1`:

**Toolbar** — add toggle buttons after the cost display:

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

**Table area** — branch on `@view_mode`:

Role view adds an outer role group level wrapping the existing category → cluster → table structure.

Category view uses the existing category → cluster → table structure but adds a ROLE column to the table header and a role cell to each row.

### 4. SpreadsheetLive — Agent View Switching

The agent can switch the view by publishing a signal. Add a new signal type:

```elixir
# In SpreadsheetLive signal handler:
String.contains?(type, ".switch_view") ->
  mode = if data[:mode] == "category", do: :category, else: :role
  {:noreply, assign(socket, :view_mode, mode)}
```

The spreadsheet mount gets a new tool:

```elixir
# In Rho.Mounts.Spreadsheet
switch_view_tool(context) -> publishes switch_view signal with mode
```

This lets the agent say `switch_view(mode: "role")` after generating role-specific skills.

### 5. Spreadsheet Mount — Schema Updates

Update `prompt_sections/2`:

```
You have a spreadsheet with columns:
id, role, category, cluster, skill_name, skill_description, level, level_name, level_description.

The "role" field identifies which job role this skill belongs to.
- Set role when generating skills for a specific role (e.g., "Data Analyst")
- Leave empty or "Unassigned" for company-wide skills not tied to a role
- The user can toggle between "By Role" view and "By Category" view

Row format when adding rows:
{"role": "Data Analyst", "category": "...", "cluster": "...", ...}
```

Update `@known_fields`:

```elixir
@known_fields ~w(id role category cluster skill_name skill_description level level_name level_description)
```

Update `build_summary/1` to include role information:

```elixir
defp build_summary(rows) do
  roles = rows |> Enum.map(& &1[:role]) |> Enum.reject(&(&1 in [nil, "", "Unassigned"])) |> Enum.uniq()

  # ... existing category/cluster summary ...

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

### 6. Skill + Reference File Updates

**SKILL.md** — update intent detection to set role:

Add to shared rules:
```
## Role Assignment
- When user specifies a role (e.g., "build skills for Data Analyst"), set role="Data Analyst" on all generated rows
- When user doesn't specify a role (e.g., "build a company framework"), set role="" (empty)
- When importing a file with role data, preserve role assignments
- After generating role-specific skills, switch to Role view: switch_view(mode: "role")
- After importing a large library, switch to Category view: switch_view(mode: "category")
```

**generate-workflow.md** — add role field to skeleton generation:

```
When adding skeleton rows, include the role field:
{"role": "[role name or empty]", "category": "...", "cluster": "...", ...}
```

**import-workflow.md** — add role extraction:

```
When importing files:
- Check if the source has role/job information
- If yes: set role field per skill based on the mapping
- If no: set role="" (company-wide library)
- For industry frameworks with role-skill mapping matrices (like FSF):
  create one row per skill × role combination
```

### 7. CSS — Toggle and Role Group Styles

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

/* Role group (outermost level in role view) */
.ss-role-group { margin-bottom: 4px; }
.ss-role-header {
  font-size: 14px; font-weight: 600; padding: 6px 8px;
  background: rgba(31, 111, 235, 0.08); border-left: 3px solid var(--teal);
}

/* Role tag in category view */
.ss-role-tag {
  display: inline-block; font-size: 10px; padding: 1px 6px;
  background: rgba(31, 111, 235, 0.1); color: var(--teal);
  border-radius: 8px; margin-right: 4px;
}
```

## Smart Defaults — Agent Auto-Switching

The `switch_view` tool is called by the agent, not by complex server logic. The SKILL.md intent table tells the agent when to switch:

| User Action | Agent Sets View To | Why |
|-------------|-------------------|-----|
| "Build skills for Data Analyst" | Role | Building for a specific role |
| "Now add Data Engineer skills" | Role | Still role-by-role building |
| "Import this Excel" (large file) | Category | Overview of imported library |
| "Show me Data Analyst skills" | Role | Explicit role request |
| "Any duplicates?" | Category | Cross-role comparison |
| "Build a company framework" (no role) | Category | No roles to group by |

The agent reads the `get_table_summary` response which now includes `roles: [...]`. If roles exist, the agent can reference them. If no roles, Category view is the natural default.

## Backward Compatibility

- Existing rows without a `role` field: treated as `role: ""` (shown under "Unassigned" in Role view)
- Existing tools (`add_rows`, `replace_all`): `role` is optional. If omitted, defaults to `""`
- The `proficiency_writer` sub-agent doesn't need to know about roles — it generates proficiency levels for skills, the role is already set by the primary agent

## Scope

### In This Spec
- `role` column added to schema
- Toggle UI (By Role / By Category)
- `switch_view` tool for agent
- Updated grouping logic (3-level for role view)
- Updated prompt sections and skill reference files
- CSS for toggle and role groups

### Not In This Spec
- Connecting to collections API (storing to backend)
- Phase 2 role-skill selection UI (different product surface)
- Cross-session duplicate detection (requires API connection)
- Role management (create/edit/delete roles as entities)
