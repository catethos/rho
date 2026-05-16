> **Completed.** `Rho.Session` has been collapsed into `Rho.Agent.Primary` +
> `Rho.Agent.Worker` + `Rho.Agent.Registry`. See CLAUDE.md migration appendix.

# Session collapse plan

Collapse `Rho.Session` (the single-primary-agent shim) into direct
use of `Rho.Agent.Registry` + `Rho.Agent.Worker`.

The bus topic is already `rho.session.<sid>.events.*` — `<sid>` is the
namespace. `Rho.Session` is a leftover indirection that hides the
registry behind a primary-agent-only façade.

`Rho.Session.EventLog`, `Rho.Session.EventLog.Supervisor`,
`Rho.Session.BusParityTest`, etc. are nested modules that only share
the namespace prefix; they are not affected.

---

## 1. Audit — every `Rho.Session.*` callsite

### In `lib/`

| function | callsite | replacement |
|---|---|---|
| `ensure_started/2` | `lib/rho_web/observatory_api.ex:183,199,222` | new `Rho.Agent.Primary.ensure_started/2` (or equivalent — see §5) |
| `ensure_started/2` | `lib/rho_web/live/session_live.ex:115,203,659` | same |
| `ensure_started/2` | `lib/rho_web/live/spreadsheet_live.ex:623,630` | same |
| `ensure_started/2` | `lib/rho/cli.ex:44` | same |
| `whereis/1` | `lib/rho_web/observatory_api.ex:180` | `Rho.Agent.Worker.whereis("primary_" <> sid)` |
| `submit/3` | `lib/rho_web/observatory_api.ex:184,188,232` | resolve pid + `Worker.submit/3` |
| `submit/3` | `lib/rho_web/live/session_live.ex:159` | same |
| `submit/3` | `lib/rho_web/live/spreadsheet_live.ex:604` | same |
| `submit/3` | `lib/rho/cli.ex:97` | same |
| `submit/3` | `lib/rho/debounce.ex:88` | same |
| `ask/3` | `lib/rho_web/observatory_api.ex:202` | new `Worker.ask/2` (see §3) |
| `inject/4` | `lib/rho_web/observatory_api.ex:251` | keep logic, move to `Rho.Agent.Primary` or inline in caller |
| `list/1` | `lib/rho_web/observatory_api.ex:68` | `Rho.Agent.Registry.find_by_session/1` + filter `role == :primary` |
| `list/1` | `lib/rho_web/live/observatory_live.ex:422` | same |
| `stop/1` | `lib/rho_web/live/session_live.ex:289` | loop `Registry.list_all/1` + `GenServer.stop` — extract into small helper or inline |
| `new_agent_id/0` | `lib/rho_web/observatory_api.ex:218` | inline: `"agent_" <> Integer.to_string(:erlang.unique_integer([:positive]))` or keep as `Rho.Agent.Worker.new_id/0` |
| `new_agent_id/0` | `lib/rho_web/live/session_live.ex:212` | same |
| `new_agent_id/0` | `lib/rho/demos/hiring/simulation.ex:92` | same |
| `new_agent_id/0` | `lib/rho/mounts/multi_agent.ex:737` | same |
| `resolve_id/1` | (no `lib/` callers — only `test/rho/session_test.exs`) | delete with `Rho.Session` |
| `info/1` | (no `lib/` callers) | delete |
| `event_log_path/1` | (no `lib/` callers outside README) | callers can use `Rho.Session.EventLog.path/1` directly |

### In `test/`

| function | callsite |
|---|---|
| `ensure_started`, `stop` | `test/rho_web/observatory_api_test.exs:128,139,150` |
| `ensure_started`, `stop` | `test/rho/session/bus_parity_test.exs:61,65` |
| `ensure_started`, `whereis`, `info`, `resolve_id`, `list` | `test/rho/session_test.exs` (regression suite) |

### Compact primitive set

Every `Session.*` call reduces to one of these primitives:

1. Start/find the primary agent for `sid` (`ensure_started/2`, `whereis/1`).
2. Control the primary worker by `sid` → resolve pid, then call `Worker.submit/3` / `Worker.cancel/1` / `Worker.info/1`.
3. List primary agents, optionally by session_id prefix.
4. Ask (synchronous round-trip).
5. Stop all agents in a session.
6. Generate a fresh agent id.

Steps 2, 4, 5, 6 belong on `Rho.Agent.Worker` / `Rho.Agent.Registry`.
Step 1 and 3 need a thin new helper — proposed name `Rho.Agent.Primary`
(one module, 3 functions: `ensure_started/2`, `whereis/1`, `list/1`).
It contains the `"primary_" <> sid` convention so callers stop hard-
coding it.

---

## 2. Registry prefix-query API

**Proposed**: `Rho.Agent.Registry.find_by_session/1` (new).

```elixir
@doc """
Return `[{agent_id, pid}]` for all live agents whose `session_id`
equals the given value. Exact match (not prefix) — use `where/2`
variants for prefix queries.
"""
@spec find_by_session(String.t()) :: [{String.t(), pid()}]
def find_by_session(session_id)
```

**ETS key shape — no change needed.** The existing schema
`{agent_id, %{session_id: ..., pid: ..., ...}}` already supports the
query via `:ets.select/2` match-specs keyed on `:map_get/2` of
`:session_id`. We already do exactly this in `list/1`, `count/1`,
`list_except/2`, etc.

For the required "return `[{agent_id, pid}]`" shape the match-spec is:

```elixir
spec = [
  {{:"$1", :"$2"},
   [{:andalso, {:==, {:map_get, :session_id, :"$2"}, session_id}, live_guard()}],
   [{{:"$1", {:map_get, :pid, :"$2"}}}]}
]
:ets.select(@table, spec)
```

**Prefix matching** (needed by current `Session.list(prefix: p)`):
ETS match-specs cannot do string prefix ops directly on a `set` table.
Options:

- **(A) Scan + post-filter in Elixir.** Cheap — agent count is small
  (≤ a few dozen per session, tens of sessions). Use the existing
  select-all + `String.starts_with?/2` filter that `Session.list/1`
  already uses. Recommended.
- (B) Switch to `ordered_set` + range queries. Rejected: much bigger
  change for a non-hot path.

**Decision:** add two functions.

```elixir
@spec find_by_session(String.t()) :: [{String.t(), pid()}]
def find_by_session(session_id)

@spec find_by_session_prefix(String.t()) :: [map()]   # returns entries
def find_by_session_prefix(prefix)
```

`find_by_session/1` is the primary new API the task calls for.
`find_by_session_prefix/1` lives alongside `list/1`/`list_all/1` (it
returns entries, not `{id, pid}` tuples) and absorbs the body of
`Session.list/1`.

---

## 3. `Worker.ask/2` design

**Signature**: `Worker.ask(pid_or_agent_id, content, opts \\ [])`.

```elixir
def ask(target, content, opts \\ []) do
  pid = resolve(target)
  session_id = info(pid).session_id
  {:ok, sub_id} = Rho.Comms.subscribe("rho.session.#{session_id}.events.turn_finished")
  {:ok, turn_id} = submit(pid, content, opts)
  await_mode = Keyword.get(opts, :await, :turn)
  result = await_reply(turn_id, await_mode)
  Rho.Comms.unsubscribe(sub_id)
  result
end
```

The body is a direct move of `Session.ask/3` +
`receive_until_done/2` + `receive_until_finish/1`. Bus-only delivery
preserved — the caller subscribes to a bus topic and receives
`{:signal, %Jido.Signal{}}` messages. No direct-pid messaging
reintroduced.

Subtlety: the subscribe **must happen before** `submit` to avoid a
race where a short turn finishes before the subscription is active.
`Session.ask/3` already orders these correctly; we keep the same
order.

Keep `receive_until_done/2` and `receive_until_finish/1` as private
helpers on `Worker`.

---

## 4. Deprecation strategy

**Recommendation: delete `Rho.Session` outright at the end of this
task** (no shim, no deprecation release cycle).

Justification:

- Small surface area. There are ~15 call-sites across `lib/` and all
  get rewritten anyway in step 4 of the implementation plan.
- Every consumer is in-repo: CLI, LiveViews, observatory API, the
  hiring demo, `multi_agent.ex`. No external callers.
- A delegated shim would silently encourage drift — new code could
  keep calling `Rho.Session` and the collapse would never finish.
- The nested modules (`Rho.Session.EventLog`, `.EventLog.Supervisor`,
  `.BusParityTest`) don't depend on `Rho.Session` as a module; they
  just share the namespace prefix. They stay put — no rename in this
  task. (Renaming them is a separate "namespace migration" task,
  explicitly out of scope.)
- Test suite `test/rho/session_test.exs` gets deleted in step 5; its
  assertions are re-expressed against the new `Rho.Agent.Primary` /
  `Rho.Agent.Registry` / `Rho.Agent.Worker` APIs in a renamed file
  `test/rho/agent/primary_test.exs`.

---

## 5. Implementation order (one commit per step)

- [x] 1. **Add `Registry.find_by_session/1` + `find_by_session_prefix/1` +
   tests.**
- [x] 2. **Add `Worker.ask/2` + tests** (move `Session.ask/3` internals).
- [x] 3. **Rewrite `Rho.Session` internals** to delegate to `Worker.ask`
   / `Registry.find_by_session_prefix`. (Collapsed into a single
   commit rather than adding `Primary` first — the delegation step
   and the caller rewrite naturally paired.)
- [x] 4. **Add `Rho.Agent.Primary` + rewrite all `lib/` callers** to hit
   `Primary` / `Worker` / `Registry` directly.
- [x] 5. **Delete `lib/rho/session.ex`** and migrate
   `test/rho/session_test.exs` → `test/rho/agent/primary_test.exs`.
- [x] 6. **Update `CLAUDE.md` §Agent System** with `Rho.Agent.Primary`,
   `Registry.find_by_session*`, and migration-appendix rows.

Done criteria: all `Rho.Session.*` references in `lib/` gone (except
the kept `Rho.Session.EventLog*` nested modules);
`mix test --seed 0` green (361 tests); CLAUDE.md updated.
