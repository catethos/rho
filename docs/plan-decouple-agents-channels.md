# Plan: Decouple Agents from Channels

## Inspiration: Bub's Architecture

Bub (the Python predecessor of Rho) has a cleaner separation that Rho drifted
from during the Elixir port:

- **`BubFramework.process_inbound/1`** is the single entry point. It takes a
  message, runs it through hooks (resolve_session → load_state → build_prompt →
  run_model → save_state → render_outbound → dispatch_outbound), and returns a
  `TurnResult`. There is no callback threading — the framework orchestrates the
  turn, and output routing is a separate hook phase at the end.

- **Channels are pure input adapters.** `CliChannel` owns its REPL loop and
  renderer (`CliRenderer`). It calls `on_receive(message)` to submit work and
  uses a `lifespan` context manager for turn completion signaling — not
  callbacks injected into the agent. The channel never reaches into the agent.

- **Rendering is channel-local.** `CliRenderer` is a separate class inside the
  CLI channel package. Agent/framework code never imports it. The agent produces
  text output; the CLI decides how to display it.

- **`ChannelManager`** only handles channel lifecycle + message queue + dispatch.
  It does NOT construct callbacks or thread display logic. Messages go in via
  `on_receive`, get queued, and processed via `framework.process_inbound`.

- **Debounce is handler-local.** `BufferedMessageHandler` wraps the handler
  function for channels that need debounce. It's not a global concern — it's
  an edge adapter wrapping `messages.put`.

- **No session process.** Bub doesn't need per-session GenServers because
  Python is single-threaded async. But Rho does — the BEAM's concurrency model
  means sessions need process isolation for queuing and cancellation. The
  insight to carry over is: the session process should be the **only** runtime
  boundary, and everything else should be a thin adapter.

## Problem Statement

The current Rho architecture has too many layers between input and execution,
and couples display logic to the agent core via callback threading — problems
that Bub's architecture avoids.

### What a message passes through today

```
mix rho.chat
  → Channel.Manager.listen_and_run (GenServer call, blocks)
    → Channel.Manager.on_receive (GenServer cast)
      → route_async (Task)
        → SessionRouter.route_message (stateless module)
          → merge_context_overrides (threads on_text/on_event from Message.context)
          → resolve_session (hooks)
          → find_or_start_worker
            → Session.Worker.send_message (GenServer.call, blocks until done)
              → run_agent_loop (Task.async)
                → AgentLoop.run (recursive function)
                  → on_event callback (ANSI rendering / socket send)
                  → on_text callback (IO.write / socket send)
```

The Web path bypasses most of this — Socket calls `SessionRouter.route_message`
directly, skipping `Channel.Manager` entirely.

Compare with Bub's flow:
```
CliChannel._main_loop → on_receive(message) → ChannelManager queue
  → framework.process_inbound(message) → hooks pipeline → TurnResult
  → dispatch_outbound → channel.send(outbound)
```

### Core problems

1. **Six layers for a message to reach the agent.** Channel.Manager, Channel.Message,
   SessionRouter, and Worker are four runtime concepts where one or two would do.
   (Bub has two: ChannelManager → Framework.)

2. **Callbacks threaded through every layer.** `on_text`, `on_event`, `on_done`
   are created at the edge (CLI/Socket), stuffed into `Message.context`, passed
   through Manager → SessionRouter → Worker → AgentLoop. The agent executes
   channel-owned rendering code. (Bub never does this — channels observe output
   after the turn, via `channel.send` and the `lifespan` context manager.)

3. **AgentLoop contains display opinions.** `default_on_event/1` does ANSI
   `IO.puts` — terminal rendering inside the agent core. `IO.puts("")` after
   streaming assumes a terminal. (Bub's `Agent` has no rendering code at all —
   `CliRenderer` is entirely in the CLI channel package.)

4. **Two divergent output paths.** CLI goes through Manager's `route_async`.
   Web spawns its own Task with its own closures. Adding a third channel means
   inventing a third output path.

5. **Worker task lifecycle is broken.** `Task.async/1` links to the GenServer.
   Cancel demonitors but can't kill the task — it keeps running, emitting events.

6. **Channel.Manager does four unrelated things.** Channel lifecycle management,
   session override application, debounce routing, and async dispatch with
   `IO.puts` error handling — all in one GenServer.

7. **`Rho.Channel` behaviour conflates input and output.** `start/stop` (input
   adapter lifecycle) and `send_message` (output rendering) are different
   concerns bundled into one behaviour.

8. **`Channel.Message` exists to carry callbacks.** Once callbacks are removed,
   the envelope struct has no reason to exist — it's just `content` + `opts`.

9. **SessionRouter is a thin passthrough.** It does three small things
   (resolve_session, find_or_start, merge_context_overrides) that could be
   functions on Session.

---

## Redesigned Architecture

### Core Principle

**Reduce to the essential abstractions.** A session is already a natural process
boundary — make it the single runtime concept. Adapters (CLI, Web) talk to it
directly. Events flow via plain message passing to subscribers on the session.
No middleware, no envelopes, no callback threading.

### Four abstractions, total

Inspired by Bub's clean layering (Framework + Channel + Agent + Renderer),
adapted for OTP concurrency:

```
1. Session      — owns state, sequencing, subscribers. The only runtime boundary.
                  (Bub equivalent: Framework + Agent, but as a GenServer for
                  concurrency/queuing that Python doesn't need)
2. AgentLoop    — pure computation. Single `emit` callback. No display logic.
                  (Bub equivalent: Agent._agent_loop — no rendering code)
3. Adapters     — CLI/Web/HTTP translate input/output. Talk to Session directly.
                  (Bub equivalent: CliChannel with its own CliRenderer)
4. Edge helpers — debounce, rendering. Adapter-local, not global.
                  (Bub equivalent: BufferedMessageHandler, CliRenderer)
```

### Architecture diagram

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   CLI REPL   │  │  Web Socket  │  │   HTTP API   │
│              │  │              │  │              │
│  subscribe() │  │  subscribe() │  │    ask()     │
│  submit()    │  │  submit()    │  │  (sync wrap) │
│  render()    │  │  render()    │  │              │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       └────────────┬────┘─────────────────┘
                    ▼
┌──────────────────────────────────────────────────────┐
│                   Rho.Session                        │
│                                                      │
│  Public API (facade):                                │
│    ensure_started/1, submit/3, subscribe/2,          │
│    cancel/1, info/1, list/1, ask/3                   │
│                                                      │
│  Per-session GenServer (Rho.Session.Server):         │
│    - owns tape, tools, config                        │
│    - queues turns                                    │
│    - runs AgentLoop in Task.Supervisor.async_nolink  │
│    - maintains subscriber list with monitors         │
│    - broadcasts events via send/2 to subscribers     │
│    - handles cancel with :cancelling state           │
└──────────────────────────────────────────────────────┘
                    │
                    ▼ runs inside Task
┌──────────────────────────────────────────────────────┐
│                   AgentLoop                          │
│                                                      │
│  Pure recursive function. Single emit callback.      │
│  No on_text/on_event split. No display logic.        │
│  No default_on_event. No IO.puts.                    │
│                                                      │
│  emit.(%{type: :text_delta, text: "Hello"})          │
│  emit.(%{type: :tool_start, name: "bash", ...})      │
│  emit.(%{type: :tool_result, name: "bash", ...})     │
│  emit.(%{type: :step_start, step: 1, ...})           │
│                                                      │
│  HookRuntime overrides happen inside AgentLoop,      │
│  before emit — emit sees the effective result only.  │
└──────────────────────────────────────────────────────┘
```

### What gets deleted

| Rho Module | Bub Equivalent | Reason for Deletion |
|---|---|---|
| `Rho.Channel.Manager` | `ChannelManager` exists but is thinner — no callback threading | Rho's does 4 unrelated things; adapters talk to Session directly |
| `Rho.Channel.Message` | `ChannelMessage` exists but carries no callbacks | Rho's only existed to carry `on_text`/`on_event`/`on_done` |
| `Rho.SessionRouter` | No equivalent (framework resolves session inline) | Thin passthrough; absorbed into `Rho.Session` facade |
| `Rho.Channel` behaviour | `Channel` ABC exists but `send` is optional, not conflated | Rho's conflates input lifecycle with output rendering |
| `Rho.Channel.Web` | N/A | Only existed for `send_message` dispatch via ClientRegistry |
| `Rho.Web.ClientRegistry` | N/A | Replaced by session subscriber list |
| `Rho.Channel.Supervisor` | N/A | Only supervised debounce; debounce moves to adapter edge |

### What gets renamed/moved

| Before | After |
|---|---|
| `Rho.Session.Worker` | `Rho.Session.Server` |
| `default_on_event`, `format_args`, `print_tool_output` in AgentLoop | `Rho.CLI.Renderer` (or inline in CLI adapter) |

---

## Design Details

### `Rho.Session` — public API facade

Stateless module with functions that locate or create session processes.
Absorbs the useful parts of `SessionRouter`.

```elixir
defmodule Rho.Session do
  @doc "Find or start a session. Returns {:ok, pid}."
  def ensure_started(session_id, opts \\ [])

  @doc "Look up a running session. Returns pid or nil."
  def whereis(session_id)

  @doc "Submit input. Returns {:ok, turn_id} immediately."
  def submit(session, content, opts \\ [])

  @doc "Subscribe to session events. Auto-cleaned on process death."
  def subscribe(session, pid \\ self())

  @doc "Unsubscribe from session events."
  def unsubscribe(session, pid \\ self())

  @doc "Cancel the current turn."
  def cancel(session)

  @doc "Get session info."
  def info(session)

  @doc "List active sessions."
  def list(opts \\ [])

  @doc "Synchronous submit — subscribe, submit, collect until turn_finished."
  def ask(session, content, opts \\ [])

  @doc "Resolve session ID from opts, using hooks if needed."
  def resolve_id(opts)
end
```

`session` parameter accepts either a pid or a session_id string (resolved via
Registry). `submit/3` is a short `GenServer.call` that enqueues and returns
`{:ok, turn_id}` — it does *not* block until the agent finishes.

`ask/3` is a convenience wrapper for callers that want request/response
semantics (tests, HTTP API):

```elixir
def ask(session, content, opts \\ []) do
  subscribe(session)
  {:ok, turn_id} = submit(session, content, opts)
  result = receive_until_done(turn_id)
  unsubscribe(session)
  result
end

defp receive_until_done(turn_id) do
  receive do
    {:session_event, _sid, ^turn_id, %{type: :turn_finished, result: result}} ->
      result
  end
end
```

### `Rho.Session.Server` — per-session GenServer

Renamed from `Worker`. Owns everything about a session's runtime state.

```elixir
defstruct [
  :session_id,
  :workspace,
  :memory_mod,
  :memory_ref,
  :agent_name,
  :task_ref,        # monitor ref for current turn task
  :task_pid,        # pid for cancellation
  :current_turn_id, # string, for event correlation
  status: :idle,    # :idle | :busy | :cancelling
  queue: :queue.new(),
  subscribers: %{}  # %{pid => monitor_ref}
]
```

**Removed fields:** `channel`, `chat_id` (dead state), `caller` (no longer
blocking on GenServer.reply).

#### Subscriber management

```elixir
def handle_call({:subscribe, pid}, _from, state) do
  if Map.has_key?(state.subscribers, pid) do
    {:reply, :ok, state}
  else
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end
end

def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
  {_ref, subscribers} = Map.pop(state.subscribers, pid)
  {:noreply, %{state | subscribers: subscribers}}
end
```

#### Event broadcast

The Session GenServer does **not** broadcast events itself during a turn.
Instead, it snapshots the subscriber list when starting the turn and passes
it to the Task. The Task sends directly to subscribers — no GenServer hop,
no bottleneck, and all per-turn events come from one process (guaranteed
ordering).

```elixir
defp start_turn(content, opts, state) do
  turn_id = new_turn_id()
  session_id = state.session_id
  subscriber_pids = Map.keys(state.subscribers)

  emit = fn event ->
    tagged = Map.merge(event, %{turn_id: turn_id})
    for pid <- subscriber_pids do
      send(pid, {:session_event, session_id, turn_id, tagged})
    end
    :ok
  end

  config = Rho.Config.agent(state.agent_name)
  model = opts[:model] || config.model
  tools = resolve_all_tools(state, depth: opts[:depth] || 0)

  agent_opts = [
    system_prompt: opts[:system_prompt] || config.system_prompt,
    tools: tools,
    agent_name: state.agent_name,
    max_steps: opts[:max_steps] || config.max_steps,
    tape_name: state.memory_ref,
    memory_mod: state.memory_mod,
    emit: emit,
    workspace: state.workspace
  ]
  |> maybe_put(:provider, config.provider)

  messages = [ReqLLM.Context.user(content)]

  task = Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
    emit.(%{type: :turn_started})
    result = Rho.AgentLoop.run(model, messages, agent_opts)
    emit.(%{type: :turn_finished, result: result})
    result
  end)

  %{state |
    status: :busy,
    task_ref: task.ref,
    task_pid: task.pid,
    current_turn_id: turn_id
  }
end
```

**Why snapshot subscribers:** Subscribers added mid-turn won't get partial
events (which would be confusing). They'll get events starting from the next
turn. This is the correct semantic — a turn is an atomic unit of observation.

**Late subscriber caveat:** A subscriber that joins after `submit` but before
the Task starts could miss `turn_started`. This is acceptable — `subscribe`
before `submit` is the documented contract.

#### Turn completion signaling (inspired by Bub's `lifespan`)

Bub's `CliChannel` uses a `lifespan` context manager attached to the message
itself — when the framework finishes processing (including error paths), the
lifespan exits and signals the CLI to show the next prompt. This is elegant
because it guarantees cleanup regardless of success/failure path.

In Rho's OTP model, the equivalent is the subscriber event stream: the Session
Task always emits `:turn_finished` (with `result: {:ok, _}` or `{:error, _}`)
as its final act, and `:turn_cancelled` from the Server on cancel. The CLI
adapter watches for these to release the REPL prompt — same guarantee, adapted
for processes instead of context managers.

#### Cancel with `:cancelling` state

```elixir
def handle_cast(:cancel, %{status: :busy, task_pid: pid} = state) when is_pid(pid) do
  Process.exit(pid, :shutdown)
  {:noreply, %{state | status: :cancelling}}
end

# Task death confirmed — safe to proceed
def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref, status: :cancelling} = state) do
  broadcast(state, %{type: :turn_cancelled, turn_id: state.current_turn_id})
  state = %{state | status: :idle, task_ref: nil, task_pid: nil, current_turn_id: nil}
  state = process_queue(state)
  {:noreply, state}
end
```

The `:cancelling` state ensures no queue processing until the task is confirmed
dead. No interleaved turns. No stale events.

#### `submit` is a short `call`

```elixir
def handle_call({:submit, content, opts}, _from, %{status: :idle} = state) do
  state = start_turn(content, opts, state)
  {:reply, {:ok, state.current_turn_id}, state}
end

def handle_call({:submit, content, opts}, _from, state) do
  turn_id = new_turn_id()
  state = %{state | queue: :queue.in({content, opts, turn_id}, state.queue)}
  broadcast(state, %{type: :queued, turn_id: turn_id, position: :queue.len(state.queue)})
  {:reply, {:ok, turn_id}, state}
end
```

No caller field. No `GenServer.reply` later. The call returns immediately.
Callers observe completion via subscription events.

#### Commands

Commands (`send_command`) currently bypass queueing and run while a turn is
active. This risks races against the running loop (concurrent tape writes).
Two options:

1. **Queue commands like messages** — simplest, safest
2. **Keep commands out-of-band** but acknowledge the race — document it

For now: queue commands. They're rare and the sequencing guarantee is worth it.

### AgentLoop — single `emit` callback

Replace the `on_event` + `on_text` split with a single `emit` callback.
All events go through it, including text deltas.

```elixir
def run(model, messages, opts \\ []) do
  emit = opts[:emit] || fn _ -> :ok end
  # ... rest of setup ...

  loop_opts = %{
    emit: emit,
    tape_name: tape_name,
    memory_mod: memory_mod,
    # ... no on_event, no on_text ...
  }
end
```

**Text streaming** — what was `on_text`:

```elixir
# In process_stream:
process_opts = [on_result: fn chunk -> emit.(%{type: :text_delta, text: chunk}) end]

case ReqLLM.StreamResponse.process_stream(stream_response, process_opts) do
  {:ok, response} ->
    # No IO.puts("") — that was a terminal assumption
    # ...
```

**Tool events** — what was `on_event`:

```elixir
defp emit_event(event, %{emit: emit, tape_name: tape_name, memory_mod: memory_mod}) do
  # 1. Write to tape (deterministic, always)
  if tape_name, do: memory_mod.append_from_event(tape_name, event)

  # 2. Broadcast to subscribers (observation, no override)
  emit.(event)
end
```

**Override semantics** — `HookRuntime.dispatch_event/1` can still return
`{:override, result}` for `:tool_result` events. This happens **inside
AgentLoop, before `emit`**. The emit callback sees the effective result only.
No override returns from `emit` — it always returns `:ok`.

```elixir
# Tool result flow:
raw_result = tool_def.execute.(args)

# 1. HookRuntime override (control flow)
effective_result = case Rho.HookRuntime.dispatch_event(%{type: :tool_result, ...}) do
  {:override, override} -> override
  _ -> raw_result
end

# 2. Emit effective event (observation only)
emit_event(%{type: :tool_result, output: effective_result, ...}, loop_opts)

# 3. Feed effective result to LLM
ReqLLM.Context.tool_result(call_id, effective_result)
```

**Deleted from AgentLoop:**
- `default_on_event/1` and all its clauses
- `format_args/1`
- `print_tool_output/1`
- `if on_text_cb, do: IO.puts("")`
- `on_event` fallback to `&default_on_event/1`
- `{:override, result}` return handling from `emit_event`

### CLI adapter (modeled after Bub's `CliChannel` + `CliRenderer`)

Bub keeps the CLI channel and its renderer as a self-contained package
(`bub/channels/cli/`). The channel owns the REPL loop, the renderer, and
the turn-completion signaling. Agent/framework code never imports the renderer.

Rho's CLI adapter follows the same pattern:
1. Runs the REPL loop (blocking `IO.gets` — Bub uses `prompt_toolkit`)
2. Talks to `Rho.Session` directly (Bub calls `on_receive`)
3. Subscribes to session events (Bub uses `lifespan` context manager)
4. Renders events with ANSI formatting (Bub has `CliRenderer` with Rich)

```elixir
defmodule Rho.CLI do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(opts) do
    {:ok, %{session_id: nil, repl_pid: nil, current_turn_id: nil, opts: opts}}
  end

  def handle_cast({:start, session_id, stop_event, opts}, state) do
    # Ensure session exists
    {:ok, _pid} = Rho.Session.ensure_started(session_id, opts)

    # Subscribe this GenServer to session events
    Rho.Session.subscribe(session_id)

    # Start REPL loop
    gl = opts[:group_leader]
    parent = self()
    repl_pid = spawn_link(fn ->
      if gl, do: Process.group_leader(self(), gl)
      repl_loop(parent, session_id, stop_event)
    end)

    {:noreply, %{state | session_id: session_id, repl_pid: repl_pid}}
  end

  # Render events from session
  def handle_info({:session_event, _sid, turn_id, event}, state) do
    render(event)

    # Release REPL prompt on turn completion
    if event.type in [:turn_finished, :turn_cancelled] and turn_id == state.current_turn_id do
      if state.repl_pid, do: send(state.repl_pid, :prompt_ready)
      state = %{state | current_turn_id: nil}
    end

    {:noreply, state}
  end

  # REPL submitted a line
  def handle_info({:submit, content}, state) do
    {:ok, turn_id} = Rho.Session.submit(state.session_id, content)
    {:noreply, %{state | current_turn_id: turn_id}}
  end

  # --- Rendering (moved from AgentLoop.default_on_event) ---

  defp render(%{type: :text_delta, text: text}), do: IO.write(text)

  defp render(%{type: :tool_start, name: name, args: args}) do
    IO.puts(IO.ANSI.yellow() <> "  [tool] #{name}(#{format_args(args)})" <> IO.ANSI.reset())
  end

  defp render(%{type: :tool_result, status: :ok, output: output}) do
    print_tool_output(output)
  end

  defp render(%{type: :tool_result, status: :error, output: reason}) do
    IO.puts(IO.ANSI.red() <> "  [error] #{reason}" <> IO.ANSI.reset())
  end

  defp render(%{type: :llm_usage, step: step, usage: usage}) when is_map(usage) do
    input = Map.get(usage, :input_tokens, "?")
    output = Map.get(usage, :output_tokens, "?")
    IO.puts(IO.ANSI.faint() <> "  [step #{step}] tokens: #{input} in / #{output} out" <> IO.ANSI.reset())
  end

  defp render(%{type: :turn_finished}) do
    IO.puts("")
  end

  defp render(_event), do: :ok

  # --- REPL loop (runs in spawned process) ---

  defp repl_loop(parent, session_id, stop_event) do
    case IO.gets("rho> ") do
      :eof ->
        IO.puts("\nBye!")
        send(stop_event, :stop)

      input ->
        content = String.trim(input)

        if content != "" do
          send(parent, {:submit, content})

          receive do
            :prompt_ready -> :ok
          end
        end

        repl_loop(parent, session_id, stop_event)
    end
  end

  # format_args/1 and print_tool_output/1 moved here from AgentLoop
  # ...
end
```

**`mix rho.chat` simplifies to:**

```elixir
def run(args) do
  Mix.Task.run("app.start")
  {opts, _, _} = OptionParser.parse(args, ...)

  session_id = opts[:session] || "cli:default"

  IO.puts("rho — interactive chat")
  IO.puts("")

  Rho.CLI.start_repl(session_id, [
    group_leader: Process.group_leader(),
    model: opts[:model],
    # ...
  ])

  # Block until stop
  receive do
    :stop -> :ok
  end
end
```

No `Channel.Manager`. No `listen_and_run`. Direct.

### Web Socket adapter

```elixir
# On session.create / session.resume:
Rho.Session.ensure_started(session_id, workspace: workspace)
Rho.Session.subscribe(session_id)

# On message:
{:ok, turn_id} = Rho.Session.submit(session_id, content, opts)
# No Task spawn, no callbacks, no closures

# In handle_info:
def handle_info({:session_event, _sid, _turn_id, event}, state) do
  {:push, {:text, encode(event_to_json(event))}, state}
end

# On session switch: unsubscribe old, subscribe new
# On terminate: unsubscribe (or let monitor cleanup handle it)
```

### HTTP API adapter

```elixir
# Synchronous endpoint — uses ask/3
post "/sessions/:id/messages" do
  result = Rho.Session.ask(session_id, content)
  case result do
    {:ok, text} -> json(conn, 200, %{response: text})
    {:error, reason} -> json(conn, 500, %{error: to_string(reason)})
  end
end
```

### Debounce

Stays as `Rho.Channel.Debounce` (or rename to `Rho.Debounce`) but is used
by specific adapters that need it, not by a global manager. The Telegram
adapter would own its debounce instance. CLI doesn't use it. Web doesn't
use it.

---

## Event Catalog

All events are maps with a `:type` key and a `:turn_id` string.
Delivered as `{:session_event, session_id, turn_id, event}`.

| Event Type | Emitted From | Description |
|---|---|---|
| `:turn_started` | Task | Turn began processing |
| `:text_delta` | Task (via emit) | Streaming text chunk from LLM |
| `:step_start` | Task (via emit) | Beginning of a loop iteration |
| `:tool_start` | Task (via emit) | Tool invocation starting |
| `:tool_result` | Task (via emit) | Tool execution completed (post-override) |
| `:llm_text` | Task (via emit) | Text emitted alongside tool calls |
| `:llm_usage` | Task (via emit) | Token usage stats for a step |
| `:compact` | Task (via emit) | Tape compaction occurred |
| `:error` | Task (via emit) | LLM call or stream error |
| `:turn_finished` | Task | Turn completed, carries `result` |
| `:turn_cancelled` | Server | Turn was cancelled |
| `:queued` | Server | Input queued behind active turn |
| `:command_result` | Server/Task | Direct tool command result |

**Ordering guarantee:** All per-turn events (`:turn_started` through
`:turn_finished`) come from the same Task process — BEAM per-sender ordering
guarantees subscribers receive them in sequence.

Server-level events (`:queued`, `:turn_cancelled`) come from the GenServer
and may interleave with turn events from a different sender. This is fine —
they are metadata about the session, not part of the turn stream.

**`turn_id`:** String-based (`System.unique_integer([:positive]) |> Integer.to_string()`).
JSON-encodable, log-friendly.

---

## Implementation Plan

### Phase 0: Fix Worker task lifecycle

No new abstractions. Just fix the broken cancel.

- Replace `Task.async/1` with `Task.Supervisor.async_nolink/2`
- Store `task_pid` alongside `task_ref`
- Add `:cancelling` status — cancel kills task, waits for `{:DOWN}` before
  processing queue
- Keep everything else the same

**Files changed:** `lib/rho/session/worker.ex`

### Phase 1: Create `Rho.Session` facade + subscriber support

- Create `Rho.Session` module with the public API
- Add subscriber management to Worker (subscribe/unsubscribe/monitor/broadcast)
- Add `submit/3` (async) alongside existing `send_message/3` (sync)
- Add `ask/3` as sync wrapper over subscribe+submit
- Rename `Worker` → `Server` (optional, can defer)

Existing callers (`SessionRouter.route_message`, `Worker.send_message`) keep
working. New code can use `Rho.Session` API.

**Files changed:**
- `lib/rho/session.ex` (new)
- `lib/rho/session/worker.ex` (subscriber support, submit)

### Phase 2: Unify AgentLoop to single `emit` callback

- Replace `on_event` + `on_text` with single `emit` callback
- Remove `default_on_event`, `format_args`, `print_tool_output` from AgentLoop
- Remove `IO.puts("")` after streaming
- Remove `{:override, result}` return from emit — overrides stay in
  HookRuntime, before emit
- `emit` defaults to `fn _ -> :ok end`
- Update Worker to construct `emit` callback that broadcasts to subscribers

**Files changed:**
- `lib/rho/agent_loop.ex`
- `lib/rho/session/worker.ex`

### Phase 3: Migrate Web Socket to `Rho.Session` API

- Socket uses `Rho.Session.ensure_started` + `subscribe` + `submit`
- Handle `{:session_event, ...}` in `handle_info` for rendering
- Remove Task spawn with callback closures
- Remove `{:agent_text, ...}`, `{:agent_event, ...}`, `{:agent_done, ...}` handlers
- Remove `task_ref` from socket state
- Unsubscribe on session switch and terminate

**Files changed:**
- `lib/rho/web/socket.ex`
- `lib/rho/web/api_router.ex` (use `Rho.Session.ask` for sync endpoint)

### Phase 4: Migrate CLI to `Rho.Session` API

- CLI GenServer subscribes to session, renders events in `handle_info`
- REPL loop sends `{:submit, content}` to GenServer; waits for `:prompt_ready`
- GenServer sends `:prompt_ready` on `:turn_finished`/`:turn_cancelled`
- Move rendering logic from AgentLoop into CLI
- Verify group leader for GenServer IO (may need to set in `handle_cast`)
- Remove `on_text`/`on_done` from message context

**Files changed:**
- `lib/rho/channel/cli.ex` (or rename to `lib/rho/cli.ex`)
- `lib/mix/tasks/rho.chat.ex`

### Phase 5: Delete dead infrastructure

Now that both adapters use `Rho.Session` directly:

- Delete `Rho.Channel.Manager`
- Delete `Rho.Channel.Message`
- Delete `Rho.SessionRouter`
- Delete `Rho.Channel` behaviour
- Delete `Rho.Channel.Web`
- Delete `Rho.Web.ClientRegistry`
- Delete `Rho.Channel.Supervisor` (move debounce supervisor if still needed)
- Remove `:on_text`, `:on_event` from any remaining opts/passthrough
- Remove `channel`, `chat_id` from Session.Server state
- Update `application.ex` supervision tree
- Update tests

**Files deleted:**
- `lib/rho/channel/manager.ex`
- `lib/rho/channel/message.ex`
- `lib/rho/session_router.ex`
- `lib/rho/channel.ex`
- `lib/rho/channel/web.ex`
- `lib/rho/channel/supervisor.ex`

**Files changed:**
- `lib/rho/application.ex`
- `lib/rho/session/worker.ex` (remove dead fields)
- Tests

---

## Migration Safety

Each phase is independently deployable:

| Phase | Risk | What breaks if wrong |
|---|---|---|
| 0 | Low | Cancel semantics only |
| 1 | Low — additive | Nothing; new API alongside old |
| 2 | Medium | AgentLoop callers need updating; dual-path during migration |
| 3 | Medium | Web output; but isolated to socket.ex |
| 4 | Medium | CLI output; but isolated to cli.ex |
| 5 | Low — deletion | Compile errors guide you to stragglers |

### Key Invariants

- **Subscribe before submit**: callers must subscribe before submitting to
  avoid missing events (especially `turn_finished`)
- **Single-sender ordering**: all per-turn events from the Task process
- **Emit is observation-only**: no override returns, no control flow
- **Snapshot subscribers at turn start**: mid-turn subscriber changes take
  effect on next turn
- **Cancel waits for death**: `:cancelling` state blocks queue processing
  until `{:DOWN}` confirms task termination

### Known Limitations

- **No replay**: late subscribers get nothing. History still via
  `memory_mod.history/1`.
- **No backpressure**: slow subscribers accumulate messages. Acceptable at
  current scale.
- **Subscriber snapshot is per-turn**: a subscriber added after `submit`
  won't see that turn's events. This is a feature (consistent observation),
  not a bug.
- **Session identity**: the default session resolution (`"cli:default"`)
  is adapter-chosen, not architecture-imposed. Multi-adapter observation
  of the same session requires sharing a session_id explicitly.

---

## Comparison: Bub → Rho Before → Rho After

### Bub (Python, clean separation)

```
CliChannel._main_loop (owns REPL + CliRenderer)
  → on_receive(message)  (no callbacks in message)
    → ChannelManager queue
      → framework.process_inbound(message)
        → hooks pipeline (resolve → build → run_model → render → dispatch)
          → Agent._agent_loop (no display code)
        → channel.send(outbound)
  → lifespan exits → prompt released
```

### Rho Before (6 layers, callbacks threaded)

```
mix rho.chat
  → Channel.Manager.listen_and_run
    → Channel.Manager.on_receive
      → route_async (Task)
        → SessionRouter.route_message
          → merge_context_overrides (on_text, on_event)
          → Worker.send_message (blocks)
            → AgentLoop (on_text callback, on_event callback, default_on_event)
```

### Rho After (2 layers, events broadcast — Bub's separation + OTP concurrency)

```
CLI / Web Socket / HTTP
  → Rho.Session.submit (returns immediately)
    → Session.Server starts Task
      → AgentLoop (single emit callback, no display logic)
        → events sent directly to subscriber pids
  → adapter renders events (CLI: ANSI, Web: JSON)
  → :turn_finished releases prompt (like Bub's lifespan)
```

12 modules → 5 modules. 6 layers → 2 layers. Callbacks → plain messages.
Same separation Bub has, adapted for OTP.
