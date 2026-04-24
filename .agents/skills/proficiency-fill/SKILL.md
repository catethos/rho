---
name: proficiency-fill
description: Workflow for generating proficiency levels for skills added or edited after the initial skeleton was saved
---

## Ad-hoc Proficiency Fill Workflow

Use when the user has edited or added skills after the skeleton was saved and needs proficiency levels generated for them.

Path: delegate_task_lite(role: "proficiency_writer", task: "...") → await_task

### Steps

1. **Delegate** — call `delegate_task_lite(role: "proficiency_writer", task: "...")` with the category, skills, and level count.
2. **Await** — call `await_task` to wait for the proficiency writer to finish.

### CRITICAL: table name in task prompt

The task prompt MUST end with: `Pass table: "library:<framework>"` to `add_proficiency_levels`.

Use the exact library table name from the earlier `manage_library(action: "create")` or `load_library` response. Omitting this makes the writer default to the bare "library" table and skip the skeleton.
