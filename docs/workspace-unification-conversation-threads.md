# Workspace Unification — Conversation Threads & Branching

## The Idea

Let users save, name, and switch between different conversation threads within a session. "I want to try a different approach — let me branch from where we were 10 messages ago and explore that direction without losing this one."

---

## What Already Exists

The infrastructure is mostly there but not connected to the UI:

| Component | Status | What it does |
|-----------|--------|--------------|
| `Rho.Tape.Fork.fork/2` | ✅ Exists | Creates a new tape starting at a specific entry ID from a source tape |
| `Rho.Tape.Fork.merge/2` | ✅ Exists | Appends a fork's delta entries back to the main tape |
| `Rho.Tape.Fork.fork_info/1` | ✅ Exists | Returns fork metadata (source tape, fork point, entry count) |
| `Rho.Tape.Context.fork/2` | ✅ In behaviour | Optional callback, implemented in `Tape.Context.Tape` |
| `Rho.Tape.Service.handoff/4` | ✅ Exists | Creates anchor with summary — natural branch point |
| `Rho.Tape.Compact.run/2` | ✅ Exists | Summarizes history into anchor |
| UI for listing/selecting threads | ❌ Missing | No way to see or switch between tapes |
| Thread metadata storage | ❌ Missing | No names, descriptions, or relationships stored |
| Agent tape_ref hot-swapping | ❌ Missing | Worker uses a fixed `tape_ref` for its lifetime |

---

## Data Model

### Thread = named tape + metadata

A thread is a named reference to a tape, with metadata about its origin and purpose:

```elixir
%Thread{
  id: "thread_abc123",
  name: "Approach A — category-first",      # user-provided
  tape_name: "session_a1b2c3d4_e5f6g7h8",  # actual tape ref
  session_id: "session-123",
  created_at: ~U[2026-04-06 12:00:00Z],
  forked_from: nil | "thread_xyz",           # parent thread id
  fork_point: nil | 42,                      # entry ID in parent tape
  summary: "Exploring category-first skill organization...",
  status: :active | :archived
}
```

### Thread Registry

A simple JSON file per session, stored alongside the EventLog:

```
_rho/sessions/{session_id}/
  events.jsonl          # existing EventLog
  ui_snapshot.json      # from tape-resume plan
  threads.json          # NEW: thread metadata
```

```json
{
  "active_thread_id": "thread_abc123",
  "threads": [
    {
      "id": "thread_main",
      "name": "Main",
      "tape_name": "session_a1b2c3d4_e5f6g7h8",
      "created_at": "2026-04-06T12:00:00Z",
      "forked_from": null,
      "summary": "Initial skill framework exploration",
      "status": "active"
    },
    {
      "id": "thread_abc123",
      "name": "Category-first approach",
      "tape_name": "session_a1b2c3d4_e5f6g7h8_fork_1",
      "created_at": "2026-04-06T14:30:00Z",
      "forked_from": "thread_main",
      "fork_point": 42,
      "summary": "Trying category-first instead of skill-first organization",
      "status": "active"
    }
  ]
}
```

### Implementation

```elixir
defmodule Rho.Session.Threads do
  @filename "threads.json"

  def list(session_id, workspace) do
    case load(session_id, workspace) do
      {:ok, data} -> data["threads"] || []
      :none -> []
    end
  end

  def active(session_id, workspace) do
    case load(session_id, workspace) do
      {:ok, data} ->
        active_id = data["active_thread_id"]
        Enum.find(data["threads"] || [], &(&1["id"] == active_id))
      :none -> nil
    end
  end

  def create(session_id, workspace, attrs) do
    # attrs: %{name, tape_name, forked_from, fork_point}
    thread = %{
      "id" => "thread_#{:erlang.unique_integer([:positive])}",
      "name" => attrs.name,
      "tape_name" => attrs.tape_name,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "forked_from" => attrs[:forked_from],
      "fork_point" => attrs[:fork_point],
      "summary" => attrs[:summary] || "",
      "status" => "active"
    }

    update(session_id, workspace, fn data ->
      threads = (data["threads"] || []) ++ [thread]
      %{data | "threads" => threads}
    end)

    {:ok, thread}
  end

  def switch(session_id, workspace, thread_id) do
    update(session_id, workspace, fn data ->
      Map.put(data, "active_thread_id", thread_id)
    end)
  end

  # ... load/save helpers
end
```

---

## User Flows

### Flow 1: Start a session (implicit main thread)

```
User opens /editor/session-123 (new session)
  → Thread "Main" created automatically
  → tape_name = session_tape(session_id, workspace)
  → No thread UI visible (single thread = no picker needed)
```

The first thread is created implicitly. No UX overhead for users who never branch.

### Flow 2: Fork from current point

```
User clicks [⑂ Fork] in the chat panel or toolbar
  → Dialog: "Name this branch" + optional "Fork from: [latest | pick a message]"
  → User names it "Try category-first approach"
  → System:
    1. Compact current thread (summarize history into anchor)
    2. Fork.fork(current_tape, at: selected_entry_id)
    3. Create thread metadata pointing to the new tape
    4. Switch active thread to the fork
    5. Hot-swap agent's tape_ref to the fork tape
  → UI:
    - Thread picker appears (now >1 thread)
    - Chat shows: "Forked from Main. Context: [summary of prior conversation]"
    - Agent has full context via the fork anchor summary
```

### Flow 3: Switch between threads

```
User clicks thread picker dropdown:
  ┌─────────────────────────────┐
  │ ● Category-first approach   │  ← active (dot indicator)
  │   Main                      │
  │   ──────────────────────    │
  │   + New thread              │
  │   ⑂ Fork from here          │
  └─────────────────────────────┘

User selects "Main"
  → System:
    1. Save current UI snapshot for current thread
    2. Switch active_thread_id
    3. Hot-swap agent's tape_ref to Main's tape
    4. Load Main's UI snapshot (or replay if no snapshot)
  → UI:
    - Chat shows Main's conversation history
    - Workspace shows Main's projection state
    - Agent resumes Main's context (from Main's tape)
```

### Flow 4: Fork from a specific past message

```
User right-clicks a message in the chat
  → Context menu: "Fork from here"
  → System resolves the message to a tape entry ID
  → Same as Flow 2 but at: that entry_id
  → The new thread starts with all history up to that message
  → Everything after that point is in the original thread only
```

### Flow 5: Resume session with multiple threads

```
User returns to /editor/session-123 (browser was closed)
  → Load threads.json
  → Restore active thread
  → Load that thread's UI snapshot
  → Agent starts with that thread's tape
  → Thread picker shows all available threads
```

---

## Compaction Before Fork

When forking, the new tape starts with a `fork_origin` anchor. The anchor's summary is all the LLM context the agent has for history before the fork point. If no compaction has happened, this summary is just "Forked from X at entry Y" — the agent loses all prior conversation context.

**Fix: Compact before forking.**

```elixir
def fork_thread(session_id, workspace, opts) do
  current_tape = current_tape_name(session_id, workspace)
  fork_point = opts[:at] || Store.last_id(current_tape)

  # 1. Summarize conversation up to fork point
  #    This gives the fork anchor a real summary
  summary = summarize_up_to(current_tape, fork_point, opts)

  # 2. Create fork with enriched anchor
  fork_name = opts[:name] || "#{current_tape}_fork_#{:erlang.unique_integer([:positive])}"
  Service.append(fork_name, :anchor, %{
    "name" => "fork_origin",
    "state" => %{
      "phase" => "fork",
      "summary" => summary,
      "next_steps" => [],
      "source_ids" => [],
      "owner" => "system"
    },
    "fork" => %{
      "source_tape" => current_tape,
      "at_id" => fork_point
    }
  })

  {:ok, fork_name}
end

defp summarize_up_to(tape_name, entry_id, opts) do
  # Build a view up to entry_id
  entries =
    Store.read(tape_name)
    |> Enum.filter(&(&1.id <= entry_id))
    |> Enum.filter(&(&1.kind in [:message, :tool_call, :tool_result]))

  if entries == [] do
    "Session started."
  else
    # Use LLM to summarize (same as Compact.run/2)
    model = opts[:model] || default_compact_model()
    messages = View.entries_to_messages_raw(entries)

    case summarize_with_llm(model, messages) do
      {:ok, summary} -> summary
      {:error, _} -> "Forked from #{tape_name} at entry #{entry_id}."
    end
  end
end
```

**The summary is the bridge.** Without it, the agent on the forked thread has amnesia. With it, the agent knows everything that happened before the fork and can continue coherently.

### When to skip compaction

- If the fork point is at entry 1–5 (barely any history) — just copy the entries
- If a recent anchor exists near the fork point — reuse its summary
- If the user explicitly says "start fresh" — use empty summary

```elixir
defp needs_summary?(tape_name, fork_point) do
  case Store.last_anchor(tape_name) do
    %{id: anchor_id} when anchor_id >= fork_point - 5 ->
      # Recent anchor exists near fork point, reuse its summary
      false

    _ ->
      fork_point > 5  # Only summarize if there's meaningful history
  end
end
```

---

## Agent Tape Hot-Swap

The critical infrastructure gap: the `Worker` uses a fixed `tape_ref` set during `init/1`. Switching threads requires changing which tape the agent reads from and writes to.

### Option A: Restart the agent (simple, safe)

```elixir
def switch_thread(socket, thread) do
  session_id = socket.assigns.session_id

  # Stop current agent
  Rho.Agent.Primary.stop(session_id)

  # Restart with new tape_ref
  Rho.Agent.Primary.ensure_started(session_id,
    tape_ref: thread["tape_name"]
  )

  # Re-subscribe, re-hydrate
  SessionCore.subscribe_and_hydrate(socket, session_id)
end
```

Pros: No changes to Worker internals. Clean state.
Cons: Loses in-flight work. Brief delay on switch.

### Option B: Hot-swap tape_ref via message (zero downtime)

```elixir
# In Worker
def handle_cast({:swap_tape, new_tape_ref}, state) do
  # Only swap when idle (not mid-turn)
  if state.status == :idle do
    Rho.Tape.View.invalidate_cache(state.tape_ref)
    {:noreply, %{state | tape_ref: new_tape_ref}}
  else
    # Queue swap for after current turn completes
    {:noreply, %{state | pending_tape_swap: new_tape_ref}}
  end
end
```

Pros: No agent restart. Instant switch.
Cons: More complex. Must handle in-flight turns carefully.

**Recommendation:** Start with Option A (restart). Move to Option B only if the restart delay is noticeable (> 1 second).

---

## Thread Picker UI

### When to show

- **0-1 threads:** No thread picker (no overhead for simple sessions)
- **2+ threads:** Thread picker appears in the tab bar or as a dropdown

### Placement

```
+--[⑂ Main ▾]--[Skills Editor]--[Chatroom]--[+]--------[Chat >]--+
|                                                                   |
|  Thread picker    Workspace tabs              Chat side panel     |
|  (leftmost)                                                       |
+-------------------------------------------------------------------+
```

Or as a subtle indicator inside the chat side panel header:

```
┌─ Chat ─────────────────────────┐
│ Thread: Category-first ▾       │  ← thread picker
│ ┌─────────────────────────┐    │
│ │ ● Category-first        │    │
│ │   Main                  │    │
│ │   ──────────────────    │    │
│ │   ⑂ Fork from here      │    │
│ │   + New blank thread    │    │
│ └─────────────────────────┘    │
│                                │
│ [agent tabs]                   │
│ [messages...]                  │
│ [input]                        │
└────────────────────────────────┘
```

### Thread summary preview

On hover or in an expanded view, show the anchor summary so the user remembers what each thread was about:

```
┌─────────────────────────────────────┐
│ ● Category-first approach           │
│   "Exploring organizing skills by   │
│    category first, then by level.   │
│    Built 3 categories so far."      │
│   Created: 2h ago · 24 messages     │
│                                     │
│   Main                              │
│   "Initial exploration of skill     │
│    framework. Decided on 5-level    │
│    system with cluster grouping."   │
│   Created: 4h ago · 87 messages     │
└─────────────────────────────────────┘
```

The summary comes from the tape's latest anchor. If no anchor exists, generate one on-demand (background compact).

---

## Thread-Aware Snapshots

The snapshot system from the tape-resume plan needs to be thread-aware:

```
_rho/sessions/{session_id}/
  threads.json
  events.jsonl
  snapshots/
    thread_main.json
    thread_abc123.json
```

Each thread gets its own snapshot. Switching threads loads the corresponding snapshot.

```elixir
def save_snapshot(session_id, workspace, thread_id, state) do
  dir = Path.join([workspace, "_rho", "sessions", session_id, "snapshots"])
  File.mkdir_p!(dir)
  path = Path.join(dir, "#{thread_id}.json")
  File.write!(path, Jason.encode!(state))
end

def load_snapshot(session_id, workspace, thread_id) do
  path = Path.join([workspace, "_rho", "sessions", session_id, "snapshots", "#{thread_id}.json"])
  case File.read(path) do
    {:ok, json} -> {:ok, Jason.decode!(json)}
    {:error, :enoent} -> :none
  end
end
```

---

## Thread-Aware Workspace State

When switching threads, workspace projection state must also switch. The spreadsheet on thread A might have different rows than thread B.

```elixir
def handle_event("switch_thread", %{"thread_id" => thread_id}, socket) do
  session_id = socket.assigns.session_id
  workspace = socket.assigns.workspace

  # 1. Save current thread's snapshot
  current_thread = socket.assigns.active_thread_id
  save_snapshot(session_id, workspace, current_thread, build_snapshot(socket))

  # 2. Switch active thread
  Threads.switch(session_id, workspace, thread_id)
  thread = Threads.get(session_id, workspace, thread_id)

  # 3. Restart agent with new tape
  switch_agent_tape(socket, thread)

  # 4. Load new thread's snapshot or replay
  socket =
    case load_snapshot(session_id, workspace, thread_id) do
      {:ok, snap} -> apply_snapshot(socket, snap)
      :none -> replay_workspace_state(socket, thread["tape_name"])
    end

  {:noreply, assign(socket, :active_thread_id, thread_id)}
end
```

---

## Compact Before Loading (Answering the Original Question)

When resuming a session with threads, the question is: should we compact before loading if there's no recent compaction?

**Answer: Yes, but only for the LLM context, and only in the background.**

| Concern | Strategy |
|---------|----------|
| **UI state** | Load from snapshot (instant). No compaction needed. |
| **LLM context** | Check `Compact.needed?/2`. If yes, run in background. |
| **Thread summaries** | Generate lazily on first display. Cache in thread metadata. |
| **Fork point** | Always compact/summarize before forking (fork anchor needs the summary). |

```elixir
def resume_thread(socket, session_id, thread) do
  tape_name = thread["tape_name"]

  # Background compact if needed — don't block UI
  if Rho.Tape.Compact.needed?(tape_name) do
    Task.start(fn ->
      Rho.Tape.Compact.run(tape_name, model: default_model())
      # Update thread summary from new anchor
      update_thread_summary(session_id, thread["id"], tape_name)
    end)
  end

  # Load UI state immediately from snapshot
  socket
end
```

The user sees their UI instantly. The agent's context gets compacted in the background. By the time the user sends their first message, compaction is likely done.

---

## Integration with Workspace Unification Plan

### New step: Thread infrastructure

Insert after Step 3 (unification), before Step 4 (chatroom):

| Step | What |
|------|------|
| 0 | Signal metadata enrichment |
| 0.5 | Snapshot save/load infrastructure |
| 1 | Extract SessionCore |
| 2 | Extract projections as pure reducers |
| 3 | Unify into single SessionLive |
| **3.5** | **Thread infrastructure: registry, picker UI, fork with compaction, agent tape swap** |
| 4 | Add ChatroomProjection + chatroom workspace |
| 5 | Formalize Workspace behaviour (if needed) |
| 5.5 | Purify SessionProjection |
| 6 | Event-sourced user edits |

### Changes to existing modules

| Module | Change |
|--------|--------|
| `Rho.Tape.Fork` | Enrich fork anchor with LLM-generated summary (not just "Forked from X") |
| `Rho.Tape.Service` | Add `list_forks/1`, `thread_summary/1` |
| `Rho.Agent.Worker` | Support `tape_ref` restart or hot-swap |
| `RhoWeb.SessionLive` | Thread picker in render, `switch_thread` event handler |
| `RhoWeb.Session.SessionCore` | Thread-aware subscribe/hydrate |
| `RhoWeb.Session.Snapshot` | Thread-aware snapshot paths |

---

## Visualization: Thread Tree

For sessions with many branches, a visual tree could help:

```
Main ─────────●─────────●─────────●──── (active)
              │                   │
              │                   └── Category-first ──●──●
              │
              └── Flat structure ──●──●──● (archived)
```

Each node is an anchor or fork point. This is a future enhancement — start with the flat dropdown list.

---

## Summary

| Question | Answer |
|----------|--------|
| Should we save different threads? | Yes — threads are named references to tapes with metadata |
| Can the user choose which to continue? | Yes — thread picker switches the agent's tape_ref and loads the corresponding UI snapshot |
| Should we compact before loading? | Yes for LLM context (background), no for UI (use snapshots) |
| Should we compact before forking? | Yes — the fork anchor summary is the agent's only context for pre-fork history |
| What already exists? | `Fork.fork/2`, `Fork.merge/2`, `Compact.run/2`, tape JSONL persistence |
| What's missing? | Thread metadata storage, thread picker UI, agent tape hot-swap, enriched fork anchors |
