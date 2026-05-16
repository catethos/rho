# Improvement Loop — Round 2 Plan

**Goal**: Address the remaining issues surfaced in Round 1 and push for higher-quality multi-agent coordination.

## Problem Areas to Investigate

### 1. Observatory Resilience
**Observed**: A single `KeyError` crashed the Observatory GenServer, losing all session metrics.
**Investigation**:
- Audit all `%{m | key: value}` patterns in `process_signal/3` — every key used with map update syntax must exist in `default_metrics()`
- The `handle_info` for signal processing should rescue exceptions so one bad signal doesn't take down the whole observer

**Proposed fix**:
- Wrap `process_signal/3` in a try/rescue inside `handle_info`
- Log the error and continue rather than crashing
- Add a test that sends signals in unexpected order (e.g., `turn_finished` before `turn_started`)

### 2. Tape Serialization
**Observed**: Agent tape entries returned as `{kind: null, payload: null}` — the API couldn't serialize them.
**Investigation**:
- Check the shape of entries returned by `memory_mod.history/1`
- The `sanitize_tape_entry/1` function accesses `entry[:kind]` and `entry[:payload]` — if entries are structs with different field names, this returns nil
- Read `Rho.Memory.Tape` to understand the actual entry shape

**Proposed fix**:
- Update `sanitize_tape_entry/1` to handle the actual entry struct shape
- Add the entry's role/content fields to the serialized output
- This is critical for debugging — without readable tapes, we can't see what agents actually saw

### 3. Finch Connection Pool Sizing
**Observed**: With 4+ concurrent agents making LLM requests, Finch hit "excess queuing for connections" errors.
**Investigation**:
- Check current Finch pool config (likely default 50 connections, 1 pool)
- Determine if this is a pool_size or pool_count issue
- Check if OpenRouter has its own rate limits

**Proposed fix**:
- Increase Finch pool size for the LLM endpoint
- Or: add a concurrency semaphore in `Rho.Reasoner.Direct` to limit concurrent LLM calls per session
- The semaphore approach is safer — it prevents overwhelming both local resources and upstream rate limits

### 4. Evaluator Quality Assessment
**Observed**: Evaluators produced results but we didn't deeply inspect quality. Round 2 should compare:
- Does multi-agent evaluation produce better/more nuanced results than single-agent?
- Are the evaluator outputs differentiated (technical vs culture vs comp) or are they overlapping?
- Is the coordinator's synthesis good, or does it just concatenate?

**Method**:
- Run single-agent (test1-style) and multi-agent (test5-style) side by side
- Save both final outputs to files
- Compare coverage: does multi-agent catch things single-agent missed?
- Check for contradictions between evaluators that the coordinator failed to resolve

### 5. Structured Reasoner Reliability
**Observed**: Structured reasoner frequently ignored JSON format. But it has a key advantage: streaming tool arguments are visible in the UI.
**Investigation**:
- Is the JSON format instruction being placed prominently enough in the prompt?
- Does the prompt_format `:xml` interact badly with the JSON output requirement?
- Would few-shot examples of delegation tool calls improve compliance?

**Proposed approach**:
- Add a `delegate_task` example to the structured reasoner's examples list
- Test if XML prompt format hurts JSON output compliance
- Consider a hybrid: structured reasoner for streaming + fallback to direct if JSON parse fails

### 6. Cost Optimization
**Observed**: Multi-agent (39K tokens) costs ~4.7x single-agent (8.4K tokens). Is this justified?
**Investigation**:
- Break down tokens per agent to find the biggest consumers
- Check if evaluator system prompts are being sent redundantly (each sub-agent gets its own copy)
- Check if `inherit_context: false` is correctly preventing parent tape from being copied

**Proposed approach**:
- Measure evaluator input tokens — if system prompt dominates, consider shortening
- Try haiku for evaluators (already configured) vs sonnet — check if quality drops
- Test with `max_steps: 3` for evaluators (currently 5) to see if they finish in 1-2 steps anyway

### 7. Signal Flow Completeness
**Observed**: Signal flow tracked delegations and results but missed inter-agent messages. The `task.requested` and `task.completed` signals were the only ones captured.
**Investigation**:
- Check if `delegate_task` and `await_task` publish the right signal types
- Does `send_message` publish signals that Observatory can track?
- Are there missing event types the Observatory should subscribe to?

**Proposed fix**:
- Ensure all multi-agent tools publish signals with consistent source/target fields
- Add `message.sent` and `message.received` flow tracking
- Include timing data in flows to visualize the delegation timeline

## Execution Order

1. **Observatory resilience** (defensive coding) — quick win, prevents data loss
2. **Tape serialization** — needed for debugging everything else
3. **Finch pool / concurrency** — prevents connection failures under load
4. **Run evaluation quality comparison** — needs 1-3 fixed first
5. **Cost optimization** — informed by quality comparison
6. **Structured reasoner** — nice-to-have, lower priority
7. **Signal flow completeness** — polish

## Test Protocol

For each change:
1. Run the same hiring evaluation task
2. Compare metrics against test5 baseline (4 agents, 39K tokens, 0 errors)
3. Track: token count, error count, agent count, wall-clock time, output quality

Use session IDs `round2_test1`, `round2_test2`, etc. for easy comparison.
