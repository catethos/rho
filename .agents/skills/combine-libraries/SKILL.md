---
name: combine-libraries
description: Workflow for merging multiple skill libraries into one (requires explicit user approval before committing)
uses: [combine_libraries]
---

## Combine Libraries Workflow

Path: combine_libraries(commit: false) → ⏸ PRESENT PREVIEW & WAIT FOR USER APPROVAL → combine_libraries(commit: true)

### Steps

1. **Preview** — call `combine_libraries(commit: false)` to see what will happen.
2. **Present** — show the user: source libraries, total skill count, any conflicts or overlaps.
3. **Wait for approval** — ask for explicit confirmation before proceeding.
4. **Commit** — ONLY after approval, call `combine_libraries(commit: true)`.

### CRITICAL

NEVER auto-commit. Always show the user what will happen (sources, skill count, conflicts) and ask for explicit confirmation.
