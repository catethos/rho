> **Superseded.** `Rho.Memory` has been renamed to `Rho.Tape.Context`;
> `Rho.Memory.Tape` is now `Rho.Tape.Context.Tape`. See CLAUDE.md migration appendix.

# Pluggable Memory System

## Problem

The tape memory system is hardcoded throughout `agent_loop.ex`, `session/worker.ex`, `plugins/subagent.ex`, and the web layer. Direct calls to `Rho.Tape.Service`, `Rho.Tape.View`, `Rho.Tape.Compact`, and `Rho.Tape.Fork` make it impossible to swap in a different memory backend (vector DB, simple in-memory, external store, etc.).

## Goal

Define a `Rho.Memory` behaviour so any memory implementation can be plugged in. The current tape system becomes the default implementation. Each memory system brings its own tools (anchor, search, clear, etc.).

## Behaviour Definition

```elixir
defmodule Rho.Memory do
  @type memory_name :: String.t()
  @type entry_kind :: :message | :tool_call | :tool_result | :anchor | :event
  @type tool_def :: %{tool: ReqLLM.Tool.t(), execute: (map() -> {:ok, String.t()} | {:error, term()})}

  # --- Required ---
  @callback memory_name(session_id :: String.t(), workspace :: String.t()) :: memory_name()
  @callback bootstrap(memory_name()) :: :ok | {:ok, term()}
  @callback append(memory_name(), entry_kind(), payload :: map(), meta :: map()) :: {:ok, term()}
  @callback append_from_event(memory_name(), event :: map()) :: :ok
  @callback build_context(memory_name()) :: [map()]
  @callback provide_tools(memory_name(), context :: map()) :: [tool_def()]
  @callback info(memory_name()) :: map()
  @callback history(memory_name()) :: [map()]
  @callback reset(memory_name(), opts :: keyword()) :: :ok

  # --- Optional ---
  @callback compact_if_needed(memory_name(), opts :: keyword()) :: {:ok, :not_needed} | {:ok, term()} | {:error, term()}
  @callback search(memory_name(), query :: String.t(), limit :: integer()) :: [term()]
  @callback handoff(memory_name(), phase :: String.t(), summary :: String.t(), opts :: keyword()) :: {:ok, term()}
  @callback fork(memory_name(), opts :: keyword()) :: {:ok, memory_name()}
  @callback merge(fork_name :: memory_name(), main_name :: memory_name()) :: {:ok, integer()}
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec() | nil

  @optional_callbacks [compact_if_needed: 2, search: 3, handoff: 4, fork: 2, merge: 2, child_spec: 1]
end
```

## Phases

### Phase 0 — Create behaviour and tape adapter (no callers change)

Add new code only. Zero risk.

**Create:**
- `lib/rho/memory.ex` — behaviour definition above
- `lib/rho/memory/tape.ex` — wraps existing `Rho.Tape.*` modules, delegating each callback:
  - `memory_name/2` → `Tape.Service.session_tape/2`
  - `bootstrap/1` → `Tape.Service.ensure_bootstrap_anchor/1`
  - `append/4` → `Tape.Service.append/4`
  - `append_from_event/2` → `Tape.Service.append_from_event/2`
  - `build_context/1` → `Tape.View.default/1 |> Tape.View.to_messages/1`
  - `provide_tools/2` → returns `Anchor`, `SearchHistory`, `RecallContext`, and new `ClearMemory` tool defs
  - `compact_if_needed/2` → `Tape.Compact.run_if_needed/2`
  - `search/3` → `Tape.Service.search/3`
  - `handoff/4` → `Tape.Service.handoff/4`
  - `fork/2` → `Tape.Fork.fork/2`
  - `merge/2` → `Tape.Fork.merge/2`
  - `reset/2` → `Tape.Service.reset/2`
  - `child_spec/1` → `Rho.Tape.Store` child spec

**Modify:**
- `lib/rho/config.ex` — add `memory_module/0` that reads from config, defaults to `Rho.Memory.Tape`

### Phase 1 — Migrate Session.Worker

Replace direct tape calls in `session/worker.ex` with memory behaviour calls.

| Before | After |
|---|---|
| `Tape.Service.session_tape(sid, ws)` | `memory_mod.memory_name(sid, ws)` |
| `Tape.Service.ensure_bootstrap_anchor(name)` | `memory_mod.bootstrap(name)` |
| `Tape.Service.info(name)` | `memory_mod.info(name)` |
| `Tape.Service.append_event(name, ...)` | `memory_mod.append(name, :event, ...)` |

Store `memory_mod` in worker state. Pass it to AgentLoop via opts.

Remove `:anchor`, `:search_history`, `:recall_context` from `Config.@contextual_tools`. Instead, `Session.Worker` calls `memory_mod.provide_tools(name, ctx)` and appends those to the tool list.

### Phase 2 — Migrate AgentLoop

Replace all `Rho.Tape.*` calls in `agent_loop.ex`. The loop receives `memory_mod` and `memory_name` in opts instead of `tape_name`.

| Before | After |
|---|---|
| `Tape.Service.append(tape, :message, ...)` | `memory_mod.append(name, :message, ...)` |
| `Tape.Service.append_from_event(tape, ev)` | `memory_mod.append_from_event(name, ev)` |
| `Tape.View.default(tape) \|> View.to_messages()` | `memory_mod.build_context(name)` |
| `Tape.Compact.run_if_needed(tape, opts)` | `memory_mod.compact_if_needed(name, opts)` |

For optional callbacks, guard with `function_exported?/3`:

```elixir
if function_exported?(memory_mod, :compact_if_needed, 2) do
  memory_mod.compact_if_needed(memory_name, opts)
else
  {:ok, :not_needed}
end
```

### Phase 3 — Migrate Subagent Plugin

Thread `memory_mod` through hook context into `plugins/subagent.ex` and `subagent/worker.ex`.

| Before | After |
|---|---|
| `Tape.Fork.fork(parent)` | `memory_mod.fork(parent)` |
| `Tape.Fork.merge(fork, main)` | `memory_mod.merge(fork, main)` |
| `Tape.Service.ensure_bootstrap_anchor(name)` | `memory_mod.bootstrap(name)` |

Fall back to fresh (non-forked) memory for implementations that don't support `fork/2`.

### Phase 4 — Migrate Web Layer

Route `web/socket.ex` and `web/api_router.ex` through `Session.Worker` instead of calling tape directly.

- Add `Session.Worker.history/1` and `Session.Worker.handoff/3` public API
- Socket and API router call Session.Worker, never memory modules directly

### Phase 5 — Migrate Application Supervisor

In `application.ex`, replace hardcoded `Rho.Tape.Store` child:

```elixir
memory_mod = Rho.Config.memory_module()
memory_children =
  if function_exported?(memory_mod, :child_spec, 1),
    do: [memory_mod.child_spec([])],
    else: []
```

### Phase 6 — Clean up

- Remove `provide_tape_store` from `HookSpec` (superseded by `Rho.Memory`)
- Move tape-specific tools under `lib/rho/memory/tape/` (optional, cosmetic)
- Remove tape tool atoms from `Config.@contextual_tools`

## Challenges

1. **Entry struct leakage** — `search/3` and `history/1` should return `[map()]` not `[Entry.t()]` so implementations aren't coupled to the tape entry format.

2. **Compact needs LLM access** — `compact_if_needed` receives model/gen_opts via the opts keyword. Alternative implementations may compact differently or not at all.

3. **`build_context` return type** — Must return ReqLLM message format since AgentLoop feeds it to `ReqLLM.stream_text`. This is acceptable coupling.

4. **Fork identity** — `fork/2` returns a new `memory_name` used with the same `memory_mod`. Works naturally.

## Migration Safety

Each phase is independently deployable. With `Rho.Memory.Tape` as default, behavior is identical at every step — it delegates to the exact same modules. Tests pass throughout.
