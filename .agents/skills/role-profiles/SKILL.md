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

analyze_role(action: "find_similar") → user picks rows in `role_candidates` tab → manage_role(action: "clone") → edit → manage_role(action: "save")

1. **Find similar** — call `analyze_role(action: "find_similar", query: "<role-name>")` (or `queries_json` for multiple roles). Results land in the `role_candidates` data-table tab grouped by query — NOT enumerated in chat. To restrict to a specific library (e.g. ESCO), pass `library_id: "<library-uuid>"` (get via `manage_library(action: "list")` first).
2. **Wait for the user to check the rows they want** in the `role_candidates` tab. Tell them how many matches landed; do not enumerate.
3. **Clone** — call `manage_role(action: "clone", role_profile_ids_json: "[\"<uuid>\"]")` with the role UUIDs the user picked. (You can read the picked UUIDs from the data-table plugin's prompt section, which lists the user's currently-selected rows.) Multiple UUIDs union skills from several roles.
4. **Edit** — modify skills, levels, or metadata as needed.
5. **Save** — call `manage_role(action: "save")` to persist.

### Building a NEW library from picked roles

If the user wants the picked roles' skills assembled into a new SKILL
LIBRARY (not a role profile) — e.g. "combine Risk Analyst and Compliance
Officer from ESCO into one framework" — that flow lives in
`create-framework` Path D, not here. Use this skill for role profiles;
switch to `create-framework` for libraries.
