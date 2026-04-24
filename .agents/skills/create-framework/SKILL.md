---
name: create-framework
description: Workflow for creating a new skill framework from scratch (analyze → create → approve → generate proficiency levels → save)
uses: [analyze_role]
---

## Create Skill Framework Workflow

Path: analyze_role(action: "find_similar") → review existing → manage_library(action: "create") → present skeleton → ⏸ USER APPROVAL → save_library(action: "generate") → await_all → save_library(action: "save")

### Steps

1. **Analyze existing** — call `analyze_role(action: "find_similar")` to find related frameworks that might inform the new one.
2. **Show connections** — if matches found, explain how they inform the new library's structure.
3. **Create skeleton** — call `manage_library(action: "create")` with categories, clusters, and skills.
4. **Present for approval** — show the full skeleton (categories, clusters, skill names, descriptions) and ask "Ready to generate proficiency levels?"
5. **Generate levels** — ONLY after explicit user approval, call `save_library(action: "generate")`.
6. **Await completion** — call `await_all` to wait for proficiency writers to finish.
7. **Save** — offer `save_library(action: "save")` to persist.

### Rules

- NEVER call `save_library(action: "generate")` without presenting the full skeleton and receiving explicit approval.
- 8-12 skills per framework, 3-6 MECE categories, 1-3 clusters each.
- Skill descriptions: 1 sentence defining the competency boundary.
- Reuse skill names from existing libraries when relevant.
- After generate + await_all, offer save. Do NOT verify with data table tools — the user sees the table.
