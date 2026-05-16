# Data Table Streams — Bounded LV Diffs for Large Editable Tables

Plan for converting `RhoWeb.DataTableComponent` to render rows via
`Phoenix.LiveView.stream/3` so the LV diff size and DOM cost stay bounded
regardless of table size.

This is the fallback we left open in the [earlier first-principles plan](large-library-data-table-plan.md):
once a user forks an immutable library whole and edits, say, a 3,800-row
category, the Postgres-backed read-view trick no longer applies — they
have a genuinely large editable table, and the LV must render it without
freezing the tab.

## Why streams (and not virtualization or pagination alone)

- **Streams** keep rows out of `@assigns` and let LV emit only diff
  fragments for the visible window. The component's process memory stays
  bounded; the WebSocket frame stays bounded; the browser DOM update
  stays bounded.
- **Pagination alone** changes the UX (page numbers, "load more"
  buttons). Streams + `phx-viewport-bottom` keep the existing scroll-to-
  see-more feel.
- **Client-side virtualization** (custom JS hook) is more code and harder
  to integrate with editing. Streams are the LV-native answer.

## Goals

1. Expanding a 3,800-row group renders in < 200ms with a bounded LV diff
   (target: ≤ 200 rows in the first frame).
2. Subsequent rows arrive on `phx-viewport-bottom` with no perceptible
   pause for the user.
3. Existing affordances keep working: column sort, optimistic edits,
   in-line cell editing, children-panel (proficiency levels) expansion,
   delete-row, add-row-in-group, group-name editing.
4. No changes required in `DataTable.Server` or agent tools — streams
   are an LV-rendering concern.

## Non-goals

- Replacing `DataTable.Server` storage. It still holds all rows for the
  session table. Memory cost is acceptable (~5MB for 14k skill rows
  without embeddings).
- Server-side filtering/search beyond what already exists.
- Cross-group virtualization (the page can still have many groups; only
  rows-within-a-group stream).
- Mobile-specific layout.

---

## Current architecture (recap, with file:line refs)

`apps/rho_web/lib/rho_web/components/data_table_component.ex`:

- `update/2` — line 30 onwards. Receives the full row list from parent,
  applies optimistic edits, sorts, groups via `group_rows/2`, assigns
  `:rows`, `:grouped`, `:collapsed`.
- Top-level template (line 691) walks `@grouped` (a 2-level structure)
  and renders each L1/L2 group's header + body.
- `data_table_rows/1` (line 755) — the per-group body. Renders every
  row of the group inline:
  - Panel mode (skills with proficiency-levels children): line 800–865
  - Flat mode: line 867+
- `handle_event("toggle_group", ...)` (line 316) — flips a `MapSet` in
  `@collapsed`. Pure server-state, no DB.

Rendering cost when a 3,800-row group expands ≈ 3,800 `<tr>`s in a single
LV diff; the WebSocket frame is several MB and the browser parses
3,800 DOM nodes on the main thread. Both are O(rows-in-group), and
that's what we want to make O(window-size).

---

## Design

### One stream per L2 (or L1-leaf) group

Each leaf group — the innermost level that actually contains rows —
gets its own LV stream:

```elixir
stream_name = :"rows_#{group_id}"
# group_id is the existing "grp-<cat-slug>-<cluster-slug>" identifier
# already minted at template line 696, 721
```

Why per-group instead of one flat stream:

- Group expand/collapse maps cleanly to "populate stream" / "leave
  empty." A collapsed group renders zero rows.
- A user expanding *one* category of ESCO doesn't trigger the
  population of any other group.
- Phoenix streams aren't easily filterable in templates; per-group
  streams sidestep the issue.
- `stream_insert/4` for optimistic edits and `stream_delete/3` for
  row removal both target a single named stream — clean fit.

The cost: many stream names per page (one per leaf group). LV handles
this fine; each stream is just an entry in `@streams`.

### Group lifecycle

| User action | Component does |
|-|-|
| Initial render | All groups collapsed (current behavior); no streams populated. Each group renders header only. |
| Click chevron on group `G` | `toggle_group` handler: if `G` is becoming visible and its stream is unpopulated, call `populate_group_stream/2` to seed first window (default 200 rows). Otherwise just toggle `@collapsed`. |
| Scroll to bottom of `G`'s body | `phx-viewport-bottom="load_more_in_group" phx-value-group=G` on the group body. Handler appends the next 200 rows. |
| `:table_changed` (server-side mutation) | Reset every populated group's stream with `reset: true`. Collapsed groups stay unpopulated. |
| Optimistic edit on row `R` in group `G` | `stream_insert(socket, :"rows_G", updated_R)` — same dom_id replaces in place. |
| Add row in group `G` | `stream_insert(socket, :"rows_G", new_row, at: 0)`. |
| Delete row `R` in group `G` | `stream_delete(socket, :"rows_G", R)`. |
| Sort change | Reset all populated streams with the new ordering. |

### Component state additions

```elixir
# Tracks which groups have a streamed window. Maps group_id → %{
#   total: total_row_count,
#   loaded: rows_streamed_so_far,
#   sort: {sort_by, sort_dir} the stream is ordered by
# }
@streamed_groups :: %{String.t() => %{total: non_neg_integer(),
                                       loaded: non_neg_integer(),
                                       sort: {atom() | nil, :asc | :desc}}}

# Page size, configurable via assigns from parent
@stream_page_size :: pos_integer() # default 200
```

`@rows` and `@grouped` are kept *for grouping metadata only* — i.e.,
the parent still passes the full row list, the component still groups
to know what L1/L2 sections exist and their counts. But row rendering
inside a group's `<tbody>` no longer iterates `@rows`; it iterates the
stream.

Memory: `@rows` lives in the LV process the same way it does today. We
only avoid emitting it into the LV diff. (We could later remove `@rows`
from the assigns and pull rows from the parent on-demand, but that's a
bigger refactor; not required to fix the symptom.)

### Template changes

Replace inside `data_table_rows/1`:

```heex
<%= for row <- @rows do %>
  <tr id={"row-#{row_id(row)}"}>...</tr>
<% end %>
```

with:

```heex
<tbody id={"rows-tbody-#{@group_id}"} phx-update="stream"
       phx-viewport-bottom={if more_pages?(@streamed_groups, @group_id),
                             do: "load_more_in_group", else: nil}
       phx-value-group={@group_id}>
  <tr :for={{dom_id, row} <- @streams[:"rows_#{@group_id}"] || []}
      id={dom_id}>...</tr>
</tbody>
```

`phx-update="stream"` is required for streams to work correctly. The
`phx-viewport-bottom` is unset (nil) when no more pages remain, so it
stops firing when the group is fully streamed.

The two render branches (panel mode vs flat) both apply.

### Children panel (proficiency-level rows)

These are expanded inline below their parent row. They're small (a
handful of levels per skill) and per-row. Streams handle them fine —
when a parent row is expanded, its children render inside the same
row's `<td>` panel; we don't put them in a stream.

If a parent row is in the stream and its children change (add level,
edit level), we re-emit that parent row via `stream_insert` and the
template re-renders the parent including its children.

### Sort column

When the user clicks a column header:

1. `handle_event("sort_column", ...)` updates `@sort_by`/`@sort_dir`.
2. Re-sort `@rows` once (already done; cheap on 14k items).
3. Re-group `@grouped` (also cheap).
4. For every populated group, reset the stream with the first window
   of the new ordering: `stream(socket, :"rows_G", first_window, reset: true)`.

Collapsed groups stay unpopulated.

### `:table_changed` invalidation

The parent LV already calls `send_update(DataTableComponent, ...,
rows: ...)` when the DataTable.Server fires `:table_changed`. Today
that re-runs `update/2` and re-renders all rows.

After:
- `update/2` notes that `@rows` has changed (compare versions).
- Walks `@streamed_groups` and, for each, recomputes the group's row
  list (by filtering the new `@rows`) and resets that stream.
- Collapsed groups stay zero-cost.

The diff cost on a coarse invalidation now scales with *visible
populated groups × page size*, not with total row count.

---

## Phased implementation

### Phase A — Stream the inner row body, no behavior change

**Scope:** only `data_table_rows/1` and its callers in the main
template (lines 691–747, 755–877).

- Add `stream_configure/3` calls in `mount/1` for streams that the
  component might use. Configurations are idempotent and cheap; we can
  configure on-demand by `populate_group_stream/2`.
- Replace the inner `for row <- @rows` with the streams template snippet
  above.
- On every `update/2` that delivers a fresh `@rows`, populate every
  *currently expanded* group's stream with the full row list (no
  windowing yet).

This is the safest first step — it converts the rendering path to
streams without changing user-visible behavior. Diffs become smaller
(streams emit one item at a time during reset). Tests should still
pass unmodified.

**Files touched:** `data_table_component.ex` only.

**Validation:** before/after WebSocket frame size on a 3,800-row group
expand. Should drop dramatically because `phx-update="stream"` emits
one stream item per row instead of one big subtree.

### Phase B — Lazy population on expand

**Scope:** `handle_event("toggle_group", ...)` and the new
`populate_group_stream/2` helper.

- New `@streamed_groups` assign.
- `populate_group_stream` runs on first expand; grabs the group's
  rows from `@rows`, sorts using current `@sort_by`/`@sort_dir`,
  takes first `@stream_page_size`, calls `stream(socket, name, ...)`.
- On collapse, the stream stays populated (cheap; user might re-expand).

Collapsed groups now contribute zero rows to the LV state and zero
DOM nodes.

**Files touched:** `data_table_component.ex` only.

**Tests:** add `data_table_component_test.exs`:
- Group with 100 rows: expand renders 100 rows.
- Group with 5,000 rows: expand renders 200 rows; `more_pages?` returns
  true.
- Multiple groups: expanding A doesn't populate B.

### Phase C — Viewport-driven incremental loading

**Scope:** new event `load_more_in_group`, the `phx-viewport-bottom`
attribute on group `<tbody>`, page tracking in `@streamed_groups`.

- `handle_event("load_more_in_group", %{"group" => g}, socket)`:
  computes the next window from `@rows` (filtered to group, sorted,
  sliced), calls `stream(socket, :"rows_#{g}", chunk)` (no reset).
  Bumps `loaded`. If `loaded >= total`, sets `more_pages?` false so the
  `<tbody>` stops firing the event.

**Files touched:** `data_table_component.ex` only.

**Tests:**
- 5,000-row group: expand → load_more → load_more → load_more …
  until total reached; then no more events fire.
- Sort change mid-scroll resets the group to first window.

### Phase D — Sort + invalidation reset

**Scope:** `handle_event("sort_column", ...)` and the `:table_changed`
path in `update/2`.

- On sort change: walk populated groups, reset each with first window
  in new order.
- On version bump in `update/2`: same reset for populated groups.

**Files touched:** `data_table_component.ex` only.

**Tests:**
- Edit a cell → optimistic-edit-applies-on-stream test (already in B?).
- Receive a `:table_changed` event with new rows → populated streams
  reset.

### Phase E — Optimistic edits + add/delete via stream ops

**Scope:** the existing `start_edit`, `cancel_edit`, `commit_edit`,
`add_row`, `delete_row` handlers — they currently work by re-rendering
the full row list with `apply_optimistic`. Switch to `stream_insert`
for inserts/updates and `stream_delete` for deletes on the row's
group stream.

**Files touched:** `data_table_component.ex` only.

**Tests:**
- Edit a cell while group is streamed → only that row's stream entry
  updates; other rows don't re-render.
- Delete a row → row disappears from stream; row count decrements.
- Add a row → appears at top of group stream.

### Phase F — Polish

- Remove `@rows` from the rendered template (still in assigns for
  group computation; stop emitting via `<%= length(@rows) %>` etc).
- Trim `apply_optimistic` (no longer needed if Phase E lands).
- Drop the optimistic-edit assigns map after server confirmation
  (stream items are authoritative once committed).

---

## Cross-cutting concerns

### Group computation cost

`group_rows/2` runs on every `update/2`. For 14k rows it's ~30ms in
Elixir — fine. We don't need to move grouping to streams.

### `dom_id` collisions across groups

Use the existing `row_id/1` helper which returns the row's stable
identifier. Same row in two streams would collide, but our model is
1-row-1-group so this can't happen.

### Expand-all / collapse-all

These exist as helpers that flip the `@collapsed` set. After Phase B,
expand-all triggers populate of every group — for a library with many
small groups this could mean dozens of stream populations. Check the
total row count first; if > some cap, refuse expand-all with a flash
("Too many rows; expand groups individually") rather than freezing the
tab.

### Add row when no group is yet expanded

`add_row` posts to the parent which writes through `DataTable.Server`.
The `:table_changed` event arrives; if the group it landed in isn't
yet streamed, do nothing (stays unstreamed). Once user expands the
group, the new row is included in first window.

### `phx-viewport-bottom` and groups in a single page

If multiple groups are expanded simultaneously and the user scrolls,
which group's `phx-viewport-bottom` fires? The LV docs are clear:
each `<tbody>` with the attribute fires independently when its bottom
is reached. The `phx-value-group` distinguishes them in the handler.

### Tape replay / snapshot

Streams aren't part of the workspace snapshot. Tape replay runs
`update/2` again with the rehydrated `@rows`; populated streams get
reseeded based on which groups are expanded. No special handling.

---

## Risks & open questions

1. **Stable sort across pages.** When loading the next 200 rows, ties
   on the sort key would shuffle if Elixir's `Enum.sort_by` isn't
   stable. It is stable (since OTP 22), but document it. Or always
   add `:slug` as a secondary sort key.
2. **Old browsers and `phx-viewport-bottom`.** Phoenix LV docs note
   it's IntersectionObserver-based; modern browsers fine, IE not
   supported. Confirm target browsers; we don't support IE anyway.
3. **`phx-update="stream"` and existing classes.** The data table has
   classes like `dt-row dt-parent-row dt-skill-expanded` that depend
   on the row's expanded state. With streams, expansion state per row
   is server-tracked; updates re-emit the row with the new class.
   Verify the children-panel toggle still flicks state correctly.
4. **Streamed-group memory.** Even with streams, the LV holds a
   `dom_id → row` map per stream for diff calculation. For a fully
   loaded 3,800-row group that's roughly the same memory as before.
   But we only fully load if the user actually scrolls through the
   whole thing, which is rare. Memory becomes proportional to
   *interaction depth*, not data size.
5. **Tests using `assert html =~ "<tr id=\"row-..."`** style. The
   existing test suite likely has assertions that scan the rendered
   HTML for row content. With `phx-update="stream"`, the rendered HTML
   in tests still contains `<tr>`s after the stream has emitted; these
   tests should keep working. Verify in Phase A.

---

## Out of scope for this plan

- Server-side row search/filter (query box on top of the data table).
- Row groupings other than the existing `group_by` schema field.
- Persisting expand/collapse state across page reloads.
- Mobile column collapsing.

---

## Suggested rollout

- **Phase A** lands behind no flag. Pure refactor; equivalent UX.
  Validate via WS frame size on a forked-ESCO testbed.
- **Phases B–E** can land in any order after A. Each is internally
  consistent.
- **Phase F** is cleanup; defer until B–E settle.

If Phase A alone is enough (because diff size + DOM ops are the only
real bottleneck and lazy-load isn't critical for the typical user),
stop there. Phase B+ are progressive enhancements.

## Summary

- One stream per leaf group; group bodies use `phx-update="stream"`.
- Collapsed groups: zero stream cost.
- First expand: populate first 200 rows.
- Scroll inside group: `phx-viewport-bottom` loads next 200.
- Sort/invalidation: reset populated streams.
- Edits/adds/deletes: `stream_insert`/`stream_delete` on the row's group.
- Six small phases, each landable independently.
- All changes are inside `data_table_component.ex` — no `DataTable.Server`
  changes, no agent-tool changes, no schema changes.
