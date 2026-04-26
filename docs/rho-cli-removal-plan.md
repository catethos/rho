# `apps/rho_cli` Removal Plan

**Date:** 2026-04-26 · **Branch:** `refactor` (continues from combined-simplification-plan)

---

## Purpose

`apps/rho_cli` is a misnomer — it's a mixed-concerns app where ~70% of the
code has nothing to do with a CLI. It exists for historical reasons: it
was the first place an interactive REPL was needed, and config-loading
ended up there because it was needed to drive the REPL.

The actual CLI surface (`Rho.CLI.Repl`, `Rho.CLI.CommandParser`,
`mix rho.chat`) is now redundant — `apps/rho_web` provides the user
interface and `Rho.Session.start/2` is the programmatic entry point.

**The blocker we want to remove:**

```elixir
# apps/rho/lib/rho/config.ex — runtime-discovery shim, lines 31-37
def agent_config(name \\ :default) do
  if cli_config_available?() do
    Rho.CLI.Config.agent(name)        # ← reaches up the dep graph
  else
    default_agent_config()
  end
end
```

`apps/rho` (core) has to discover `apps/rho_cli` (presentation) at runtime
because config-loading lives in the wrong layer. Same shim exists in
`Rho.Session.start/2` for `Rho.RunSpec.FromConfig`. Killing `apps/rho_cli`
puts the loader where it belongs (in core) and removes both shims.

**What this unlocks:**

- `Rho.RunSpec.FromConfig` becomes reachable from `apps/rho_stdlib`,
  which removes the layering wall blocking the migration of every
  `Supervisor.start_worker` caller to explicit RunSpecs (the option B
  we previously rejected — see combined-simplification-plan.md).
- The `build_default_run_spec/2` synthesizer in `Rho.Agent.Worker`
  can be deleted after that migration.

---

## Inventory: what's in `apps/rho_cli` today

| File | Lines | Concern | Disposition |
|------|-------|---------|-------------|
| `lib/rho/cli/config.ex` | ~150 | `.rho.exs` loader | **Move** → `apps/rho` as `Rho.AgentConfig` |
| `lib/rho/run_spec/from_config.ex` | ~65 | declarative config → RunSpec | **Move** → `apps/rho` as `Rho.RunSpec.FromConfig` |
| `lib/rho/cli/application.ex` | ~155 | Dotenvy + plugin/transformer registration + Python init | **Split** → some to `apps/rho/Application`, plugin registration to `apps/rho_stdlib/Application`, Python init to `apps/rho_stdlib/Application` |
| `lib/rho/cli/repl.ex` | ~? | interactive REPL | **Delete** |
| `lib/rho/cli/command_parser.ex` | ~? | `,bash ls` parsing for REPL | **Delete** |
| `test/rho/cli/command_parser_test.exs` | ~? | tests for the above | **Delete** |
| `lib/mix/tasks/rho.chat.ex` | ~50 | launches REPL | **Delete** (depends on REPL) |
| `lib/mix/tasks/rho.run.ex` | ~? | one-shot message | **Move** → `apps/rho/lib/mix/tasks/` |
| `lib/mix/tasks/rho.trace.ex` | ~? | tape analysis | **Move** → `apps/rho/lib/mix/tasks/` |
| `lib/mix/tasks/rho.smoke.ex` | ~25 | `mix test` wrapper | **Move** → `apps/rho/lib/mix/tasks/` |
| `lib/mix/tasks/rho.verify.ex` | ~20 | `mix test` wrapper | **Move** → `apps/rho/lib/mix/tasks/` |
| `mix.exs` | — | app definition | **Delete** with the app |

**External callers of `Rho.CLI.*` (must be updated):**

| File | Line | Reference |
|------|------|-----------|
| `apps/rho/lib/rho/config.ex` | 12, 33, 44, 54-56, 79, 86-87 | runtime-discovery shim |
| `apps/rho/lib/rho/session.ex` | 11, 119-121 | runtime-discovery shim for `RunSpec.FromConfig` |
| `apps/rho/lib/rho/run_spec.ex` | 14 | docstring example |
| `apps/rho_web/lib/rho_web/live/app_live.ex` | 2363 | `Rho.CLI.Config.agent_names()` |
| `apps/rho_web/lib/rho_web/live/session_live.ex` | 225 | `Rho.CLI.Config.agent_names()` |
| `apps/rho_web/lib/rho_web/live/session_live/layout_components.ex` | 353 | `Rho.CLI.Config.agent_names()` |
| `apps/rho_web/mix.exs` | — | `{:rho_cli, in_umbrella: true}` dep |

---

## Target state

```
apps/
├── rho/                # core runtime + config loading + mix tasks
│   ├── lib/rho/
│   │   ├── agent_config.ex          # was Rho.CLI.Config
│   │   ├── run_spec/from_config.ex  # moved from rho_cli
│   │   ├── config.ex                # simplified — no runtime-discovery shims
│   │   └── ...
│   └── lib/mix/tasks/
│       ├── rho.run.ex
│       ├── rho.trace.ex
│       ├── rho.smoke.ex
│       └── rho.verify.ex
├── rho_stdlib/         # tools + plugin registration on boot
│   └── lib/rho/stdlib/
│       └── application.ex           # adds plugin registration + Python init
├── rho_web/            # user interface (no longer depends on rho_cli)
└── rho_frameworks/     # domain
```

**Dependency graph after:**

```
rho ← rho_stdlib ← rho_web ← rho_frameworks
                    ↘
                     rho_frameworks
```

(Was: `rho ← rho_stdlib ← rho_cli ← rho_web → rho_frameworks`.)

---

## Migration phases

Each phase is independently committable and leaves the umbrella in a
green state (compiles + tests pass). Order matters — earlier phases
unblock later ones.

### Phase 1: Move config loader to `apps/rho`

**Goal:** `Rho.CLI.Config` → `Rho.AgentConfig` in `apps/rho`. No
runtime-discovery shims for config.

1. Copy `apps/rho_cli/lib/rho/cli/config.ex` →
   `apps/rho/lib/rho/agent_config.ex`. Rename module to `Rho.AgentConfig`.
2. Update `apps/rho/lib/rho/config.ex`:
   - Replace runtime discovery (`Code.ensure_loaded?(Rho.CLI.Config)`)
     with direct calls to `Rho.AgentConfig`.
   - Remove the `default_agent_config/0` fallback — `AgentConfig.agent/1`
     already returns sensible defaults when `.rho.exs` is missing.
   - Drop `@compile {:no_warn_undefined, ...}` — no longer needed.
3. Replace `Rho.CLI.Config` references in:
   - `apps/rho/lib/rho/config.ex`
   - `apps/rho_web/lib/rho_web/live/app_live.ex:2363`
   - `apps/rho_web/lib/rho_web/live/session_live.ex:225`
   - `apps/rho_web/lib/rho_web/live/session_live/layout_components.ex:353`
4. Keep `Rho.CLI.Config` as a thin alias delegating to `Rho.AgentConfig`
   for the duration of `apps/rho_cli` (makes the rest of the migration
   incremental). It will be deleted with the app in Phase 6.

**Verify:** `mix compile --warnings-as-errors && mix test` umbrella-wide.

### Phase 2: Move `Rho.RunSpec.FromConfig` to `apps/rho`

**Goal:** Remove the `Rho.RunSpec.FromConfig` runtime-discovery shim
from `Rho.Session.start/2`.

1. Move `apps/rho_cli/lib/rho/run_spec/from_config.ex` →
   `apps/rho/lib/rho/run_spec/from_config.ex`. Update `alias` to
   `Rho.AgentConfig` (was `Rho.CLI.Config`).
2. Update `apps/rho/lib/rho/session.ex`:
   - Remove `@compile {:no_warn_undefined, Rho.RunSpec.FromConfig}`.
   - Remove the `Code.ensure_loaded?` shim (lines 119-121).
   - Call `Rho.RunSpec.FromConfig.build/2` directly.
3. Update the docstring in `apps/rho/lib/rho/run_spec.ex` (the
   `:coder` example).

**Verify:** `mix compile --warnings-as-errors && mix test`.

### Phase 3: Redistribute Application boot work

**Goal:** Move what `Rho.CLI.Application.start/2` does into the right
apps so deleting `apps/rho_cli` doesn't lose any runtime setup.

**Current responsibilities of `Rho.CLI.Application.start/2`:**

| Action | New home |
|--------|----------|
| `Dotenvy.source([".env", DOTENV_FILE])` | `Rho.Application.start/2` (apps/rho — env loading is core, needed before any agent runs) |
| `Rho.Stdlib.Skill.Loader.init_cache_table()` | `Rho.Stdlib.Application.start/2` (already starts skill-related state) |
| Plugin registration loop (`Rho.PluginRegistry.register/2`) | `Rho.Stdlib.Application.start/2` — owns the registry already |
| Transformer registration | Same — `Rho.Stdlib.Application.start/2` |
| `maybe_init_python` (Pythonx for `:python` tool) | `Rho.Stdlib.Application.start/2` — Python tool is stdlib |
| `maybe_init_erlang_python` (for `:py_agent` plugin) | `Rho.Stdlib.Application.start/2` |
| `prep_stop` (graceful agent shutdown) | `Rho.Application.prep_stop/1` — agents live in apps/rho |

**Care points:**

- The `register_builtin_plugins/0` loop reads `.rho.exs` (via
  `Rho.AgentConfig.agent_names()` after Phase 1). When this moves to
  `Rho.Stdlib.Application`, it pulls the dependency `rho_stdlib → rho`
  through `Rho.AgentConfig` — which is fine, that direction is already
  established. Verify no circular deps.
- `Pythonx.uv_init/1` is currently called from `Rho.CLI.Application`
  but `Pythonx` lives in `apps/rho_stdlib` deps. Moving the init call
  to `Rho.Stdlib.Application` is more natural.

**Verify:** Boot the umbrella in `iex -S mix`, confirm:
- Plugins are registered (`Rho.PluginRegistry.list/0`)
- Python is initialized if any agent uses `:python`
- `.env` values are loaded
- `mix test` umbrella-wide passes

### Phase 4: Move keep-worthy mix tasks

**Goal:** Preserve `mix rho.run`, `mix rho.trace`, `mix rho.smoke`,
`mix rho.verify`. Delete `mix rho.chat` (depends on REPL).

1. Move `apps/rho_cli/lib/mix/tasks/{rho.run,rho.trace,rho.smoke,rho.verify}.ex` →
   `apps/rho/lib/mix/tasks/`.
2. Update `mix rho.run` to call `Rho.RunSpec.FromConfig.build/2` directly
   (currently uses `Rho.CLI.Config.agent/1`).
3. `mix rho.trace` reads tape files — verify it has no `Rho.CLI.*` deps.
4. `mix rho.smoke` and `mix rho.verify` are pure `mix test` wrappers — no
   code changes needed.
5. **Delete** `apps/rho_cli/lib/mix/tasks/rho.chat.ex`.

**Verify:** `mix rho.smoke`, `mix rho.run "hello"`, `mix rho.trace summary`
all run without errors.

### Phase 5: Delete REPL + CommandParser

**Goal:** Remove the actually-CLI portion. No replacement.

1. Delete `apps/rho_cli/lib/rho/cli/repl.ex`.
2. Delete `apps/rho_cli/lib/rho/cli/command_parser.ex`.
3. Delete `apps/rho_cli/test/rho/cli/command_parser_test.exs`.
4. Remove the runtime-discovery shim for `Rho.CLI.CommandParser` in
   `apps/rho/lib/rho/config.ex` (`parse_command/1`, lines 53-60).
   Check whether `parse_command/1` has any callers — if not, delete the
   function.

**Verify:** `mix compile --warnings-as-errors && mix test`.

### Phase 6: Delete `apps/rho_cli`

**Goal:** Remove the app entirely.

1. Remove the temporary `Rho.CLI.Config` alias added in Phase 1.
2. Delete `apps/rho_cli/` directory (lib/, test/, mix.exs, README if any).
3. Remove `{:rho_cli, in_umbrella: true}` from `apps/rho_web/mix.exs`.
4. Update root `mix.exs` if it references `rho_cli` anywhere.

**Verify:**
- `mix deps.get && mix compile --warnings-as-errors`
- `mix test` umbrella-wide
- `mix rho.smoke` (sanity-check the moved tasks)

### Phase 7: Update CLAUDE.md

**Goal:** Reflect the new structure.

1. Umbrella structure section: 4 apps instead of 5.
2. Drop the `apps/rho_cli/` description.
3. Move config loader doc reference under `apps/rho/`.
4. Update mix-tasks list under `apps/rho/`.
5. Drop the `Rho.CLI` plugin-module-map entry if any.

**Verify:** No `Rho.CLI` references remain anywhere outside git history.

---

## After this — what becomes possible

### Immediate follow-up: migrate every spawn site to explicit RunSpecs

This is option B from the previous discussion (combined-simplification-plan.md
"Phase 13 follow-up"). With `Rho.RunSpec.FromConfig` in `apps/rho`, the
layering wall is gone:

1. `apps/rho_web/lib/rho_web/live/app_live.ex:1342` and
   `session_live.ex:238` switch to:
   ```elixir
   spec = Rho.RunSpec.FromConfig.build(role_atom,
     workspace: File.cwd!(),
     session_id: sid,
     user_id: user_id,
     organization_id: org_id
   )
   {:ok, _pid} = Rho.Agent.Supervisor.start_worker(
     agent_id: agent_id,
     session_id: sid,
     workspace: File.cwd!(),
     agent_name: role_atom,
     role: role_atom,
     tape_ref: agent_ref,
     run_spec: spec
   )
   ```
2. `apps/rho_stdlib/lib/rho/stdlib/plugins/multi_agent.ex:558,921` switches
   the same way (now reachable since `FromConfig` is in `apps/rho`).
3. `apps/rho_frameworks/.../simulation.ex` already uses RunSpec (Phase 13).
4. Once all callers pass `:run_spec`, **delete `Rho.Agent.Worker.build_default_run_spec/2`**
   and the `||` fallback in `Worker.init`. `state.run_spec` becomes
   structurally-required, not synthesized.

### Then: simplify `Rho.Config`

After Phase 1+2 and the migration above, `Rho.Config` shrinks to maybe
two functions: `tape_module/0` and `capabilities_from_plugins/1`. Most of
its current surface area is the runtime-discovery shim infrastructure
that disappears with `apps/rho_cli`.

Consider whether `Rho.Config` is even needed as a separate module after
this — `tape_module/0` could move to `Rho.Tape`, capabilities to
`Rho.Stdlib`. That decision is downstream.

### Optional cleanup: `Rho.Runner.run/3` (legacy 3-arity)

Currently kept for direct test usage. After the spawn-site migration,
audit whether tests can be moved to `Runner.run/2` with `RunSpec.build/1`.
If yes, drop the 3-arity form and `build_runtime/3` + `build_context_struct/4`
in `apps/rho/lib/rho/runner.ex` (~50 LOC).

---

## Risk assessment

| Risk | Mitigation |
|------|-----------|
| Plugin-registration ordering — boot-time race between `Rho.PluginRegistry` startup and `register_builtin_plugins/0` | Both start in `Rho.Application` / `Rho.Stdlib.Application`. Verify the supervision-tree order: registries start before the plugin-registration call. Today this works because `Rho.CLI.Application.start/2` runs *after* `Rho.Application` and `Rho.Stdlib.Application` are fully started — preserve that ordering by using `Application.ensure_all_started(:rho_stdlib)` or just relying on app dependency order in extra_applications. |
| `.rho.exs` discovery — `Rho.AgentConfig.load_file/0` reads from CWD; behavior must not change when run from different mix entry points | Test that `mix rho.run` and `mix test` (from umbrella root) and IEx (`-S mix`) all find the same `.rho.exs`. |
| Mix-task discovery — `mix rho.*` tasks are discovered via app loading | Tasks moved to `apps/rho` are discovered as long as `:rho` is in the umbrella. Verify with `mix help \| grep rho`. |
| Pythonx init order — `Pythonx.uv_init/1` must run before any agent that uses `:python` | Move to `Rho.Stdlib.Application.start/2`. The stdlib app starts before any LV or framework that would spawn an agent using `:python`, so this is safe. |
| Tests that exercise `Rho.CLI.*` paths | `apps/rho_cli/test/rho/cli/command_parser_test.exs` is the only one; it gets deleted with the parser. |
| In-progress branches assuming `apps/rho_cli` exists | Greenfield project, no contributors — not an issue. |

---

## Sequencing notes

- Phases 1, 2, 3 are mechanical moves with shims preserved → low risk.
- Phase 4 is also mechanical.
- Phase 5 deletes code but only code that's exclusively used by the
  about-to-be-deleted REPL.
- Phase 6 is the cliff — once the app is gone, you can't easily bring
  it back without git revert. Run the full test matrix before doing it.
- Phase 7 is documentation cleanup — do it last so the docs reflect
  the actual end state.

Estimated effort: 4-6 hours of focused work for phases 1-7. Most of it
is mechanical search/replace; the only design decisions are in Phase 3
(redistributing Application setup).
