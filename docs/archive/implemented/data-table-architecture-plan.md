# Data Table Architecture — Implementation Plan

**Date:** 2026-04-10
**Status:** Planning — not yet started
**Context:** Discussion rooted in `docs/archive/implemented/spreadsheet-agent-handoff.md` and the realization that the current `Rho.Stdlib.Plugins.DataTable` model (LiveView owns rows, tools round-trip via sync pid messages) is inefficient and racy.

## Goals

1. Move row ownership out of the LiveView into a **per-session process** that tools can call synchronously as if the table were an in-memory object.
2. Support **multiple independently-schemaed tables per session** (e.g. `main`, `library`, `role_profile`), keyed by name.
3. Make the LiveView a **pure renderer** that subscribes to PubSub and re-renders on change.
4. Keep the core/stdlib boundary clean — no Phoenix deps leak into `apps/rho/`.
5. Preserve the existing agent tool surface as much as possible so existing `.rho.exs` configs keep working.

## Decisions locked in discussion

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Per-session GenServer owns tables (not ETS-only, not Agent Worker state) | Clean stdlib boundary, synchronous calls, solves write-then-read races |
| 2 | Multiple tables per session, keyed by string name, default `"main"` | Natural fit for library + role_profile side-by-side workflows |
| 3 | **Declared** schemas via `Rho.Stdlib.DataTable.Schema` struct — not inferred | Self-documenting, drives LV column rendering, enables prompt auto-generation |
| 4 | Tool addressing: explicit optional `table:` param, defaults to `"main"` | Opt-in complexity; simple agents ignore it |
| 5 | LV: single `:data_table` workspace with **internal tab strip** (Option B + hybrid door) | Avoids shell atom-key migration; leaves room to promote to multi-pane later via `initial_table` param |
| 6 | Sessions own tables (not agents) | Sub-agents inside a session share the same tables — matches how `session_id` flows today |
| 7 | No persistence layer initially | RAM only; server uses `restart: :temporary` — crash stays down with clear error rather than silently restarting empty. Add tape snapshots later if needed |
| 8 | Notifications via `Rho.Comms` (not Phoenix.PubSub) — single session-scoped topic with coarse invalidation events; LV refetches snapshots on change | `Rho.Comms` already exists cross-app; avoids adding `:phoenix_pubsub` dep to stdlib; works in CLI/headless; eliminates subscription races |
| 9 | `"main"` table created eagerly on server init with a dynamic (permissive) schema | Avoids LV mounting with `active_table: "main"` that doesn't exist; removes branching |
| 10 | Two schema modes: **dynamic** (string keys, no validation) for `"main"`, **strict** (reject unknown fields) for typed tables | Avoids invisible stored-but-not-rendered fields; prevents atom table leaks from LLM-generated keys |
| 11 | Every table carries a monotonic `version` counter, incremented on every mutation | Cheapest correctness primitive — detects stale snapshots, enables future optimistic concurrency |
| 12 | `create_table` is a client API only, not exposed as an agent tool initially | Domain tools call it internally; reduces LLM surface area. Expose later if a real workflow needs ad-hoc table creation |

## Module layout

All new code lives in `apps/rho_stdlib/lib/rho/stdlib/data_table/`.

| Module | Role |
|--------|------|
| `Rho.Stdlib.DataTable` | Client API. All row ops take `opts` keyword list with `table: "name"` (default `"main"`). Thin wrapper over `GenServer.call`. |
| `Rho.Stdlib.DataTable.Server` | `GenServer`. Holds `%{session_id, tables: %{name => Table.t()}, table_order: [name]}`. Publishes coarse invalidation events via `Rho.Comms` after every mutation. Uses `restart: :temporary`. |
| `Rho.Stdlib.DataTable.Table` | Struct: `%Table{name, schema, rows_by_id, row_order, version, next_id}`. Pure data. Explicit row ordering. |
| `Rho.Stdlib.DataTable.Schema` | Struct: `%Schema{name, columns: [%Column{}], key_fields, children_key, child_columns: [%Column{}]}`. Declares allowed fields + types. `children_key` (e.g. `:proficiency_levels`) enables nested child rows — matches the DB's `{:array, :map}` embedded shape. |
| `Rho.Stdlib.DataTable.Schema.Column` | Struct: `%Column{name, type, required?, doc}`. |
| `Rho.Stdlib.DataTable.Registry` | `Registry` (via-keyed by `session_id`). |
| `Rho.Stdlib.DataTable.Supervisor` | `DynamicSupervisor` for server instances. |

Existing `Rho.Stdlib.Plugins.DataTable` stays — it's where the **agent tools** live — but its body gets rewritten to call `Rho.Stdlib.DataTable` instead of doing `send`/`receive` gymnastics.

## Notification scheme (via `Rho.Comms`)

Single session-scoped topic: `"rho.session.#{session_id}.events.data_table"`.

The server publishes **coarse invalidation events** — not row deltas. The LV responds by refetching snapshots from the server. This eliminates subscription races (no per-table topic to miss) and avoids recreating a second data engine in the LV.

Message shapes:

```elixir
# Published after any table mutation
{:data_table, :table_changed, table_name, version}

# Published when table list changes
{:data_table, :table_created, table_name, version}
{:data_table, :table_removed, table_name}
```

### Snapshot API (server-side)

LV and tools use these to read current state — no delta reconciliation needed:

```elixir
get_session_snapshot(session_id)
#=> %{tables: [%{name, schema, row_count, version}], table_order: [...]}

get_table_snapshot(session_id, table_name)
#=> %{name, schema, rows, row_count, version}

summarize_table(session_id, opts \\ [])
#=> %{total_rows, fields: [%{field, unique_count, sample}], version}
```

## Supervision

Add to `Rho.Stdlib.Application`'s children:

```elixir
{Registry, keys: :unique, name: Rho.Stdlib.DataTable.Registry},
{DynamicSupervisor, name: Rho.Stdlib.DataTable.Supervisor, strategy: :one_for_one}
```

Server start is **lazy**: `Rho.Stdlib.DataTable.ensure_started(session_id)` is called on first tool invocation AND on first LV mount. Idempotent. Server crashes are isolated per session. Child spec uses `restart: :temporary` — if the server crashes, it stays down with a clear error rather than silently restarting with empty state.

On init, the server eagerly creates a `"main"` table with a dynamic (permissive) schema so it's always available.

Lifecycle: server stays up for the life of the session. A `Rho.Stdlib.DataTable.SessionJanitor` process subscribes to `rho.agent.stopped` via `Rho.Comms` and stops the matching DataTable server when the primary agent for a session terminates. This avoids inventing a new cross-app teardown protocol — see Risks §1.

## Schema declaration example

```elixir
# In apps/rho_frameworks/lib/rho_frameworks/schemas.ex
alias Rho.Stdlib.DataTable.Schema
alias Rho.Stdlib.DataTable.Schema.Column

def library_schema do
  %Schema{
    name: "library",
    columns: [
      %Column{name: :category, type: :string, required?: true, doc: "Top-level grouping"},
      %Column{name: :cluster, type: :string, required?: true, doc: "Sub-grouping within category"},
      %Column{name: :skill_name, type: :string, required?: true, doc: "Skill name"},
      %Column{name: :skill_description, type: :string, required?: false}
    ],
    children_key: :proficiency_levels,
    child_columns: [
      %Column{name: :level, type: :integer, required?: true, doc: "0-5, 0 = placeholder"},
      %Column{name: :level_name, type: :string, required?: false},
      %Column{name: :level_description, type: :string, required?: false}
    ],
    key_fields: [:skill_name]
  }
end

def role_profile_schema do
  %Schema{
    name: "role_profile",
    columns: [
      %Column{name: :skill_name, type: :string, required?: true},
      %Column{name: :required_level, type: :integer, required?: true},
      %Column{name: :required, type: :boolean, required?: true}
    ],
    key_fields: [:skill_name]
  }
end
```

Schemas are declared by domain code (`rho_frameworks`, user code), not by `rho_stdlib`. The stdlib just validates against whatever schema was passed to `create_table/3`.

## Client API

```elixir
# Lifecycle
Rho.Stdlib.DataTable.ensure_started(session_id)
Rho.Stdlib.DataTable.stop(session_id)

# Table management
Rho.Stdlib.DataTable.create_table(session_id, table_name, schema, opts \\ [])
Rho.Stdlib.DataTable.ensure_table(session_id, table_name, schema, opts \\ [])  # idempotent create-if-missing
Rho.Stdlib.DataTable.list_tables(session_id)          #=> [%{name, schema, row_count, version}]
Rho.Stdlib.DataTable.get_schema(session_id, table_name)
Rho.Stdlib.DataTable.drop_table(session_id, table_name)

# Snapshots (server-side computation, no delta replay)
Rho.Stdlib.DataTable.get_session_snapshot(session_id)  #=> %{tables: [...], table_order: [...]}
Rho.Stdlib.DataTable.get_table_snapshot(session_id, table_name)  #=> %{name, schema, rows, version}
Rho.Stdlib.DataTable.summarize_table(session_id, opts \\ [])  #=> %{total_rows, fields, version}

# Row ops — all take opts keyword list with `table: "name"` (default "main")
Rho.Stdlib.DataTable.add_rows(session_id, rows, opts \\ [])
Rho.Stdlib.DataTable.get_rows(session_id, opts \\ [])
Rho.Stdlib.DataTable.update_cells(session_id, changes, opts \\ [])
Rho.Stdlib.DataTable.delete_rows(session_id, ids, opts \\ [])
Rho.Stdlib.DataTable.delete_by_filter(session_id, filter, opts \\ [])
Rho.Stdlib.DataTable.replace_all(session_id, rows, opts \\ [])
```

All operations are synchronous `GenServer.call`s. Server publishes coarse invalidation via `Rho.Comms` after each mutation.

### `ensure_table/4`

Handles concurrent sub-agent races on first table creation:
- Creates the table if it doesn't exist
- If it already exists with the same schema: returns `:ok`
- If it already exists with a different schema: returns `{:error, :schema_mismatch}`

Domain tools should call `ensure_table/4` before writes to named tables.

### Schema modes and atom safety

- **Dynamic tables** (e.g. `"main"`): store field names as **strings**. No validation, no atom conversion. Accepts arbitrary LLM-generated keys safely.
- **Strict tables** (e.g. `"library"`, `"role_profile"`): declared column names are atoms. Unknown fields are **rejected** (not silently stored). Obvious primitive coercions apply (`"1"` → `1`, `"true"` → `true`).

Never call `String.to_atom/1` on user/agent-generated keys.

## Agent tool surface (`Rho.Stdlib.Plugins.DataTable`)

All existing tools keep their names. Every tool that takes table data gets a new optional `table` parameter defaulting to `"main"`.

New tools:
- `list_tables` — returns `[%{name, schema, row_count, version}]` so agents can orient
- `delete_by_filter` — trivial now that the server owns the data (this is suggestion #1 from the original 5)

Note: `create_table` is deliberately **not** exposed as an agent tool. Domain tools call it internally via the client API. This keeps the LLM surface area small.

Tools that will change shape slightly:
- `get_table`, `get_table_summary`, `add_rows`, `update_cells`, `delete_rows`, `replace_all` — add optional `table` param.

Tools that go away:
- Nothing — the shape of the legacy tools is preserved, only the internals change.

## LiveView rewrite

`apps/rho_web/lib/rho_web/workspaces/data_table.ex`:

1. Remove local `rows_map` / `next_id` assigns.
2. On mount: call `Rho.Stdlib.DataTable.ensure_started(session_id)`, subscribe to `"rho.session.#{session_id}.events.data_table"` via `Rho.Comms`, fetch `get_session_snapshot(session_id)`.
3. Assign: `tables: snapshot.tables`, `table_order: snapshot.table_order`, `active_table: "main"` (or `initial_table` param). Fetch `get_table_snapshot` for the active table only.
4. Handle `{:data_table, :table_changed, table_name, version}` → refetch `get_table_snapshot` if `table_name == active_table`. Handle `:table_created` / `:table_removed` → refetch `get_session_snapshot`.
5. Render a tab strip using `table_order` (stable ordering) with click-to-switch, highlighting `active_table`.
6. Render the active table's rows using its schema's columns.

`apps/rho_web/lib/rho_web/live/session_live.ex`:

1. Delete the `handle_info({:data_table_get_table, _, _}, …)` dispatcher at line 699 — no longer used.
2. Anything else referencing the old signal-bus `data_table_*` events gets removed or simplified.

## Migration strategy

This is invasive — touches tools, LV, and several `rho_frameworks` files. Do it in this order:

### Phase 1 — Core infrastructure (no behavior changes yet)
1. Create `Rho.Stdlib.DataTable.*` modules (Schema, Column, Table, Server, Registry, Supervisor, SessionJanitor, client API)
2. Table struct uses `rows_by_id` + `row_order` for explicit ordering, `version` counter for invalidation
3. Server eagerly creates `"main"` on init; supports `ensure_table/4` for idempotent named-table creation
4. Wire into `Rho.Stdlib.Application` supervision tree (including SessionJanitor)
5. Write unit tests for the server in isolation (including concurrent `ensure_started`, concurrent `ensure_table`, write-then-read ordering)
6. **Does not touch any existing code.** Fully additive.

### Phase 2 — Rewrite tools + LV atomically (single commit, no shim)

Because nothing is currently depending on the data table in production, Phase 2 and Phase 3 from the original plan collapse into a single atomic change.

**Plugin (`Rho.Stdlib.Plugins.DataTable`):**
1. Replace `send`/`receive` in `get_table_tool` with `DataTable.get_rows/2`; replace `get_table_summary_tool` with `DataTable.summarize_table/2`
2. Replace `stream_rows_progressive` + signal publishing in write tools with `DataTable.add_rows/2` etc.
3. Add `table` param (default `"main"`) to all tool parameter schemas
4. Add new `list_tables`, `delete_by_filter` tools (not `create_table` — internal API only)
5. Delete the ETS registry `:rho_data_table_registry` and the `register/2`, `unregister/1`, `with_pid/2`, `read_rows/1`, `stream_rows_progressive/4`, `publish_event/4`, `generate_row_id/0` exports — all dead code after this phase

**LiveView (`RhoWeb.Workspaces.DataTable`):**
6. Rewrite as a pure renderer that subscribes to PubSub and renders from server state
7. Add tab strip for switching between tables
8. Accept `initial_table` param (default `"main"`) — the hybrid-door hook for future multi-pane

**Session shell (`RhoWeb.Live.SessionLive`):**
9. Delete `handle_info({:data_table_get_table, _, _}, …)` dispatcher at line 699
10. Delete any `data_table_*` signal-bus subscriptions that exist today

Ship as one commit. Verify the spreadsheet agent flow end-to-end before moving to Phase 3.

### Phase 3 — Integrate with rho_frameworks domain
1. Create `RhoFrameworks.DataTableSchemas` with `library_schema/0` and `role_profile_schema/0`
2. Update `LibraryTools.load_library` to call `DataTable.create_table(session_id, "library", library_schema())` + `add_rows(session_id, "library", rows)`
3. Update `RoleTools.load_role_profile` similarly for `"role_profile"`
4. Update `save_to_library` / `save_role_profile` to read from the named table instead of `DT.read_rows(ctx.session_id)` (which defaults to `"main"`)
5. Check `%Rho.Effect.Table{schema_key: :skill_library}` at `library_tools.ex:104` — this already hints at multi-schema; update it to carry an explicit `table_name` the LV can use to open the right tab

### Phase 4 — Original 5 suggestions revisited
1. **`delete_by_filter`** — already done in Phase 2
2. **Two-phase `save` (plan/execute)** — add `mode: "plan" | "execute"` param to `save_role_profile` and `save_to_library`. "plan" returns a dry-run summary (rows to insert/update/delete, constraints). "execute" applies.
3. **`get_org_view`** — new tool in `role_tools.ex` that reads all role profiles in the org, computes shared-vs-unique skills across them via `MapSet.intersection`, returns a summary. Pure Ecto query, no architecture changes needed.
4. **Versioning (`version`, `is_default`, `year`)** — **still a separate decision.** Adds a migration, changes `save_role_profile` shape, introduces `set_default_version` tool. Only pursue if there's a real product need.
5. **Proficiency generation in parallel (`generate_proficiency_levels`)** — **skip.** The current `delegate_task_lite` path via `:multi_agent` achieves the same outcome and fits the rho kernel/stdlib model better.

### Phase 5 — Cleanup and verification
1. Delete dead code (ETS registry, old signal topics, unused handlers)
2. Update `CLAUDE.md` plugin module map to mention `Rho.Stdlib.DataTable.*`
3. Run `mix test --app rho_stdlib` and `mix test --app rho_web`
4. Run a smoke test of the spreadsheet agent via `mix rho.chat` (if applicable) or the observatory

## Risks and open questions

### Resolved

| # | Question | Resolution |
|---|----------|------------|
| 1 | Session lifecycle coupling | `Rho.Stdlib.DataTable.SessionJanitor` subscribes to `rho.agent.stopped` via `Rho.Comms` and stops matching servers. No new protocol needed. |
| 2 | Who creates the "main" table? | **Eagerly on server init** with a dynamic schema. Always available, no branching. |
| 3 | Schema validation strictness | **Two modes:** dynamic tables (string keys, no validation) for `"main"`; strict tables (reject unknown fields) for typed tables. No "warn + store" — it creates invisible state. |
| 4 | Backward compat during migration | **No compat shim.** Nothing in production depends on current wiring. Atomic rewrite. |
| 5 | Multi-table subscriptions in LV | **Eliminated.** Single session-scoped `Rho.Comms` topic with coarse invalidation. LV refetches snapshots. No per-table subscriptions. |
| 7 | Row ID source | **Server generates IDs.** Move `generate_row_id/0` into server. Use a single canonical `id` field end-to-end (not both `row_id` and `id`). |
| 8 | Headless use | **Works by design.** CLI and tests use client API directly. Note in CLAUDE.md. |
| 9 | Nested vs flat table shape | **Keep nested.** The DB stores `proficiency_levels` as `{:array, :map}` embedded on the `skills` row — not a separate table. Flattening would require transform-on-load and re-nest-on-save. Stdlib schema supports `children_key` + `child_columns` to stay shape-compatible with the DB. `update_cells` handles `"row_id:child:idx"` addressing. |

### Still open

### 6. Tape integration

Should `DataTable.Server` mutations be recorded on the tape? Probably yes for replayability, but that's a later addition — the server can accept a `tape_module` opt and log after each mutation. Punt for now; design for the hook.

### 10. Crash UX

With `restart: :temporary`, a crashed server stays down. The LV and tools need to handle `{:error, :not_running}` gracefully. The LV should show a clear "table state lost — reload/regenerate" message. Tools should return an actionable error to the agent.

## Out of scope for this plan

- Persistence to disk
- Undo/redo history
- Collaborative editing (multiple sessions sharing a table)
- Row-level permissions
- The original suggestion #4 (versioning) — still needs a product decision
- The original suggestion #5 (in-process parallel proficiency generation) — explicitly declined

## Rough sequencing

- **Phase 1** — fully additive infrastructure, zero existing code touched.
- **Phase 2** — atomic tool + LV rewrite, deletes old signal-bus path. Architectural core.
- **Phase 3** — migrate `rho_frameworks` tools to named tables with declared schemas.
- **Phase 4** — ship the original 5 suggestions that survived the redesign.
- **Phase 5** — cleanup, CLAUDE.md updates, full test sweep.

Each phase is roughly one commit. Phase 2 is the high-risk, high-value one.

## Success criteria

- The LV holds no row state — confirmed by grepping for `rows_map`, `next_id` in `RhoWeb.Workspaces.DataTable` and finding nothing.
- `Rho.Stdlib.Plugins.DataTable` tools have no `send`/`receive` calls.
- Two tables (`library`, `role_profile`) can be open in the same session, each with its own schema, each rendered when active via the tab strip.
- The write-then-read race is gone: `add_rows` followed immediately by `get_table` in a single agent step sees the newly-added rows.
- A `mix test --app rho_stdlib` run with a DataTable test suite passes without any LV (headless).
- Concurrent `ensure_started/1` from 10 processes converges to one server.
- Concurrent `ensure_table/add_rows` on same session/table does not error.
- Server crash → tools get clear `{:error, :not_running}`, LV shows recovery message (no silent empty restart).
- No `String.to_atom/1` calls on user/agent-generated keys.
- Tab ordering is stable across re-renders.
- The frameworks agent (`.rho.exs :spreadsheet`) completes a full library-load → role-derivation → save flow against the new architecture.

## Continuing from `docs/archive/implemented/spreadsheet-agent-handoff.md` after this plan

This plan only covers the **architectural substrate** (multi-table server, schemas, LV rewrite) and the three surviving quick-win tools from the initial analysis. It does NOT finish porting the old spreadsheet agent from the handoff doc. Here is the explicit follow-up track to do after Phases 1–5 above are done.

### Post-plan checklist — bringing the handoff agent to parity

Work in this order. Each item is independent once Phase 5 is complete.

#### Track A — Externalize the prompt into skill files (handoff §1)

The handoff shipped 12 markdown files under `.agents/skills/framework-editor/`. The current repo has the entire workflow inlined in `.rho.exs :spreadsheet.system_prompt` (~150 lines). This is hard to maintain and hard to iterate on.

1. Create `.agents/skills/framework-editor/SKILL.md` with the intent-detection table from the handoff (the "No files, describes a role → Generate" table). Adapt the tool names to the current repo (`list_libraries` not `list_frameworks`, `load_library` not `load_framework`, etc.).
2. Create workflow files, adapted to the current domain:
   - `generate-workflow.md` — bottom-up role creation (Path a in current prompt)
   - `import-workflow.md` — file ingest via `:doc_ingest`
   - `enhance-workflow.md` — adding proficiency levels to existing skills
   - `reference-workflow.md` — "create X like Y" via `find_similar_roles` + `clone_role_skills`
   - `persistence-workflow.md` — save/load flows, versioning (if added)
   - `deduplication-workflow.md` — `find_duplicates` + `merge_skills` + `dismiss_duplicate`
   - `template-workflow.md` — `load_template("sfia_v8")` + `fork_library`
   - `dreyfus-model.md` — 5-level proficiency model reference (can be copied verbatim)
   - `proficiency-prompt.md` — the prompt used by `delegate_task_lite` for level generation
   - `quality-rubric.md` — behavioral indicator quality rules (copy verbatim)
3. Update `.rho.exs :spreadsheet`:
   - Set `default_skills: ["framework-editor"]`
   - Add `:skills` to the mounts list
   - Strip the giant `system_prompt` down to a one-liner: `"You are a skill framework editor. Follow the framework-editor skill for all workflows."`
4. Verify via `mix rho.chat -a spreadsheet` that the agent loads the skill at boot.

#### Track B — File ingest audit (handoff §2 — `get_uploaded_file`, `import_from_file`)

The handoff had dedicated file-ingest tools backed by Python (openpyxl, pdfplumber). The current repo mounts `:doc_ingest` in the spreadsheet agent. Two questions to answer:

1. Does `Rho.Stdlib.Plugins.DocIngest` cover Excel sheets with multiple tabs? Check `apps/rho_stdlib/lib/rho/stdlib/plugins/doc_ingest.ex`. If not, add a sheet parameter.
2. Does it stream large files in pages (the handoff had pagination for big XLS files)? If not, decide whether to add pagination or keep it simple.
3. If `:doc_ingest` turns out to be insufficient, either extend it or add a thin `Rho.Stdlib.Tools.Xlsx` tool — but try not to duplicate what's already there.

#### Track C — Two-phase save (handoff §2 — `save_framework(mode: plan/execute)`)

Covered by Phase 4 of this plan, but the handoff has a richer "plan" output than what's sketched here. After Phase 4 is shipped, polish the plan output to match the handoff shape:

- Rows to INSERT (with counts)
- Rows to UPDATE (with diffs)
- Rows to DELETE (with IDs and names)
- Constraint violations if any
- Auto-generated version number preview (only if versioning from Track E is done)

#### Track D — Versioning decision (handoff §3 — `(company_id, role_name, year, version)`)

**This is a product decision, not a technical one.** Only pursue if there's a real need for role-profile version history.

If yes:
1. New migration: add `version`, `is_default`, `year` to `role_profiles` table
2. Unique constraint `(organization_id, name, year, version)`
3. `save_role_profile` becomes `save_role_profile(action: "create" | "update")` — create bumps version, update overwrites
4. New tool `set_default_version(role_profile_id)` — transactional flip
5. New tool `get_role_version_history(name)` — list all versions + which is default
6. "First version of a role → is_default=true" rule in the changeset
7. Update `list_role_profiles` to return default version by default, all versions with an `all: true` param

If no: explicitly document in CLAUDE.md that role profiles are single-version and upserts overwrite. Close the track.

#### Track E — Company/org view tools (handoff §2 — `get_company_overview`, `get_company_view`)

Phase 4 of this plan ships `get_org_view`. The handoff also had `get_company_overview` which returns "a company's roles with default versions + industry templates" as the agent's welcome-screen bootstrap.

Add `get_org_overview` to `shared_tools.ex`:
- Lists all role profiles for the current org (with default version if Track D is done)
- Lists all libraries (mutable + immutable, from `list_libraries`)
- Lists available industry templates from `priv/templates/`
- Returned in a single call so the agent can orient on session start

The handoff had the agent call this on the very first message. Wire that into `generate-workflow.md` / `SKILL.md` from Track A.

#### Track F — Multi-role merge (handoff §2 — `merge_roles(mode: plan/execute)`)

Handoff had a role-level two-phase merge with dedup. Current repo has skill-level merge (`merge_skills`) but no role-level merge. Decide if needed:
- If the flow is "user loads 3 roles, agent dedupes skills across them and merges into one role," add a `merge_role_profiles` tool to `role_tools.ex` using `Ecto.Multi`
- Otherwise, skip — skill-level dedup may be enough

#### Track G — Known-issue cleanup (handoff §Known Issues)

These are bugs from the old codebase. Re-verify against the current repo before fixing; some may no longer exist after the restructure.

1. **Finch pool exhaustion** (medium) — root cause was metadata fetch on stream connections. Check `req_llm` version and pool config in `apps/rho/`. If still an issue, increase pool size or fix stream handling.
2. **Reference workflow calls `get_uploaded_file` on DB templates** (low) — handled by Track A (rewriting the skill files) if the old logic is copied verbatim without thinking. Avoid it.
3. **Agent skips skeleton review phase** (low) — prompt improvement, fix in Track A skill files.
4. **Title-case normalization: "HR Manager" → "Hr Manager"** (low) — check `role_tools.ex` save path for `String.capitalize` or similar; use `String.split/join` with per-word handling instead.

#### Track H — Acceptance test (handoff's 10 scenarios)

The handoff shipped a 10-scenario test suite in `docs/experiments/2026-04-07-company-flow-testing.md` (does not exist in current repo). The scenarios are listed in handoff §Tested Scenarios. After Tracks A–G are done, re-run those 10 scenarios against the current spreadsheet agent as end-to-end acceptance tests:

1. Browse template → pick role → save
2. Multi-role select + merge
3. Load → edit → versioned save
4. Generate from scratch (one role)
5. Multi-role from scratch (3 roles)
6. Template as reference
7. Multi-sheet Excel import + enhance
8. Load → edit → save update in place
9. Fully structured Excel import (100% match)
10. Access control (multi-company / multi-org)

Capture the results in a new `docs/experiments/YYYY-MM-DD-spreadsheet-agent-acceptance.md` file with demo scripts (exact user messages to replicate each scenario).

### What we are explicitly NOT porting from the handoff

For the record, after this plan + the tracks above, these handoff features are deliberately left out:

| Handoff feature | Why skipped |
|-----------------|-------------|
| `generate_proficiency_levels` (in-process `Task.async_stream` parallel LLM) | `delegate_task_lite` via `:multi_agent` already achieves the same outcome and fits the rho plugin model |
| `switch_view: :role \| :category` | Rendering concern — can be done as LV sort/group toggle without a tool |
| `get_uploaded_file` as a dedicated tool | Covered by `:doc_ingest` unless Track B says otherwise |
| Monolithic `spreadsheet_live.ex` (1720 lines) | Current split into `session_live.ex` + `RhoWeb.Workspaces.DataTable` is cleaner, keep it |
| `extra_opts` plumbing through Session → Worker → mount | Already covered by `Rho.Context.organization_id` / `user_id` fields |
| `companies` table | Already covered by `RhoFrameworks.Accounts` org model |

### Suggested order of work

```
THIS PLAN (Phases 1-5)
   │
   ▼
Track A   (skill files — biggest UX win for lowest risk)
   │
   ▼
Track E   (get_org_overview — agent bootstrap)
   │
   ▼
Track B   (file ingest audit — unblocks import scenarios)
   │
   ▼
Track H   (acceptance scenarios 1-9 except versioned ones)
   │
   ▼
Track D   (versioning — product decision point)
   │
   ├─ if yes ─▶ Track C (polished two-phase save) ─▶ Track H scenarios 3 + 8 pass
   │
   └─ if no  ─▶ skip C/D, document it
   │
   ▼
Track F   (role merge — only if acceptance scenario 2 fails without it)
   │
   ▼
Track G   (known-issue cleanup as bugs surface)
```

Tracks A, E, B are safe quick wins. D is the gating product decision. F and G are reactive.
