# Persistence Workflow

## Save Flow (Versioned)

1. User says "save this" or agent detects significant edits
2. Call `save_framework(mode: "plan", year: CURRENT_YEAR)` — returns:
   - Roles found in spreadsheet (grouped by role column)
   - For each role: `status: "new"` (first-ever → auto-default) or `status: "exists"` (update vs new version?)
   - Mismatches (rows with empty or unexpected role values)
3. **ALWAYS present the full plan to the user and WAIT for their response.** Do NOT call execute in the same turn as plan.
   - For `status: "new"`: "Data Scientist → 2026 v1 (new, will be default)"
   - For `status: "exists"`: **ASK the user**: "Data Engineer already exists (2026 v1, created Apr 9). Update it or create a new version (v2)?"
   - **Default to `action: "create"` (new version) unless user explicitly says "update" or "overwrite".**
   - **NEVER auto-choose "update" — overwriting destroys the previous version permanently.**
4. User confirms and makes choices for each existing role
5. Call `save_framework(mode: "execute", year: Y, decisions: "[...]")`
   - Each decision: `{"role_name": "X", "action": "create"|"update", "existing_id": N}`
   - Use `action: "create"` for new roles AND for existing roles where user chose "new version"
   - Use `action: "update"` ONLY when user explicitly said to overwrite
6. Confirm: "Saved 3 roles: Data Scientist 2026 v1 (default), Data Engineer 2026 v2 (draft), Product Manager 2026 v1 (default)"

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

## Set Default Version

1. User says "set Data Scientist 2026 v1 as default"
2. Call `get_company_overview` to find the framework ID
3. Call `set_default_version(framework_id)` — flips is_default in a transaction
4. Confirm: "Set Data Scientist 2026 v1 as default"

## When to Remind About Saving

- After generating a new framework (skeleton + proficiency levels done)
- After importing from a file
- After making 5+ edits in a session
- When user says "done" or "finished"
