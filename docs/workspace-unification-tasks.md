# Workspace Unification — Task List

Tracks implementation of the [workspace unification plan](workspace-unification-plan.md).

---

## Step 0: Signal Metadata Enrichment

- [x] Add `event_id` (UUID) generation to `Rho.Comms.SignalBus.publish/3`
- [x] Add `emitted_at` (millisecond timestamp) to `Rho.Comms.SignalBus.publish/3`
- [x] Define normalized signal shape: `%{type, data, meta: %{event_id, emitted_at, correlation_id, source}}`
- [x] Ensure EventLog replay produces the same normalized shape as live signals
- [x] Verify no downstream code breaks from added metadata fields
- [x] Tests: signals carry `event_id` and `emitted_at`; shape matches between live and replay

## Step 0.5: UI Snapshot Infrastructure

- [x] Create `RhoWeb.Session.Snapshot` module (`save/3`, `load/2`, `delete/2`)
- [x] Define snapshot schema (what to include/exclude — see plan)
- [x] Handle serialization: `MapSet` → list, atom keys → string keys
- [x] Handle deserialization: list → `MapSet`, string keys → atoms via `String.to_existing_atom/1`
- [x] Add `apply_snapshot/2` helper to `SessionLive` (or `SessionCore`)
- [x] Add `build_snapshot/1` helper to extract snapshotable state from socket
- [x] Tests: round-trip save/load produces identical state

## Step 1: Extract SessionCore

- [x] Create `RhoWeb.Session.SessionCore` module
- [x] Move session ID validation to `SessionCore.validate_session_id/1`
- [x] Move `subscribe_and_hydrate/2` (signal bus subscription, agent hydration, assign setup)
- [x] Move `unsubscribe/1` (bus unsub + spreadsheet PID unregistration)
- [x] Move `ensure_session/2` (session creation with `agent_name` option)
- [x] Move common assigns initialization (`init/2`)
- [x] Move avatar loading helpers
- [x] Move message sending logic (`send_message/3`)
- [x] Move UI stream tick handling (`handle_ui_spec_tick/2`)
- [x] Move spreadsheet PID registration into subscribe/unsubscribe lifecycle
- [x] Rename assigns: `active_tab` → `active_agent_id`, `tab_order` → `agent_tab_order`
- [x] Update `SessionLive` to call `SessionCore` functions
- [x] Update `SpreadsheetLive` to call `SessionCore` functions
- [x] Tests: existing LiveView tests still pass with no behaviour change

## Step 2: Extract Projections as Pure Reducers

- [x] Create `RhoWeb.Projection` behaviour (`handles?/1`, `init/0`, `reduce/2`)
- [x] Create `RhoWeb.Projections.SpreadsheetProjection`
  - [x] Move `handle_rows_delta` → `reduce_rows_delta`
  - [x] Move `handle_replace_all` → `reduce_replace_all`
  - [x] Move `handle_update_cells` → `reduce_update_cells`
  - [x] Move `handle_delete_rows` → `reduce_delete_rows`
  - [x] Move `handle_structured_partial` → `reduce_structured_partial`
  - [x] Move JSON extraction helpers (`extract_complete_rows`, `extract_complete_objects`, etc.)
  - [x] Move row helpers (`atomize_keys`, `assign_ids`, `filter_rows`, `apply_cell_changes_to_map`)
  - [x] Implement suffix-based `handles?/1` (no `String.contains?`)
  - [x] All functions operate on plain maps, not `Socket.t()`
- [x] Update `SpreadsheetLive` to call projection module in `handle_info`
- [x] Tests: pure reducer tests (rows_delta appends, replay produces identical state, etc.)
- [x] Tests: existing spreadsheet behaviour unchanged

## Step 3: Unify Into Single SessionLive

- [x] Create `@workspace_registry` (plain map, no behaviour)
- [x] Create `RhoWeb.Session.SignalRouter` module
  - [x] `route/3`: runs base SessionProjection, then all workspace projections
  - [x] `read_ws_state/2` and `write_ws_state/3` using single `ws_states` assign
- [x] Wire `SessionLive` to use `SignalRouter.route/3` with `workspaces` + `ws_states` assigns
- [x] Wire `SpreadsheetLive` to use `SignalRouter.route/3` (reads from `ws_states.spreadsheet`)
- [x] Tests: SignalRouter read/write and workspace dispatch
- [x] Implement unified `SessionLive.mount/3`
  - [x] `determine_initial_workspaces/1` from `live_action`
  - [x] Initialize `ws_states` from projection `init/0`
  - [x] Snapshot load on mount (from Step 0.5)
  - [x] Tail replay for catch-up
- [x] Implement `handle_params/3` — keep process alive on route changes
  - [x] Same session: add workspace tab, switch to it (no remount)
  - [x] Different session: full resubscribe
- [x] Implement workspace tab events
  - [x] `switch_workspace` — assign change only
  - [x] `add_workspace` — init projection, hydrate from tape, switch
  - [x] `close_workspace` — remove from workspaces/ws_states, switch to next
  - [x] `toggle_chat` — show/hide chat side panel
- [x] Implement `show_chat_panel?/1` — auto-hide when chatroom active
- [x] Implement `available_workspaces/1` — for "+" picker
- [x] Move `{:spreadsheet_get_table, ...}` handler to unified `SessionLive`
- [x] Implement snapshot save in `terminate/2`
- [x] Extract chat side panel as a component
- [x] Create workspace tab bar component (with "+" picker dropdown)
- [x] Extract `SpreadsheetComponent` LiveComponent from `SpreadsheetLive` render
- [x] Update router: all routes → `SessionLive` with `live_action`
- [x] Delete `SpreadsheetLive`
- [x] Tests: chat route works (full-width chat)
- [x] Tests: spreadsheet route works (spreadsheet + chat side panel)
- [x] Tests: workspace tab switching preserves state (no remount)
- [x] Tests: route change within same session preserves state

## Step 3.5: Conversation Threads

- [x] Create `RhoWeb.Session.Threads` module
  - [x] `list/2`, `active/2`, `get/3`
  - [x] `create/3` — create thread metadata
  - [x] `switch/3` — update `active_thread_id`
  - [x] `delete/3` — remove non-active thread
  - [x] JSON persistence in `_rho/sessions/{session_id}/threads.json`
- [x] Implement implicit "Main" thread creation on new session (`init/3`)
- [x] Implement fork flow
  - [x] `fork_thread/4` — compact before fork (LLM summary stub), create fork tape, create thread metadata
  - [x] `needs_summary?/2` — skip compaction for very short histories or recent anchors
  - [x] `summarize_up_to/3` — LLM-based summarization for fork anchor (stub, returns nil)
- [x] Implement thread switching
  - [x] Save current thread's snapshot
  - [x] Switch `active_thread_id`
  - [x] Restart agent with new tape (Option A)
  - [x] Load target thread's snapshot (or replay)
- [x] Make snapshots thread-aware (`snapshots/{thread_id}.json`)
- [x] Thread picker UI
  - [x] Hidden when single thread
  - [x] Dropdown in chat panel header when 2+ threads
  - [x] Thread summary preview on hover (from thread summary field)
  - [x] "Fork from here" action
  - [x] "New blank thread" action
- [x] Implement "Fork from here" on chat messages (resolve message → tape entry ID via index)
- [x] Tests: implicit main thread created
- [x] Tests: fork creates new tape with correct fork_point
- [x] Tests: thread switch saves/loads correct snapshots
- [x] Tests: agent restarts with correct tape on thread switch

## Step 4: Add ChatroomProjection + Chatroom Workspace

- [x] Create `RhoWeb.Projections.ChatroomProjection`
  - [x] Handle `message_sent`, `broadcast`, `text_delta`, `llm_text`, `turn_finished`
  - [x] Suffix-based `handles?/1`
  - [x] Pure `reduce/2` using `meta.event_id` for message IDs, `meta.emitted_at` for timestamps
  - [x] `append/2`, `update_streaming/3`, `flush_streaming/2`
- [x] Create `RhoWeb.ChatroomComponent` LiveComponent
  - [x] Interleaved timeline rendering with speaker labels
  - [x] Color-coded per agent_id
  - [x] Direction indicators (→ for direct, "(to all)" for broadcast)
  - [x] Streaming indicator per agent
  - [x] Input area with @mention support
- [x] Add chatroom to `@workspace_registry`
- [x] Add `/chatroom` and `/chatroom/:session_id` routes
- [x] Add `determine_initial_workspaces(:chatroom)` clause
- [x] Implement @mention parsing in `send_message` (resolve role/agent_id → target)
- [x] Tests: chatroom projection handles all multi-agent signal types
- [x] Tests: replay produces identical chatroom state
- [x] Tests: @mention routing works

## Step 5: Formalize Workspace Behaviour (If Needed)

- [x] Evaluate whether plain registry map is sufficient after chatroom — yes, sufficient
- [ ] ~~If needed: create `RhoWeb.Workspace` behaviour~~ — not needed
- [ ] ~~If needed: convert registry entries~~ — not needed

## Step 5.5: Purify SessionProjection

- [x] Audit all side effects in current `SessionProjection`
  - [x] `push_event/3` calls — 4 sites (text-chunk, stream-end x2, signal)
  - [x] `Process.send_after/3` calls — 1 site (ui_spec_tick)
  - [x] `System.unique_integer/1` / `System.monotonic_time/1` calls — msg_id + timestamps
  - [x] `Rho.Agent.Registry` lookups — message_sent (pre-resolved in SignalRouter)
  - [x] Direct socket assign reads/writes — all converted to plain map ops
- [x] Create `RhoWeb.Projections.SessionState` — pure reducer
  - [x] Returns `{state, effects}` where effects are descriptors
  - [x] Effect types: `{:push_event, name, payload}`, `{:send_after, delay, msg}`
  - [x] Registry lookups pre-resolved in SignalRouter enrichment step
  - [x] IDs via monotonic counter in state; timestamps via signal meta.emitted_at
- [x] Create `RhoWeb.Session.SessionEffects` — impure effect applicator
  - [x] `apply/2` reduces effect list into socket changes
- [x] Update `SignalRouter` to call `SessionState.reduce/2` then `SessionEffects.apply/2`
- [x] Tests: `SessionState.reduce/2` is pure (same input → same output) — 33 tests
- [x] Tests: all existing session behaviour preserved — 195 tests pass

## Step 6: Event-Sourced User Edits

### Prerequisites

- [x] Generate stable row IDs at publish time in `Rho.Stdlib.Plugins.Spreadsheet`
- [x] Include row IDs in `rows_delta` event payloads
- [x] Ensure `Rho.Comms.publish/3` writes to durable tape (not just transient PubSub)

### Implementation

- [x] Add `client_op_id` to user edit signals
- [x] Implement optimistic local update in `SpreadsheetComponent`
- [x] Publish edit signals through `Rho.Comms.publish/3`
- [x] Update `SpreadsheetProjection.reduce/2` to handle `client_op_id` reconciliation
  - [x] Skip if matches pending optimistic op
  - [x] Apply normally if from another user
- [x] Implement last-write-wins conflict policy at cell level
- [x] Tests: local edits appear immediately (optimistic)
- [x] Tests: remote edits arrive and are applied
- [x] Tests: same edit not applied twice (client_op_id dedup)
- [x] Tests: conflict resolution (last-write-wins by `emitted_at`)
