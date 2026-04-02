# Improvement Loop — Round 2 Results

**Date**: 2026-03-25
**Goal**: Move from DAG-only multi-agent to agents that can actually discuss with each other.

## Problem Statement

Round 1 ended with a clean DAG workflow (test5): coordinator delegates to 3 evaluators, awaits results, synthesizes. But removing `:multi_agent` from evaluators to prevent recursive explosion also killed any ability for peer discussion. The topology was strictly fan-out/fan-in — no deliberation.

## Changes Made

### 1. Mount tool filtering (multi_agent.ex)

**Problem**: `:multi_agent` mount was all-or-nothing — you got all tools or none.
**Fix**: Added `:only` / `:except` options to `multi_agent` mount. The `tools/2` callback now pipes through `filter_tools/2` which checks mount opts.

```elixir
# Coordinator gets everything except polling
{:multi_agent, except: [:collect_results]}

# Evaluators get only messaging + discovery
{:multi_agent, only: [:send_message, :broadcast_message, :list_agents, :get_agent_card]}
```

This lets evaluators communicate with peers without being able to spawn new agents.

### 2. New simulation tools (multi_agent.ex)

Added three tools for the spawn-message-collect pattern:

- **`spawn_agent`** — creates an agent that starts idle (no initial task), ready for messages. Unlike `delegate_task`, doesn't require `await_task` — the agent stays alive.
- **`collect_results`** — reads an agent's tape without stopping it. Non-destructive observation.
- **`stop_agent`** — explicit teardown when done.

Also added `finish` to the multi_agent tool list so any agent with the mount can signal final completion.

### 3. Push-based message flow (worker.ex, session.ex, finish.ex)

**Problem**: Coordinator polled with `collect_results` + `bash sleep`, burning tokens.
**Fix**: Evaluators push results back via `send_message`, coordinator receives them as new turns.

Code changes to support this:
- **finish.ex**: Changed return from `{:ok, value}` to `{:final, value}` so workers can distinguish "done for now" from "done forever".
- **agent_loop.ex**: `{:final, value, entries}` now returns `{:final, value}` (not `{:ok, value}`) to the worker.
- **worker.ex**: New `handle_info` clause for `{:final, value}` — replies to waiters. Regular `{:ok, text}` turns no longer reply to waiters, allowing multi-turn conversations. Added `{:set_persistent_tools, tools}` cast for spawned agents. Added `:agent_idle` broadcast after turn ends with empty queue.
- **session.ex**: `ask/3` accepts `await: :finish` option. `receive_until_done/2` in `:finish` mode waits for a `{:final, value}` event, with a 30s timeout fallback after the last turn_finished.
- **observatory_api.ex**: `/ask` endpoint accepts `"await": "finish"` body param.

### 4. Evaluator prompt changes (.rho.exs)

Replaced "call finish tool with your evaluation" with instructions to `send_message` results back to the requesting agent and engage with other evaluators' findings.

### 5. Coordinator prompt changes (.rho.exs)

Added "Simulation" section alongside existing "Delegation" section. Describes the spawn → send → end_turn → receive → finish flow. Explicitly says "Do NOT poll with collect_results or sleep with bash."

Removed `:bash` from coordinator mounts to close the sleep escape hatch.

## Test Runs

| Run | Config | Agents | Tokens | Coordinator Turns | Evaluator Turns (avg) | Errors | Outcome |
|-----|--------|--------|--------|-------------------|-----------------------|--------|---------|
| round2_test1 | DAG baseline (delegate/await) | 4 | 36,689 | 2 | 1 | 0 | Clean DAG, no messaging. Evaluators didn't use send_message — no reason to. |
| round2_sim1 | spawn + full multi_agent on evaluators | 5 | 335,986 | — | — | 1 | Evaluators got spawn_agent/collect_results, went rogue. Culture evaluator spawned sub-agents. |
| round2_sim2 | spawn + `only: [messaging]` on evaluators | 4 | 346,580 | 6 | 2 | 0 | Push model worked. Evaluators used send_message (2 turns). Coordinator still polled with collect_results ×9 and bash sleep ×3. |
| round2_sim5 | Removed bash + collect_results from coordinator | 4 | 444,069 | 9 | 3 | 0 | No polling. Coordinator went 9 turns but never called `finish` — `await: :finish` hung. |
| round2_sim6 | Added implicit idle detection (turns >= 2) | 4 | 68,691 | 3 | 1 | 1 | Fast but returned too early — only 2/3 evaluators had responded. 1 evaluator had 0 output tokens (LLM call may have failed). |
| round2_sim7 | Timeout-based (30s after last turn) | 4 | 164,596 (at HTTP return) → 381,022 (final) | 4 → 7 | 2-4 | 0 | Returned mid-simulation (2/3 responses). Simulation continued in background. Evaluators had real cross-examination (up to 7 turns). |

## What Works

1. **Tool filtering** — `only:` / `except:` on multi_agent mount is the right granularity. Eliminates explosion without cutting off communication.
2. **Push messaging** — evaluators reliably use `send_message` to push results to the coordinator. The worker's `process_signal` → `start_turn` pipeline handles incoming messages correctly.
3. **Multi-turn discussion** — evaluators respond to broadcasts and cross-examine each other (sim7: up to 7 turns for compensation evaluator, 4 for culture, 3 for technical).
4. **spawn_agent** — creates agents that stay alive across multiple message-triggered turns. The persistent_tools mechanism ensures tools survive across turns.
5. **Token efficiency at the evaluator level** — individual evaluators use 5-35K tokens across 1-4 turns. Reasonable.

## Open Problems for Round 3

### P1. Coordinator doesn't call `finish` — the `/ask` completion problem

**Severity**: High — blocks reliable synchronous simulation execution.

The coordinator consistently uses `end_turn` instead of `finish` for its final step. This means `await: :finish` either hangs forever or requires a timeout heuristic that races against async message delivery.

**Root cause**: The LLM treats `end_turn` as the natural way to end any turn. `finish` is associated with subagents ("return result to parent"). The coordinator doesn't think of itself as needing to "finish" — it thinks it's having a conversation.

**Possible fixes**:
- Remove `end_turn` from the tool list when `finish` is available (forces the model to use `finish`)
- Rename `finish` to something the coordinator would naturally reach for (e.g., `submit_final_answer`)
- Make `end_turn` behave like `finish` when called by the primary agent (auto-promote)
- Accept that simulations are inherently async and don't try to make `/ask` synchronous for them

### P2. Coordinator token explosion across turns

**Severity**: High — 104-638K input tokens on the coordinator alone.

Each new turn replays the full tape (system prompt + all prior messages). By turn 7, the coordinator has accumulated the entire conversation history from all evaluator exchanges. The tape grows linearly but input tokens grow quadratically across turns.

**Root cause**: `memory_mod.build_context(tape_name)` returns the full message history. Every message from every evaluator gets appended to the tape and replayed on the next turn.

**Possible fixes**:
- Aggressive compaction between turns (summarize prior evaluator messages)
- Cap the context window for message-triggered turns (only include last N messages)
- Have the coordinator maintain a structured summary rather than raw message history
- Use a separate "scratchpad" mount where the coordinator writes notes, rather than replaying full messages

### P3. Timing gap between coordinator idle and evaluator response

**Severity**: Medium — coordinator goes idle between turns, creating a window where timeout-based detection fires prematurely.

The coordinator sends messages to evaluators, calls `end_turn`, goes idle. Evaluators process (takes 5-20s for an LLM call), then send_message back. During those 5-20s, the coordinator is idle with an empty queue. Any timeout-based heuristic must be longer than the slowest evaluator response.

**Possible fixes**:
- Track "outstanding messages" — coordinator knows it sent 3 messages and should expect 3 replies
- Agent-level state: `:waiting_for_messages` status distinct from `:idle`
- Increase timeout to 120s+ (simple but wasteful for fast completions)
- Event-driven: coordinator registers interest in N replies, system notifies when all arrive

### P4. Evaluator occasionally fails silently

**Severity**: Medium — in sim6, one evaluator (agent_836) had 0 output tokens and never responded.

**Root cause**: Unknown. Possibly an LLM API error that was swallowed, or the evaluator's first turn failed and it went idle without sending a message. The coordinator had no way to know the evaluator was dead.

**Possible fixes**:
- Health checking: coordinator can `list_agents` to see status, but this is polling again
- Death notification: when a spawned agent's turn errors, send an error message back to the parent automatically
- Timeout per evaluator: if no response within X seconds, coordinator proceeds without it

### P5. No structured discussion protocol

**Severity**: Low (architectural) — agents discuss but there's no protocol structure.

Currently discussion is freeform: broadcast a summary, evaluators respond whenever. There's no "round" concept, no voting mechanism, no convergence detection. For simple 3-agent discussions this works, but for larger simulations it won't scale.

**Possible fixes**:
- Discussion mount: provides `propose`, `vote`, `consensus_check` tools
- Round-based protocol: coordinator explicitly runs numbered rounds with clear prompts
- Convergence signal: agents signal "I have nothing new to add" and coordinator detects quorum

## Architecture Observations

- **Tool availability shapes behavior more than prompts**: Removing `collect_results` and `bash` from the coordinator was far more effective than prompt instructions saying "don't poll." If the model can poll, it will poll.
- **`finish` vs `end_turn` is a fundamental UX gap**: These two tools serve different purposes (signal final result vs. yield control) but the model conflates them. This distinction matters most for multi-turn agents.
- **The worker's message handling is solid**: `deliver_signal` → mailbox → `process_signal` → `start_turn` works correctly. Messages queue when busy, process when idle, tools persist across turns. The plumbing is right.
- **Coordinator is the bottleneck**: Evaluators are efficient (5-35K tokens, 1-4 turns, focused tool use). The coordinator burns 10-20x more tokens because it accumulates everyone's context. Fixing coordinator efficiency is the highest-leverage improvement.
- **DAG and simulation can coexist**: The same mount with different `only:`/`except:` filters supports both patterns. `delegate_task`/`await_task` for DAG, `spawn_agent`/`send_message`/`finish` for simulation. No need to choose one.

## Metrics Comparison (Round 1 best → Round 2 best)

| Metric | test5 (R1 DAG) | round2_test1 (R2 DAG) | round2_sim7 (R2 simulation) |
|--------|---------------|----------------------|---------------------------|
| Agents | 4 | 4 | 4 |
| Tokens | 39,508 | 36,689 | 164,596 (at return) / 381,022 (final) |
| Coordinator turns | 2 | 2 | 4-7 |
| Evaluator turns (avg) | 1 | 1 | 2-4 |
| Tool calls | 10 | 10 | 15-21 (coordinator) + 2-3 per evaluator |
| Errors | 0 | 0 | 0-1 |
| Inter-agent messages | 0 | 0 | 8-15 |
| Discussion rounds | 0 | 0 | 1-2 (broadcast + response) |

Simulation costs ~4-10x more tokens than DAG, but produces genuinely differentiated evaluations with cross-examination. Whether that tradeoff is worth it depends on the use case.
