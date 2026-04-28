---
name: create-framework
description: Workflow for creating a new skill framework from scratch (analyze → create → approve → generate proficiency levels → save)
uses: [analyze_role]
---

## Create Skill Framework Workflow

Path: load_similar_roles → review existing → generate_framework_skeletons → present skeleton → ⏸ USER APPROVAL → generate_proficiency → save_framework

### Steps

1. **Find similar** — call `load_similar_roles` (intake-style fields) to surface related role profiles that might inform the new framework.
2. **Show connections** — if matches found, explain how they inform the new library's structure.
3. **Generate skeleton** — call `generate_framework_skeletons` with name/description (and optional domain/target_roles/skill_count/similar_role_skills). Returns an async agent_id; the data table populates as rows stream in.
4. **Present for approval** — once the skeleton finishes streaming, show the full result (categories, clusters, skill names, descriptions) and ask "Ready to generate proficiency levels?"
5. **Generate levels** — ONLY after explicit user approval, call `generate_proficiency` with `table_name: "library:<framework name>"` and `levels:` (default 5). This call **blocks until all category writers finish** (~30–60s) and returns a single summary. Do not call `await_all` after — the workers are already done.
6. **Save** — offer `save_framework` to persist.

### Rules

- NEVER call `generate_proficiency` without presenting the full skeleton and receiving explicit approval.
- 8-12 skills per framework, 3-6 MECE categories, 1-3 clusters each.
- Skill descriptions: 1 sentence defining the competency boundary.
- Reuse skill names from existing libraries when relevant.
- After generate + await_all, offer save. Do NOT verify with data table tools — the user sees the table.

### Anti-patterns (do NOT do these)

- ❌ `load_library` after `generate_framework_skeletons` — the skeleton rows are already in the `library:<name>` table. `load_library` reads from the DB, where the library does not exist yet, and will fail with "Library not found".
- ❌ `manage_library(action: "create")` before `save_framework` — `save_framework` looks up or creates the library by name automatically. Pre-creating produces an empty DB record and a duplicate-name conflict on save.
- ❌ Calling `generate_framework_skeletons` more than once for the same framework — re-running appends to the existing table; re-do only if the user explicitly asks to regenerate.
- ❌ `await_all` after `generate_proficiency` — the chat-side `generate_proficiency` already blocks until every category writer completes. Calling `await_all` afterward sends an empty `agent_ids` list and errors.
- ❌ Using `query_table` / `describe_table` to "verify" what was just generated — the user sees the table directly. Trust the tool's row-count response.
