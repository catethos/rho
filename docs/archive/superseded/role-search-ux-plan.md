# Role Search UX — Two-Stage + Embedding Cache

## Problem

`/orgs/:slug/roles` runs server-side semantic search via
`Roles.find_similar_roles/3`. Every keystroke (post 300ms debounce) currently
blocks on:

1. `RhoEmbeddings.embed_many([query])` — OpenAI API round-trip, ~200–500ms
2. pgvector KNN — ~10–50ms

Total: **~500–800ms** of blank-results state after typing stops. The LiveView
input also stays unresponsive during the synchronous handler.

## Goal

Perceived latency under 50ms, semantic results within ~500ms, no UX regression
on rare/uncached queries. Keep the existing semantic-search quality.

## Approach

Two coordinated changes:

### 1. Two-stage rendering: instant LIKE → semantic backfill

On each `search_roles` event:

1. **Synchronously** run the existing LIKE branch
   (`find_similar_roles_fallback/3`). This is a single SQL query, ~10–50ms,
   returns rows in the same shape as the KNN branch. Render immediately.
2. **Async** (`start_async/3`) kick off the embedding+KNN call. When it
   returns, replace the rendered list with the semantic results.
3. While the async is in flight, show a subtle "Refining…" indicator next to
   the search input.
4. Cancel any in-flight async task when a newer keystroke arrives so the
   latest query always wins (avoid stale-result clobber).

### 2. Embedding cache (LRU, keyed on exact query string)

OpenAI is the bottleneck. Backspacing, retyping, or revisiting the page with
the same query should not re-hit the API.

- Per-LV cache stored in socket assigns: `%{query => vector}`, capped at ~50
  entries with simple FIFO eviction (no need for true LRU at this size).
- Or: process-wide ETS cache with TTL (~1 hour), shared across all sessions.
  Bigger win because hot queries ("data scientist", "engineer") hit OpenAI
  exactly once per TTL window across the entire app.
- **Pick ETS** — small change, much bigger payoff. Bound size to ~1000
  entries with a simple sweep on insert.

## Implementation

### Files to touch

- `apps/rho_frameworks/lib/rho_frameworks/roles.ex`
  - Split `find_similar_roles/3` into two public functions: `find_similar_roles_fast/3`
    (LIKE only, synchronous) and `find_similar_roles_semantic/3` (KNN, can fall
    back to LIKE if embed fails). Keep the existing `find_similar_roles/3` as a
    thin wrapper for non-LV callers (`role_tools.ex`, `load_similar_roles.ex`)
    that calls semantic.
  - Both functions return the same map shape they already do.

- `apps/rho_frameworks/lib/rho_frameworks/roles/embedding_cache.ex` (new)
  - GenServer wrapping ETS table. Public API:
    - `get(query) :: {:ok, vector} | :miss`
    - `put(query, vector) :: :ok`
  - Bounded to ~1000 entries with FIFO eviction on insert (oldest 100 dropped
    when full).
  - Started in `RhoFrameworks.Application` supervision tree.
  - `find_similar_roles_semantic` consults cache before calling
    `RhoEmbeddings.embed_many`.

- `apps/rho_web/lib/rho_web/live/app_live.ex`
  - Replace synchronous `handle_event("search_roles", ...)`:
    1. Call `find_similar_roles_fast` synchronously, assign as
       `role_search_results`.
    2. Cancel any prior async via `Phoenix.LiveView.cancel_async/2`.
    3. Start `Phoenix.LiveView.start_async(socket, :semantic_search, fn -> ... end)`
       that calls `find_similar_roles_semantic`.
    4. Assign `role_search_pending?: true` so the template can show
       "Refining…".
  - Add `handle_async(:semantic_search, {:ok, results}, socket)` to replace
    `role_search_results` and clear the pending flag. Guard against stale
    results by including the query string in the async payload and comparing
    to the current `role_search_query` — if it doesn't match, drop the
    response.
  - Template: render a small "Refining…" badge next to the search input when
    `@role_search_pending?` is true.
  - On query empty: clear pending flag, cancel in-flight async, set results
    to `nil` (back to grouped private list).

### Behaviour matrix

| User action | Visible immediately | Settled within 500ms |
|---|---|---|
| Types "eng" | LIKE matches for `%eng%` | KNN-ranked semantic matches |
| Backspaces to "en" | LIKE matches for `%en%` | KNN matches (cache hit if recent) |
| Pauses on cached query | LIKE matches | KNN from cached vector → no OpenAI call (~30ms total) |
| Clears query | Grouped private list | (no async) |
| OpenAI fails / times out | LIKE matches stay visible | "Refining…" flag clears; user sees fallback results |

### Stale-result handling

Each async carries the query that triggered it. In `handle_async`, compare
to the live `role_search_query`:

```elixir
def handle_async(:semantic_search, {:ok, %{query: q, results: results}}, socket) do
  if socket.assigns.role_search_query == q do
    {:noreply, assign(socket, role_search_results: results, role_search_pending?: false)}
  else
    # User has since typed more. Discard. The newer async will deliver.
    {:noreply, socket}
  end
end
```

`Phoenix.LiveView.cancel_async/2` on each new keystroke also helps — the
cancelled task simply won't deliver. The query-comparison guard is a
belt-and-braces safeguard.

## Out of scope

- Local fastembed model (much bigger ops change; revisit only if OpenAI
  cost/latency becomes the bottleneck after the cache lands).
- Search-on-submit UX (rejected — existing per-keystroke feel is the right
  target, just faster).
- Prefix-trie pre-computation of common queries (premature; cache will cover
  the realistic hot set).

## Verification

- Compile: `mix compile`
- Tests: existing `find_similar_roles/3` tests in
  `apps/rho_frameworks/test/rho_frameworks/roles_test.exs` should still pass
  (the wrapper preserves the public API).
- Manual: type "data scientist" — should see LIKE matches instantly,
  semantic match (`data scientist` at #1) within ~500ms first time, ~30ms
  on repeat (cache hit).
- Logs: confirm `RhoEmbeddings.embed_many` is called once per unique query,
  not once per keystroke.

## Rollout

Single PR. No migrations. No config changes. Feature works the same for
non-LV callers (tools, use_cases) — they keep using `find_similar_roles/3`
which now delegates to the semantic variant unchanged.
