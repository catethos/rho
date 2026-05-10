---
name: consolidate-framework
description: Workflow for reviewing and resolving duplicate skills within a saved library
uses: [dedup_library, save_framework]
---

## Consolidate Framework Workflow

Path: dedup_library(library_id) → user reviews dedup_preview tab in UI → save_framework

### Steps

1. **Open the review panel** — call `dedup_library(library_id: "<uuid>")`. This detects candidate-duplicate pairs (cosine similarity + slug/word heuristics, optional cluster summary), writes them to the session's `dedup_preview` table, and opens the tab. The agent's response carries the pair count and (when available) a cluster digest the user can read for navigation.
2. **Wait for the user.** They review the rows in the data-table UI and set each row's `resolution` cell to `merge_a` (keep skill A, absorb B), `merge_b`, or `keep_both` (record as intentionally distinct). Do NOT enumerate pairs in chat. Do NOT call merge or dismiss tools per pair — those don't exist anymore; the resolution column IS the merge/dismiss interface.
3. **Apply on save.** When the user says "save" / "apply" / "done", call `save_framework(table: "library:<name>")`. The save step reads `dedup_preview`, applies merges/dismissals for resolved rows, then persists the cleaned library. Unresolved rows are skipped (kept as-is).

### Anti-patterns

- ❌ Listing the duplicate pairs in chat. The table is the source of truth — the agent's job is to surface the count and any cluster summary, not paraphrase the pair list.
- ❌ Calling per-pair merge or dismiss tools. They no longer exist. Edits happen in the `dedup_preview` `resolution` column.
- ❌ Re-running `dedup_library` while the user is mid-review. It overwrites the table and discards their picks.
