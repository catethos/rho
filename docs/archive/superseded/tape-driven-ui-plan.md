# Tape-Driven UI Plan

## Core Insight

The Tape is the source of truth for everything that happened in a
session. The UI should project from the Tape, not from ephemeral bus
signals. This makes resume, compaction, multi-agent rendering, and
CLI/Web unification all fall out naturally.

## Scope

This plan targets **conversation chat rendering** only (CLI + LiveView).
Observatory, spreadsheet, debug/prompt flows, and other specialized UIs
continue to use bus signals until a later phase.

## Current Architecture (signal-driven)

```
Runner → emit(event) → signal bus → 15+ signal types → projection layer → UI assigns
                                   ↘ Recorder → Tape (side-effect)
```

Problems:
- The UI reconstructs state from transient signals (600+ lines of projection)
- Resume requires replaying an EventLog JSONL file through the projection
- Compaction invalidates the signal history; UI has no way to re-derive state
- CLI and Web have independent rendering, duplicating logic
- Streaming, tool calls, and text arrive as different signal types requiring
  different handling paths

## Proposed Architecture (tape-driven)

```
Runner → Tape.append(entry) → Tape (append-only, source of truth)
                             ↓
                      UIProjection.apply_entry(state, entry) → updated state
                             ↓
              ┌──────────────┼──────────────┐
              ↓              ↓              ↓
         CLI render    LiveView render   (future)

Streaming (transient):
Runner → StreamBuffer (ETS overlay, per {agent_id, turn_id})
                      ↓ throttled every 50–100ms
              UI renders partial content
                      ↓ on stream complete
              Final :message entry appended to Tape
```

The signal bus still exists but carries one notification for chat:
`rho.session.<sid>.tape.entry_appended` (already published by Recorder).
The UI subscribes to this, reads the entry from the Tape, and projects it.

Other bus signals (`rho.agent.*`, `rho.task.*`, debug events) remain
unchanged.

## Design

### 1. Tape entries are the canonical data model

The Tape already stores these entry kinds:

| Kind | Payload | Source |
|------|---------|--------|
| `:message` | `%{"role" => "user"\|"assistant", "content" => text}` | User input, LLM response |
| `:tool_call` | `%{"name" => name, "args" => args, "call_id" => id}` | LLM tool invocation |
| `:tool_result` | `%{"name" => name, "output" => text, "status" => status, "call_id" => id}` | Tool execution result |
| `:event` | `%{"name" => "llm_usage", ...}` | Usage stats, errors |
| `:anchor` | `%{"name" => "session/start"\|"compact/...", "state" => summary}` | Compaction checkpoints |

These are sufficient to reconstruct the full conversation. What's
missing is metadata that currently lives only on signals:

- `agent_id` — which agent produced this entry
- `turn_id` — which turn this entry belongs to
- `step` — which step within the turn
- `ts_us` — microsecond timestamp for cross-agent ordering

### 2. Enrich tape entries with agent/turn metadata

Add to the entry's `meta` field at write time. The existing `date` field
is preserved; `ts_us` is an additional numeric timestamp for merge ordering.

```elixir
%Rho.Tape.Entry{
  id: integer,
  kind: :message | :tool_call | :tool_result | :event | :anchor,
  payload: map,
  meta: %{
    "agent_id" => String.t(),
    "turn_id" => String.t(),
    "step" => integer,
    "ts_us" => integer  # System.system_time(:microsecond)
  },
  date: String.t()  # existing ISO 8601 field, unchanged
}
```

The Recorder already has access to `runtime.mount_context` which
contains `agent_id`, `session_id`. The `turn_id` and `step` are
**not currently available in `Recorder`** — they must be threaded
explicitly from `Runner`/worker into `Recorder.record_*` via an
opts/meta parameter.

The projection must tolerate missing metadata (entries recorded before
this enrichment won't have these fields) and use sensible fallbacks.

### 3. `Tape.UIProjection` — stateful reducer, not stateless mapper

A stateless `Entry → Message` mapper is insufficient. The projection
must:
- Pair `tool_result` entries with their prior `tool_call`
- Accumulate usage totals across `:event` entries
- Handle anchors as "conversation summarized" markers
- Support both full hydration and incremental live updates identically

```elixir
defmodule Rho.Tape.UIProjection do
  @moduledoc """
  Stateful reducer that projects tape entries into UI-renderable state.
  Shared by both CLI and LiveView.
  """

  defstruct [
    :messages,        # ordered list of renderable messages
    :usage,           # accumulated usage stats
    :tool_call_index, # %{call_id => message} for pairing results
    :agents           # set of agent_ids seen
  ]

  @type message :: %{
    id: integer,
    type: :text | :tool_call | :tool_result | :thinking | :error | :anchor | :usage,
    agent_id: String.t() | nil,
    turn_id: String.t() | nil,
    content: term,
    meta: map
  }

  @doc "Build full projection from a list of entries (hydration)."
  def init(entries) do
    Enum.reduce(entries, initial_state(), &apply_entry/2)
  end

  @doc "Apply a single new entry to existing projection state (live update)."
  def apply_entry(entry, state) do
    # Pattern-match on entry kind, update state accordingly
    # - :message → append to messages
    # - :tool_call → append + index by call_id
    # - :tool_result → pair with indexed tool_call, append
    # - :event (llm_usage) → accumulate into usage
    # - :anchor → append summary marker
    ...
  end

  defp initial_state do
    %__MODULE__{
      messages: [],
      usage: %{},
      tool_call_index: %{},
      agents: MapSet.new()
    }
  end
end
```

### 4. Full conversation = reduce the tape

```elixir
# Hydration (resume / mount): read tape, reduce all entries
state = tape_name
  |> Rho.Tape.Context.history()  # use memory abstraction, not Store.read/1 directly
  |> Rho.Tape.UIProjection.init()

# Live update: on entry_appended signal, apply single entry
def handle_info({:signal, %{type: "rho.session." <> _, data: data}}, socket) do
  entry = reconstruct_entry(data)
  state = Rho.Tape.UIProjection.apply_entry(entry, socket.assigns.projection)
  {:noreply, assign(socket, projection: state)}
end
```

Use `Rho.Tape.Context` (or a new `timeline/1` callback on the memory
behaviour) rather than `Store.read/1` directly. This avoids leaking
the ETS/JSONL implementation and stays compatible with future
pluggable backends.

### 5. Streaming via transient overlay (NOT mutable tape entries)

**The tape remains strictly append-only.** `Rho.Tape.Entry` is
documented as immutable; `Rho.Tape.Store` is append-only with JSONL
persistence; `Rho.Tape.View` caches by `last_id` and would break on
in-place updates. Adding a general `Store.update/3` would violate all
of these invariants.

Instead, streaming uses a **transient ETS overlay**:

```
StreamBuffer (ETS, keyed by {agent_id, turn_id})
  ├── chunk arrives → update buffer in-place (ETS)
  ├── every 50–100ms → push current buffer to connected UI clients
  └── stream complete → append final :message entry to Tape, clear buffer
```

```elixir
defmodule Rho.Tape.StreamBuffer do
  @moduledoc """
  Transient streaming overlay. Accumulates text chunks in ETS.
  Not persisted. Not part of the durable tape.
  """

  @table :rho_stream_buffer

  def start_stream(agent_id, turn_id) do
    :ets.insert(@table, {{agent_id, turn_id}, ""})
  end

  def append_chunk(agent_id, turn_id, chunk) do
    :ets.update_element(@table, {agent_id, turn_id}, {2, get(agent_id, turn_id) <> chunk})
  end

  def get(agent_id, turn_id) do
    case :ets.lookup(@table, {agent_id, turn_id}) do
      [{_, text}] -> text
      [] -> nil
    end
  end

  def finish_stream(agent_id, turn_id) do
    text = get(agent_id, turn_id)
    :ets.delete(@table, {agent_id, turn_id})
    text  # caller appends final :message entry to tape
  end
end
```

UI throttling: batch updates every **50–100ms** or **256–512 chars**,
whichever comes first. Do not write every token to the durable tape.

#### Advanced path (future, if needed)

If crash-resumable mid-token streams become necessary, use an
**append-only patch log** instead of in-place mutation:

```
append :message_start  (kind: :event, name: "message_start")
append :message_delta   (kind: :event, name: "message_delta", chunk: "...")
append :message_final   (kind: :message, role: "assistant", content: full_text)
```

The projection coalesces deltas. This preserves event-sourcing,
persistence, and replay while staying append-only. Only pursue this
if transient `StreamBuffer` proves insufficient.

### 6. Multi-agent = session timeline merge (in projection layer)

Merge projected entries from each agent memory ref in the **session
projection layer**, sorted by `{ts_us, agent_id, id}` for
deterministic ordering.

This is called a **session timeline merge** (not "tape merge") to
avoid confusion with the existing `Rho.Tape.Fork.merge/2`.

```elixir
def session_timeline(session_id) do
  session_id
  |> Registry.list_all()
  |> Enum.flat_map(fn agent ->
    agent.memory_ref
    |> Rho.Tape.Context.history()
    |> Enum.map(&add_agent_meta(&1, agent))
  end)
  |> Enum.sort_by(&{&1.meta["ts_us"] || 0, &1.meta["agent_id"] || "", &1.id})
  |> Rho.Tape.UIProjection.init()
end
```

If `{ts_us, agent_id, id}` ordering proves insufficient, add a
session-scoped `session_seq` counter later. Don't build that upfront.

### 7. Compaction is transparent

When the tape compacts, old entries are replaced by an `:anchor` with
a summary. The projection renders anchors as "conversation was
summarized here" markers. The UI doesn't need to know about
compaction — it just projects whatever the tape contains.

### 8. CLI and Web share the projection

```
UIProjection.apply_entry(state, entry) → updated state
    ↓                        ↓
Render.Terminal          Render.LiveView
(ANSI text)              (HEEx components)
```

Adding a new entry kind means:
1. Add a clause in `UIProjection.apply_entry/2`
2. Add a clause in `Render.Terminal` (CLI)
3. Add a clause in `Render.LiveView` (Web)

Not 15+ signal handlers in a 600-line projection module.

### 9. UI hydration windowing

Full-tape hydration can be expensive for long sessions. Support an
initial **tail window** from day 1:

- Hydrate the **last 200–500 timeline items** on mount
- Add lazy "load older" pagination later if needed
- The current web UI already caps displayed messages to ~200 per agent

## What the signal bus still does

The bus remains for:

1. **Tape change notifications** — `rho.session.<sid>.tape.entry_appended`
   (already exists). This is the sole UI chat trigger.
2. **Agent lifecycle** — `rho.agent.started`, `rho.agent.stopped`. These
   are not tape entries; they're coordination events.
3. **Task lifecycle** — `rho.task.requested`, `.accepted`, `.completed`.
   These are coordination events, not conversation content. The
   observatory consumes them for the interaction graph.
4. **Inter-agent signals** — `rho.message.sent`, etc. Delivered via
   mailbox. The resulting conversation is recorded on the receiving
   agent's tape.
5. **Observatory / debug / spreadsheet** — all existing specialized
   UI flows remain bus-driven until a later phase.
6. **Streaming transport** — `text_delta` signals remain for low-latency
   CLI rendering during the migration. Removed once `StreamBuffer` is
   proven.

The key shift: **conversation content flows through the tape;
coordination and debug events flow through the bus.**

## What to record as tape entries (coordination events)

Record **coarse task lifecycle milestones** as `:event` entries on the
tape so they appear in the unified timeline and survive resume:

- `task.requested`
- `task.accepted`
- `task.completed` / `task.failed`

Do **not** mirror every low-level coordination signal into the tape.

## Migration path

### Phase 1: Metadata enrichment

- Add `agent_id`, `turn_id`, `step`, `ts_us` to `Entry.meta`
- Update `Recorder.record_*` to accept explicit meta/opts (thread
  `turn_id` and `step` from `Runner`)
- Populate `ts_us` via `System.system_time(:microsecond)`
- `entry_appended` signal payload includes the full entry
- No UI changes; existing signals still work

### Phase 2: `UIProjection` reducer + `StreamBuffer`

- Implement `UIProjection` as a stateful reducer with `init/1` and
  `apply_entry/2` for all entry kinds
- Implement `StreamBuffer` transient overlay
- Write tests against real tape data
- No UI changes yet — validation only

### Phase 3: Tape-driven LiveView (alongside existing)

- New `SessionLive` that hydrates from tape on mount (tail window)
- Subscribes to `tape.entry_appended` for live updates
- Per-agent tabs first (simpler, proves the projection works)
- Streaming via `StreamBuffer` → throttled pushes
- Run alongside old `SessionLive` for A/B comparison

### Phase 4: Tape-driven CLI

- Replace signal-based CLI rendering with `UIProjection` + `Render.Terminal`
- Streaming via `StreamBuffer` (re-render last line on update)
- Share renderer logic with LiveView where possible

### Phase 5: Unified multi-agent timeline + cleanup

- Optional: merge per-agent tabs into a single session timeline view
- Delete `SessionProjection` (600+ lines)
- Remove per-event chat signal types from the bus (keep `entry_appended`)
- Delete `inflight` buffer logic
- Remove `text_delta` signal handling once `StreamBuffer` is proven
- Only remove bus signals used exclusively for chat rendering;
  observatory/debug signals remain

## What changes in the Runner

Minimal. The Runner already writes to the tape via Recorder. Changes:

1. Recorder accepts explicit `turn_id` and `step` via opts/meta
2. Recorder populates `meta.agent_id`, `meta.turn_id`, `meta.step`,
   `meta.ts_us` at write time
3. `entry_appended` signal payload includes the full entry (not just
   kind/data), so consumers don't need a second read
4. New `StreamBuffer` module handles transient streaming chunks
5. On stream completion, `StreamBuffer.finish_stream/2` returns the
   full text and Recorder appends the final `:message` entry

The Runner's `emit` callback continues to exist for streaming transport
during migration. The canonical state is always the tape.

## Risks and guardrails

1. **Metadata backfill**: existing tape entries won't have
   `agent_id`/`turn_id`/`step`/`ts_us`. The projection must tolerate
   missing meta and use fallbacks (e.g., `nil` agent, entry `date` as
   timestamp proxy).

2. **Full-tape hydration cost**: mitigated by tail windowing (200–500
   items) from day 1.

3. **"Remove per-event signals" scope creep**: only retire
   signal-driven **chat rendering** signals. Observatory, spreadsheet,
   and debug flows keep their signals.

4. **Turn/step plumbing**: `Recorder.record_*` must accept explicit
   meta rather than guessing from runtime. Thread from `Runner`.

5. **StreamBuffer crash recovery**: the buffer is transient by design.
   If the process crashes mid-stream, the partial text is lost. The
   tape remains consistent (no partial entry was written). The UI
   shows the stream stopped. This is acceptable for MVP; the
   append-only patch log (advanced path) addresses this if needed.

## When to consider the advanced path

Consider a more complex design only if one of these becomes true:
- You need **crash-resumable mid-token streams**
- You need **exact causal ordering** across many agents beyond
  timestamp + tiebreakers
- Session hydration grows beyond **100–200ms**
- Sessions regularly exceed **thousands of entries**
- You want the Observatory/debug UI to be tape-backed too
