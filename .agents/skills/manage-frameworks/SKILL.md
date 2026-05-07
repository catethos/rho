---
name: manage-frameworks
description: Workflow for working with EXISTING saved libraries — loading a library to edit, publishing a draft as a new version, and setting which version is the default
uses: [manage_library, load_library, save_framework, library_versions]
---

## Manage Frameworks Workflow

This skill covers the lifecycle of libraries that already exist in the
database: loading a saved library to edit it, publishing a draft as a
new version (v2), and setting which version is the default.

For BUILDING a new framework, use `create-framework`.
For LOADING a built-in template (sfia_v8) or a document file, use
`import-framework`.

## How saving and versioning actually work

Three explicit user-driven beats:

1. **Save** — `save_framework` always writes to a DRAFT.
   - If the library doesn't exist by name → creates a new draft.
   - If a draft already exists → updates the existing draft.
   - If only published versions exist → auto-creates a new draft and saves there. The published version is FROZEN and never modified.
2. **Publish** — `manage_library(action: "publish", library_id: <draft-uuid>)` freezes the draft as the next version (e.g. v2). Only happens when the user explicitly asks.
3. **Set default** — `library_versions(action: "set_default", library_id: <published-uuid>)` flips which version is returned by default. Only published versions can be default; drafts cannot.

The agent NEVER calls publish or set_default automatically — both are explicit user requests.

## Path: Load → Edit → Save (S3)

1. **List if needed** — `manage_library(action: "list")` to find the library name and UUID, unless the user named it.
2. **Load** — `load_library(library_name: "<name>")`. Resolves to: the draft if one exists, else the default published version, else the most recent published version. Populates the `library:<name>` workspace table.
3. **Edit** — `update_cells`, `edit_row`, `add_rows`, `delete_rows`, or `delete_by_filter` against `table: "library:<name>"`. Follow the system prompt's READ BEFORE REWRITE rule.
4. **Save** — `save_framework(table: "library:<name>")`. Behavior:
   - If a draft of this library exists → updates the draft contents.
   - If only published versions exist → auto-creates a NEW draft and saves there. The response includes a `draft_library_id`.
5. **Confirm to user** — "Saved 'HR Manager' draft (9 skills). v1 is still the only published version. Say 'publish this as v2' if you want to lock these changes in."

The agent does NOT need to call `manage_library(action: "create_draft")`
manually — `save_framework` handles draft creation automatically when
required.

## Path: Publish a draft as a new version (S3 follow-up)

When the user says "publish this", "save as v2", "lock this in":

1. **Find the draft UUID** — call `manage_library(action: "list")` and locate the draft for this library name. Drafts show as `... draft` (no version number).
2. **Publish** — `manage_library(action: "publish", library_id: "<draft-uuid>", [version_tag: "..."], [notes: "..."])`. The tool first syncs the workspace rows back to the draft, then promotes the draft to the next version. Auto-generates a `YYYY.N` version tag if none provided.
3. **Confirm** — "Published 'HR Manager' v2. The previous default (v1) is still the default — say 'set v2 as default' to switch."

Errors to handle:
- `:already_published` — the agent passed a UUID of a published version, not the draft. Re-list and find the draft UUID.
- `:not_found` — UUID is wrong. Re-list.

## Path: Set Default Version (S11)

The default is the version returned by `load_library(library_name: "X")`
when no explicit version is requested. Only one default per
`(org, library_name)`. Drafts cannot be set as default — only published
versions.

Use the lookup-then-act pattern:

1. **List versions** — `library_versions(action: "list", library_name: "<name>")` returns each version with its UUID and a `*default*` marker on the current default. Example output:
   ```
   "HR Manager" versions:
   Draft: <uuid> (updated: ...)
   - v1 (3213b761-...) — 7 skills *default*
   - v2 (5ff190d0-...) — 9 skills
   ```
2. **Confirm** — if the user wasn't specific, ask which version (e.g. "v1 or v2?").
3. **Set default** — `library_versions(action: "set_default", library_id: "<version-uuid>")`. The previous default is automatically demoted in the same transaction.
4. **Confirm to user** — "Set 'HR Manager' v2 as default."

Common mistakes:
- ❌ Passing a library NAME to `set_default` — the tool requires a version UUID.
- ❌ Passing the DRAFT UUID — drafts cannot be default. Tool returns `:not_published, "Only published versions can be set as default."`. Publish first.
- ❌ Skipping the list step and guessing — UUIDs are not derivable from names.

## Anti-patterns

- ❌ Calling `manage_library(action: "create_draft")` before edits. `save_framework` already creates drafts automatically when needed. Manual `create_draft` only matters if the user wants to FORK the latest published version into a fresh draft without saving over an existing draft — rare in chat.
- ❌ Calling `manage_library(action: "publish")` without explicit user request. Publishing is irreversible (the version is frozen) — always wait for the user to say "publish" / "save as v2" / "lock this in".
- ❌ Calling `library_versions(action: "set_default")` with a library name instead of a version UUID. Look up via `library_versions(action: "list")` first.
- ❌ Using `load_library` to load a just-generated skeleton — the skeleton rows are already in the workspace; `load_library` reads from the DB.
