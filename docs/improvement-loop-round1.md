# Improvement Loop — Round 1 Results

**Date**: 2026-03-25
**Task**: Hiring committee evaluation (3 candidates for Senior Backend Engineer)

## Test Runs

| Run | Config | Agents | Tokens | Tools | Errors | Outcome |
|-----|--------|--------|--------|-------|--------|---------|
| test1 | structured reasoner, no delegation instructions | 1 | 8,432 | 1 | 0 | Single agent answered directly, no delegation |
| test2 | structured reasoner + delegation instructions | 1 | 7,422 | 0 | 0 | Structured reasoner produced plain text, ignored JSON format |
| test3 | direct reasoner + delegation instructions | 1 | 21,281 | 4 | 3 | LLM called `await_task` without calling `delegate_task` first |
| test4 | direct reasoner + explicit 2-step instructions | 29 | 129,577 | 57 | 12 | Delegation worked but agents exploded recursively |
| test5 | direct reasoner + constrained evaluators | 4 | 39,508 | 10 | 0 | Clean run: 1 coordinator + 3 evaluators, zero errors |

## Bugs Fixed

### 1. Observatory API body parsing (observatory_api.ex)
**Problem**: `handle_submit` and `handle_ask` called `Plug.Conn.read_body(conn)` but the Phoenix router's `:api` pipeline already runs `Plug.Parsers` which consumes the body. Second read returned empty/error.
**Fix**: Changed to `conn.body_params` which contains the already-parsed JSON.

### 2. Observatory crash on `turn_started` (observatory.ex)
**Problem**: `default_metrics()` didn't include `:last_turn_started`, but `process_signal` used `%{m | last_turn_started: now()}` which requires the key to exist (map update syntax only updates existing keys).
**Fix**: Added `:last_turn_started`, `:status`, `:current_step`, `:current_tool`, `:queued` to `default_metrics()`.

## Config Changes

### 3. Default agent system prompt (.rho.exs)
**Problem**: No delegation instructions — agent answered directly even with `multi_agent` mount available.
**Fix**: Added explicit two-step delegation section:
```
1. FIRST call `delegate_task` — this returns an agent_id.
2. THEN in the NEXT step, call `await_task` with the agent_ids from step 1.
Never call `await_task` without first calling `delegate_task`.
```

### 4. Default agent reasoner (.rho.exs)
**Problem**: Structured reasoner (`reasoner: :structured`) uses `stream_text` without native tool_use — tools described only in prompt. LLM frequently ignored JSON format and answered in plain text.
**Fix**: Switched to `reasoner: :direct` which uses native tool_use protocol. Much more reliable tool calling.

### 5. Evaluator agent explosion (.rho.exs)
**Problem**: All three evaluator profiles had `mounts: [:multi_agent, :journal]`. When delegated to, they spawned their own sub-agents (researchers), which spawned more at depth 3. Result: 29 agents, 129K tokens, Finch connection pool exhaustion.
**Fix**:
- Removed `:multi_agent` from evaluator mounts → `mounts: [:journal]`
- Reduced `max_steps` from 20 → 5 (evaluators should finish in 1-2 LLM calls)
- Simplified system prompts to focus on direct evaluation + `finish` tool
- Switched all evaluators to `reasoner: :direct`

## Metrics Improvement (test4 → test5)

| Metric | Before (test4) | After (test5) | Change |
|--------|---------------|---------------|--------|
| Agents | 29 | 4 | -86% |
| Tokens | 129,577 | 39,508 | -70% |
| Tool calls | 57 | 10 | -82% |
| Errors | 12 | 0 | -100% |
| Diagnostic issues | 8 | 0 | -100% |
| Signal flow | broken (Observatory crashed) | 3 delegations + 3 results | working |

## Architecture Observations

- **Structured vs Direct reasoner**: The structured reasoner is unreliable for tool calling — the LLM often ignores the JSON format and produces plain text. Direct reasoner (native tool_use) is significantly more reliable. Structured may be better for streaming visibility but needs stronger enforcement.
- **Recursive delegation is dangerous**: Any agent with `multi_agent` mount can spawn sub-agents. Without explicit depth/mount constraints, this creates exponential agent trees. The `@max_depth 3` guard prevents infinite recursion but still allows 3 levels of delegation.
- **Finch connection pool**: Concurrent LLM requests from many agents overwhelm the default connection pool. Need pool sizing or request queuing for multi-agent scenarios.
- **Observatory resilience**: A single missing map key crashed the entire Observatory GenServer, losing all metrics for the session. The GenServer should be more defensive.
