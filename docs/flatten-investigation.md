# Flatten Investigation: Should rho_stdlib + rho_cli merge into rho?

**Date:** 2026-04-25 · **Branch:** `refactor` · **Ref:** REDESIGN.md §5C

## Executive Summary

**Recommendation: Do NOT flatten.** Fix the leaky seam instead.

- **rho_stdlib → rho: No.** Would drag 6 heavy deps (pythonx, erlang_python, xlsxir, floki, live_render, yaml_elixir) into the core runtime. Destroys the "zero external tool deps" invariant.
- **rho_cli → rho: No (for now).** CLI is small (1,451 LOC, 1 unique dep: dotenvy), but REPL/boot/dotenv are entrypoint concerns, not core-runtime concerns.
- **Instead:** Remove the 3 cross-app reach-ins from `rho/lib/rho/config.ex` and `worker.ex` with explicit extension points.

---

## Summary Table

| Factor | Flatten Both | Flatten CLI Only | Fix Seam (keep 5 apps) |
|--------|:---:|:---:|:---:|
| Core stays lightweight | ✗ | ✓ | ✓ |
| "Zero tool deps" invariant | ✗ Broken | ✓ | ✓ |
| rho usable as standalone lib | ✗ | ✓ | ✓ |
| rho_frameworks avoids CLI deps | ✗ | ✗ | ✓ |
| Eliminates Code.ensure_loaded? hacks | ✓ | Partial | ✓ (via behaviours) |
| Fewer umbrella apps | ✓ (3 apps) | ✓ (4 apps) | ✗ (5 apps) |
| Simpler mental model | ✓ | Neutral | ✗ |
| Supervision tree stays clean | ✗ (merge 8 children) | ✗ (merge 1 child + boot) | ✓ |
| Compile-time blast radius | ✗ Worse | Neutral | ✓ |
| Migration effort | ~1.5 days | ~0.5 days | ~1 day |

---

## 1. Dependency Weight

### Current rho deps (apps/rho/mix.exs)
```
req_llm ~> 1.6
jido_signal ~> 2.0
jason ~> 1.4
nimble_options ~> 1.0
```

### What flattening stdlib would ADD to rho
```
floki ~> 0.37         # HTML parsing
pythonx ~> 0.4        # Python interpreter (NIF, compiles CPython)
erlang_python ~> 2.3  # Erlang↔Python bridge
xlsxir ~> 1.6         # Excel parsing
live_render ~> 0.5    # LiveView rendering
yaml_elixir ~> 2.11   # YAML parsing
```

### What flattening cli would ADD
```
dotenvy ~> 1.1        # .env file loading
```

### Impact

- **Compile time:** `pythonx` and `erlang_python` are NIFs. Adding them to rho means every `mix compile` of the core touches NIF compilation. Currently isolated to stdlib.
- **"Zero external tool deps" invariant:** CLAUDE.md line 12 states: `rho/ # Core agent runtime kernel (ZERO Phoenix/Ecto deps)`. Flattening breaks this — rho would carry HTML/Excel/Python/YAML deps.
- **Standalone library use:** Anyone wanting `{:rho, in_umbrella: true}` as a lightweight agent runtime would inherit Python, Excel, YAML. Unusable as a clean dep.

---

## 2. Compilation Coupling

```
$ mix xref graph --format stats
Tracked files: 204 (nodes)
Compile dependencies: 27 (edges)
Exports dependencies: 87 (edges)
Runtime dependencies: 482 (edges)
```

### Compile-connected edges (full output)

Only 2 clusters of compile-connected edges exist:
1. `runner.ex → tape/projection/jsonl.ex` (internal to rho)
2. `stdlib.ex → 14 stdlib plugin/tool modules` (internal to rho_stdlib)

**Zero compile-connected edges cross the rho↔stdlib or rho↔cli boundary.** This means:
- Changing stdlib code does NOT force rho core to recompile today
- Flattening would **introduce** compile coupling that doesn't currently exist

### Runtime coupling (the actual problem)

`apps/rho/lib/rho/config.ex` has `@compile {:no_warn_undefined, [Rho.CLI.Config, Rho.CLI.CommandParser, Rho.Stdlib]}` and uses `Code.ensure_loaded?` to optionally call:
- `Rho.CLI.Config.agent/1`
- `Rho.CLI.Config.agent_names/0`
- `Rho.CLI.Config.sandbox_enabled?/0`
- `Rho.CLI.CommandParser.parse/1`
- `Rho.Stdlib.capabilities_from_plugins/1`

`apps/rho/lib/rho/agent/worker.ex` directly calls `Rho.Stdlib.capabilities_from_plugins/1`.

This is a **leaky boundary**, not proof the boundary is pointless. The fix is behaviours/callbacks, not merging.

---

## 3. Test Isolation

| App | Test files | test_helper.exs | Mimic stubs |
|-----|-----------|-----------------|-------------|
| rho | 20+ files | `Mimic.copy(ReqLLM, ReqLLM.StreamResponse, Rho.Config)` | 3 modules |
| rho_stdlib | 10+ files | `ExUnit.start()` only | None |
| rho_cli | 1 file | `ExUnit.start()` only | None |

**After flatten:** All 31+ test files share one test_helper.exs. rho_stdlib tests that currently run with zero mocks would inherit the Mimic.copy setup. Not a dealbreaker, but adds noise.

**Current fast loop:** `mix test --app rho` runs only core tests (~20 files). After flatten, `mix test --app rho` runs all 31+ files. Slower feedback for core-only changes.

---

## 4. What Problem Does Flattening Solve?

REDESIGN.md §5C motivation: _"three different entry paths"_ → merge stdlib+cli into rho for 3 apps instead of 5.

**But Phases 1–4 already solved the entry path problem** via `Rho.Session`. The three frontends (CLI, web, tests) now all go through `Rho.Session.start → send → stop`.

What remains:
- The `Code.ensure_loaded?` hacks in `config.ex` feel ugly
- 5 apps feels like a lot for one product
- Cross-app navigation is slightly annoying

These are **aesthetic concerns**, not architectural ones. They don't justify pulling pythonx/erlang_python/xlsxir into the core runtime.

---

## 5. Real-World Dependency Graph

```
rho_web ──→ rho, rho_stdlib, rho_cli, rho_frameworks
rho_frameworks ──→ rho, rho_stdlib  (NO rho_cli!)
rho_cli ──→ rho, rho_stdlib
rho_stdlib ──→ rho
rho ──→ (external only)
```

**Key finding:** `rho_frameworks` does NOT depend on `rho_cli` — not in mix.exs, not in code. (Note: CLAUDE.md line 102 incorrectly claims it does. That's stale.)

If we flatten stdlib+cli into rho:
- `rho_frameworks` would inherit `dotenvy`, `pythonx`, `erlang_python`, `xlsxir`, `floki`, `live_render`, `yaml_elixir` — **7 deps it doesn't need**
- The clean `rho_frameworks → rho + rho_stdlib` graph becomes `rho_frameworks → rho (with everything)`

---

## 6. Supervision Impact

### Would be merged into rho.Application
```
# From rho_stdlib.Application:
{Registry, name: Rho.PythonRegistry}
{DynamicSupervisor, name: Python.Supervisor}
{Registry, name: Rho.Stdlib.DataTable.Registry}
{DynamicSupervisor, name: Rho.Stdlib.DataTable.Supervisor}
Rho.Stdlib.DataTable.SessionJanitor

# From rho_cli.Application:
Rho.CLI.Repl
# + Dotenvy boot, Python init, plugin registration
```

Core supervision tree goes from 9 children to 15+. Python/DataTable/REPL processes boot even when running headless or in test mode.

---

## 7. The Right Fix: Seal the Boundary

Instead of flattening, fix the 3 cross-app reach-ins:

### 7a. Replace `Rho.Config` runtime dispatch with behaviours

```elixir
# In apps/rho/lib/rho/config_provider.ex
defmodule Rho.ConfigProvider do
  @callback agent(atom()) :: map()
  @callback agent_names() :: [atom()]
  @callback sandbox_enabled?() :: boolean()
end
```

`rho_cli` implements this. `rho` reads `Application.get_env(:rho, :config_provider, Rho.DefaultConfigProvider)`.

### 7b. Replace `Rho.Stdlib.capabilities_from_plugins` call in worker.ex

Either:
- Move `capabilities_from_plugins/1` into `rho` (it's a small function that iterates plugins)
- Or use a `CapabilityProvider` behaviour

### 7c. Move `parse_command` behind a behaviour or into RunSpec

Command parsing is an entrypoint concern. It shouldn't live in core config.

**Estimated effort:** ~1 day. Result: rho boots and tests with zero knowledge of stdlib/cli.

---

## Recommendation

**Fix the seam. Keep 5 apps. Don't flatten.**

The boundary between rho (core runtime) and rho_stdlib (batteries) is architecturally meaningful. The boundary violations are small and fixable. The cost of flattening (heavy deps in core, broken invariant, forced deps on rho_frameworks, merged supervision trees) outweighs the benefit (fewer directories, no Code.ensure_loaded? hacks).

If appetite exists for reducing app count later, the only defensible merge is **rho_cli → rho** (it's small, 1 dep, pure entrypoint code). But even that should wait until after the seam is sealed — you may find it's not worth it.
