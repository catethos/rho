# Large-Library Data Table — First-Principles Plan

Replaces an earlier draft that proposed streaming + virtualization +
a lazy-table backend. Those were patches to symptoms. The underlying
problem is a conflated concept, not a missing optimization.

## The conflation

`Rho.Stdlib.DataTable` is doing two different jobs:

1. **Editable session scratch space.** Small (≤ a few hundred rows),
   mutable, ephemeral. Source of truth lives in the per-session
   GenServer until the user saves. Examples: a role_profile draft, an
   in-progress fork, the Suggest output.

2. **Read view over a Postgres table.** Large, immutable, source of
   truth in Postgres. Examples: ESCO, any public framework, "show me
   what's in this library."

Job 1's natural data structure is an in-memory list with versioning
and coarse invalidation — exactly what `DataTable.Server` is. Job 2's
natural data structure is a query plan. We've been forcing job 2 into
the same in-memory list, which is why everything falls over at 14k
rows. Adding streams or pagination would just hide the conflation.

## What to do

**Stop putting Postgres-backed libraries into `DataTable`.**

The `DataTable.Server` is right-sized for ephemeral editable workspaces.
Don't change it. Don't add a lazy backend. Don't add virtualization.
Change the dispatch instead.

`load_library_into_data_table` (`apps/rho_web/lib/rho_web/live/app_live.ex:3554–3590`)
currently treats every library the same. Split by mutability:

- **Mutable library** (the user's draft / fork) → existing path.
  `load_library_rows` + `replace_all`. Bounded by the user's typical
  customisation size; if it ever isn't, that's a different problem
  (someone forked ESCO and is editing all 14k rows — extremely rare).

- **Immutable library** (ESCO, any public framework) → **do not load
  rows into `DataTable`**. Open the library's existing browse view as
  the chat companion. Browse view is already implemented and already
  Postgres-backed lazily — see "Existing assets" below. Agent reads
  via existing tools.

This is a routing change, not a data-structure rewrite.

## Existing assets we already have

- `apps/rho_web/lib/rho_web/live/app_live.ex:188–238` — the libraries
  show page builds its UI from `list_skill_index` + `list_cluster_skills`.
  Postgres-backed, lazy per cluster, fast on ESCO. This is the canonical
  "library browser." **Reuse it.**
- `RhoFrameworks.Library.list_skill_index/2` (`library.ex:773`) —
  one row per (category, cluster) with counts. Cheap aggregate query.
- `RhoFrameworks.Library.list_cluster_skills/4` (`library.ex:794`) —
  loads one cluster on demand.
- Agent tools `browse_library`, `find_skill`, `find_similar_skills`
  already exist (`apps/rho_frameworks/lib/rho_frameworks/tools/`).
  These are how the agent reads libraries today.

## Concrete changes

### Change 1 — Loader picks a strategy by mutability

`apps/rho_web/lib/rho_web/live/app_live.ex:3554` —
`load_library_into_data_table`:

```elixir
defp load_library_into_data_table(socket, library_id) do
  org_id = ...
  lib = Library.get_library(org_id, library_id) ||
        Library.get_visible_library!(org_id, library_id)

  if lib.immutable do
    open_library_browser_companion(socket, lib)
  else
    load_mutable_library_into_data_table(socket, lib)
  end
end
```

`load_mutable_library_into_data_table` is the current body — unchanged.
`open_library_browser_companion` is new but small: it patches to the
existing libraries show page in a chat-companion layout, so the agent
sits next to the browser instead of behind a data table. The chat
panel already supports being a companion to non-data-table workspaces
(see `Shell.show_chat`).

### Change 2 — `browse_library` agent tool defaults to aggregate

`apps/rho_frameworks/lib/rho_frameworks/tools/library_tools.ex:289–318`:

The agent tool currently calls `Library.browse_library(lib.id, opts)`
with no limit. For ESCO this returns 14k rows in one tool result —
which blows the LLM context the same way the LV blows the WebSocket.

Fix: when the resolved library has > N skills (start at 500) and no
`category` filter, return a category index instead and tell the agent
to drill down.

```elixir
case Library.skill_count(lib.id) do
  n when n > 500 and is_nil(args[:category]) ->
    index = Library.list_skill_index(lib.id)
    {:ok, format_category_index(lib.name, index, n)}
  _ ->
    skills = Library.browse_library(lib.id, opts)
    {:ok, format_browse_results(lib.name, skills)}
end
```

Format text steers the agent: "Library X has 13,960 skills across 30
categories. Call `browse_library` again with `category: <name>` to
list a category, or use `find_skill` for keyword search."

This change is independent of the routing change; ship it whether or
not the LV change lands first.

### Change 3 — Optional `:read_only` flag on `DataTable.Table`

Not needed today. Worth flagging only because we may want it later if
we ever decide to import a *partial* view of a public library into
the editable workspace ("import these 50 ESCO skills as draft rows").
Implementation when we need it: add `:read_only` field; mutation
calls return `{:error, :read_only, reason}`; loader sets it for any
table copied from an immutable source. **Don't build this now.**

## What we are explicitly not building

- Phoenix streams in `data_table_component`. Not needed; large
  read-only libraries don't go through the data table at all.
- A lazy `DataTable` backend. Adds an abstraction we don't need.
- Server-side pagination + virtualized scrolling in the data table.
  The data table is for editable work; if it grows beyond a few
  thousand rows the user is misusing it.
- Changes to `DataTable.Server` storage. It's fine as-is.

## Edge cases

- **A user forks ESCO and now has a 14k-row editable library.**
  Acceptable but rare. If it becomes common, add Phoenix streams to
  `data_table_component` *then* — and only that, not the lazy backend.
  Until then, the editable path's natural growth limit (a typical org
  customizes < 1k skills) keeps things tractable.
- **An agent calls `get_rows` on a library opened via the browser.**
  Doesn't happen — the library isn't in the agent's `DataTable` at
  all. Agent uses `browse_library`, `find_skill`, etc., which already
  exist and which Change 2 makes scale.
- **A user wants to copy a few ESCO skills into their draft.**
  Future affordance: an "import to my workspace" button on the browse
  view, or an agent tool `import_skills(library_id, skill_ids)` that
  copies rows into the user's editable table. Out of scope for this
  plan; mention as a follow-up.
- **Tape replay snapshot.** No change. Browser-backed views aren't
  in `DataTable`, so they aren't in the snapshot. The browser page
  re-derives state from `library_id` on mount, which is already how
  the libraries show page works.

## Sequencing

1. **Change 2** first (independent, small, fixes a latent agent
   context-blow problem regardless of UI). One-file edit in
   `library_tools.ex`. ~30 lines.
2. **Change 1** second. Splits the loader and routes immutable
   libraries to the browse companion. Touches `app_live.ex` only.
   ~50 lines plus a helper for the companion layout.
3. Telemetry over a couple of weeks. Look for: anyone forking ESCO
   and editing > 2k skills; any agent flow that wanted `browse_library`
   to dump everything. If neither shows up, this is done.

## Open questions

1. **Companion layout.** Today the data-table workspace and the chat
   panel can sit side-by-side via `Shell`. The browse view is its
   own LiveView (`AppLive` :libraries_show action). Decide whether
   the companion is "open the libraries show page in a tab next to
   chat" or "render a stripped-down browse component inside the
   chat workspace." Former is simpler and reuses existing UI; latter
   is more integrated but means duplicating the index/cluster UI.
   Default: simpler.
2. **What does the chat agent know about?** When the browse companion
   is open, the agent's `library_id` context should be set so its
   tool calls (`browse_library`, `find_skill`) default to that
   library. Trivial — pass `library_id` through `chat_context` the
   same way other entry points do (see
   `app_live.ex:3718 maybe_put("library_id", ...)`).
3. **Mutable libraries that grow large.** Pick a threshold above
   which we *also* refuse to dump into the data table for the user's
   own libraries. 5k feels right but pick once we have telemetry.

## Summary

- Throw out streaming / virtualization / lazy-backend.
- The fix is a routing change: immutable library → existing browse
  page; mutable library → existing data table.
- One independent agent-tool fix so `browse_library` doesn't blow the
  LLM context on ESCO.
- No new data structures.
- Total surface: two files, ~80 lines.
