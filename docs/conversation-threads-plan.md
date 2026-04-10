# Conversation Threads — Implementation Plan

## Scope

Step 3.5 from workspace-unification-tasks.md. This plan covers the **pure data layer** (`Rho.Session.Threads`) and its tests. LiveView wiring and UI are deferred to a follow-up.

## Data Model

A thread is a named tape with metadata:

```elixir
%{
  "id" => "thread_abc123",
  "name" => "Category-first approach",
  "tape_name" => "session_xxx_fork_1",
  "created_at" => "2026-04-06T14:30:00Z",
  "forked_from" => nil | "thread_main",
  "fork_point" => nil | 42,
  "summary" => nil | "Trying category-first...",
  "status" => "active"
}
```

String keys throughout (JSON round-trips cleanly without atom creation).

## File Layout

```
_rho/sessions/{session_id}/
  threads.json          # {active_thread_id, threads: [thread...]}
  snapshots/
    thread_main.json
    thread_abc123.json
```

`threads.json` schema:

```json
{
  "active_thread_id": "thread_main",
  "threads": [
    {"id": "thread_main", "name": "Main", "tape_name": "session_abc_def", ...}
  ]
}
```

## Module: `Rho.Session.Threads`

Location: `apps/rho_web/lib/rho_web/session/threads.ex` (under `RhoWeb.Session` namespace, alongside `SessionCore`, `SignalRouter`, `Snapshot`).

### Public API

| Function | Signature | Description |
|----------|-----------|-------------|
| `init/2` | `(session_id, workspace, opts)` | Create implicit "Main" thread with the session's existing tape_name. Writes `threads.json`. No-op if file exists. |
| `list/2` | `(session_id, workspace)` | Returns `[thread]` from `threads.json`. Empty list if no file. |
| `active/2` | `(session_id, workspace)` | Returns the active thread map, or `nil`. |
| `get/3` | `(session_id, workspace, thread_id)` | Returns a single thread map, or `nil`. |
| `create/3` | `(session_id, workspace, attrs)` | Adds a new thread to the registry. Returns `{:ok, thread}`. |
| `switch/3` | `(session_id, workspace, thread_id)` | Updates `active_thread_id`. Returns `:ok` or `{:error, :not_found}`. |
| `delete/3` | `(session_id, workspace, thread_id)` | Removes a thread (cannot delete active). Returns `:ok` or `{:error, reason}`. |

### Persistence

- Read/write `threads.json` via `File.read!/1` + `Jason.decode!/1` / `Jason.encode!/2` + `File.write!/2`.
- `threads_path/2` returns `Path.join([workspace, "_rho", "sessions", session_id, "threads.json"])`.
- All writes are atomic: write to `.tmp`, then `File.rename/2`.

### Thread ID Generation

`"thread_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)` — 11 chars, URL-safe.

### Init / Implicit Main Thread

`init/2` is called once when a session first needs threads (on first fork, or on session create). It:
1. Checks if `threads.json` exists — if so, returns existing state.
2. Looks up the session's current tape_name from `Rho.Agent.Registry` or accepts it as opt.
3. Creates `threads.json` with a single "Main" thread pointing at the existing tape.

### Fork Flow (deferred to LiveView wiring phase)

`fork_thread/3` will:
1. Call `needs_summary?/2` to decide if compaction is needed.
2. If needed, call `summarize_up_to/3` (LLM call via `Rho.Tape.Compact`).
3. Call `tape_module.fork(current_tape, at: fork_point)` to create the fork tape.
4. Call `create/3` to register the new thread.
5. Call `switch/3` to make it active.

This function touches LLM and tape infrastructure — implement and test separately from the pure registry CRUD.

### Thread-Aware Snapshots (deferred to LiveView wiring phase)

`Snapshot.save/3` and `Snapshot.load/2` will gain an optional `thread_id` parameter:
- `snapshots/{thread_id}.json` instead of `ui_snapshot.json`
- Backward-compatible: if no thread_id, falls back to `ui_snapshot.json`.

## Implementation Order

1. Write `RhoWeb.Session.Threads` — pure CRUD + JSON persistence
2. Write tests for all public functions
3. Wire `init/2` into `SessionCore.ensure_session/3` (implicit Main thread)
4. Wire `fork_thread/3` (requires tape + LLM integration)
5. Wire thread switching into `SessionLive.handle_event`
6. Thread-aware snapshots
7. Thread picker UI

This session covers steps 1-2.
