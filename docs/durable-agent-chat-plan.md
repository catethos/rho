# Durable Agent Chat Plan

> Make Rho's agent conversations durable end-to-end and addressable over HTTP,
> so a Node.js host (or any client) can drive sessions, disconnect at any time,
> and resume — even across worker crashes — without losing state.

---

## 1. Why this is on the table

CLAUDE.md states the production target is a Node.js host calling into Rho via
a transport boundary; the Phoenix LiveView is a demo. We already have most of
the durable-stream pattern in `Rho.Tape.Store` (append-only log, monotonic
offsets, anchors as compaction checkpoints, replay-on-boot, projection-based
context rebuild). What's missing for "durable agent chat":

1. **Crash-resume of in-flight tool calls.** If `Rho.Agent.Worker` crashes
   between dispatching a tool and recording its result, the tape has the call
   but no result. On restart the runner replays the tape but the in-progress
   tool call is silently lost. Conversations are durable across "completed
   turns" but not across "in-flight turns". (`apps/rho/lib/rho/runner.ex:649`,
   `apps/rho/lib/rho/tool_executor.ex:51`.)
2. **No HTTP wire surface for the tape.** Today the only way for a remote
   client to drive an agent is through `Rho.Session.send/2` (BEAM-local) or
   the LiveView. There's no HTTP endpoint a Node.js host can `POST` user
   messages to or `GET`/SSE-tail to receive events with replay-from-offset
   semantics. (`apps/rho_web/lib/rho_web/router.ex` has no `:api` pipeline.)
3. **Worker lifecycle isn't tied to the tape.** A new chat needs a worker
   started before `POST` works; an idle workspace shouldn't keep workers
   alive forever. We need ensure-on-receive + idle-stop semantics.
4. **JSONL storage doesn't survive past the demo.** `Rho.Tape.Store.init/1`
   scans every `.jsonl` under `~/.rho/tapes/` into ETS on boot, rebuilds the
   token index in memory, and re-opens the file on every append
   (`apps/rho/lib/rho/tape/store.ex:122,200`). `read(name, after_id)` is an
   ETS select — meaning the entire tape must already be loaded, defeating the
   `?after=N` resume story for cold tapes. No transactions, no per-tenant
   retention, torn-write risk on partial lines.
5. **No durable session index.** `Rho.Agent.Registry` is ETS-only — gone on
   BEAM restart. Listing a user's sessions over HTTP requires scanning the
   tapes directory and joining with auth metadata that doesn't live there.
6. **No autonomous-agent primitive.** Workers only act inside a turn started
   by a user `POST /inputs`. Scheduled work ("summarise yesterday at 9am"),
   event-driven wake-ups ("file changed → re-run tests"), and any "agent
   that keeps working between user inputs" have no shipping primitive.

This plan addresses 1–6 in four independent, shippable phases. Each phase is
useful on its own.

---

## 2. Architectural shape

```
                 ┌────────────────────────────────┐
   Node.js host  │     POST /tapes/:name/inputs   │  user message arrives
   ───────────▶  │     → ensure_worker(tape)      │
                 │     → tape append :message     │
                 └─────────────┬──────────────────┘
                               │
         ┌─────────────────────▼─────────────────────┐
         │  Rho.Agent.Worker  (per session/agent_id) │
         │   • restart: :transient                   │
         │   • on init: replay tape → resume         │  ◀── Phase 1 fix
         │   • on tool call: write :tool_call_started│
         │   • on tool result: write :tool_call_done │
         └─────────────────────┬─────────────────────┘
                               │ append entries
         ┌─────────────────────▼─────────────────────┐
         │  Rho.Tape.Store (already exists)          │
         │   single GenServer writer + ETS readers   │
         │   JSONL persistence, monotonic IDs        │
         └─────────────────────┬─────────────────────┘
                               │
         ┌─────────────────────▼─────────────────────┐
         │  Rho.Tape.Tail (new)                      │
         │   wraps Store + Rho.Events PubSub         │
         │   → SSE GET /tapes/:name/entries?after=N  │
         └───────────────────────────────────────────┘
```

The tape is the only state. Workers, HTTP connections, and projections are
all derivative.

---

## 3. Phase 1 — Crash-resume of in-flight tool calls

**Goal:** if a worker dies mid-tool-call, the next worker restart picks up
the call, decides whether to retry, finalize, or surface an error, and
continues the conversation without the user noticing data loss.

### 3.1 New tape entry kinds

Extend `Rho.Tape.Entry.kind` (`apps/rho/lib/rho/tape/entry.ex:7`) with two
new variants alongside the existing `:tool_call`:

- `:tool_call_started` — written **before** dispatch. Payload mirrors
  `:tool_call` but adds `started_at` and `worker_id`. Marker that says
  "dispatch happened; result not yet in the log."
- `:tool_call_completed` — written **after** the result lands. Payload is
  the same as today's `:tool_result` plus `started_id` (the entry id of
  the matching `:tool_call_started`).

The existing `:tool_call` / `:tool_result` pair stays — it's still the
entry shape the LLM context replay consumes. The new pair is a side-table
for crash-recovery bookkeeping. (Keeping them separate avoids touching
`Rho.Tape.Projection.JSONL.build/1` and the Recorder rebuild path.)

### 3.2 Recorder hook points

In `Rho.ToolExecutor.dispatch/5` (`apps/rho/lib/rho/tool_executor.ex:73`),
just after `apply_stage(:tool_args_out, ...)` returns `{:cont, %{args: new_args}}`,
write `:tool_call_started`. In `collect/3`
(`apps/rho/lib/rho/tool_executor.ex:167`), after the existing
`emit.(event)`, write `:tool_call_completed` with the matching `started_id`.

Add two thin helpers to `Rho.Recorder`:

```elixir
@spec record_tool_call_started(Runtime.t(), tool_call) :: {:ok, integer()}
@spec record_tool_call_completed(Runtime.t(), integer(), result) :: :ok
```

The first returns the new entry's `id` so the executor can correlate.
Both are no-ops when `tape.name` is `nil` (consistent with existing
recorder helpers).

### 3.3 Recovery scan on Worker init

In `Rho.Agent.Worker.init/1` (`apps/rho/lib/rho/agent/worker.ex:206`),
after `memory_mod.bootstrap(ref)`, run a recovery scan over the tape:

```
unmatched =
  for %{kind: :tool_call_started, id: sid, payload: p} <- entries,
      not Enum.any?(entries, fn e ->
        e.kind == :tool_call_completed and e.payload["started_id"] == sid
      end),
      do: {sid, p}
```

For each unmatched started entry, decide policy (see 3.4) and either:

- **Re-dispatch**: write a fresh `:tool_call_started` and run the tool
  again (only safe for tools tagged `idempotent: true`).
- **Mark abandoned**: write a `:tool_call_completed` with status `:error`
  and `error_type: :worker_crash`. The runner sees a normal tool result
  with an error string and the LLM gets the chance to react.

### 3.4 Idempotency tagging

Add an `idempotent: boolean()` field to the tool def emitted by
`Rho.Tool` (default `false` — fail-safe). Existing builtin tools that
are clearly idempotent (`fs_read`, `web_fetch` GETs, `bash` with no
side-effects? — no, leave `false`) get the flag explicitly. The
recovery policy reads this flag to choose re-dispatch vs. mark-abandoned.

For Phase 1, **everything defaults to mark-abandoned**. The
re-dispatch path is structurally allowed but no tool opts in yet —
that's a follow-up that requires per-tool review.

### 3.5 Test plan

New file: `apps/rho/test/rho/agent/worker_crash_recovery_test.exs`.
Cases:

1. Tool dispatches, worker `Process.exit(pid, :kill)`, fresh worker on
   same `agent_id` finishes turn with `:worker_crash` tool result.
2. Two unmatched starteds in a row (worker died, restarted, died again
   before finishing) → both get marked abandoned on next start.
3. Started/completed pair already matched → no recovery action.
4. Idempotent tool tagged → re-dispatched (test once we have an
   opt-in).

### 3.6 Out of scope for Phase 1

- LLM call resumption. If the worker dies mid-`runtime.turn_strategy.run`
  (i.e. mid-LLM-call) we still lose tokens already streamed. ReqLLM
  doesn't expose mid-stream resumption today; the tape just gets a
  partial-then-restart. Acceptable: text deltas are reconstructable.
- Compaction interaction. `compact_if_needed` should treat `:tool_call_started`/
  `:tool_call_completed` as ephemeral bookkeeping and never compact them
  alone (only as part of a closed pair). Verify in the existing
  `apps/rho/lib/rho/tape/compact.ex` path.

---

## 4. Phase 2 — HTTP tape transport

**Goal:** every operation today reachable through `Rho.Session` is reachable
over HTTP, with replay-from-offset semantics for events.

### 4.1 Wire surface

Single new controller mounted under `/api/v1` in `RhoWeb.Router`.
JSON in, JSON / SSE out. Auth via bearer token (see 4.5).

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/v1/sessions` | Start a session. Body `{ "agent": "...", "workspace": "...", "session_id": "..." (optional) }`. Returns `{ "session_id": "...", "tape_name": "...", "primary_agent_id": "..." }`. |
| `POST` | `/api/v1/sessions/:sid/inputs` | Send a user message. Body `{ "content": "...", "tools": [...] (optional) }`. Returns `{ "turn_id": "...", "input_entry_id": 12 }`. Async: returns immediately. |
| `GET`  | `/api/v1/sessions/:sid/entries?after=N&limit=100` | Read tape entries with id > N. Returns `{ "entries": [...], "last_id": 42 }`. |
| `GET`  | `/api/v1/sessions/:sid/events?after=N` | **SSE stream**. Replays entries with id > N, then tails live events. Each `data:` line is one entry JSON. |
| `GET`  | `/api/v1/sessions/:sid/info` | Wraps `Rho.Session.info/1`. |
| `POST` | `/api/v1/sessions/:sid/cancel` | Cancel current turn (`Rho.Agent.Worker.cancel/1`). |
| `DELETE` | `/api/v1/sessions/:sid` | Stop session (`Rho.Session.stop/1`). |

### 4.2 SSE tail = replay + subscribe

The tail endpoint is the heart of the durable-stream contract:

1. Read `Rho.Tape.Store.read(tape_name, after_id)` and write each entry as
   an SSE `data:` line. (Synchronous; uses ETS, no GenServer hop.)
2. After the catch-up read, `Rho.Events.subscribe(session_id)` and
   forward future `Rho.Events.Event` structs that map to a tape entry.
3. Critical: between step 1 and 2 there's a window where new entries
   could land. Solve by **subscribing first**, then reading, then
   deduping by entry id (skip events with id ≤ last id we wrote out).
4. Heartbeat with `: keepalive\n\n` every 15s so intermediaries don't
   close the connection.
5. Client reconnects with the last id it saw → seamless resume.

This subscribe-then-read ordering is exactly the pattern the notebook's
sources call out for offset-based resumability.

### 4.3 Worker lifecycle on input

`POST /api/v1/sessions/:sid/inputs` does:

1. `Rho.Agent.Primary.whereis(sid)` — if alive, send.
2. Otherwise `Rho.Agent.Primary.ensure_started(sid, ...)` — which by
   `init/1` will replay the tape (Phase 1's recovery scan runs here)
   and the worker comes back hydrated.
3. `Rho.Agent.Worker.submit(pid, content, opts)` returns `{:ok, turn_id}`.
4. The HTTP response includes the `turn_id` so the client can correlate
   the SSE stream's eventual `turn_finished` event.

Idle workers should self-stop. Add `:idle_timeout_ms` to `RunSpec` (default
`30 * 60_000`); reset in `start_turn`, expire via `Process.send_after`.
Worker crash on idle = no data loss, since tape is the source of truth.

### 4.4 New session bootstrap

`POST /api/v1/sessions` builds a `Rho.Session.start/1` call. The Node.js
host either provides its own `session_id` (idempotent — repeated calls
return the same session) or omits and gets a generated one. Tape name
is derived deterministically by `Rho.Tape.Service.session_tape/2`, so
the host can compute it client-side too.

### 4.5 Auth

For the Node.js host, **bearer token** in `Authorization: Bearer <jwt>`,
verified by a new `RhoWeb.Plugs.ApiAuth`. JWT carries `user_id` +
`organization_id` and these flow into `RunSpec` via `Rho.Session.start/1`
opts. Token rotation, token issuance, and scope are out of scope for
this plan but the plug structure should accommodate them.

### 4.6 Error model

All endpoints return JSON of shape `{"error": {"type": "...", "message": "..."}}`
with HTTP 4xx/5xx. `type` is a stable string (`session_not_found`,
`unauthorized`, `worker_busy`, `invalid_input`) so the Node.js host
can branch programmatically.

### 4.7 Test plan

`apps/rho_web/test/rho_web/api/sessions_controller_test.exs`:

1. Start session, send input, GET entries — assert all expected entry
   kinds present in order.
2. Two clients connect to SSE in parallel — both receive the same
   stream including a delayed `turn_finished`.
3. Client connects to SSE with `after=5`, agent has appended 12
   entries — only entries 6..12 plus future entries arrive.
4. Send input while busy — second `POST /inputs` queues; assert
   `turn_id` differs.
5. Cancel mid-turn — assert `turn_cancelled` event fires.
6. Worker crash mid-turn (force-kill via test helper) → SSE client sees
   `:worker_crash` tool result without dropping connection (exercises
   Phase 1 + Phase 2 together).

### 4.8 Out of scope for Phase 2

- WebSocket variant. SSE is one-way (server→client) and is what the
  durable-stream model needs. Node.js host posts back over plain HTTP.
  WebSocket adds complexity without clear win.
- Compression. Tape entries are small; gzip at reverse-proxy if needed.

---

## 5. Phase 3 — Postgres-backed tape storage

**Goal:** move the tape from JSONL+ETS+boot-rescan to the Postgres
database the project already runs (Neon, via `RhoFrameworks.Repo`).
Reads become lazy + range-indexed, appends become transactional and
genuinely concurrent, boot is constant-time, and the new `sessions` /
`triggers` tables in Phase 4 can FK directly into existing user/org
data. Subsumes the previously planned "per-tape writer" phase — once
tapes live in Postgres, multiple BEAM processes can write in parallel
through MVCC; no per-tape singleton needed.

> **CLAUDE.md note.** The kernel rule "`apps/rho/` has ZERO
> Phoenix/Ecto deps" needs a small relaxation: Postgrex is allowed for
> storage. (Phoenix and Ecto are still kept out of the kernel; the
> backend uses `Postgrex` directly via the existing `DATABASE_URL`.)
> The rule's spirit — keep the kernel portable, no web framework — is
> preserved. Update CLAUDE.md as part of this phase.

### 5.1 Backend behaviour

Introduce `Rho.Tape.Backend` with the contract `Rho.Tape.Store` already
exposes: `append/2`, `read/1`, `read/2`, `last_id/1`, `get/2`, `clear/1`,
`search_ids/2`, `last_anchor/1`. Two implementations:

- `Rho.Tape.Backend.JSONL` — current `Store` logic, kept compilable for
  local dev / livebook / "zero-setup" tests. Selected when
  `:tape_backend` is `:jsonl` or no `DATABASE_URL` is configured.
- `Rho.Tape.Backend.Postgres` — new, default in production. Uses a
  dedicated `Postgrex` connection pool against the same database
  `RhoFrameworks.Repo` already targets.

Backend is selected via `Rho.Config` and wired through
`Rho.Tape.Service`. Test env defaults to JSONL for speed; integration
tests that exercise the Postgres path opt in explicitly.

### 5.2 Schema (Postgres)

Lives in the existing Neon DB alongside `users` / `frameworks`, in a
`rho_tape` schema for clarity:

```sql
CREATE SCHEMA IF NOT EXISTS rho_tape;

CREATE TABLE rho_tape.entries (
  id          BIGSERIAL PRIMARY KEY,
  tape_name   TEXT NOT NULL,
  tape_id     BIGINT NOT NULL,            -- monotonic per tape
  kind        TEXT NOT NULL,
  payload     JSONB NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tape_name, tape_id)
);
CREATE INDEX entries_range_idx ON rho_tape.entries (tape_name, tape_id);
CREATE INDEX entries_kind_idx  ON rho_tape.entries (tape_name, kind);
CREATE INDEX entries_payload_gin ON rho_tape.entries USING GIN (payload jsonb_path_ops);

CREATE TABLE rho_tape.meta (
  tape_name        TEXT PRIMARY KEY,
  next_id          BIGINT NOT NULL,
  last_anchor_id   BIGINT
);

-- Full-text search via tsvector + GIN replaces the in-memory token index.
ALTER TABLE rho_tape.entries
  ADD COLUMN content_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('simple', coalesce(payload->>'content', ''))
  ) STORED;
CREATE INDEX entries_fts_idx ON rho_tape.entries USING GIN (content_tsv);
```

`tape_id` preserves the existing user-facing monotonic-per-tape ID
(SSE `?after=N` and tape replay both rely on it). `id` is the global
PK that gives Postgres a fast, append-only insertion path. JSONB
+ GIN means future "find all `tool_call` entries with name X"
queries are a simple `payload @> '{"name":"X"}'`.

### 5.3 Lazy reads

`read(name, from_id, limit)` becomes:

```sql
SELECT tape_id, kind, payload
FROM rho_tape.entries
WHERE tape_name = $1 AND tape_id > $2
ORDER BY tape_id
LIMIT $3;
```

No ETS load, no full-tape rebuild. Postgres's index-only scan on
`(tape_name, tape_id)` makes this O(log N + limit). An LRU cache in
front of the backend handles hot tapes for the worker's transcript
rebuild path. Replay on worker init becomes O(turn) not O(tape
lifetime).

### 5.4 Append + concurrency

`append/2` is one `INSERT … RETURNING tape_id` inside a transaction
that also bumps `rho_tape.meta.next_id` for the relevant `tape_name`
(via `INSERT … ON CONFLICT DO UPDATE`). Per-tape ordering is enforced
by the unique `(tape_name, tape_id)` constraint and a row-level lock
on the `meta` row.

The big win over SQLite: **multiple BEAM processes can append to
different tapes in parallel.** Postgres MVCC + per-row locking on
`meta` gives true concurrent writes across tapes; only writes to the
*same* tape serialize on its meta row, which is the ordering guarantee
we want anyway. The per-tape-writer split the old plan called for is
unnecessary — Postgres provides exactly that semantic for free.

A small `Rho.Tape.WriterPool` (Postgrex pool, e.g. `poolboy` or
DBConnection's built-in pool) handles connection lifetime; appends
never go through a singleton GenServer.

### 5.5 Migration

One-shot `mix rho.migrate_tapes`:

1. Reads each `~/.rho/tapes/*.jsonl` line by line.
2. Streams via `COPY rho_tape.entries (...) FROM STDIN` for each tape
   in a single transaction (orders of magnitude faster than per-row
   `INSERT`).
3. Rebuilds `rho_tape.meta` per tape and `ANALYZE`s the table.
4. Idempotent: skips a tape if any rows already exist for that name.

Old JSONL files are left in place; operator deletes them once
Postgres-backed runs are confirmed healthy. `Rho.Tape.Backend.JSONL`
stays compilable for one release as a config rollback.

### 5.6 Why this replaces the per-tape writer

- Postgres MVCC serves concurrent reads and concurrent writes natively;
  the only contention is on the per-tape `meta` row, which is the
  ordering guarantee we want.
- Boot is constant-time — no scan of `~/.rho/tapes/`.
- Phase 2's `?after=N` SSE catch-up is a real range query.
- Phase 4's `sessions` and `triggers` tables FK into the same database
  with cross-table joins to existing users/orgs — impossible with a
  separate per-app SQLite file.
- Multi-node, multi-Phoenix-instance, multi-Node.js-host all become
  trivial later: same DB, same MVCC.
- Neon's scale-to-zero, branching, and PITR cover backup/DR with no
  added ops surface.

### 5.7 Test plan

`apps/rho/test/rho/tape/backend/postgres_test.exs`:

1. Round-trip parity: same entries written via JSONL and Postgres
   produce identical `Entry.to_json` output.
2. Range read: 10k entries, `read(name, 9_990)` returns ≤10 rows and
   completes in <10ms (network-bound floor).
3. Genuine concurrent writers: 8 tasks writing to 8 distinct tapes in
   parallel — none block, all finish in roughly the time of one.
4. Same-tape writers serialize correctly: 4 tasks writing to one tape
   produce contiguous `tape_id` values 1..N with no gaps or duplicates.
5. tsvector FTS returns the same set of IDs as the legacy tokenizer
   for the existing `search_ids/2` test corpus.
6. Migration tool: pre-existing JSONL fixtures → Postgres gives
   byte-equal output via a re-export round-trip.
7. JSONL fallback still works when `:tape_backend` is `:jsonl`
   (livebook / no-DB dev path).

### 5.8 Out of scope

- **Multi-tenant DB sharding.** Single shared `rho_tape.entries` is
  fine until row count or noisy-neighbour problems force the issue.
- **Cross-region replication.** Neon handles this if/when needed.
- **Replacing `RhoFrameworks.Repo`.** Tape backend uses Postgrex
  directly to keep the kernel Ecto-free; the existing repo continues
  to own domain tables in the same database.
- **Online schema migrations.** Initial schema is the only shape this
  plan ships. Future changes ride on a `priv/repo/migrations/` path
  alongside the existing `rho_frameworks` migrations.

---

## 6. Phase 4 — Session index & durable triggers

**Goal:** make sessions discoverable across BEAM restarts, and let
agents wake without a user `POST` — closing the gap between
"request-driven chat" and "autonomous agent."

### 6.1 Sessions table

Lives in the same Postgres DB as tapes and the existing `users` table,
in a `rho_session` schema:

```sql
CREATE SCHEMA IF NOT EXISTS rho_session;

CREATE TABLE rho_session.sessions (
  session_id        TEXT PRIMARY KEY,
  user_id           BIGINT REFERENCES users(id) ON DELETE SET NULL,
  organization_id   BIGINT,
  agent_name        TEXT NOT NULL,
  workspace         TEXT NOT NULL,
  tape_name         TEXT NOT NULL,
  status            TEXT NOT NULL,        -- :active | :idle | :stopped
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_active_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX sessions_user_idx ON rho_session.sessions (user_id, last_active_at DESC);
CREATE INDEX sessions_org_idx  ON rho_session.sessions (organization_id, last_active_at DESC);
CREATE INDEX sessions_status_idx ON rho_session.sessions (status) WHERE status = 'active';
```

The `user_id` FK gives "list this user's sessions" the right join
semantics for free, including when the user is deleted.

Wire-up:
- `Rho.Session.start/1` inserts (or updates `last_active_at` on
  re-ensure).
- `Rho.Agent.Worker` updates `last_active_at` on every turn boundary
  and flips `status` on idle-timeout / explicit stop.

### 6.2 New endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/sessions` | List sessions for the authenticated user/org. Supports `?status=&limit=&before=`. |
| `GET` | `/api/v1/sessions/:sid` | Persisted session metadata (works even when no worker is alive — the existing `info` endpoint stays for live-worker fields). |

These complement the Phase 2 endpoints, which all assume the caller
already knows the `session_id`.

### 6.3 Trigger primitive

```elixir
%Rho.Trigger{
  id:              String.t(),
  session_id:      String.t(),
  kind:            :cron | :event,
  schedule:        String.t() | nil,        # for :cron — e.g. "0 9 * * *"
  event_pattern:   map() | nil,             # for :event — Rho.Events match spec
  input_template:  String.t(),              # rendered with bindings on fire
  enabled:         boolean(),
  last_fired_at:   integer() | nil,
  next_fire_at:    integer() | nil
}
```

- `Rho.Trigger.Scheduler` — single GenServer per node that owns timers.
  Boots from the `triggers` table; survives restart.
- On fire: `Rho.Agent.Primary.ensure_started(session_id, …)` →
  `Rho.Agent.Worker.submit(pid, rendered_input, …)`. Worker replays
  tape via Phase 1's recovery path → handles input → idle-times-out.
  All resulting events still flow through the Phase 2 SSE wire — a
  client tailing `/events` sees trigger-driven turns identically to
  user-driven ones.
- Event triggers subscribe to `Rho.Events` once on scheduler boot;
  cron triggers use `Process.send_after` with re-arm on fire.

### 6.4 Triggers table

```sql
CREATE TABLE rho_session.triggers (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL REFERENCES rho_session.sessions(session_id) ON DELETE CASCADE,
  kind            TEXT NOT NULL,
  schedule        TEXT,
  event_pattern   JSONB,
  input_template  TEXT NOT NULL,
  enabled         BOOLEAN NOT NULL DEFAULT true,
  last_fired_at   TIMESTAMPTZ,
  next_fire_at    TIMESTAMPTZ
);
CREATE INDEX triggers_session_idx ON rho_session.triggers (session_id);
CREATE INDEX triggers_armed_idx   ON rho_session.triggers (next_fire_at)
  WHERE enabled = true AND next_fire_at IS NOT NULL;
```

HTTP surface:
- `POST   /api/v1/sessions/:sid/triggers`  — create
- `GET    /api/v1/sessions/:sid/triggers`  — list
- `PATCH  /api/v1/triggers/:tid`           — enable/disable, edit
- `DELETE /api/v1/triggers/:tid`           — remove

### 6.5 Use cases unlocked

- **Daily summary.** Cron at 09:00, input `"Summarise yesterday's tape
  and post to #ops"`.
- **File-watcher.** Event trigger on `lens.file.changed` with
  `path: "lib/foo.ex"` → input `"Re-run the tests touching foo.ex"`.
- **Inbox poll.** Cron every 5 min → input `"Check inbox for new
  tickets and triage"`.
- **Multi-stage workflow handoff.** One agent finishes, emits an event
  the next agent's trigger subscribes to.

### 6.6 Test plan

`apps/rho_web/test/rho_web/api/sessions_index_test.exs` and
`apps/rho/test/rho/trigger/scheduler_test.exs`:

1. Insert 5 sessions across 2 orgs; `GET /sessions` for org A returns
   only its 3, ordered by `last_active_at DESC`.
2. Cron trigger with a fake clock fires at the expected wall time;
   `Worker.submit` is called with the rendered input.
3. Event trigger: publish a matching `Rho.Events.Event`; assert the
   worker is started and the input submitted exactly once.
4. Restart simulation: stop scheduler, drop in-memory state, restart —
   pending triggers re-armed from the table; no double-fire.
5. Disabled trigger does not fire.
6. Trigger fires while worker is already busy → input queues (Phase 2
   queueing semantics).

### 6.7 Out of scope

- **Multi-node trigger leadership.** Single scheduler per node; if Rho
  ever scales horizontally, a leader-election layer (`:global` or
  `Horde`) goes in front.
- **Per-org rate limits / fairness.** Naive FIFO fire order is enough
  until a real tenant collision happens.
- **Rich cron syntax.** Start with hh:mm + every-N-minutes. Add a
  proper cron lib (`Crontab`) only if needed.
- **Visual trigger builder.** HTTP API only; UI follow-up.

---

## 7. Phases ranked

| Phase | Ships what | Estimated effort | Risk |
|---|---|---|---|
| 1. Crash-resume tool calls | Conversations no longer lose in-flight tool work on worker crash. Most user-visible reliability gain. | ~2 days | Low — additive entry kinds, recovery scan is local to Worker.init. |
| 2. HTTP tape transport | The actual durable agent chat product. Node.js host can now drive sessions. | ~3–4 days | Medium — auth + SSE backpressure + worker lifecycle have edge cases. |
| 3. Postgres-backed tape | Lazy reads, constant-time boot, real range queries, transactional + concurrent appends, FK-able from Phase 4 tables. Reuses existing Neon DB. Subsumes the per-tape writer phase. | ~2–3 days | Medium — storage migration; mitigated by JSONL fallback + idempotent migrate task. |
| 4. Session index & triggers | Discoverable sessions across restart; autonomous agents (cron + event-driven). | ~3 days | Medium — scheduler edge cases (clock skew, double-fire on restart). |

Ship in order. Phase 1 makes Phase 2 trustworthy; Phase 2 makes Phase 3
worth doing; Phase 3's `sessions`/`triggers` schema is what Phase 4
hangs off of.

---

## 8. Things explicitly **not** in this plan

- **Broadway / NATS JetStream / Commanded.** The notebook recommends
  these for distributed multi-consumer pipelines. Rho's agent loop is a
  single in-process consumer per session — those tools would add
  operational weight (extra service, ack semantics that don't map onto
  our ToolExecutor) without solving anything Phase 1 doesn't already
  solve in-tree.
- **Replicating the tape across nodes.** Phase 3 brings storage onto
  the project's existing Neon Postgres, which already gives us a
  durable, multi-region-capable backing store; multi-BEAM-node
  deployments work out of the box. Cross-region replication / read
  replicas remain an ops decision, not a code one.
- **Async projections (Bumblebee → pgvector).** Useful feature, but
  belongs in a separate "memory / retrieval" plan, not the durable-chat
  plan.
- **Replacing `Rho.Agent.EventLog` with the tape.** EventLog serves a
  different purpose (raw firehose, including filtered-out text deltas).
  Worth revisiting once Phase 2 lands; for now leave it.
- **Per-tape writer process pool.** Earlier draft had this as Phase 3.
  Subsumed by Phase 3's SQL backend — the bottleneck it solved
  (file-handle thrash + global GenServer) doesn't exist once tapes live
  in SQLite with WAL.

---

## 9. Concrete file diff summary

### Phase 1
- `apps/rho/lib/rho/tape/entry.ex` — extend `kind` typespec.
- `apps/rho/lib/rho/recorder.ex` — add `record_tool_call_started/2`,
  `record_tool_call_completed/3`.
- `apps/rho/lib/rho/tool_executor.ex` — call new recorder helpers in
  `dispatch/5` and `collect/3`. Thread the `started_id` through the
  task return value.
- `apps/rho/lib/rho/agent/worker.ex` — add `recover_in_flight/2` call
  inside `init/1` (after `bootstrap`).
- `apps/rho/lib/rho/tool.ex` — add `idempotent` field to tool defs.
- `apps/rho/test/rho/agent/worker_crash_recovery_test.exs` (new).

### Phase 2
- `apps/rho_web/lib/rho_web/router.ex` — add `:api` pipeline + scope.
- `apps/rho_web/lib/rho_web/plugs/api_auth.ex` (new).
- `apps/rho_web/lib/rho_web/api/sessions_controller.ex` (new).
- `apps/rho_web/lib/rho_web/api/tail_sse.ex` (new) — SSE writer.
- `apps/rho/lib/rho/tape/tail.ex` (new) — combine `Store.read/2` +
  `Rho.Events` subscribe with dedupe.
- `apps/rho/lib/rho/run_spec.ex` — add `:idle_timeout_ms` field.
- `apps/rho/lib/rho/agent/worker.ex` — idle-timeout self-stop.
- `apps/rho_web/test/rho_web/api/sessions_controller_test.exs` (new).

### Phase 3
- `apps/rho/lib/rho/tape/backend.ex` (new) — behaviour.
- `apps/rho/lib/rho/tape/backend/jsonl.ex` (new) — current `Store`
  logic moved behind the behaviour (kept for dev / livebook).
- `apps/rho/lib/rho/tape/backend/postgres.ex` (new) — Postgrex queries
  + JSONB payload + tsvector FTS.
- `apps/rho/lib/rho/tape/writer_pool.ex` (new) — Postgrex pool.
- `apps/rho/lib/rho/tape/store.ex` — thin facade dispatching to the
  configured backend.
- `apps/rho/lib/rho/config.ex` — `:tape_backend` setting (default
  `:postgres` when `DATABASE_URL` is set, `:jsonl` otherwise).
- `apps/rho/lib/rho/application.ex` — start the Postgrex pool when
  Postgres backend is selected.
- `apps/rho/lib/mix/tasks/rho.migrate_tapes.ex` (new) — JSONL → Postgres
  via `COPY FROM STDIN`.
- `priv/repo/migrations/<ts>_create_rho_tape.exs` (new) — schema +
  tables + indexes (lives in `apps/rho_frameworks/` since the repo
  owns migrations).
- `apps/rho/test/rho/tape/backend/postgres_test.exs` (new).
- `apps/rho/test/rho/tape/backend/jsonl_test.exs` (new — pin existing
  behaviour).
- `apps/rho/mix.exs` — add `:postgrex` dep.
- `CLAUDE.md` — relax the kernel dep rule to "no Phoenix; Postgrex
  allowed for storage."

### Phase 4
- `apps/rho/lib/rho/session_index.ex` (new) — `sessions` table CRUD.
- `apps/rho/lib/rho/session.ex` — write-through to `SessionIndex` on
  start / stop / activity.
- `apps/rho/lib/rho/agent/worker.ex` — `last_active_at` ticks on turn
  boundaries.
- `apps/rho/lib/rho/trigger.ex` (new) — struct + persistence helpers.
- `apps/rho/lib/rho/trigger/scheduler.ex` (new) — cron + event timers.
- `apps/rho/lib/rho/application.ex` — start `Trigger.Scheduler`.
- `apps/rho_web/lib/rho_web/api/sessions_index_controller.ex` (new) —
  `GET /sessions`, `GET /sessions/:sid` (persisted view).
- `apps/rho_web/lib/rho_web/api/triggers_controller.ex` (new).
- `apps/rho_web/lib/rho_web/router.ex` — mount the two new controllers.
- `apps/rho/test/rho/trigger/scheduler_test.exs` (new).
- `apps/rho_web/test/rho_web/api/sessions_index_test.exs` (new).
- `apps/rho_web/test/rho_web/api/triggers_controller_test.exs` (new).

---

## 10. Open questions to resolve before starting

1. **Idempotency tagging policy.** Default `false` is safe but means no
   tool ever gets re-dispatched in Phase 1. Is "mark abandoned" enough,
   or do we want at least `fs_read` / `web_fetch` to opt in immediately?
2. **Auth issuance.** Phase 2 assumes JWTs exist. Who issues them?
   `RhoFrameworks.Accounts.UserToken` already mints session tokens for
   the LiveView — extend that, or new path?
3. **Session ownership.** Should `POST /sessions` with an existing
   session_id be allowed (idempotent ensure-started), forbidden, or
   only allowed when the bearer token matches the original owner?
   Recommend: idempotent + owner check.
4. **SSE entry shape.** Entries have already-serialized JSON; do we
   forward exactly the JSONL on-disk format, or wrap each in
   `{type, id, data}` for forward-compat? Recommend wrap.
5. **Postgrex vs. Ecto in `apps/rho/`.** Using Postgrex directly keeps
   the kernel Ecto-free (preserving CLAUDE.md's spirit while relaxing
   the literal "ZERO Phoenix/Ecto deps" rule for storage). The
   alternative — funnelling tape writes through `RhoFrameworks.Repo` —
   would force a kernel→frameworks dependency that breaks the
   layering. Recommend Postgrex direct, with migrations owned by
   `rho_frameworks` (which already has Ecto + a migration path to the
   same DB).
6. **Schema isolation.** Use dedicated Postgres schemas (`rho_tape`,
   `rho_session`) or pollute `public`? Recommend dedicated schemas —
   keeps domain tables (`users`, `frameworks`, …) separate and lets us
   grant narrow permissions per schema later if needed.
7. **Neon cold-start under tape writes.** Scale-to-zero will stall the
   first write after sleep. Add a `Rho.Tape.Backend.Postgres`
   warmup-on-boot ping (cheap `SELECT 1`) plus reasonable retry on
   first append — or accept the one-off latency? Recommend warmup +
   bounded retry.
8. **Trigger DSL.** HTTP-only configuration, or also a `.rho.exs`
   `triggers:` key for repo-checked-in cron jobs? Recommend HTTP-only
   first; static config is a follow-up.
9. **Per-session trigger budget.** Default cap (e.g. 20 triggers per
   session) to avoid runaway scheduling? Recommend yes, configurable.
10. **Backend rollout plan.** Run JSONL + Postgres in shadow mode for
    a week before flipping default, or trust the migration tool +
    tests and flip immediately? Recommend immediate flip with the
    JSONL backend kept compilable for one release as a config
    rollback.
