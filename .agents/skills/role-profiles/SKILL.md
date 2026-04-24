---
name: role-profiles
description: Workflow for creating and cloning role profiles (requires an existing library)
uses: [analyze_role, browse_library]
---

## Role Profile Workflows

Role profiles use the `role_profile` table and require an existing skill library.

### Path (a) — New role profile

browse_library → manage_role(action: "start_draft") → add_rows(table: "role_profile") → manage_role(action: "save")

1. **Browse** — call `browse_library` to show available skills from the library.
2. **Start draft** — call `manage_role(action: "start_draft")` to initialize a role profile.
3. **Add skills** — call `add_rows(table: "role_profile")` with selected skills and required levels.
4. **Save** — call `manage_role(action: "save")` to persist.

### Path (b) — Clone an existing role

analyze_role(action: "find_similar") → manage_role(action: "clone") → edit → manage_role(action: "save")

1. **Find similar** — call `analyze_role(action: "find_similar")` to find roles to base the new one on.
2. **Clone** — call `manage_role(action: "clone")` to copy an existing role as a starting point.
3. **Edit** — modify skills, levels, or metadata as needed.
4. **Save** — call `manage_role(action: "save")` to persist.
