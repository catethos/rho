# Tape System — Layered Implementation Plan

## Core Model

Four primitives, three invariants, one write strategy.

### Primitives

| Primitive | Role |
|-----------|------|
| **Tape** | Chronological sequence of facts. Append-only. |
| **Entry** | An immutable fact record. Monotonic ID, never modified in place. |
| **Anchor** | Logical checkpoint for state reconstruction. Carries structured state payload. |
| **View** | Task-oriented assembled context window. Derived, never stored. |

Additionally, **Index** is a derived structure (e.g., anchor graph, search index) that accelerates queries but is never a source of truth.

## Conversation and Trace Projections

The tape is the source of truth for both user conversation history and agent
debugging. Conversations and threads are metadata that point to tapes. Chat UI,
LLM context, trace timelines, failure reports, and debug bundles are all
projections over the same append-only entries.

`Rho.Tape.View` remains the LLM context primitive.
`Rho.Trace.Projection.context/1` delegates to the canonical tape projection
path used by the runner. UI snapshots are cache only; a chat must be
rebuildable from tape projections.

### Invariants

1. **History is append-only, never overwritten** — corrections are new entries that reference old ones, not mutations.
2. **Derivatives never replace original facts** — views, indexes, summaries are assembled on demand from the tape.
3. **Context is constructed, not inherited wholesale** — views select and assemble entries by policy, not by copying the full tape.

### Write Strategy: Hooks for Facts, Tools for Anchors

How entries get written to the tape is a critical architectural decision. There are three options:

| Option | Mechanism | Problem |
|--------|-----------|---------|
| **Pure tool** | LLM calls `write_to_tape` | Non-deterministic — LLM may forget, skip entries, or write inconsistently. Tape loses its completeness guarantee. |
| **Pure hook** | Agent loop writes everything automatically | Anchors require semantic judgment (summary, phase, next_steps) that mechanical rules can't produce. |
| **Hybrid** | Hooks for facts, tool for anchors | Facts are complete by construction. Anchors are meaningful by design. |

**The tape uses the hybrid approach.**

**Deterministic via hooks (no LLM choice):**
- `:message` entries — written automatically when user sends a message or LLM responds
- `:tool_call` entries — written automatically when the loop dispatches a tool
- `:tool_result` entries — written automatically when a tool returns
- `:event` entries — written automatically for usage stats, errors, step boundaries

The existing `on_event` callback in `AgentLoop` is the insertion point. A tape-writing layer intercepts events *before* the user's display callback fires. The LLM never sees this, never decides whether to call it. Every event hits tape.

**LLM-directed via tool (requires judgment):**
- `:anchor` entries — the LLM decides when a phase transition happens. Anchors carry structured state (`summary`, `next_steps`, `source_ids`) that requires semantic understanding.
- Handoffs — same reasoning. The agent knows when discovery is done and implementation should begin.

**Why not pure hooks for anchors?** A mechanical rule ("anchor every 20 entries") produces meaningless summaries. The anchor's value comes from the LLM's judgment about *what just happened* and *what should happen next*.

**Why not tools for facts?** Asking the LLM to record its own conversation is like asking someone to manually log every word while speaking. It'll forget, it wastes tokens, and the tape becomes unreliable.

---

## How Tape Changes Agent Memory

### The Problem with the Current Approach

Today, `AgentLoop` accumulates every message into a growing list (`updated_context = context ++ [assistant_msg | tool_results]`) and passes the full history on every LLM call:

```
Turn 1:  [system, user1]
Turn 2:  [system, user1, assistant1, user2]
Turn 3:  [system, user1, assistant1, user2, assistant2, tool_call, tool_result, user3]
...
Turn 50: [system, ...everything...]  ← context window blows up
```

This works until it doesn't — windows fill up, costs balloon, and irrelevant early messages dilute attention.

### The Tape Solution: View Replaces Accumulator

The tape stores everything. But what goes to the LLM is a **View** — assembled on demand, scoped by the latest anchor:

```
Tape (complete, on disk):
  [e1, e2, e3, e4, ◇anchor, e5, e6, e7, e8]

What the LLM sees (View):
  [system_prompt, anchor.summary, e5, e6, e7, e8]
```

The anchor's `summary` field compresses everything before it into a paragraph. The LLM gets full detail for recent context and a compressed summary for older context.

### What Changes Concretely

**1. The message list becomes a View, not an accumulator.**
Instead of passing `messages` that grow forever, each turn assembles a View:

```elixir
view = Rho.Tape.View.default(tape_name)
messages = View.to_messages(view)  # anchor summary + recent entries
response = ReqLLM.generate_text(model, messages, opts)
```

The agent loop no longer owns message history. The tape does.

**2. Compaction replaces truncation.**
When context gets large, instead of crude truncation or hoping the provider's window is big enough, the agent writes an anchor summarizing what happened, and the View shifts forward. Old entries stay on tape for recall but leave the active context.

**3. The agent can recall across anchors.**
If a topic from turn 5 becomes relevant again at turn 45, the View can reach back across anchors (topic threading). With the current accumulator, you either have everything (expensive) or you've lost it (truncated). With tape, you selectively pull in old entries by relevance.

**4. Sessions become resumable for free.**
With tape persisted to JSONL, you reconstruct the View on restart — the agent picks up where it left off.

| | Current | With Tape |
|---|---|---|
| Storage | In-memory list, lost on exit | Append-only JSONL, permanent |
| What LLM sees | Everything, always growing | View: anchor summary + recent entries |
| Context overflow | Crash or truncate | Compact: summarize + new anchor |
| Old context | Gone or bloating the window | On tape, recallable by topic |
| Resumability | None | Reconstruct View from tape |

---

## Layer 1: Tape + Entry + Anchor

The append-only event log with monotonic IDs.

### Entry

```
Entry {
  id: integer          # monotonic, contiguous within a tape
  kind: atom           # :message | :tool_call | :tool_result | :anchor | :event
  payload: map         # string keys, entry-specific data
  meta: map            # optional metadata (string keys)
  date: string         # ISO 8601 timestamp
}
```

- `id` is assigned by the Store on append, not by the caller.
- `payload` and `meta` always use string keys (normalized on write) for serialization consistency — JSON round-trips produce string keys, so normalizing on write prevents atom/string mismatches between in-memory and deserialized forms.
- Entries are immutable once appended. To correct entry 101, you append entry 103 with a reference to 101 — entry 101 stays.

### Tape (Store)

The storage backend. Single writer (GenServer serializes appends), concurrent readers (ETS with `read_concurrency: true`).

```
ETS layout:
  {{tape_name, seq_id}, entry}          # per-entry storage, O(1) append
  {{tape_name, :meta}, %{next_id: n}}   # metadata per tape
```

Operations:
- `append(tape_name, entry)` → assigns next ID, writes JSONL line (with base64 redaction), inserts ETS
- `read(tape_name)` → direct ETS select, sorted by seq_id. No GenServer call.
- `clear(tape_name)` → deletes ETS entries + JSONL file
- On init: loads existing `.jsonl` files from disk into ETS

Persistence: one JSONL file per tape under `~/.rho/tapes/`. Base64 data URIs are redacted to `[media]` before writing to prevent file bloat.

### Anchor

An anchor is an Entry with `kind: :anchor`. What makes it special is the **state contract** in its payload:

```
Anchor payload {
  "name": string           # phase name, e.g. "discovery", "implement", "verify"
  "state": {
    "phase": string        # current phase identifier
    "summary": string      # human-readable summary of what happened before this point
    "next_steps": [string] # suggested next actions
    "source_ids": [int]    # entry IDs that informed this anchor (provenance)
    "owner": string        # "human" | "agent"
  }
}
```

Key semantics:
- Anchors are **reconstruction markers, not deletion points**. Full history before the anchor is preserved in the tape.
- The default read set starts from the latest anchor forward — entries before the anchor are preserved but not in the default view.
- `ensure_bootstrap_anchor(tape_name)` creates an initial `session/start` anchor if none exists.

### Service (stateless high-level API)

Convenience module that calls Store for persistence:

- `session_tape(session_id, workspace)` → derives deterministic tape name from MD5 hashes
- `ensure_bootstrap_anchor(tape_name)` → creates initial anchor if missing
- `append(tape_name, kind, payload, meta)` → wraps Entry.new + Store.append
- `append_from_event(tape_name, event)` → translates AgentLoop events into tape entries (used by the hook layer)
- `append_event(tape_name, name, payload)` → convenience for `:event` entries
- `info(tape_name)` → entry/anchor counts, last anchor name, entries since last anchor
- `search(tape_name, query, limit)` → substring search on `:message` entries
- `reset(tape_name, archive)` → clear with optional JSONL backup, re-bootstrap

### Files

- `lib/rho/tape/entry.ex`
- `lib/rho/tape/store.ex`
- `lib/rho/tape/service.ex`
- Modify `lib/rho/application.ex` to add Store to supervision tree

---

## Layer 1.5: AgentLoop Integration

The bridge between the tape system and the existing agent loop. This is where the write strategy materializes.

### Hook Layer: Deterministic Fact Recording

The agent loop already emits events via `on_event`. The tape integration wraps this with a recording layer that fires *before* the display callback:

```elixir
# In AgentLoop, the event dispatch becomes:
defp emit_event(event, opts) do
  # 1. Deterministic: always write to tape if tape_name is set
  if tape_name = opts[:tape_name] do
    Rho.Tape.Service.append_from_event(tape_name, event)
  end

  # 2. User callback (display, override, etc.) — unchanged
  if on_event = opts[:on_event] do
    on_event.(event)
  end
end
```

Event-to-entry mapping:

| AgentLoop Event | Tape Entry Kind | Payload |
|-----------------|-----------------|---------|
| `%{type: :llm_text, text: t}` | `:message` | `%{"role" => "assistant", "content" => t}` |
| `%{type: :tool_start, name: n, args: a}` | `:tool_call` | `%{"name" => n, "args" => a}` |
| `%{type: :tool_result, name: n, ...}` | `:tool_result` | `%{"name" => n, "status" => s, "output" => o}` |
| `%{type: :llm_usage, ...}` | `:event` | `%{"name" => "llm_usage", "usage" => u}` |
| `%{type: :error, reason: r}` | `:event` | `%{"name" => "error", "reason" => r}` |

User messages are recorded when they enter the loop (before the first LLM call), not via events.

### View-Based Context Assembly

The agent loop's context accumulation (`context ++ [assistant_msg | tool_results]`) is replaced by View assembly:

```elixir
# Before (current):
do_loop(model, updated_context, ...)

# After (with tape):
# 1. Append new entries to tape (via hooks above)
# 2. Assemble fresh View from tape
view = Rho.Tape.View.default(tape_name)
context = Rho.Tape.View.to_messages(view)
do_loop(model, context, ...)
```

The loop no longer carries message state. The tape is the single source of truth; the View reconstructs context each turn.

### Anchor Tool

A new tool registered in the tool registry, available to agents that need phase management:

```elixir
# lib/rho/tools/anchor.ex
%{
  tool: ReqLLM.tool(
    name: "create_anchor",
    description: "Mark a phase transition. Use when shifting from one task phase to another.",
    parameter_schema: [
      name: [type: :string, required: true, doc: "Phase name"],
      summary: [type: :string, required: true, doc: "Summary of what happened"],
      next_steps: [type: {:array, :string}, doc: "Suggested next actions"]
    ]
  ),
  execute: fn args -> ... end
}
```

The tool needs access to `tape_name`, which is injected via closure at tool resolution time (when `Rho.Config.resolve_tools/1` runs).

### Bootstrap Flow

In `rho.chat` and `rho.run`:

```elixir
tape_name = Rho.Tape.Service.session_tape(session_id, workspace)
Rho.Tape.Service.ensure_bootstrap_anchor(tape_name)

Rho.AgentLoop.run(model, messages, [
  tape_name: tape_name,
  tools: resolved_tools,
  on_event: &default_on_event/1,
  ...
])
```

### Files

- Modify `lib/rho/agent_loop.ex` — add `emit_event/2`, `tape_name` option, View-based context
- `lib/rho/tools/anchor.ex` — anchor creation tool
- Modify `lib/rho/config.ex` — add `:anchor` to tool registry
- Modify `lib/mix/tasks/rho.chat.ex` — tape bootstrap + pass `tape_name`
- Modify `lib/mix/tasks/rho.run.ex` — tape bootstrap + pass `tape_name`

---

## Layer 2: View

Task-oriented assembled context windows. A View is **derived, never stored** — it's computed on demand from the tape.

### Concept

The tape holds all facts. But execution (LLM calls, tool runs) needs a **subset** — the relevant context window. A View assembles that subset by:

1. Finding the relevant anchor(s)
2. Selecting entries after the anchor (the "default read set")
3. Optionally including entries from before the anchor by policy (e.g., search, topic threading)

```
View {
  tape_name: string
  anchor_id: integer | nil     # starting point (nil = from beginning)
  entries: [Entry]             # the assembled context
  policy: atom                 # how entries were selected
}
```

### `to_messages/1` — View to LLM Context

The View must convert its entries back to the message format that ReqLLM expects. This is the critical bridge between tape and agent loop:

```elixir
def to_messages(%View{entries: entries, anchor_id: anchor_id} = view) do
  messages = []

  # If there's an anchor, prepend its summary as a system-level context message
  if anchor = find_anchor(view) do
    messages = [ReqLLM.Context.system("Context: #{anchor.payload["state"]["summary"]}")]
  end

  # Convert each entry to its corresponding ReqLLM message type
  messages ++ Enum.flat_map(entries, &entry_to_message/1)
end
```

Entry-to-message mapping:

| Entry Kind | ReqLLM Message |
|------------|----------------|
| `:message` (role: user) | `ReqLLM.Context.user(content)` |
| `:message` (role: assistant) | `ReqLLM.Context.assistant(content)` |
| `:tool_call` | Part of `ReqLLM.Context.assistant("", tool_calls: [...])` |
| `:tool_result` | `ReqLLM.Context.tool_result(id, output)` |
| `:anchor` | Skipped (summary already prepended) |
| `:event` | Skipped (not conversational) |

### View assembly strategies

**A. Default view** — entries from latest anchor forward:
```
[e1, e2, A1, e4, A2, e6, e7]
                    ^^^^^^^^^ default read set
         ^^^^^^^^^ preserved, not in default view
```

**B. Multi-turn view** — assembled from latest anchor, filtering to conversation-relevant kinds (`:message`, `:tool_call`, `:tool_result`). Strips `:event` entries that aren't useful to the LLM:
```
[T1, T2, T3(anchor), T4, T5, T6]
                      ^^^^^^^^^ assembled on demand
```
Turns before the anchor are not in the default view. Each turn may contain multiple entries (message + tool_call + tool_result).

**C. Topic threading** — when a topic recurs (T1 returns as T1*), the view can reach back across anchors to pull in the original topic's entries:
```
[T1, T2, T3, T1*]
 ↑              ↑
 └──── anchor recall ────┘
```
The view assembles entries from both T1 and T1* into a coherent topic view. Human and agent collaborate via organized anchors.

**D. Cross-session** — sessions are isolated by default (each has its own tape). Cross-session queries are opt-in, explicitly chosen:
```
Session A → tape A timeline  ─ ─ ─ ┐
                                     │ explicit cross-query
Session B → tape B timeline  ─ ─ ─ ┘  (actively chosen)
```

### Files

- `lib/rho/tape/view.ex`

---

## Layer 3: Handoff

A constrained phase transition. Handoff writes a new anchor and shifts the execution origin.

### Concept

A handoff is a three-step operation:
1. Write a new anchor entry with structured state
2. Attach minimum inherited state (summary, source_ids, next_steps)
3. Shift execution origin past the new anchor — the default view now starts here

```
Discovery ──handoff──→ Implement ──handoff──→ Verify
    ◇                      ◇                     ◇
    anchor                 anchor                 anchor
```

### State contract

The anchor's state payload carries forward the minimum context needed for the next phase:

```
{
  "phase": "implement",
  "summary": "Discovery complete.",
  "next_steps": ["Run migration", "Integration tests"],
  "source_ids": [128, 130, 131],
  "owner": "agent"
}
```

- `source_ids` provide **provenance** — you can jump back to the original entries that led to this anchor.
- `summary` is a hint, not a replacement. The raw entries remain on tape and can be recalled.
- The view after handoff only includes entries from this anchor forward, but a topic-threading view can reach back.

### Relationship to Compaction

Handoff and compaction are the same mechanism with different triggers:
- **Handoff**: LLM-initiated via `create_anchor` tool. The agent decides a phase is complete.
- **Compaction**: System-initiated when context approaches window limits. Automatically triggers anchor creation (which requires an LLM call to produce the summary).

Both produce an anchor. Both shift the View forward. The difference is who decides when.

### Files

- `lib/rho/tape/service.ex` — enrich `handoff/3` with full state contract

---

## Layer 4: Context Strategies

Three mechanism combos for managing context window size.

### Compact

**Problem**: Context exceeds the window limit.

**Solution**: Shrink the default read set by creating a new anchor. Entries before the anchor are preserved but excluded from the default view.

```
[e1, e2, e3, e4, ◇, e5, e6, e7, e8, ...]
 ↑ preserved, not in view ↑  ↑ default read set ↑
```

Key: **compact ≠ delete history**. It shrinks the default read set by inserting an anchor. The old entries remain on tape and can be recalled.

Implementation: the agent loop monitors context size. When it approaches the window limit, it injects a compaction step — asking the LLM to produce a summary of the current context, then writing that as an anchor. This is a system-initiated handoff.

```
[growing context...] → context_size > threshold
  → LLM call: "Summarize the current conversation state"
  → Write anchor with summary
  → Next View starts from new anchor
```

### Summary

**Problem**: Need a high-level overview for the next phase.

**Solution**: The anchor's state carries a summary derived from specific entries, with `source_ids` pointing back to the raw facts.

```
[e128, e130, e132] → anchor.state = {
                       summary: "Discovery is complete.",
                       source_ids: [128, 130, 131]
                     }
```

Key: **summaries cite sources; hints only**. The summary is a derived artifact — the original entries remain accessible for full recall.

### Fork / Merge

**Problem**: Need parallel exploration with controlled convergence.

**Solution**: Fork creates an isolated tape that starts at a specific entry ID. Writes go to the fork. Merge appends the fork's new entries (delta only) back to the main tape.

```
Main Tape              Fork Tape
  [120] ──fork(at id=120)──→
                            [121] append
                            [122] append
                            [123] append
       ←──merge(new_only)───
  [121, 122, 123]
```

Key: **merge appends deltas only; no mainline rewrites**. The main tape never has entries modified — only new entries from the fork are appended.

Implementation:
- Fork is a new tape with a `fork_origin` anchor referencing the source tape and entry ID
- Merge reads the fork's entries after the origin and appends them to the main tape
- Process isolation in OTP: each fork runs in its own process with its own tape name

### Files

- `lib/rho/tape/compact.ex` — compaction logic (summarize + handoff)
- `lib/rho/tape/fork.ex` — fork/merge operations

---

## Layer 5: Memory + Anchor Graphs

Complex memory assembled from anchor graphs.

### Concept

Anchors can form **non-linear graphs**, not just a single timeline. Memory views assemble context from multiple anchor nodes, guided by policy.

```
Tape          Anchor Graph       Memory View
 e101 ──────→ A1
                ├── A2            View (assembled)
 e102           └── A3 ─────────→   ↑
                                  assemble
 e103 ──────→ A4
```

- **Anchor Graph**: anchors reference other anchors via `source_ids`, forming a DAG
- **Memory View**: assembled by traversing the anchor graph and collecting relevant entries
- **Policy-guided**: different use cases (observability, eval, training) assemble different views from the same graph

### Why complex

1. Anchors can form non-linear graphs, not a single timeline
2. Memory views assemble from multiple nodes, guided by policy
3. Graph structure requires explicit lineage and provenance

### Implementation

- Anchors already have `source_ids` from Layer 3 — these form graph edges
- Need an anchor graph index (derived, not stored as truth) for efficient traversal
- View assembly becomes graph traversal: BFS/DFS from a starting anchor, collecting entries

### Files

- `lib/rho/tape/anchor_graph.ex` — graph traversal and indexing
- Extend `lib/rho/tape/view.ex` with graph-aware assembly

---

## Layer 6: Teams + Cross-Tape Views

Multi-agent coordination.

### Shared Tape

Multiple agents append to the same tape. Entries keep their origin (which agent wrote them). The tape remains append-only; ownership is traceable.

```
Agent A ──→ Shared Tape
Agent B ──→   [A:201, B:202, C:203, A:204]
Agent C ──→       append-only timeline
```

Implementation: entries gain an `origin` field in `meta` (agent ID). The Store already supports concurrent appends via GenServer serialization.

### Cross-Tape View

Teams read each other's tapes via views to coordinate. Tapes remain isolated — views assemble cross-tape context.

```
Team A → Tape A [A1, A2, A3]
                    ↕ views assemble cross-tape context
Team B → Tape B [B1, B2, B3]
```

- Views are assembled, tapes remain isolated
- A cross-tape view reads from multiple tapes and merges entries by timestamp or anchor references
- This is opt-in, explicitly requested

### Files

- `lib/rho/tape/cross_view.ex` — cross-tape view assembly
- Extend entry `meta` with `origin` field

---

## Layer 7: Appendix Use Cases

Applications built on top of the tape primitives.

### A. Observability

Tape retains sessions, tool calls, and events for a replayable web timeline.

```
Session → Tape (append-only trace) → Web UI
            anchor
            msg        → filters → Timeline (turn/tool/event)
            tool                   Replay (inspect exact path)
            event                  Usage (token + anchor stats)
```

The UI is a derived view; raw facts remain in the append-only tape. Filters select by session, tool, or event type.

### B. Eval

Slice by anchor, replay history, inspect decisions, then write scores and labels back as derived facts.

```
[anchor A12, tool/event/msg entries, anchor A13]
   ↓ bounded by anchors
Tape Slice → Human Review → Derived Facts (appended)
              ├── history replay    → Replay (history stays visible)
              ├── decision check    → Check (decisions stay inspectable)
              └── notes             → Recall (labels stay linked)
```

Key: **show the path and decisions to people first, then append derived annotations**. Scores, labels, and rationales are new entries appended to the tape — they don't modify the original entries.

### C. Training / RL

Tape works with RL frameworks: slice by anchor, attach rewards, and export trajectories.

```
Agent Runtime → Tape → RL Trainer
                session/start
                tool + event trace    → export → Proxy Input (OpenAI-compatible)
                assistant turns                  Async Update (train after enough episodes)
                                                 Next Session (serve newer weights)
              ←── episode refresh / weight refresh ──→
```

The training layer should **consume tape exports, not replace tape** as the raw record.

---

## Implementation Order

| Layer | Scope | Dependencies |
|-------|-------|-------------|
| 1 | Entry, Store, Service, Anchor | None (Jason for JSON) |
| 1.5 | AgentLoop integration (hooks, View-based context, anchor tool) | Layer 1 + Layer 2 |
| 2 | View (assembly, `to_messages/1`) | Layer 1 |
| 3 | Handoff (enriched state contracts) | Layer 1 |
| 4 | Compact, Summary, Fork/Merge | Layers 1-3 |
| 5 | Anchor Graphs, Memory Views | Layers 1-3 |
| 6 | Teams, Cross-Tape Views | Layers 1-2 |
| 7 | Observability, Eval, Training exports | All layers |

**Practical build sequence:**

1. **Layer 1** (Entry, Store, Service) — pure infrastructure, no agent changes. Tests can exercise append/read/clear in isolation.
2. **Layer 2** (View + `to_messages/1`) — builds on Layer 1. Can be tested with manually constructed tapes.
3. **Layer 1.5** (AgentLoop integration) — wires hooks into the loop, replaces message accumulation with View-based context, registers anchor tool. This is the moment the agent starts using tape for memory.
4. **Layer 3** (Handoff) — enriches the anchor tool with full state contracts.
5. **Layers 4, 5, 6** — independent of each other, built as needed.
