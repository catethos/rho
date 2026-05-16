# Task: LiveView pure-renderer rewrite for the DataTable architecture

> **Status update (2026-04-10): Phase 3 shipped.**
>
> The named-table migration is complete. `RhoFrameworks.Tools.LibraryTools` and
> `RhoFrameworks.Tools.RoleTools` now create and read from `"library"` and
> `"role_profile"` named tables via `Rho.Stdlib.DataTable.ensure_table/4` and
> `DataTable.get_rows(…, table: "name")`. `%Rho.Effect.Table{}` carries an explicit
> `table_name` which `EffectDispatcher` uses to route canonical writes and the
> LV tab-strip uses to auto-switch (`SessionLive.apply_data_table_event :view_change`).
> The legacy `DT.read_rows/1` + fall-back-to-main path is gone.
>
> Integration coverage: `apps/rho_frameworks/test/rho_frameworks/tools/named_table_roundtrip_test.exs`
> — library round-trip, role_profile round-trip, both tables open simultaneously,
> `:not_running` and empty-table error shapes.
>
> The LV pure-renderer rewrite described below is still the remaining follow-up
> (the projection layer still exists as a legacy adapter). The Phase 3 shipping
> does NOT include the full projection removal — it only closes the frameworks
> tools migration and confirms the tab-strip flow works end-to-end.
>
> The active-table UX question (plugin tools default to `"main"` — not the last
> loaded table) was resolved via Option A: prompt + tool-description guidance in
> the `:spreadsheet` agent, plus a new `start_role_profile_draft` domain tool for
> Path (a) bottom-up creation. See CLAUDE.md §"Named tables".

## Context

The data table architecture plan in `docs/archive/implemented/data-table-architecture-plan.md` was implemented through Phases 1–3 + 5. The per-session GenServer (`Rho.Stdlib.DataTable.Server`) now owns all row state canonically, and `Rho.Stdlib.Plugins.DataTable` tools call into it synchronously. The write-then-read race is gone and the stdlib boundary is clean.

**What was deliberately deferred:** the LiveView was NOT rewritten as a pure renderer. Instead, `Rho.Stdlib.Plugins.DataTable` and `Rho.Stdlib.EffectDispatcher` publish a **legacy UI compatibility shim** — after every write to the server they also emit the old-format `data_table_rows_delta`, `data_table_replace_all`, etc. signals that the existing `RhoWeb.Projections.DataTableProjection` consumes. This keeps the UI working but maintains two parallel state paths.

Your job is to remove that shim by making the LiveView a pure renderer that subscribes to coarse invalidation events and re-fetches snapshots from the server.

## What the plan specified

From `docs/archive/implemented/data-table-architecture-plan.md` §"LiveView rewrite" and §"Notification scheme":

- Single session-scoped topic: `"rho.session.#{session_id}.events.data_table"`
- Server publishes coarse invalidation events: `%{event: :table_changed, table_name, version}`, `%{event: :table_created, ...}`, `%{event: :table_removed, ...}` — already implemented
- LV on mount: `ensure_started(session_id)`, subscribe to the topic, fetch `get_session_snapshot/1`
- Assigns: `tables`, `table_order`, `active_table` (default `"main"` or `initial_table` param)
- Handle invalidation → refetch `get_table_snapshot/2` for the active table only
- Render a **tab strip** using `table_order` with click-to-switch
- Render active table's rows using its schema's columns

## Why this is complicated

### 1. The existing UI is NOT a single LiveView — it's a workspace/projection framework

`RhoWeb.Workspaces.DataTable` is a workspace metadata module plugged into `RhoWeb.Workspace.Registry`. The actual rendering happens in `RhoWeb.DataTableComponent` (a `LiveComponent`), state lives in a "workspace state" map keyed by `:data_table` inside the parent `SessionLive`'s assigns, and updates flow through `RhoWeb.Session.SignalRouter` which dispatches signals to per-workspace projection reducers. You can't just rewrite one file.

Critical files to understand before touching anything:
- `apps/rho_web/lib/rho_web/workspaces/data_table.ex` — workspace metadata
- `apps/rho_web/lib/rho_web/workspace.ex` + `workspace/registry.ex` — the workspace framework
- `apps/rho_web/lib/rho_web/projections/data_table_projection.ex` — **the pure reducer that currently owns `rows_map`, `partial_streamed`, `pending_ops`, `cell_timestamps`, schema, known_fields** — this is what needs to go away or be re-purposed
- `apps/rho_web/lib/rho_web/components/data_table_component.ex` — the actual renderer, with inline editing, group expand/collapse, optimistic updates, nested child rows
- `apps/rho_web/lib/rho_web/session/signal_router.ex` — how signals reach projections
- `apps/rho_web/lib/rho_web/session/effect_dispatcher.ex` — translates `%Rho.Effect.Table{}` into signals AND writes to the server (added in Phase 3)
- `apps/rho_web/lib/rho_web/session/session_core.ex` — mount/subscribe/hydrate

### 2. The projection is a pure reducer; refetching requires side effects

`DataTableProjection.reduce/2` has signature `(state, signal) -> new_state`. Calling `DataTable.get_table_snapshot/2` from inside is a side effect that breaks the abstraction. Options:

- **(a)** Have the LV itself (in `handle_info`) do the refetch and `ws_state_update` the workspace state. This keeps reducers pure.
- **(b)** Replace the projection with a lightweight adapter that delegates to the server and only caches the latest snapshot in ws_state. The "reduce" becomes "detect invalidation → return new state marked stale → LV refetches on next render." Messy.
- **(c)** Remove the projection entirely and hold `data_table` state outside the workspace framework. Biggest diff, cleanest result.

**Decision: (a)**, but with an important constraint: **do NOT fetch snapshots in `component_assigns/2`**. That runs during render — putting `GenServer.call` there creates repeated side effects and unpredictable render-time I/O. Instead, handle data table invalidations at the **LiveView boundary**: intercept `rho.session.<sid>.events.data_table` messages in `SessionLive.handle_info/2` (and `SkillLibraryLive.handle_info/2`), refetch the snapshot there, and push the result into `ws_states`. The workspace state shape becomes a **snapshot cache**:

```elixir
%{
  tables: [],
  table_order: [],
  active_table: "main",
  active_snapshot: nil,   # %{rows: [...], version: N}
  active_version: nil,
  mode_label: nil,
  error: nil
}
```

### 3. Optimistic edits and child-row editing

`DataTableComponent.handle_event("save_edit", ...)` applies an optimistic edit locally via `DataTableProjection.apply_optimistic_edit/5` (or `apply_optimistic_child_edit/7`), tracks a `client_op_id` in `pending_ops`, and publishes a `data_table_user_edit` signal. The server-side echo is deduped.

You need to reproduce this UX against the new server API:
- The server currently has `update_cells/3` but does NOT round-trip a `client_op_id` or any "confirmation" back to the caller.
- If you remove the projection's `pending_ops` MapSet, you lose optimistic-edit de-dup.
- Simplest path: call `DataTable.update_cells/3` synchronously from the LV event handler, then immediately refetch the snapshot. Skip the `client_op_id` dance entirely. The invalidation event from the server will arrive moments later and result in a no-op refresh since the version is already current.
- **Important:** `update_cells/3` currently returns only `:ok` — it does NOT return enough state for true optimistic rendering from the return value. You must either: (1) change `update_cells/3` to return `{:ok, version | snapshot}`, or (2) follow it with `get_table_snapshot/2`.
- Make sure child-row edits (the `"parent_id:child:idx"` format) still work — the server's `Table.update_cells` expects a different format (`"child:<idx>:<field>"`). You'll need to reconcile these. Keep the translation string-based (no `String.to_atom/1`).

### 4. Progressive streaming UX

The current flow **streams rows in batches** via `stream_rows_progressive` so the user sees rows appear incrementally as the LLM generates them. This is partly driven by `DataTableProjection.reduce_structured_partial/2`, which parses partial JSON from `structured_partial` signals (the `action_input.rows_json` stream) and extracts complete row objects as they come in.

**Watch out:** if you remove the shim entirely, you lose this progressive UX. The server currently writes rows atomically from tool calls — there is no streaming path into it. Options:

- **(i)** Accept a worse UX (rows appear all at once when the tool returns) and delete the streaming path
- **(ii)** Keep a narrow streaming hook: let the plugin call `DataTable.add_rows/3` in chunks as the JSON parses, so invalidation events fire multiple times and the LV repeatedly refetches. This preserves the UX at the cost of more refetches.
- **(iii)** Keep `reduce_structured_partial` alive as a *display-only* overlay that shows partial rows until the server catches up, then the server snapshot wins.

**Decision: (i) — all-at-once for this PR.** The streaming UX is tightly coupled to `structured_partial` parsing in the projection layer; preserving it during the rewrite adds significant complexity for marginal benefit. If streaming must return later, option (iii) — a display-only partial-row overlay — is the least-bad advanced path. Do NOT do chunked canonical `add_rows/3` writes during this rewrite.

### 5. Schema resolution currently hardcoded in the web layer

`DataTableProjection.resolve_schema_key/1` maps `:skill_library | :role_profile` to `RhoWeb.DataTable.Schemas.*`. The new `Rho.Stdlib.DataTable.Schema` (in stdlib) and `RhoWeb.DataTable.Schema` (in web) are DIFFERENT structs with different fields (`:key` vs `:name`, `:label`, `:editable`, `:css_class`, `:group_by`, etc.).

The stdlib schema is what the server stores. The web schema drives rendering (columns with labels, css classes, groupings, edit behavior). You need either:
- A mapping layer that converts stdlib `%Schema{}` → web `%Schema{}` at render time
- A richer stdlib schema (probably wrong — pulls rendering concerns into stdlib)
- A parallel web schema registry keyed by table name that the LV picks based on `active_table`

Recommended: the third option. Keep the two schema types distinct, and have the LV look up the web schema by table name from `RhoWeb.DataTable.Schemas` using the `active_table` assign. Key the registry by `table_name` for known tables, with a **generic fallback** for `"main"` / unknown tables. Also add `table_name` to `%Rho.Effect.Table{}` now (plan §Phase 3 step 5) so the LV can resolve the correct web schema from effects.

### 6. Two consumers: `SessionLive` and `SkillLibraryLive`

Both LiveViews own data table UI:
- `apps/rho_web/lib/rho_web/live/session_live.ex` — the main chat session LV; workspace-based
- `apps/rho_web/lib/rho_web/live/skill_library_live.ex` — the standalone skill library page with a chat overlay; holds `dt_projection` directly in assigns (not workspace-based)

Your rewrite has to handle both. `skill_library_live.ex` is simpler and a good first target.

### 7. Rho.Effect.Table is still in the flow

Tools return `%Rho.ToolResponse{effects: [%Rho.Effect.Table{...}]}`. `EffectDispatcher` consumes them. After the rewrite, `EffectDispatcher` should:
- Still call `DataTable.ensure_table` / `DataTable.replace_all` / `add_rows` on the server
- Stop publishing `rows_delta` / `replace_all` / `schema_change` legacy signals
- Possibly publish a "set active table" signal so the LV can switch tabs when an effect targets a named table

The `%Rho.Effect.Table{schema_key: :skill_library}` field is the hint — the plan §Phase 3 step 5 says to promote this to an explicit `table_name`.

## Things to watch

- **Don't break `skill_library_live.ex`** — it bypasses the workspace framework and uses `DataTableProjection` directly.
- **Don't break the spreadsheet agent** (`.rho.exs :spreadsheet`). End-to-end smoke test: `mix rho.chat -a spreadsheet` and run a "generate a role profile" flow.
- **Subscription races** — the LV must subscribe to the invalidation topic BEFORE calling `get_session_snapshot/1`, otherwise a write between snapshot-and-subscribe is lost. Do the subscribe first.
- **Don't add duplicate subscriptions** — `SessionCore.subscribe_and_hydrate/3` already subscribes to `rho.session.#{session_id}.events.*`. Adding a second dedicated data_table subscription will cause duplicate delivery. Reuse the existing wildcard subscription.
- **Version checks** — refetching on every invalidation is fine, but you can optimize by ignoring events where the reported `version` is not newer than the last rendered version (prevents redundant renders under heavy write bursts).
- **`terminate/2`** — must unsubscribe. Check both LVs.
- **Atom safety** — Iron Law #10. The plan's `"id:child:idx"` child addressing and any schema-key-to-table mapping must never call `String.to_atom/1` on user/LLM input. Use `String.to_existing_atom/1` with rescue or whitelist maps.
- **No Phoenix deps in stdlib** — keep all rendering, schema-label, and ws_state code in `apps/rho_web/`. The stdlib server already has zero Phoenix deps — don't regress that.
- **Tests** — add LV tests with `Phoenix.LiveViewTest` that cover: mount → snapshot displayed, external write → invalidation → refresh, tab switching, optimistic cell edit, child row edit, server crash → error UI.
- **The plugin shim must be deleted in the same PR** — otherwise you have three state paths: server, legacy signals, and snapshot refetch. Delete `stream_rows_progressive`/`stream_legacy_rows`/`publish_event` call sites in `Rho.Stdlib.Plugins.DataTable` and `EffectDispatcher` together with the LV rewrite.
- **Crash semantics are inconsistent with the plan** — `get_table_snapshot/2`, `get_rows/2`, `update_cells/3` all call `ensure_started/1`, which silently creates an empty server after a crash. This undermines `restart: :temporary` and the "show error" UX. Fix client API so mount/init explicitly calls `ensure_started/1`, but normal reads/writes return `{:error, :not_running}` if absent.
- **`rows_map` assumption in component** — the current `DataTableComponent` assumes `rows_map` + `sort_order`, but server snapshots return an ordered row list. Update grouping helpers to work on the ordered list directly.
- **Active-table fallback on removal** — when a `:table_removed` event fires for the active table, switch to `"main"` if present, else first table in `table_order`. This is currently unspecified.
- **Shell pulse / auto-open behavior** — workspace open/pulse currently piggybacks on projection state changes. You may lose those unless you explicitly mirror them in the snapshot-cache update path.

## Suggested sequencing

1. **Fix crash semantics first.** Change client API (`get_table_snapshot/2`, `get_rows/2`, `update_cells/3`) to return `{:error, :not_running}` instead of silently calling `ensure_started/1`. Only mount/init paths should call `ensure_started/1`. This is the hidden issue most likely to bite the pure-renderer rewrite.
2. Read all 7 files listed in §1 of "Why this is complicated" — the problem becomes much clearer once you've seen the workspace framework.
3. Build the web schema registry keyed by table name (§5). Add `table_name` to `%Rho.Effect.Table{}`.
4. Rewrite `DataTableComponent` to take `rows` (ordered list) + `schema` (web schema) + `active_table` directly instead of a projection state map. Update grouping helpers to work on the ordered list (not `rows_map` + `sort_order`).
5. **Rewrite `SkillLibraryLive` first** — it's simpler (no workspace framework) and validates the approach. Handle invalidation in `handle_info`, refetch snapshot, render via the new component interface.
6. **Rewrite `SessionLive` + `RhoWeb.Workspaces.DataTable`.** Keep the workspace framework. Put refresh logic in LV `handle_info` message handling — NOT in `component_assigns/2` or the reducer.
7. **Only after both LVs are snapshot-driven**, delete `DataTableProjection` (or reduce it to a thin stub).
8. Delete the legacy-signal shim in `Rho.Stdlib.Plugins.DataTable` and `EffectDispatcher`. Delete `stream_rows_progressive`, `stream_legacy_rows`, `publish_event`, and the `data_table_rows_delta` / `replace_all` / `update_cells` / `delete_rows` signal paths.
9. Add LV tests.
10. Run `mix cmd --app rho_web mix test` and the spreadsheet agent smoke test.

## Other deferred items from the original plan

While you're in the area, here's what else was explicitly deferred. Do NOT bundle these into the LV rewrite — they're separate PRs.

### Plan Phase 3 steps 2–5 — migrate frameworks tools to named tables

Currently `RhoFrameworks.Tools.LibraryTools.save_to_library` and `RhoFrameworks.Tools.RoleTools.save_role_profile` read from the default `"main"` table via `DT.read_rows/1`. The schemas already exist in `RhoFrameworks.DataTableSchemas` (`library_schema/0`, `role_profile_schema/0`). Once the LV supports multiple tables via the tab strip, switch these tools to `ensure_table` + `add_rows(…, table: "library")` and `read_rows(…, table: "library")`. Update `%Rho.Effect.Table{schema_key: :skill_library}` at `library_tools.ex:104` to carry an explicit `table_name` the LV can use to open the right tab.

### Plan Phase 4 — the three surviving quick wins (delete_by_filter is already shipped)

1. **Two-phase save (`save_*` with `mode: "plan" | "execute"`)** — `"plan"` returns a dry-run summary (rows to insert/update/delete, constraint violations). `"execute"` applies. Purely additive; no architecture changes.
2. **`get_org_view`** — new tool in `role_tools.ex` that reads all role profiles in the org, computes shared-vs-unique skills via `MapSet.intersection`, returns a summary. Pure Ecto query.
3. **Proficiency generation in parallel** — explicitly declined per the plan; the `:multi_agent` plugin handles this better.

### Plan §Risks item 6 — tape integration

Should `DataTable.Server` mutations be recorded on the tape for replayability? Design for the hook: accept a `tape_module` opt and log after each mutation. Not urgent.

### Plan §Risks item 10 — crash UX

`restart: :temporary` means a crashed server stays down. Tools and the LV should handle `{:error, :not_running}` gracefully: the LV should show "table state lost — reload/regenerate" rather than silently appearing empty. Currently this path is untested; worth adding a LV test that kills the server and verifies the error UI.

### Tracks A–H from the spreadsheet agent handoff

See `docs/archive/implemented/data-table-architecture-plan.md` §"Continuing from `docs/archive/implemented/spreadsheet-agent-handoff.md`". Track A (externalize the prompt into skill files under `.agents/skills/framework-editor/`) is the highest-leverage follow-up and is completely independent of the LV rewrite.

---

Start by reading `docs/archive/implemented/data-table-architecture-plan.md` for the architectural north star, then the files listed in §1. Expect the rewrite itself to be roughly one focused PR; the projection deletion + test additions will dominate the diff.
