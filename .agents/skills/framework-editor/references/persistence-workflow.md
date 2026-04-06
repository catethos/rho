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
