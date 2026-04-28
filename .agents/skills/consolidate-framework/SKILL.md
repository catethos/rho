---
name: consolidate-framework
description: Workflow for deduplicating and consolidating skills within a library
uses: [dedup_library]
---

## Consolidate Framework Workflow

Path: dedup_library(action: "report") → review duplicate pairs → save_framework

### Steps

1. **Report duplicates** — call `dedup_library(action: "report")` to identify duplicate/overlapping skills.
2. **Review pairs** — present the duplicate pairs to the user and discuss which to merge/remove.
3. **Apply changes** — make the consolidation edits.
4. **Save** — call `save_framework` to persist.
