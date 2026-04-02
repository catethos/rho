# Observatory: AI-Driven Multi-Agent Improvement Loop

## What Was Built

Two new modules were added to Rho:

### 1. `Rho.Observatory` (`lib/rho/observatory.ex`)
GenServer that subscribes to the signal bus and collects real-time metrics:
- Per-agent: step count, tool call counts/latencies, token usage, errors, cost
- Per-session: agent count, total tokens, total errors
- Signal flow tracking (delegation patterns between agents)
- Event buffer (last 200 events per session)
- Diagnostic heuristics: high error rate, large context, tool hotspots, slow tools, excessive steps

### 2. `RhoWeb.ObservatoryAPI` (`lib/rho_web/observatory_api.ex`)
JSON HTTP API (Plug-based, no controller scaffolding):

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/sessions` | List all sessions with activity |
| GET | `/api/sessions/:id/metrics` | Aggregated session metrics |
| GET | `/api/sessions/:id/agents` | All agents + live status |
| GET | `/api/sessions/:id/signals` | Signal flow graph |
| GET | `/api/sessions/:id/events` | Recent events (last N) |
| GET | `/api/sessions/:id/diagnose` | Run diagnostic heuristics |
| GET | `/api/agents/:id/metrics` | Single agent metrics |
| GET | `/api/agents/:id/tape` | Agent tape history (memory) |
| POST | `/api/sessions/:id/submit` | Submit input (async, returns turn_id) |
| POST | `/api/sessions/:id/ask` | Submit input (sync, blocks until done) |

### 3. Wiring
- `Rho.Observatory` added to supervision tree in `lib/rho/application.ex` (after SignalBus, before Agent.Supervisor)
- API pipeline + forward added to `lib/rho_web/router.ex`

## How to Start

```bash
RHO_WEB_ENABLED=true mix phx.server
# API available at http://localhost:4001/api/
```

## The Improvement Loop Plan

### Phase 1: Observe a Multi-Agent Task

Start Rho, then give it a task that exercises multi-agent coordination. The `.rho.exs` already has evaluator agents for a hiring committee scenario. A good test task:

```bash
# Submit a task via the API
curl -X POST http://localhost:4001/api/sessions/test1/ask \
  -H 'Content-Type: application/json' \
  -d '{"content": "Evaluate these 3 candidates for Senior Backend Engineer: 1) Alice - 8yr Elixir, $175K ask, job-hopped 3x in 5yr. 2) Bob - 5yr Go/Python, $160K, stable 4yr tenure, no Elixir. 3) Carol - 12yr distributed systems, $200K ask, strong OSS contributions."}'
```

This should trigger the default agent to delegate to technical_evaluator, culture_evaluator, and compensation_evaluator via multi_agent tools.

### Phase 2: Collect Observations

```bash
# What happened?
curl http://localhost:4001/api/sessions/test1/metrics | jq .
curl http://localhost:4001/api/sessions/test1/agents | jq .
curl http://localhost:4001/api/sessions/test1/diagnose | jq .
curl http://localhost:4001/api/sessions/test1/events | jq .
curl http://localhost:4001/api/sessions/test1/signals | jq .

# Deep dive on specific agent
curl http://localhost:4001/api/agents/AGENT_ID/tape | jq .
```

### Phase 3: Analyze and Improve

Based on observations, look for:

1. **Token waste** — Are agents sending too much context? Is compaction working? Are system prompts bloated?
   - Fix: Trim system prompts, adjust compact_threshold, reduce max_steps

2. **Error patterns** — Which tools fail? Are agents retrying the same failing call?
   - Fix: Improve error messages, add tool argument validation, adjust system prompts to guide better tool use

3. **Delegation efficiency** — Does the primary agent delegate well? Do sub-agents finish quickly?
   - Fix: Adjust agent profiles in `.rho.exs`, improve role descriptions, change models (haiku for simple tasks, sonnet for complex)

4. **Coordination overhead** — Are agents sending too many messages to each other? Is there unnecessary back-and-forth?
   - Fix: Simplify coordination protocol, reduce max_steps for sub-agents, make system prompts more directive

5. **Cost optimization** — Which agents burn the most tokens? Can cheaper models handle certain roles?
   - Fix: Switch models, reduce prompt verbosity, enable caching

6. **Step budget** — Are agents using all their steps? Are they finishing early?
   - Fix: Right-size max_steps per agent profile

### Phase 4: Apply Changes

Changes typically go to:
- `.rho.exs` — agent profiles (model, mounts, max_steps, system_prompt)
- `lib/rho/agent_loop.ex` — loop behavior, compaction thresholds
- Mount implementations — tool behavior, error handling
- `lib/rho/reasoner/direct.ex` — LLM call strategy, retry logic

### Phase 5: Re-run and Compare

After changes, re-run the same task and compare metrics. The Observatory persists per-session, so you can run `test1` then `test2` and compare.

## Key Files Reference

| File | Purpose |
|------|---------|
| `.rho.exs` | Agent profiles — model, mounts, system prompt, max_steps |
| `lib/rho/observatory.ex` | Metrics collector (NEW) |
| `lib/rho_web/observatory_api.ex` | HTTP API (NEW) |
| `lib/rho/application.ex` | Supervision tree (MODIFIED) |
| `lib/rho_web/router.ex` | Routes (MODIFIED) |
| `lib/rho/agent_loop.ex` | Core agent loop |
| `lib/rho/reasoner/direct.ex` | LLM call + tool execution |
| `lib/rho/agent/worker.ex` | Agent process, event emission |
| `lib/rho/comms/signal_bus.ex` | Signal bus (jido_signal wrapper) |
| `lib/rho/agent/registry.ex` | ETS agent discovery |
| `lib/rho/session.ex` | Session lifecycle |
| `lib/rho/config.ex` | Config loading, mount resolution |

## Architecture Notes

- Observatory subscribes to `rho.session.*.events.*`, `rho.agent.*`, `rho.task.*` on the signal bus
- High-frequency events (text_delta, llm_text, llm_usage) only publish to bus when subscribers exist — Observatory's subscription ensures they flow
- The `/api/sessions/:id/ask` endpoint is synchronous (blocks until agent finishes) — useful for scripted testing
- The `/api/sessions/:id/submit` endpoint is async (returns turn_id) — poll events endpoint to watch progress
- Agent tape (memory) is accessible via the API for deep inspection of what the agent saw and did
