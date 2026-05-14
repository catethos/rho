# Unified Conversation and Trace System Plan

## Summary

This plan combines two related goals into one architecture:

1. User-facing durable conversations with threads, forks, resume, and history.
2. Developer-facing agent debugging using tapes as a flight recorder.

The core insight is that these are not separate systems. A conversation is a
human-readable projection of an agent trace. Debugging is an engineer-readable
projection of the same trace.

The implementation should make tape the durable source of truth, then build
conversation UX, LLM context, and debug tooling as projections over the same
append-only facts.

## First Principles

### Fundamental Truths

1. Agents produce a chronological sequence of facts:
   user messages, assistant messages, tool calls, tool results, errors,
   usage, compaction, anchors, and forks.
2. A user conversation is a named, navigable view over those facts.
3. A debugging session is another view over those facts.
4. If the UI and the debugger disagree, the system is already broken.
5. UI socket state is convenient but not durable truth.
6. A fork point must refer to an actual tape entry, not a visual index.
7. The LLM-visible context must be reproducible from persisted state.

### Design Rule

Tape is truth. Everything else is derived:

- Chat messages are derived from tape.
- LLM context is derived from tape.
- Debug reports are derived from tape and event logs.
- Cost and failure reports are derived from tape.
- UI snapshots are cache only.

## Target Primitives

### Tape

Append-only sequence of immutable entries. Already lives under
`Rho.Tape.*`.

Existing relevant modules:

- `Rho.Tape.Entry`
- `Rho.Tape.Store`
- `Rho.Tape.Service`
- `Rho.Tape.View`
- `Rho.Tape.Fork`
- `Rho.Tape.Projection.JSONL`

### Conversation

A durable user-facing container for one chat session.

It owns metadata:

- title
- owner
- organization
- active thread
- archive status
- timestamps

It does not own message history. Message history lives in tapes.

### Thread

A named branch inside a conversation. Each thread points to a tape.

Examples:

- `Main`
- `Try a smaller framework`
- `Debug failing tool loop`
- `Fork from user message 12`

### Anchor

A semantic checkpoint in a tape. Anchors summarize prior entries and define
where the default LLM context should resume.

### Projection

A derived view over tape entries:

- chat projection
- LLM context projection
- debug timeline projection
- failure projection
- cost projection
- bundle export projection

## Current Codebase Baseline

The codebase already has many useful pieces:

- `Rho.Session` starts and sends messages to durable sessions.
- `Rho.Agent.Primary.resume/2` resumes a stopped session by starting a fresh worker.
- `Rho.Agent.Worker` stores `tape_ref` in worker state.
- `Rho.Runner` and `Rho.Recorder` write semantic facts to tape.
- `Rho.Tape.View.default/1` builds the working LLM context from the latest anchor.
- `RhoWeb.Session.Threads` stores a thread registry in `threads.json`.
- `RhoWeb.Session.Snapshot` stores UI snapshots, including per-thread snapshots.
- `AppLive` already has handlers for switching threads, blank threads, and fork-from-here.
- `mix rho.trace` already provides aggregate trace reports.
- `Rho.Stdlib.Plugins.Tape` exposes agent-facing tape tools.

The main gaps:

- Threads live in `rho_web`, but conversation identity should be a core runtime concept.
- Forking uses UI message indexes where it needs tape entry ids.
- Forked tapes currently start with a `fork_origin` anchor but do not necessarily preserve prior context.
- Debugging requires manually joining tape files, event logs, projections, and UI state.
- UI snapshots are sometimes treated like the recoverable chat state, but they should be cache.

## Target Architecture

```text
Tape entries
  -> Rho.Trace.Projection.chat/1
  -> Rho.Trace.Projection.context/1
  -> Rho.Trace.Projection.debug/1
  -> Rho.Trace.Projection.failures/1
  -> Rho.Trace.Projection.costs/1
  -> Rho.Trace.Bundle.write/2

Conversation metadata
  -> active thread
  -> thread tape name
  -> ownership and listing

Web UI
  -> uses conversation metadata for navigation
  -> uses chat projection for durable rebuild
  -> uses snapshots only for fast cache

Coding agent
  -> uses mix rho.debug or debug_tape tools
  -> gets exact context and failure reports from tape
```

## Data Model

### Conversation JSON

Initial implementation should be file-backed, not Ecto-backed. This keeps
the core runtime independent of Phoenix and Ecto.

Suggested path:

```text
<RHO_DATA_DIR>/conversations/
  index.json
  conv_<id>.json
```

Schema:

```json
{
  "id": "conv_xxx",
  "session_id": "lv_xxx",
  "user_id": "123",
  "organization_id": "456",
  "title": "New conversation",
  "active_thread_id": "thread_main",
  "created_at": "2026-05-14T00:00:00Z",
  "updated_at": "2026-05-14T00:00:00Z",
  "archived_at": null,
  "threads": []
}
```

### Thread JSON

```json
{
  "id": "thread_main",
  "name": "Main",
  "tape_name": "session_abcd1234_ef567890",
  "forked_from": null,
  "fork_point_entry_id": null,
  "summary": null,
  "created_at": "2026-05-14T00:00:00Z",
  "updated_at": "2026-05-14T00:00:00Z",
  "status": "active"
}
```

### Tape Entry Metadata

Add optional metadata to tape entries. Keep all keys as strings.

```json
{
  "conversation_id": "conv_xxx",
  "thread_id": "thread_main",
  "session_id": "lv_xxx",
  "agent_id": "lv_xxx/primary",
  "turn_id": "123",
  "step": 4,
  "model": "openrouter:...",
  "strategy": "Elixir.Rho.TurnStrategy.TypedStructured"
}
```

This metadata is optional for backward compatibility. Old tapes without these
fields must still load and project correctly.

## Phase 0: Naming and Compatibility Decisions

### Decisions

1. Put new durable conversation modules in `apps/rho`, not `apps/rho_web`.
2. Keep `RhoWeb.Session.Threads` temporarily as a compatibility wrapper.
3. Use file-backed JSON metadata first.
4. Use string keys for all persisted maps.
5. Keep tape payloads unchanged where possible.
6. Store conversation/thread ids in tape `meta`, not in every payload.
7. Treat UI snapshots as cache only.

### New Namespaces

```text
apps/rho/lib/rho/conversation.ex
apps/rho/lib/rho/conversation/index.ex
apps/rho/lib/rho/conversation/thread.ex
apps/rho/lib/rho/conversation/ref.ex
apps/rho/lib/rho/trace/projection.ex
apps/rho/lib/rho/trace/analyzer.ex
apps/rho/lib/rho/trace/bundle.ex
apps/rho/lib/mix/tasks/rho.debug.ex
```

### Acceptance Criteria

- No Phoenix/Ecto dependencies are introduced into `apps/rho`.
- Existing sessions without conversation metadata still run.
- Existing `RhoWeb.Session.Threads` tests continue to pass during migration.

## Phase 1: Core Conversation Metadata

### Goal

Create a core durable conversation index and thread registry.

### Implementation

Create `Rho.Conversation` as the public API:

```elixir
defmodule Rho.Conversation do
  def create(attrs), do: ...
  def get(conversation_id), do: ...
  def get_by_session(session_id), do: ...
  def list(opts \\ []), do: ...
  def archive(conversation_id), do: ...
  def touch(conversation_id), do: ...

  def create_thread(conversation_id, attrs), do: ...
  def list_threads(conversation_id), do: ...
  def get_thread(conversation_id, thread_id), do: ...
  def active_thread(conversation_id), do: ...
  def switch_thread(conversation_id, thread_id), do: ...
  def delete_thread(conversation_id, thread_id), do: ...
end
```

Create `Rho.Conversation.Index` for file IO:

- `load_index/0`
- `write_index/1`
- `conversation_path/1`
- `read_conversation/1`
- `write_conversation/1`

Writes must be atomic:

1. Write to `.tmp`.
2. Rename into place.

Use `Rho.Paths.data_dir/0` for root paths.

### Tests

Create:

```text
apps/rho/test/rho/conversation_test.exs
apps/rho/test/rho/conversation/index_test.exs
```

Test cases:

- create conversation
- get by id
- get by session id
- list by user id
- list by organization id
- archive
- create main thread
- create named thread
- switch active thread
- prevent deleting active thread
- atomic writes survive reload

### Acceptance Criteria

- Conversations can be listed without scanning all tape JSONL files.
- Thread registry works outside Phoenix.
- Root metadata includes `session_id`, `user_id`, and `organization_id`.

## Phase 2: Runtime Conversation and Thread Identity

### Goal

Carry `conversation_id` and `thread_id` through the agent runtime so tape
entries can be joined back to conversation/thread metadata.

### Files to Update

- `apps/rho/lib/rho/run_spec.ex`
- `apps/rho/lib/rho/context.ex`
- `apps/rho/lib/rho/session.ex`
- `apps/rho/lib/rho/agent/worker.ex`
- `apps/rho/lib/rho/runner.ex`
- `apps/rho/lib/rho/recorder.ex`

### RunSpec Additions

Add fields:

```elixir
:conversation_id,
:thread_id
```

### Context Additions

Add fields:

```elixir
conversation_id: String.t() | nil,
thread_id: String.t() | nil
```

### Session Start Options

Allow:

```elixir
Rho.Session.start(
  session_id: sid,
  conversation_id: conv_id,
  thread_id: thread_id,
  tape_ref: tape_name
)
```

### Worker Behavior

When a worker starts:

- If `conversation_id` and `thread_id` are provided, copy them into `RunSpec`.
- If not provided, keep behavior unchanged.
- Do not auto-create conversations in the low-level worker.

### Recorder Metadata

Update `Rho.Recorder.append_with_tape_write/5` so every append gets standard
metadata where available.

Suggested helper:

```elixir
defp runtime_meta(%Runtime{} = runtime, extra \\ %{}) do
  %{
    "conversation_id" => runtime.context.conversation_id,
    "thread_id" => runtime.context.thread_id,
    "session_id" => runtime.context.session_id,
    "agent_id" => runtime.context.agent_id,
    "model" => to_string(runtime.model || ""),
    "strategy" => inspect(runtime.turn_strategy)
  }
  |> reject_nil_values()
  |> Map.merge(extra)
end
```

Include `turn_id` and `step` where the runtime can access them. If not
available yet, add them later without blocking the phase.

### Tests

Update or add tests:

- `apps/rho/test/rho/recorder_test.exs`
- `apps/rho/test/rho/session_test.exs`
- `apps/rho/test/rho/runner_test.exs`

Test cases:

- tape entries include conversation/thread metadata when provided
- no crash when metadata is nil
- old append paths still work

### Acceptance Criteria

- A tape entry can be traced back to a conversation and thread.
- Existing tests remain compatible.

## Phase 3: Correct Fork Semantics

### Goal

Make "Fork from here" mean the same thing in UI, tape, and LLM context.

### Current Problem

`AppLive.handle_event("fork_from_here", ...)` currently receives a UI
`message_index`. `RhoWeb.Session.Threads.fork_thread/4` expects a tape
entry id. These are not the same.

`Rho.Tape.Fork.fork/2` currently creates a fork tape with a `fork_origin`
anchor but does not materialize prior context. A fork can therefore appear
correct in the UI but give the agent too little context.

### Required Changes

#### 3.1 Attach Tape Entry Ids to Chat Messages

Update chat projection and message construction so user/assistant messages can
carry:

```elixir
%{
  tape_entry_id: 42
}
```

For messages created from live turns, capture entry ids where possible from
`Rho.Recorder`. If this is not easy in the first pass, rebuild from tape after
the turn completes.

#### 3.2 Change Fork UI Contract

Change the button payload from:

```elixir
phx-value-message_index={idx}
```

to:

```elixir
phx-value-entry_id={@message.tape_entry_id}
```

Keep a fallback path for old messages that lack `tape_entry_id`, but prefer
disabling the fork button over passing an incorrect index.

#### 3.3 Materialize Forked Tapes

Recommended MVP: copy entries up to the fork point into the fork tape.

Update `Rho.Tape.Fork.fork/2`:

1. Resolve `at_id`.
2. Create fork tape.
3. Copy source entries with `entry.id <= at_id`.
4. Append a `fork_origin` event or anchor that records source tape and at id.
5. Return fork tape name.

Important:

- Preserve payloads.
- Preserve metadata where useful, but mark copied entries with:

```json
{
  "copied_from_tape": "source",
  "copied_from_entry_id": 42
}
```

Alternative later: linked fork projection. Do not implement first unless
materialized forks become too expensive.

#### 3.4 Tool Pair Validity

When forking around tool calls, avoid invalid context:

- If a tool result is included, its tool call must also be included.
- If a tool call is included without its result, either include the result or
  exclude the incomplete pair from the projected context.

`Rho.Tape.View.drop_orphaned_tool_results/1` already protects one direction.
Add tests for forked tapes.

### Tests

Update:

```text
apps/rho/test/rho/tape/fork_test.exs
apps/rho/test/rho/tape/view_test.exs
apps/rho_web/test/rho_web/session/threads_test.exs
apps/rho_web/test/rho_web/live/app_live*_test.exs
```

Test cases:

- fork at entry id copies prior messages
- forked context includes prior user/assistant history
- forked context does not include messages after fork point
- fork metadata records source tape and entry id
- UI fork passes entry id, not message index

### Acceptance Criteria

- Forked agent sees the same prior context implied by the UI.
- Fork points are stable after refresh.
- Debug reports can say exactly where the fork happened.

## Phase 4: Trace Projection Layer

### Goal

Create one projection API for chat, LLM context, and debugging.

### New Module

```text
apps/rho/lib/rho/trace/projection.ex
```

### Public API

```elixir
defmodule Rho.Trace.Projection do
  def chat(tape_name, opts \\ [])
  def context(tape_name, opts \\ [])
  def debug(tape_name, opts \\ [])
  def failures(tape_name, opts \\ [])
  def costs(tape_name, opts \\ [])
end
```

### Projection Semantics

#### `chat/2`

Returns UI-friendly messages:

```elixir
%{
  id: "tape-42",
  tape_entry_id: 42,
  role: :user | :assistant | :system,
  type: :text | :tool_call | :anchor | :error,
  content: "...",
  agent_id: "...",
  ts: "..."
}
```

#### `context/2`

Returns exactly what the LLM should see:

```elixir
Rho.Tape.Projection.JSONL.build_context(tape_name)
```

Do not reimplement this logic. The debug view must show the same context the
runner uses.

#### `debug/2`

Returns a chronological trace:

```elixir
%{
  id: 42,
  kind: :tool_result,
  label: "tool_result fs_read ok",
  payload_preview: "...",
  meta: %{},
  date: "..."
}
```

#### `failures/2`

Returns structured failure findings:

```elixir
%{
  severity: :error | :warning | :info,
  code: :orphan_tool_result,
  entry_id: 42,
  message: "...",
  details: %{}
}
```

#### `costs/2`

Returns token and cost aggregates from `llm_usage` events.

### Tests

Create:

```text
apps/rho/test/rho/trace/projection_test.exs
```

Test cases:

- chat projection handles messages
- chat projection handles tool calls/results
- context projection matches `Rho.Tape.Projection.JSONL.build_context/1`
- debug projection is chronological
- failure projection detects known bad patterns
- old tapes without metadata still project

### Acceptance Criteria

- Web can rebuild chat from `Rho.Trace.Projection.chat/1`.
- Debug CLI can show exact LLM-visible context.
- Projection code is pure and side-effect free.

## Phase 5: Trace Analyzer

### Goal

Formalize debugging heuristics so coding agents get useful findings, not raw
JSONL spelunking.

### New Module

```text
apps/rho/lib/rho/trace/analyzer.ex
```

### Public API

```elixir
defmodule Rho.Trace.Analyzer do
  def analyze(tape_name, opts \\ [])
  def findings(entries, opts \\ [])
end
```

### Checks

Implement these checks first:

1. `:orphan_tool_result`
   A tool result has no matching tool call.

2. `:tool_call_without_result`
   A tool call has no matching result.

3. `:repeated_tool_call`
   Same tool called 3 or more times consecutively.

4. `:max_steps_exceeded`
   Error event includes max steps exceeded.

5. `:parse_error_loop`
   Multiple parse errors occur close together.

6. `:missing_final_assistant_message`
   Last user message has no assistant response and no active turn.

7. `:fork_without_context`
   A fork tape contains only `fork_origin` and no inherited conversational entries.

8. `:large_context_after_anchor`
   Entries after latest anchor exceed a configurable threshold.

9. `:tool_error_without_type`
   Tool result has status error but no useful `error_type`.

10. `:high_cost_turn`
    A usage event exceeds configurable cost or token threshold.

### Severity

Use:

- `:error` for likely correctness bugs
- `:warning` for suspicious patterns
- `:info` for useful debugging notes

### Tests

Create:

```text
apps/rho/test/rho/trace/analyzer_test.exs
```

Acceptance:

- Analyzer returns deterministic findings.
- Each finding includes enough data for a coding agent to inspect the entry.

## Phase 6: Debug Bundle and CLI

### Goal

Give a coding agent one command to collect everything needed to debug a run.

### New Modules

```text
apps/rho/lib/rho/trace/bundle.ex
apps/rho/lib/mix/tasks/rho.debug.ex
```

### CLI

```bash
mix rho.debug <session_id | conversation_id | tape_name>
mix rho.debug <ref> --out /tmp/rho-debug
mix rho.debug <ref> --last 100
mix rho.debug <ref> --format markdown
```

### Ref Resolution

Implement `Rho.Conversation.Ref.resolve/1`:

1. If input matches a conversation id, load conversation.
2. If input matches a session id, find conversation by session id.
3. If input matches a thread id, find owning conversation/thread.
4. Otherwise treat as tape name if tape exists.

Return:

```elixir
%{
  conversation_id: nil | binary(),
  session_id: nil | binary(),
  thread_id: nil | binary(),
  tape_name: binary(),
  workspace: nil | binary(),
  event_log_path: nil | binary()
}
```

### Bundle Contents

Output directory:

```text
rho-debug-<timestamp>/
  summary.json
  tape.jsonl
  events.jsonl
  chat.md
  context.md
  debug-timeline.md
  failures.md
  costs.md
  README.md
```

### `summary.json`

Include:

- conversation id
- session id
- thread id
- tape name
- event log path
- entry count
- anchor count
- latest anchor
- model names seen
- tool names seen
- total cost
- failure count

### `context.md`

Must render the exact LLM-visible context from
`Rho.Trace.Projection.context/1`.

### `failures.md`

Render analyzer findings ordered by severity and entry id.

### Tests

Create:

```text
apps/rho/test/rho/trace/bundle_test.exs
apps/rho/test/mix/tasks/rho_debug_test.exs
```

Acceptance:

- `mix rho.debug <tape>` writes a complete bundle.
- Missing event log does not fail the bundle.
- Bundle can be generated for old tapes.

## Phase 7: Web Integration

### Goal

Make AppLive use the unified conversation model while preserving existing UX.

### Files to Update

- `apps/rho_web/lib/rho_web/live/app_live.ex`
- `apps/rho_web/lib/rho_web/session/session_core.ex`
- `apps/rho_web/lib/rho_web/session/threads.ex`
- `apps/rho_web/lib/rho_web/session/snapshot.ex`
- `apps/rho_web/lib/rho_web/components/chat_components.ex`
- `apps/rho_web/lib/rho_web/components/command_palette_component.ex`

### Session Creation

When a chat session is created:

1. Create or load conversation by session id.
2. Ensure main thread exists.
3. Start `Rho.Session` with:

```elixir
conversation_id: conv["id"],
thread_id: active_thread["id"],
tape_ref: active_thread["tape_name"]
```

### Resume

When loading `/orgs/:org_slug/chat/:session_id`:

1. Load conversation by session id.
2. Load active thread.
3. Start primary agent with active thread tape.
4. Restore UI snapshot if present.
5. If no snapshot exists, rebuild chat from `Rho.Trace.Projection.chat/1`.

### Thread Switch

When switching thread:

1. Save current snapshot as cache.
2. Switch active thread in `Rho.Conversation`.
3. Stop primary agent.
4. Restart with target thread tape and metadata.
5. Load target snapshot if present.
6. Otherwise rebuild chat from tape.

### Blank Thread

When creating a blank thread:

1. Create new tape.
2. Bootstrap tape.
3. Add thread to conversation.
4. Switch active thread.
5. Restart primary on new tape.

### Fork From Here

When forking:

1. Read `entry_id` from message.
2. Create materialized fork tape from active tape at entry id.
3. Add new thread with `fork_point_entry_id`.
4. Switch active thread.
5. Restart primary on fork tape.
6. Build chat from fork tape projection.

### Debug Mode UI

When debug mode is enabled, show:

- conversation id
- active thread id
- active tape name
- latest entry id
- copy debug command
- export debug bundle action

Suggested command:

```bash
mix rho.debug <conversation_id>
```

### Snapshot Policy

Update docs and comments:

- Snapshot is cache.
- Snapshot may speed up UI restoration.
- Snapshot must not be required for durable resume.

### Tests

Update existing LiveView tests and add focused cases:

- refresh without snapshot rebuilds chat from tape
- switch thread with missing snapshot works
- fork passes tape entry id
- debug command appears in debug mode

## Phase 8: Developer-Only Debug Tape Plugin

### Goal

Let coding agents inspect traces using tools, without shell access.

### New Module

```text
apps/rho_stdlib/lib/rho/stdlib/plugins/debug_tape.ex
apps/rho_stdlib/lib/rho/stdlib/tools/debug_tape_tools.ex
```

### Tools

1. `list_recent_conversations`
2. `get_conversation`
3. `get_tape_slice`
4. `get_visible_context`
5. `get_trace_findings`
6. `get_debug_bundle_summary`

### Plugin Map

Add shorthand:

```elixir
:debug_tape => Rho.Stdlib.Plugins.DebugTape
```

Do not include this plugin in normal user agents by default.

### Prompt Material

Keep prompt sections minimal. Do not duplicate tool descriptions.

Possible binding:

```elixir
%{
  name: "debug_tape",
  kind: :trace_index,
  access: :tool,
  persistence: :runtime,
  summary: "Developer-only access to recent conversation traces"
}
```

### Tests

Create:

```text
apps/rho_stdlib/test/rho/stdlib/plugins/debug_tape_test.exs
```

Acceptance:

- Plugin exposes tools only when configured.
- Tools can inspect a known tape.
- Tools do not mutate conversation or tape state.

## Phase 9: Documentation Updates

### Update `AGENTS.md`

Add core modules under `apps/rho/`:

```markdown
- `Rho.Conversation` / `.Index` / `.Thread` / `.Ref` - durable conversation and thread metadata; maps user-visible conversations to tape-backed threads.
- `Rho.Trace.Projection` - derived chat/context/debug/cost/failure views over tape entries.
- `Rho.Trace.Analyzer` - deterministic trace checks for agent debugging.
- `Rho.Trace.Bundle` - writes portable debug bundles for coding-agent investigation.
- `Mix.Tasks.Rho.Debug` - creates a debug bundle from a session, conversation, thread, or tape reference.
```

Add invariant section:

```markdown
### Conversation and Trace Invariants

- Tape entries are the durable source of truth.
- Conversations and threads are metadata over tapes, not separate message stores.
- UI snapshots are cache only; chat must be rebuildable from tape projections.
- Fork points are tape entry ids, never UI message indexes.
- The debug context projection must use the same tape projection path as the runner.
```

Update mix tasks line:

```markdown
- `Mix.Tasks.Rho.{Run,Trace,Debug,Smoke,Verify}` - run an agent, inspect traces, create debug bundles, smoke-test, verify config.
```

Update plugin map:

```markdown
| `:debug_tape` | `Rho.Stdlib.Plugins.DebugTape` |
```

Add docs reference:

```markdown
`docs/conversation-trace-system-plan.md` - canonical plan for unifying durable conversation threads and tape-based debugging.
```

### Update `CLAUDE.md`

Apply the same updates as `AGENTS.md`. Keep both files in sync because this
repo uses both as agent-facing developer context.

### Update `docs/tape-system.md`

Add a section:

```markdown
## Conversation and Trace Projections

The tape is the source of truth for both user conversation history and agent
debugging. Conversations and threads are metadata that point to tapes. Chat UI,
LLM context, trace timelines, failure reports, and debug bundles are all
projections over the same append-only entries.
```

Clarify:

- `Rho.Tape.View` is still the LLM context primitive.
- `Rho.Trace.Projection.context/1` delegates to the canonical tape projection.
- Snapshots are not durable truth.

### Update `docs/conversation-threads-plan.md`

Add a notice at the top:

```markdown
> Superseded by `docs/conversation-trace-system-plan.md`.
> The original `RhoWeb.Session.Threads` registry is now treated as a web-layer
> compatibility shim while durable conversation/thread metadata moves to
> `Rho.Conversation` in the core app.
```

### Update `docs/durable-agent-chat-plan.md`

Add a section that references the conversation index:

```markdown
## Relationship to Conversation Metadata

Durable HTTP/session resume should use `Rho.Conversation` as the listing and
ownership index. The tape remains the message/event source of truth; the
conversation index provides user, organization, title, archive, and active
thread metadata.
```

### Update `docs/combined-simplification-plan.md`

Add a short cross-reference:

```markdown
For conversation durability and debugging, see
`docs/conversation-trace-system-plan.md`. It applies the same simplification
principle: one source of truth, many projections.
```

### Optional README Update

Add a developer command example:

```bash
mix rho.debug <session_or_tape>
```

## Phase 10: Migration and Backward Compatibility

### Existing `threads.json`

During first load:

1. If conversation metadata exists, use it.
2. Else if `_rho/sessions/{sid}/threads.json` exists, import it into
   `Rho.Conversation`.
3. Else create a conversation with one main thread pointing at the current
   session tape.

Do not delete old `threads.json` in the first migration.

### Existing Snapshots

Keep `RhoWeb.Session.Snapshot` paths unchanged. When conversation metadata
exists, snapshots can still be keyed by thread id.

### Existing Tapes

Old tapes lack conversation/thread metadata. Projections must still work.

### Existing URLs

Keep:

```text
/orgs/:org_slug/chat/:session_id
```

Do not introduce conversation id into URLs until the core migration is stable.

## Phase 11: Verification Commands

Run focused tests after each phase:

```bash
mix test apps/rho/test/rho/conversation_test.exs
mix test apps/rho/test/rho/trace
mix test apps/rho/test/rho/tape
mix test apps/rho_web/test/rho_web/session/threads_test.exs
```

Then app-level tests:

```bash
mix test --app rho
mix test --app rho_stdlib
mix test --app rho_web
```

Before final merge:

```bash
mix test
mix format
```

If formatting only touched targeted files, keep the diff scoped.

## Implementation Checklist

### Core

- [ ] Add `Rho.Conversation` modules.
- [ ] Add file-backed conversation index.
- [ ] Add thread CRUD in core.
- [ ] Add conversation/thread fields to `RunSpec`.
- [ ] Add conversation/thread fields to `Rho.Context`.
- [ ] Carry metadata through `Session`, `Primary`, `Worker`, and `Runner`.
- [ ] Add tape metadata in `Rho.Recorder`.

### Forks

- [ ] Attach tape entry ids to chat messages.
- [ ] Change fork UI event to use `entry_id`.
- [ ] Materialize forked tapes up to entry id.
- [ ] Preserve valid tool call/result context.
- [ ] Add fork regression tests.

### Trace

- [ ] Add `Rho.Trace.Projection`.
- [ ] Add `Rho.Trace.Analyzer`.
- [ ] Add `Rho.Trace.Bundle`.
- [ ] Add `mix rho.debug`.
- [ ] Add tests for projections, analyzer, bundle, and CLI.

### Web

- [ ] Bridge `RhoWeb.Session.Threads` to `Rho.Conversation`.
- [ ] Make refresh without snapshot rebuild from tape.
- [ ] Thread switch uses conversation metadata.
- [ ] Blank thread uses conversation metadata.
- [ ] Fork thread uses tape entry id.
- [ ] Add debug command UI.

### Stdlib

- [ ] Add `Rho.Stdlib.Plugins.DebugTape`.
- [ ] Add debug tape tools.
- [ ] Add `:debug_tape` shorthand.
- [ ] Add plugin tests.

### Docs

- [ ] Update `AGENTS.md`.
- [ ] Update `CLAUDE.md`.
- [ ] Update `docs/tape-system.md`.
- [ ] Mark `docs/conversation-threads-plan.md` superseded.
- [ ] Update `docs/durable-agent-chat-plan.md`.
- [ ] Update `docs/combined-simplification-plan.md`.
- [ ] Optionally update `README.md`.

## Risks and Mitigations

### Risk: Conversation Metadata Diverges From Tape

Mitigation:

- Keep messages out of conversation metadata.
- Store only pointers and display metadata.
- Rebuild chat from tape in tests.

### Risk: Forks Become Expensive

Mitigation:

- Start with materialized forks for correctness.
- Later optimize with linked fork projection if needed.

### Risk: Debug Projection Reimplements Runner Context Incorrectly

Mitigation:

- `Rho.Trace.Projection.context/1` must delegate to the same tape projection
  used by the runner.
- Add a test comparing both paths.

### Risk: Web Migration Breaks Existing Sessions

Mitigation:

- Keep `RhoWeb.Session.Threads` as compatibility shim.
- Import old `threads.json` lazily.
- Keep session-id URLs.

### Risk: Developer-Only Tools Leak To User Agents

Mitigation:

- Do not include `:debug_tape` in default configs.
- Document that it is dev-only.
- Keep prompt material minimal.

## Definition of Done

The work is complete when:

1. A user can create, resume, switch, and fork conversations.
2. A missing UI snapshot does not lose chat history.
3. Forking from a message uses a real tape entry id.
4. A forked agent sees the expected prior context.
5. A coding agent can run `mix rho.debug <ref>` and get a useful bundle.
6. Debug context matches runner context.
7. Old tapes and old sessions still load.
8. `AGENTS.md` and `CLAUDE.md` describe the new primitives and invariants.
9. Focused tests and relevant app tests pass.

