# Finch Connection Pool Exhaustion Under Parallel Agent Workloads

## Observed Symptom

When the spreadsheet agent delegates proficiency generation to multiple `proficiency_writer` sub-agents in parallel, the following error intermittently appears:

```
{:error, %RuntimeError{message: "Finch was unable to provide a connection within the timeout
due to excess queuing for connections. Consider adjusting the pool size, count, timeout or
reducing the rate of requests if it is possible that the downstream service is unable to keep
up with the current rate."}}
```

This error originates from Finch's connection checkout. It means a caller requested an HTTP connection but every slot in the pool was occupied and the checkout queue timed out before one freed up.

---

## Current Pool Configuration

```elixir
# config/config.exs:5-14
config :req_llm,
  stream_receive_timeout: 120_000,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 25, count: 1, conn_max_idle_time: 30_000]
    }
  ]
```

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `protocols` | `[:http1]` | HTTP/1.1 only — one request per connection, no multiplexing |
| `size` | `25` | 25 connections in the pool |
| `count` | `1` | Single pool instance |
| `conn_max_idle_time` | `30_000` | Idle connections reaped after 30s |
| `stream_receive_timeout` | `120_000` | Stream kept alive up to 2 minutes waiting for chunks |

**Effective capacity: 25 concurrent HTTP requests across the entire BEAM node.**

HTTP/2 multiplexing is explicitly disabled. A comment in the ReqLLM source references Finch issue #265 — large request bodies can break HTTP/2 flow control. This forces HTTP/1.1, where each in-flight request holds a dedicated TCP connection for its full duration.

---

## How Connections Are Consumed

### The Spreadsheet → Proficiency Writer Flow

1. **Spreadsheet agent** (depth 0) runs Phase 3 of framework generation (`.rho.exs:106-112`)
2. For each category (typically 3–6), it calls `delegate_task` with role `proficiency_writer`
3. `MultiAgent.do_delegate/2` (`multi_agent.ex:494-558`) calls `Supervisor.start_worker/1`, spawning a new `Worker` GenServer under `DynamicSupervisor`
4. Each `Worker` immediately starts a turn via `Task.Supervisor.async_nolink(Rho.TaskSupervisor, ...)` (`worker.ex:630`)
5. The turn calls `Rho.Runner.run/3` → `TurnStrategy.Direct.run/2` → `ReqLLM.stream_text/3` (`direct.ex:260`)
6. `ReqLLM.stream_text` checks out a Finch connection and holds it for the entire streamed LLM response

**Each sub-agent holds one Finch connection for the full duration of its LLM response** — typically 10–60 seconds, up to the 120s `stream_receive_timeout`.

### Connection Accounting for a Single User Session

| Actor | Connections Held | Duration |
|-------|-----------------|----------|
| Spreadsheet agent (parent) | 1 (own LLM call in progress while delegating) | 10–60s |
| proficiency_writer × N categories | N (one per concurrent LLM stream) | 10–60s each |
| Retry attempts (on transient failure) | up to 2 extra per failed agent | 1–2s backoff + full stream duration |

With 6 categories: **7 sustained connections minimum**, up to **13** if retries fire.

This fits within 25 for a single user — most of the time. The intermittent failures likely occur when:
- LLM responses are slow (OpenRouter routing latency, provider congestion)
- Multiple retries fire simultaneously
- The parent agent's own stream overlaps with all sub-agent streams
- `conn_max_idle_time: 30s` keeps stale connections checked out even when done streaming

---

## Why This Gets Worse

### Problem 1: The Pool Is Global — All Users Share It

`ReqLLM.Finch` is started once by `ReqLLM.Application` in the BEAM supervision tree. Every agent, every session, every user on the node shares the same 25-connection pool. There is no per-user, per-session, or per-agent isolation.

| Concurrent Users | Estimated Connections | Headroom |
|------------------|-----------------------|----------|
| 1 | 7–13 | 12–18 spare |
| 2 | 14–26 | **0–11 spare** |
| 3 | 21–39 | **pool exhausted** |
| 5 | 35–65 | **severe queuing** |

Even 2 concurrent users running the spreadsheet workflow simultaneously can hit the ceiling.

### Problem 2: No Admission Control Between Agent Spawning and Connection Pool

The system has two relevant limits:
- `@max_agents_per_session 10` (`multi_agent.ex:25`) — caps agents per session
- `@max_depth 3` (`multi_agent.ex:24`) — caps nesting depth

Neither of these limits the number of **concurrent LLM requests**. A session with 10 agents that are all simultaneously in a turn means 10 concurrent Finch connections — from one session alone. The `Task.Supervisor` (`application.ex:23`) has no concurrency ceiling; it will spawn as many tasks as requested.

The architecture creates an **impedance mismatch**: unbounded concurrency at the agent layer funnels into a fixed-size connection pool at the HTTP layer, with nothing in between to apply backpressure.

### Problem 3: HTTP/1.1 Means Connections Are Held for the Full Stream

Under HTTP/2, a single TCP connection can multiplex many requests. Under HTTP/1.1, each streaming LLM response exclusively occupies one connection until the stream completes. A slow provider response (e.g., OpenRouter routing to a congested backend) means that connection is dead weight for the entire wait.

The `stream_receive_timeout: 120_000` means a stalled stream can hold a connection for up to **2 full minutes** before timing out. During that window, that connection is unavailable to any other agent.

### Problem 4: Retries Amplify the Problem

Both `TurnStrategy.Direct` and `TurnStrategy.Structured` retry up to 2 times on transient errors (`@max_stream_retries 2`, `direct.ex:14`, `structured.ex:25`). Retryable conditions include `:timeout` and `:closed` (`direct.ex:293-299`).

When the pool is near capacity and a request times out, the retry logic fires — which requests *another* connection from the already-saturated pool. This creates a positive feedback loop:

1. Pool is near capacity → some requests queue → some queue long enough to timeout
2. Timeout triggers retry → retry requests a new connection → pool pressure increases
3. More timeouts → more retries → pool completely saturated

The retry backoff (1s, 2s) is too short to allow meaningful pool drainage when the underlying issue is capacity, not transient network failure.

### Problem 5: Connection Idle Time Creates Phantom Pressure

`conn_max_idle_time: 30_000` means a connection that finishes streaming stays checked out (idle) for up to 30 seconds before Finch reaps it. During this window it occupies a pool slot but isn't doing useful work. Under bursty workloads — which is exactly what parallel agent delegation creates — this means the pool doesn't recover capacity as quickly as streams complete.

### Problem 6: Tool Execution Can Trigger Additional HTTP Requests

Within a single agent turn, tools execute in parallel via `Task.async` (`direct.ex:121`). Some tools make their own HTTP requests:

- `WebFetch` tool uses `Req.get/2` (`web_fetch.ex:32`), which goes through the same Finch pool
- `delegate_task` itself doesn't consume a connection, but the spawned agent immediately does
- Any tool that makes external HTTP calls adds untracked connection pressure

The LLM has no visibility into pool state when deciding which tools to call or how many to call in parallel.

### Problem 7: Structured Turn Strategy Doubles Connection Usage

The `TurnStrategy.Structured` module (`structured.ex`) makes **two sequential LLM calls per turn**: one for reasoning and one for action. Each call holds a Finch connection. While they're sequential (not parallel), this doubles the connection-seconds consumed per turn compared to `Direct`.

The spreadsheet agent uses `:structured` strategy (`.rho.exs:162`), so the parent agent consumes 2× the connection time of each child `proficiency_writer` (which uses `:direct`).

### Problem 8: No Observability Into Pool State

There is no monitoring, metric, or log that tracks Finch pool utilization. The Observatory (`RhoWeb.Observatory`) collects agent-level metrics but has no visibility into HTTP connection pool pressure. The first sign of trouble is the runtime error in the agent's output — by which point the pool is already saturated.

`Finch.pool_status/2` exists but is never called anywhere in the codebase.

---

## Failure Modes

### Mode 1: Silent Agent Failure (Current)

The Finch error propagates up as `{:error, %RuntimeError{...}}` through the runner. The `proficiency_writer` agent's turn fails. The parent agent, waiting on `await_task`, receives an error result. Depending on the parent's remaining step budget, it may retry the delegation — which can fail again for the same reason.

### Mode 2: Cascade Timeout Under Load

Multiple agents timeout waiting for connections. Each fires retries. The retries also timeout. The parent agent's `await_task` eventually times out after `@await_timeout 300_000` (5 minutes). The user sees a long hang followed by a generic error.

### Mode 3: Cross-Session Interference

User A's spreadsheet workflow saturates the pool. User B, running a completely unrelated single-agent chat, gets a Finch timeout on a routine LLM call. User B has no way to know that User A's workload caused their failure. From User B's perspective, the system is broken.

### Mode 4: Starvation Under Mixed Workloads

Long-running agents (e.g., a `:coder` agent with `max_steps: 30` doing iterative debugging) hold connections for extended periods. Short-lived agents that need a quick single-turn response queue behind them. The pool has no priority or fairness mechanism — first-come, first-served.

---

## Reproducing the Issue

The simplest reproduction:

1. Start a spreadsheet session with a domain that generates 6+ categories
2. Approve the skeleton to trigger Phase 3 (parallel proficiency delegation)
3. Observe that 6 `proficiency_writer` agents spawn near-simultaneously
4. If any LLM responses are slow (>10s), the 7th+ concurrent request may fail

Higher reliability reproduction:

1. Open two browser tabs, each with a spreadsheet session
2. Trigger Phase 3 in both at roughly the same time
3. 12+ concurrent LLM streams from a 25-connection pool — near-certain failure

---

## Measuring the Problem: Available Telemetry

Before changing architecture, the problem should be measured. Finch emits telemetry events that can confirm whether pool saturation actually occurs and how severe it is. Currently **none of these are attached** in the Rho codebase.

### Finch Queue Events (Connection Checkout)

These are the most directly relevant — they measure the time spent waiting for a connection from the pool.

| Event | When | Key Measurements | Key Metadata |
|-------|------|-----------------|--------------|
| `[:finch, :queue, :start]` | Before checking out a connection | `system_time` | `name`, `pool` (pid), `request` |
| `[:finch, :queue, :stop]` | After successful checkout | `duration` (native units), `idle_time` | `name`, `pool`, `request` |
| `[:finch, :queue, :exception]` | Checkout failed (pool exhausted) | `duration` | `name`, `request`, `kind`, `reason`, `stacktrace` |

The `[:finch, :queue, :exception]` event fires on the exact failure we're seeing. The `duration` measurement tells us how long the caller waited before being rejected. The `[:finch, :queue, :stop]` event's `duration` tells us how long successful checkouts wait — a leading indicator of saturation before failures begin.

### Finch Pool Metrics (Snapshot)

Finch supports `start_pool_metrics?: true` in pool config, which enables `Finch.get_pool_status/2`. This is currently **disabled** (default `false`).

When enabled, `Finch.get_pool_status(ReqLLM.Finch, url)` returns per-pool snapshots:

```elixir
%Finch.HTTP1.PoolMetrics{
  pool_index: 1,
  pool_size: 25,                  # configured size
  available_connections: 3,       # free right now
  in_use_connections: 22          # held by active requests
}
```

This is stored in `:persistent_term` with `:atomics` references, so reading it is cheap — safe to poll on a timer (e.g., every 1s from Observatory's existing `:tick` handler).

### Request Lifecycle Events

Broader context for understanding where time is spent per LLM call:

| Event | When | Useful For |
|-------|------|-----------|
| `[:finch, :request, :start]` | `Finch.request/3` or `Finch.stream/5` called | Counting concurrent in-flight requests |
| `[:finch, :request, :stop]` | Request/stream completed | Total request duration (includes queue + connect + send + recv) |
| `[:finch, :connect, :start/stop]` | New TCP connection opened | How often connections are created vs reused |
| `[:finch, :reused_connection]` | Existing connection reused | Connection reuse rate |
| `[:finch, :recv, :stop]` | Response fully received | Actual stream duration (excluding queue/connect) |
| `[:finch, :conn_max_idle_time_exceeded]` | Idle connection reaped | Pool churn rate |

### What These Would Tell Us

With telemetry attached, we could answer:

1. **Is the pool actually saturating?** — `in_use_connections` approaching `pool_size` during parallel delegation
2. **How long do checkouts wait?** — `[:finch, :queue, :stop]` duration distribution; healthy is <1ms, concerning is >100ms
3. **How often do checkouts fail?** — `[:finch, :queue, :exception]` rate; any non-zero rate = pool exhaustion occurring
4. **What's the connection hold time?** — `[:finch, :request, :stop]` duration; this is the stream duration that prevents pool recovery
5. **Are connections being reused?** — ratio of `[:finch, :connect, :start]` to `[:finch, :reused_connection]`; low reuse under parallel load means the pool is constantly at capacity
6. **Does the problem correlate with agent count?** — cross-referencing pool metrics with the existing Observatory agent count

### What's Missing Without Telemetry

Right now, the only signal is the `RuntimeError` message in agent output. This means:

- We don't know how close to saturation the pool gets during normal (successful) operations
- We don't know the queue wait time distribution — are successful requests barely making it, or is there headroom?
- We can't distinguish between "pool too small" and "a few requests holding connections too long"
- We can't tell if the problem is worse with certain LLM providers (OpenRouter routing adds variable latency)
- The Observatory shows agent status but has no HTTP-layer visibility

---

## Summary of Contributing Factors

| Factor | Location | Impact |
|--------|----------|--------|
| Global shared pool (25 conns) | `config.exs:12` | Hard ceiling on all concurrent HTTP |
| HTTP/1.1 only | `config.exs:12` | No multiplexing, 1 req = 1 conn |
| No concurrency limit on agent turns | `application.ex:23` | Unbounded demand on bounded pool |
| 120s stream timeout | `config.exs:8` | Slow responses hold connections long |
| Retry on timeout (2 retries) | `direct.ex:14,267-286` | Failed requests amplify pool pressure |
| 30s idle connection hold | `config.exs:12` | Slow pool slot recovery |
| No per-session connection budget | `multi_agent.ex:24-25` | Only agent count is limited, not conn usage |
| No pool observability | — | Problems invisible until failure |
| Structured strategy = 2 LLM calls/turn | `structured.ex` | Parent agent uses 2× connection time |
| `@max_agents_per_session 10` | `multi_agent.ex:25` | 10 agents × concurrent turns = 10 conns from one session |
