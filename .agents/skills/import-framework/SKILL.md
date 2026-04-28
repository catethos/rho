---
name: import-framework
description: Workflow for importing skill frameworks from standard templates (SFIA) or documents (PDF, Excel, Word)
---

## Import Skill Framework Workflow

### Path (a) — Standard template import

load_library(template_key: "sfia_v8") → ask user which categories → fork_library → edit → save_framework

1. **Load template** — call `load_library(template_key: "sfia_v8")` (or other template key).
2. **Select categories** — ask the user which categories/skills they want to keep.
3. **Fork** — call `fork_library` to create an editable copy.
4. **Edit** — make requested changes.
5. **Save** — call `save_framework` to persist.

Note: Immutable (standard) libraries cannot be edited directly — fork first.

### Path (b) — Document import

ingest_document → parse into skills → load into library table → save_framework

1. **Ingest** — call `ingest_document` with the file path.
2. **Parse** — extract skills, categories, clusters, and proficiency levels from the content.
3. **Load** — populate the library table with extracted data.
4. **Save** — call `save_framework` to persist.
