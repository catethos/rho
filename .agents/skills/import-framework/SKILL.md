---
name: import-framework
description: Workflow for LOADING an existing framework as a starting library — built-in templates (sfia_v8) or unstructured documents (PDF, Word). For Excel/CSV uploads, see the spreadsheet system prompt's "Uploaded files" section.
uses: [load_library, manage_library, save_framework, fork_library]
---

## Import Skill Framework Workflow

This skill is for LOADING a framework as your starting point — bringing
data into the workspace so you can customize and save it as your own.

For other framework-getting flows:
- **Excel/CSV upload** — handled by the spreadsheet system prompt's "Uploaded files" section (`import_library_from_upload`). Don't duplicate that flow here.
- **Use existing library as INSPIRATION (not loaded)** — that's `create-framework` Path C (`browse_library` + generate inspired skills).
- **Edit an already-saved org library** — that's `manage-frameworks`.

### Path (a) — Built-in template import (S1)

User signals: "load sfia_v8 and customize it", "start from the SFIA
template".

Only `sfia_v8` ships in `priv/templates/` today. If the user names a
different template (FSF / AICB / etc.) that isn't built in, suggest
either (a) `sfia_v8`, or (b) using an existing saved org library as the
starting point via `load_library(library_name: "<name>")`.

1. **Load template** — `load_library(template_key: "sfia_v8")`. Populates the `library:sfia_v8` workspace table with all skills.
2. **Review** — summarize what loaded (≤ 3 sentences: skill count, categories, clusters). Ask: "Want to keep everything or remove some skills/categories first? You can also rename the framework."
3. **Customize** — based on the user's response:
   - Remove categories/clusters: `delete_by_filter(table: "library:sfia_v8", field: "category", value: "...")` for bulk; `delete_rows` for specific IDs.
   - Edit cells: `update_cells` / `edit_row` per the system prompt's editing rules.
4. **Confirm before saving** — present what's left ("kept 4 of 6 categories, ~80 skills").
5. **Save** — `save_framework(table: "library:sfia_v8")`. Creates a new DB library record under the user's org, named `sfia_v8` by default. Saved as a DRAFT (see `manage-frameworks` for publish/version flow). The original built-in template is untouched.
   - To save under a different name, the agent first calls `manage_library(action: "create", name: "<new name>")` to make the target library, then `save_framework(library_id: "<new-uuid>", table: "library:sfia_v8")`.

Note: built-in templates are immutable. Loading them brings the data
into the workspace; saving creates a new mutable draft library record
under the user's control.

### Path (b) — Document import (PDF, Word, image)

User signals: "import this PDF", "extract the framework from this Word
doc".

1. **Read the upload summary** — the chat message contains a `[Uploaded: <filename>]` block with a "Detected:" line.
2. **PDF or image** — the spreadsheet system prompt's "Uploaded files" section says: delegate to `data_extractor` via `delegate_task(role: "data_extractor", task: "extract structured framework data from upload <id>")`, then `await_task` for the JSON. v1 has PDF parsing stubbed — surface a clear "v2 feature" message if the upload's "Detected:" line says "PDF detected" or "Image — passthrough only".
3. **Receive structured JSON** from data_extractor.
4. **Load into workspace** — call `import_library_from_upload(upload_id, library_name: "...", ...)` if the structured JSON matches the importer's shape. Otherwise, build rows manually and use `add_rows(table: "library:<name>", rows: [...])`.
5. **Review** — summarize what loaded.
6. **Save** — `save_framework(table: "library:<name>")`. Saved as a draft.

### Anti-patterns

- ❌ Calling `import_library_from_upload` for a PDF or image — the importer expects structured rows. Use the data_extractor sub-agent for unstructured documents.
- ❌ Calling `load_library(template_key: "fsf")` or other names that don't exist in `priv/templates/` — only `sfia_v8` is built in.
- ❌ Calling `fork_library` before saving when you're just customizing the template in the workspace — the workspace edits are already separate from the template; `save_framework` creates the user's draft library record. Fork is only needed if you want to clone a SAVED library to another saved library record (rare in chat).
