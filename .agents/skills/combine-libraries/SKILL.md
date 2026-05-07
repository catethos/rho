---
name: combine-libraries
description: Workflow for merging multiple skill libraries into one (requires explicit user approval before committing)
uses: [combine_libraries]
---

## Combine Libraries Workflow

Path: **list UUIDs** → **save any workspace-only drafts** → `combine_libraries(commit: false)` → ⏸ PRESENT PREVIEW & WAIT FOR USER → `combine_libraries(commit: true, resolutions_json: "auto")`

### Pre-step: lookup UUIDs (REQUIRED)

`combine_libraries` requires saved-library UUIDs (not names). Before calling it:

0a. **List saved libraries** — `manage_library(action: "list")` returns each library with its UUID, e.g. `CEO (3213b761-...) — 7 skills, draft`.

0b. **Save any workspace-only drafts** — if the user wants to combine a library that exists only as a `library:<name>` table in the panel (not in the manage_library list), call `save_framework(table: "library:<name>")` first. Then re-list to get the new UUID.

### Steps

1. **Preview** — call `combine_libraries(source_library_ids_json: ["uuid-1", "uuid-2"], new_name: "...", commit: false)`. This populates a `combine_preview` table the user can SEE in the workspace. Each conflicting skill becomes a row with side-by-side A/B values and a Keep button.

2. **Present** — show the user a brief summary in chat: source libraries, total skill count, conflict count.
   - **Zero conflicts:** ask user to confirm and proceed to step 4.
   - **N conflicts:** tell the user *"I've put N conflicts in the `combine_preview` table — please click Keep A or Keep B on each row, then tell me to proceed."* Then WAIT.

3. **Wait for the user to resolve in the table.** Do NOT enumerate conflicts in chat or ask them to type resolutions — they'll click Keep buttons in the UI. When the user says they're done, move to step 4.

4. **Commit** — call `combine_libraries(commit: true, resolutions_json: "auto")`. The `"auto"` literal tells the tool to read resolution choices from the `combine_preview` table the user just filled out.

### CRITICAL

- NEVER auto-commit without user approval.
- NEVER ask the user to type out resolutions in chat — the table IS the resolution UI. Just say "resolve them in the table, then tell me to proceed."
- For zero-conflict merges, you can commit without `resolutions_json` — but it's harmless to pass `"auto"` anyway.
