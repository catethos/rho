# Rho Agent: Automated Improvement via AI-Driven Feedback Loops

## Overview

This document outlines the logging, data collection, and feedback mechanisms needed to enable automated, AI-driven improvement of the Rho agent. The goal is to close the loop between agent behavior and agent quality — so that an evaluator/optimizer AI can continuously identify failure modes and propose fixes.

---

## 1. Structured Trace Logs (per turn)

Events are currently ephemeral. Persist a **structured trace** for every turn:

```elixir
%Trace{
  session_id, turn_id, timestamp,
  steps: [
    %{step: 1, llm_input_tokens: N, llm_output_tokens: N, latency_ms: N,
      tool_calls: [%{name: "bash", args: %{...}, result_status: :ok, latency_ms: N, output_bytes: N}],
      had_retry: false, compact_triggered: false}
  ],
  total_steps: N, max_steps_hit: false,
  anchor_created: false, subagents_spawned: 0
}
```

**Why**: An evaluator AI can spot patterns like "agent always retries bash 3 times before getting the right command" or "agent uses 12 steps for tasks that should take 3."

**Where to hook**: `AgentLoop.do_loop/6` — wrap each iteration to capture step-level data, then write the full trace on turn completion in `Session.Worker`.

---

## 2. Tool Call Failure Taxonomy

Tool errors are currently unstructured strings. Add structured error classification:

- **error_type**: `:invalid_args | :permission_denied | :not_found | :timeout | :runtime_error | :unknown_tool`
- **was_self_corrected**: did the agent fix it on the next step?
- **correction_attempts**: how many tries before success

**Why**: An optimizer AI can identify which tools have the worst error rates and whether the system prompt needs better guidance for those tools.

**Where to hook**: Tool `execute/2` return values. Add a post-processing step in `AgentLoop` that classifies errors and tracks whether the next step re-invokes the same tool successfully.

---

## 3. Prompt-to-Outcome Pairs

For every user message, log:

```elixir
%{
  user_intent: "original prompt",
  final_output: "agent's final text response",
  tools_used: ["bash", "fs_read", "fs_write"],
  steps_taken: 7,
  did_user_follow_up_with_correction: bool,
  session_continued_after: bool,
  time_to_completion_ms: N
}
```

**Why**: This is training data. An evaluator AI can score outcomes and cluster failure modes. The "did user correct" signal is the cheapest implicit reward.

**Where to hook**: `Session.Worker` — on turn completion, assemble the pair. The correction flag gets backfilled when the *next* user message arrives.

---

## 4. User Correction Detection

Parse user follow-up messages for correction signals:

- Negative keywords: "no", "that's wrong", "not what I asked", "undo", "revert"
- User re-submits a very similar prompt (retry behavior — cosine similarity or edit distance)
- User manually edits a file the agent just wrote (detectable via `mtime` checks or git diff)

Log these as **negative feedback episodes**.

**Why**: This is the highest-signal data currently not being collected. Each correction is an implicit label: "the previous turn was wrong."

**Where to hook**: `Session.Worker.handle_cast({:submit, ...})` — before processing the new message, analyze it against the previous turn's output.

---

## 5. Context Window Efficiency Metrics

Per turn, log:

- **tokens_in_context**: total tokens sent to LLM
- **compaction_count**: how many times compaction fired during the turn
- **anchor_recovery**: after an anchor, did the agent need to `recall_context` or `search_history`? (indicates the anchor summary lost important info)
- **context_utilization**: ratio of context tokens to useful output

**Why**: An optimizer AI can tune compaction thresholds, anchor summarization prompts, and context assembly strategies.

**Where to hook**: `Tape.Compact` and `Tape.View` — instrument context assembly and compaction events.

---

## 6. System Prompt A/B Testing Infrastructure

Add:

- A `prompt_variant_id` tag on each session
- Logging of which system prompt / tool descriptions were active
- Comparison of success metrics across variants

```elixir
# In config or session start
%{
  prompt_variant: "v3-concise-tools",
  active_system_prompt_hash: "abc123",
  tool_descriptions_hash: "def456"
}
```

**Why**: This closes the loop. An AI generates prompt variants → they run against real traffic → metrics determine which variant wins.

**Where to hook**: `Config` module — add variant tagging. `Session.Worker` — include variant in trace metadata.

---

## 7. Tool Description Effectiveness

Log when the LLM:

- Calls a tool with wrong argument types/values (schema validation failures)
- Calls a tool that doesn't exist (hallucinated tool name)
- Uses tool X when tool Y would have been more efficient (detectable post-hoc by evaluator)
- Ignores a tool that would have solved the task in fewer steps

**Why**: Tool descriptions are a major lever for agent quality. An optimizer AI can rewrite them based on misuse patterns.

**Where to hook**: `AgentLoop` tool dispatch — log the full tool call context when errors occur. Post-hoc analysis by evaluator AI on completed traces.

---

## 8. Subagent Performance

Current subagent observability is limited. Add:

- **task_description** vs **actual_result** pairs
- **did parent accept result**: did the parent re-do the work after collecting?
- **depth vs quality**: track success rate at each nesting depth
- **concurrency utilization**: are subagent slots saturated? how long do spawns wait?

**Where to hook**: `Plugins.Subagent` and `Plugins.Subagent.Worker` — instrument spawn, collect, and result events.

---

## 9. Cost Attribution

Per turn: `{input_tokens, output_tokens, model, cost_usd}`. Per session: cumulative.

Tag by user intent category if classifiable (e.g., "file edit", "debugging", "exploration", "explanation").

**Why**: An optimizer AI should factor in cost. A 2-step solution at $0.02 beats a 15-step solution at $0.30 even if both succeed.

**Where to hook**: Already partially available via `:llm_usage` events. Aggregate in trace logs and add cost calculation based on model pricing.

---

## The Meta-Loop: Putting It All Together

```
┌─────────────────────────────────────────────────────────┐
│                    PRODUCTION AGENT                      │
│                                                         │
│  User ─→ Session ─→ AgentLoop ─→ Tools ─→ Response     │
│              │                                          │
│              └─→ Trace Logger ─→ Structured Traces      │
└─────────────────────────────────┬───────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────┐
│                   TRACE STORAGE                         │
│                                                         │
│  traces/   (JSONL per session)                          │
│  ├── session_abc_turn_1.jsonl                           │
│  ├── session_abc_turn_2.jsonl                           │
│  └── ...                                                │
└─────────────────────────────────┬───────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
┌───────────────────────────┐  ┌───────────────────────────┐
│     EVALUATOR AI          │  │     ANALYZER AI           │
│                           │  │                           │
│  Score each episode:      │  │  Cluster failure modes:   │
│  - success (0-1)          │  │  - "bash tool misuse"     │
│  - efficiency (steps)     │  │  - "excessive steps"      │
│  - cost                   │  │  - "wrong tool choice"    │
│  - user satisfaction      │  │  - "lost context"         │
│    (correction signal)    │  │  - "hallucinated tool"    │
└───────────┬───────────────┘  └───────────┬───────────────┘
            │                              │
            └──────────┬───────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│                   OPTIMIZER AI                          │
│                                                         │
│  Proposes changes based on scored failure clusters:     │
│  - System prompt rewrites                               │
│  - Tool description edits                               │
│  - New tool suggestions                                 │
│  - Compaction threshold tuning                          │
│  - Anchor summary prompt improvements                   │
│                                                         │
│  Output: prompt variant candidates                      │
└─────────────────────────────────┬───────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────┐
│                   A/B TEST RUNNER                        │
│                                                         │
│  - Assign variant_id to new sessions                    │
│  - Route traffic across variants                        │
│  - Collect metrics per variant                          │
│  - Promote winner after significance threshold          │
└─────────────────────────────────────────────────────────┘
```

---

## Implementation Priority

### Phase 1: Minimum Viable Feedback Loop
1. **Structured trace logs** (item 1) — foundation for everything else
2. **Tool call failure taxonomy** (item 2) — highest signal-to-effort ratio
3. **User correction detection** (item 4) — cheapest implicit reward signal

With just these three, you can periodically feed failure logs to an AI that rewrites system prompt sections. This alone compounds quickly.

### Phase 2: Optimization Infrastructure
4. **Prompt-to-outcome pairs** (item 3) — enables systematic evaluation
5. **Cost attribution** (item 9) — enables cost-aware optimization
6. **System prompt A/B testing** (item 6) — closes the automated loop

### Phase 3: Advanced Signals
7. **Context window efficiency** (item 5) — optimize memory management
8. **Tool description effectiveness** (item 7) — fine-grained tool optimization
9. **Subagent performance** (item 8) — optimize parallel execution
