# Multi-User Scalability Analysis

**Date:** 2026-04-13

After comprehensive exploration, Rho **cannot reliably serve more than ~2-3 concurrent users** in its current architecture. The issues span three layers.

---

## 1. LLM Connection Pool (CRITICAL)

The **single biggest bottleneck**. All LLM calls share one Finch pool configured in `config/config.exs`:

```elixir
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [
        protocols: [:http1],           # HTTP/1.1 ONLY — no multiplexing
        size: 25,                       # 25 connections per pool
        count: 1,                       # 1 pool instance (global)
        conn_max_idle_time: 30_000,
        start_pool_metrics?: true
      ]
    }
  ]
```

| Setting | Value | Impact |
|---------|-------|--------|
| Protocol | HTTP/1.1 only | 1 connection per streaming request |
| Pool size | 25 | Hard ceiling for concurrent LLM streams |
| Pool count | 1 | Global — all users, all agents share it |
| Stream timeout | 120s | Connection held for up to 2 minutes |

### Capacity math

A single user with multi-agent workflows uses 7-13 connections. Two users with parallel sub-agents hit the 25-connection ceiling. Three users = near-certain pool exhaustion with cascading failures (retries make it worse).

### No admission control

There is **no layer between unbounded agent spawning and the fixed-size pool**:

- `Rho.Agent.Supervisor` (`apps/rho/lib/rho/agent/supervisor.ex`) — DynamicSupervisor with no child limit
- `Rho.TaskSupervisor` — Task.Supervisor with no concurrency cap
- Each agent turn spawns a task that calls `Rho.Runner.run/3` → `TurnStrategy.Direct.stream_with_retry/6` → `ReqLLM.stream_text/3` → `Finch.stream/3`
- When the pool is exhausted, Finch returns `{:error, %RuntimeError{message: "unable to provide a connection..."}}` 
- Retry logic (2 retries with linear backoff in `direct.ex:293-325`) amplifies the problem

### Failure scenario

```
User A: 1 primary agent + 6 sub-agents streaming = 7 connections
User B: 1 primary agent + 6 sub-agents streaming = 7 connections
User C: 1 primary agent streaming                 = 1 connection
                                              Total: 15 connections (OK)

If any sub-agents retry on timeout: +2 connections each
User A retries (3 agents): +6 connections → 21 total
User B retries (2 agents): +4 connections → 25 total → POOL EXHAUSTED
User C's next turn: blocked indefinitely
```

---

## 2. Global Singletons Under Contention

### Tape Store (CRITICAL)

**Location:** `apps/rho/lib/rho/tape/store.ex:24-25, 127-142`

Single GenServer serializes ALL tape appends across all agents and sessions via `GenServer.call(__MODULE__, {:append, tape_name, entry})`. With 100 agents each taking 10 steps per turn, that's 1000 serialized writes queued on one process.

ETS reads are concurrent (no GenServer call), so read performance is fine.

### Signal Bus (HIGH)

**Location:** `apps/rho/lib/rho/comms/signal_bus.ex:13-23`

Single `Jido.Signal.Bus` instance (`:rho_bus`) routes all signals for all sessions. Signal dispatch is async (`delivery_mode: :async`), which mitigates call serialization. However, subscription registration and pattern matching scale linearly with subscriber count. With 100 sessions × multiple subscription patterns each, the bus could become a throughput bottleneck.

### SQLite (HIGH)

**Location:** `apps/rho_frameworks/lib/rho_frameworks/repo.ex`, `config/config.exs:45`

SQLite has severe write-locking: concurrent writes block readers and vice versa. The pool is configured with only 5 connections. Multiple agents writing to libraries, skills, and roles simultaneously will experience transaction timeouts and cascading blocking.

### EventLog (MEDIUM)

**Location:** `apps/rho/lib/rho/agent/event_log.ex:72-142`

One EventLog GenServer per session writes events to a JSONL file. Within a session with 10 concurrent agents, all event writes serialize through this process. File I/O latency compounds under load.

### Observatory (MEDIUM)

**Location:** `apps/rho_web/lib/rho_web/observatory.ex:70-78`

Single GenServer accumulates in-memory metrics for ALL sessions and agents. No TTL or cleanup for old sessions — unbounded memory growth over time.

### Plugin/Transformer Registries (LOW-MEDIUM)

**Location:** `apps/rho/lib/rho/plugin_registry.ex:47-49`, `apps/rho/lib/rho/transformer_registry.ex:38-40`

Both are global GenServers. Registrations serialize via `GenServer.call()`. ETS backing stores have `read_concurrency: true` so reads are fast. Risk is low if registrations only happen at startup, but increases if plugins are registered dynamically per-session.

---

## 3. Session Isolation (Well Designed)

The logical isolation between sessions is sound:

- Each session gets a unique `session_id` (format: `lv_<unique_integer>`)
- **DataTable.Server** — one per session via `{:via, Registry, {Rho.Stdlib.DataTable.Registry, session_id}}`
- **EventLog** — one per session via `{:via, Registry, {Rho.EventLogRegistry, session_id}}`  
- **Agent Registry** — global ETS table but all queries filter by `session_id` via match-specs; no cross-contamination
- **Signal Bus** — topic patterns (`rho.session.<sid>.events.*`) provide logical per-session channels
- **User/org context** — stored per-agent in Worker struct, not shared
- **Session Janitor** — auto-stops DataTable.Server when primary agent stops

Agents from different sessions never receive each other's signals. Session creation is atomic via `System.unique_integer([:positive])`.

---

## Summary Table

| Component | Severity | Issue | Location |
|-----------|----------|-------|----------|
| Finch connection pool | CRITICAL | 25-conn global pool, HTTP/1.1, no admission control | `config/config.exs:5-21` |
| Tape Store | CRITICAL | All appends serialize through single GenServer | `rho/lib/rho/tape/store.ex:24-25` |
| Signal Bus | HIGH | Single bus for all sessions; subscription count scales linearly | `rho/lib/rho/comms/signal_bus.ex:13-23` |
| SQLite | HIGH | Write-locking, 5-connection pool | `config/config.exs:45`, `rho_frameworks/repo.ex` |
| EventLog | MEDIUM | Per-session file I/O serializes within a session | `rho/lib/rho/agent/event_log.ex:72-142` |
| Observatory | MEDIUM | Unbounded in-memory metrics, no TTL | `rho_web/lib/rho_web/observatory.ex:70-78` |
| Plugin/Transformer Registries | LOW | Registration calls serialize; reads are concurrent | `rho/lib/rho/plugin_registry.ex:47-49` |

---

## Recommendations (by priority)

### P0 — Connection pool

- **Short-term:** Increase pool size (e.g., 100) as a stopgap
- **Medium-term:** Enable HTTP/2 multiplexing (multiple streams per connection)
- **Long-term:** Add admission control — a semaphore or token bucket between agent spawning and LLM calls to prevent pool exhaustion cascades; per-session connection budgets

### P1 — Tape Store

- Partition writes by session or agent (per-session GenServer instead of global)
- Or switch to async appends (`GenServer.cast` + periodic flush)
- ETS reads are already concurrent and don't need changes

### P1 — Database

- Migrate from SQLite to PostgreSQL for concurrent write safety
- Essential if multiple users will hit the frameworks domain simultaneously

### P2 — Sub-agent strategy

- Consider sequential (not parallel) sub-agent LLM calls as a latency-for-throughput tradeoff
- Or implement a concurrency limiter (e.g., max 3 concurrent LLM calls per session)

### P2 — Observatory

- Add TTL-based cleanup for sessions older than 1 hour
- Consider moving to periodic snapshots instead of continuous accumulation

### P3 — Monitoring

- Attach Finch pool telemetry to Observatory so pool exhaustion is visible before errors occur
- Add `read_concurrency: true` to FinchTelemetry ETS table (`rho_web/lib/rho_web/finch_telemetry.ex:94`)
