# Fly.io scale-to-zero — operational notes

Context: the app is deployed to Fly with `auto_stop_machines = "stop"` and
`min_machines_running = 1`. This document catalogs the real operational
consequences of machines stopping and starting, ranked by how much they
actually matter for this codebase.

## TL;DR

With `min_machines_running = 1`, the primary machine stays running during
normal operation. Machines still stop/start during deploys, Fly platform
restarts, and scaling events beyond the first. The biggest things to know:

- **Rate limiter ETS state resets on every machine stop.** Limits are
  per-node memory, not persistent.
- **Cold-start latency** on the first request after a full stop (~2–8s).
- **LiveView in-memory state (socket assigns, in-flight chats) dies on
  stop.** Anything not persisted to the tape/DB is lost; LV clients
  auto-reconnect with whatever's in storage.
- **User sessions survive.** Session tokens live in SQLite on the volume,
  so users stay logged in across machine cycles.

The rest is edge cases.

## Severity 1 — actually matters

### Rate limiter counters reset on every stop

`RhoWeb.RateLimiter` uses Hammer's ETS backend (`use Hammer, backend: :ets`).
Counters live in VM memory. When the machine stops, the table is gone; on
restart an attacker gets a fresh 5-attempts-per-5-minutes budget.

`min_machines_running = 1` mostly saves this — Fly keeps at least one
machine running even under autoscale. But:

- Deploys stop the old machine before starting the new one.
- Fly platform restarts (rare, announced) cycle the VM.
- Crashes cycle the VM.
- Scale-up/down events beyond min cycle additional machines.

An attacker who can afford to wait for a ~5-minute idle period or trigger
any of the above effectively bypasses per-IP throttling.

**Fixes, in order of effort:**

1. Accept it. For a low-value app, the bar to brute-force is still high
   enough (bcrypt + 5/min/IP baseline), and forcing a stop is non-trivial.
2. Swap Hammer to a persistent backend once Redis is in the stack:
   `{:hammer_backend_redis, ...}`. API is unchanged.
3. Persist attempt counters in SQLite with a small `auth_attempts` table
   and a 5-minute-window query. Inherits volume durability; modest code.

### Cold-start latency

A fully stopped machine pays BEAM boot + SQLite open + WAL replay on
wake. Rough budget: **2–8 seconds** depending on DB size and VM spec.
Fly's proxy holds the request during wake so it succeeds — just feels
slow to the user. Login and registration are the worst UX for this
because users are already slightly anxious.

**Mitigations:**

- Keep `min_machines_running = 1` (already set).
- Add a trivial `/health` endpoint + external uptime pinger
  (UptimeRobot, Better Stack) every 3–4 minutes. Keeps the machine warm
  without paying for multiple machines. Incidentally preserves the
  rate limiter counters. Recommended default.
- Set `auto_stop_machines = "off"` if cost isn't a concern. Simplest.

### LiveView in-flight state dies on stop

Every active LV process is killed on machine stop. Users lose:

- Unsaved form state.
- Chat sessions in progress.
- Anything held in socket assigns that isn't persisted.

LV clients auto-reconnect; the new process mounts fresh from whatever
the DB/tape contains. The experience is "page hiccupped, now shows last
saved state."

Project-specific implications:

- **`Rho.Stdlib.DataTable.Server`** is `restart: :temporary`
  (per `CLAUDE.md`). After a stop, callers get `{:error, :not_running}`
  — existing code handles this actionably. Degrades gracefully.
- **`Rho.Agent.Worker`** conversations live in memory. Survival on stop
  depends entirely on tape flush cadence. If every event is persisted
  to the tape as it happens, fine. If tapes batch in memory and flush
  periodically, the unflushed tail is lost.

**Action item:** verify tape flush policy. Any worker that can be
interrupted mid-operation and hold state not yet in the tape is at risk.

## Severity 2 — edge cases, probably fine

### `TokenSweeper` 24h timer resets on boot

`RhoFrameworks.Accounts.TokenSweeper` uses `Process.send_after/3` with a
24h interval. Each boot resets the clock. If the machine somehow restarts
every <24h, only the 1-minute-after-boot initial sweep runs.

Not a correctness problem — expired tokens are still filtered at query
time by `UserToken.verify_session_token_query/1`. They just pile up in
the table until a sweep catches them.

With `min_machines_running = 1` and infrequent deploys, this realistically
runs most days.

**If it ever matters:** store `last_swept_at` in a small table and
compare wall-clock on boot, so restarts don't reset cadence. Overkill
for current scale.

### Unclean shutdown + WAL

Fly sends `SIGTERM` with a default 5s grace period, then `SIGKILL`. In
the SIGKILL case there may be uncheckpointed WAL data — SQLite recovers
automatically on next open, but startup takes slightly longer.

**Not data loss.** Configure larger grace window if needed:

```toml
# fly.toml
[[services]]
  kill_timeout = 30  # seconds
```

Only matters with long-running transactions or large WAL files.

### Deploys are ungraceful for SQLite-on-volume

A Fly deploy stops the old machine, mounts the volume on the new one,
starts it. Brief downtime (seconds). No clean fix with SQLite — migrating
to LiteFS or Postgres removes the volume binding.

## Not a concern

### Sessions survive machine stops

User session tokens live in SQLite on the mounted volume. After wake,
users are still logged in — no "logged out every night" UX. This is
the single most important property the DB-backed session design gives
you under scale-to-zero.

### PubSub

Single-node app; no cross-node message loss to worry about. If you ever
go multi-node (LiteFS/Postgres + horizontal scale), PubSub needs a
distributed adapter.

### Foreign keys and data integrity

`ecto_sqlite3` enables `PRAGMA foreign_keys = ON` per connection.
Cascades and constraint checks work regardless of machine lifecycle.

### WAL on volume

SQLite is explicitly designed for this pattern. The `-wal` and `-shm`
sidecar files stay on `/data` across stops; recovery is automatic on
reopen.

### Webhooks / external callbacks

HTTP requests wake the machine via Fly's proxy. Webhook providers that
retry on timeout (Stripe, email providers) survive a cold start. No
special handling required.

## Recommended next step

If you pick one thing, set up a 3-minute keepalive ping to `/health`
from a free external monitor. Costs nothing, eliminates cold-start UX
hit, and preserves rate limiter counters as a side effect. Everything
else on the severity-1 list is "know it exists, act when it bites."
