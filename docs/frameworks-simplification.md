# rho_frameworks Simplification — Investigation

**Date:** 2026-04-25 · **Branch:** `refactor`  
**Premise:** Phases 1–6 gave us Session, RunSpec, ToolExecutor, Plugin. No backward compat needed.

---

## Current Surface Area

rho_frameworks is 8,244 lines across 47 files. It touches core infra in **6 distinct ways**:

| Touchpoint | Where | What it does |
|-----------|-------|-------------|
| `Rho.Config.agent_config()` | roles.ex, lenses.ex, skeleton_generator.ex, proficiency.ex | Gets model/provider just to call ReqLLM directly |
| `Rho.Agent.LiteWorker` | skeleton_generator.ex, proficiency.ex, library.ex | Spawns lightweight agent tasks |
| `Rho.Comms.publish` | skeleton_generator.ex, proficiency.ex, lenses.ex | Publishes task/score events to bus |
| `Rho.Plugin` behaviour | plugin.ex, identity_plugin.ex | Registers tools + prompt sections |
| `Rho.Stdlib.DataTable` | editor.ex, library_tools.ex, role_tools.ex, shared_tools.ex | Table CRUD |
| `Rho.Context` | runtime.ex, proficiency.ex, skeleton_generator.ex | Manually constructs minimal contexts for LiteWorker |

---

## First-Principles Observation

rho_frameworks does **3 fundamentally different things** with one mechanism:

1. **Domain logic** — Ecto CRUD, versioning, dedup, gap analysis (no LLM needed)
2. **Single-shot structured LLM calls** — role ranking, lens scoring, semantic dedup (one prompt → one response, no tools)
3. **Tool-using agent jobs** — skeleton generation, proficiency fan-out (multi-step, tools, async)

Today all three go through the same workaround pattern:
```
Rho.Config.agent_config(:role) → build Rho.Context manually → LiteWorker.start(...)
```

The redesigned core lets us separate these cleanly.

---

## Proposed Architecture

### Lane 1: Domain Logic (no changes needed)

These modules are already clean:

| Module | Lines | Status |
|--------|-------|--------|
| `Library` (CRUD, versioning, forking, dedup) | 1,702 | ✅ Keep as-is |
| `Library.Editor` (table ↔ DB bridge) | 279 | ✅ Keep as-is |
| `Library.Skeletons` (pure transforms) | 71 | ✅ Keep as-is |
| `Library.Operations` (composite pipelines) | 42 | ✅ Keep as-is |
| `Roles` (CRUD, compare, career ladder) | 592 | 🔄 Extract LLM call |
| `Lenses` (scoring engine, ARIA seed) | 782 | 🔄 Extract LLM call |
| `GapAnalysis` | 111 | ✅ Keep as-is |
| `Accounts`, schemas, flows | ~800 | ✅ Keep as-is |

### Lane 2: Single-Shot LLM → `RhoFrameworks.LLM`

**New module.** Wraps `ReqLLM.generate_object` with frameworks-owned config. No Session, no Runner, no tools.

```elixir
defmodule RhoFrameworks.LLM do
  @doc "Rank candidate roles by semantic similarity."
  def rank_roles(candidates, query, limit, opts \\ [])

  @doc "Score a role profile via structured LLM analysis."
  def score_lens(lens, target_payload, opts \\ [])

  @doc "Find semantic duplicate pairs among skills."
  def semantic_duplicates(skills, opts \\ [])
end
```

**What this replaces:**

| Current code | Location | Problem |
|-------------|----------|---------|
| `rank_similar_via_llm/3` | roles.ex:419–466 | Calls `Rho.Config.agent_config()`, builds messages, calls `ReqLLM.generate_object` inline |
| `score_via_llm/3` | lenses.ex:223–233 | Same pattern — config → messages → ReqLLM |
| `find_semantic_duplicates/1` | library.ex:1413–1468 | Spawns LiteWorker for a **single structured call** that doesn't need tools |

**Config:** `RhoFrameworks.LLM` reads from `Application.get_env(:rho_frameworks, :llm, ...)` or a dedicated config module. No more `Rho.Config.agent_config()` reach-in.

### Lane 3: Agent Jobs → `RunSpec` + `Runner.run`

**For skeleton generation and proficiency fan-out only.** These genuinely use tools and multi-step loops.

#### Replace LiteWorker with RunSpec-based tasks

```elixir
defmodule RhoFrameworks.AgentJobs do
  @doc "Start an async agent job. Returns {:ok, task_pid}."
  def start(prompt, %Rho.RunSpec{} = spec) do
    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      messages = [ReqLLM.Context.user(prompt)]
      Rho.Runner.run(messages, spec)
    end)
  end

  @doc "Start a skeleton generation job."
  def generate_skeleton(prompt, scope, opts \\ [])

  @doc "Fan out proficiency generation across categories."
  def generate_proficiency(categories, scope, opts \\ [])
end
```

#### Replace `RhoFrameworks.Runtime` with `RhoFrameworks.Scope`

```elixir
defmodule RhoFrameworks.Scope do
  @enforce_keys [:organization_id, :session_id]
  defstruct [:organization_id, :session_id, :user_id]
end
```

**Why not reuse RunSpec?** Because RunSpec is agent execution config (model, strategy, tools, emit). Scope is business context (org, session, user). Different concerns.

**Conversion at the boundary:**
```elixir
# In tool execute callbacks:
scope = RhoFrameworks.Scope.from_context(ctx)
Editor.create(params, scope)
```

### What Gets Deleted

| Module/Pattern | Lines | Reason |
|---------------|-------|--------|
| `RhoFrameworks.Runtime` | 62 | Replaced by `Scope` (simpler, no agent concepts) |
| `Runtime.from_rho_context/1` | — | `Scope.from_context/1` instead |
| `Runtime.lite_parent_id/1` | — | Not needed without LiteWorker |
| `build_lite_context/1` (3 copies) | ~30 | Gone — RunSpec carries context |
| All `Rho.Config.agent_config()` calls (4 sites) | ~20 | Frameworks owns its config |
| Direct `Rho.Comms.publish` (4 sites) | ~40 | Use `emit` callback or return effects |
| Global IdentityPlugin registration | 1 line | Make explicit in .rho.exs or RunSpec plugins |

### What Gets Narrowed

#### Internal tools for subagents

Current skeleton generator reuses the broad `manage_library(action: "create")` tool. The LLM needs prompt instructions like "call tools ONE AT A TIME in this exact order."

**Better:** Single-purpose internal tools:

| Current | New |
|---------|-----|
| `manage_library(action: "create")` | `create_library` (single tool, 1 param) |
| `save_skeletons` (already exists) | Keep |
| `add_proficiency_levels` (already exists) | Keep |
| `finish` | Keep |

Simpler schemas → better LLM reliability → fewer prompt instructions.

---

## Dependency Changes

### Before (rho_frameworks → core)

```
Rho.Config.agent_config()        ← config indirection
Rho.Agent.LiteWorker             ← 565-line reimplemented agent loop  
Rho.Comms.publish                ← transport coupling
Rho.Context (manual construction) ← workaround
Rho.PluginRegistry.register      ← global side effect
Rho.Stdlib.DataTable             ← legitimate dependency
Rho.Tool DSL                     ← legitimate dependency
Rho.ToolResponse / Rho.Effect    ← legitimate dependency
```

### After

```
Rho.RunSpec + Rho.Runner.run     ← only for tool-using jobs (2 places)
Rho.Stdlib.DataTable             ← unchanged
Rho.Tool DSL                     ← unchanged
Rho.ToolResponse / Rho.Effect    ← unchanged
ReqLLM (direct)                  ← for single-shot LLM calls
```

**Removed dependencies:** `Rho.Config`, `Rho.Agent.LiteWorker`, `Rho.Comms` (from frameworks), `Rho.Context` (manual construction), `Rho.PluginRegistry` (global registration).

---

## Migration Plan

### Phase A: Extract LLM calls (~0.5d)

1. Create `RhoFrameworks.LLM` with frameworks-owned config
2. Move `rank_similar_via_llm` logic from `roles.ex` → `LLM.rank_roles/4`
3. Move `score_via_llm` logic from `lenses.ex` → `LLM.score_lens/3`
4. Move semantic dedup from `library.ex` (LiteWorker.start + await) → `LLM.semantic_duplicates/2`
5. Delete all `Rho.Config.agent_config()` calls from frameworks

### Phase B: Replace Runtime with Scope (~0.5d)

1. Create `RhoFrameworks.Scope` (3 fields)
2. Add `Scope.from_context/1` bridge
3. Replace all `Runtime.t()` params → `Scope.t()` in Editor, Operations, Proficiency
4. Delete `RhoFrameworks.Runtime`

### Phase C: Replace LiteWorker with RunSpec jobs (~1d)

1. Create `RhoFrameworks.AgentJobs` with `start/2`
2. Rewrite `SkeletonGenerator.generate/2` → build RunSpec, call `AgentJobs.start/2`
3. Rewrite `Proficiency.start_fanout/2` → build RunSpecs per category, call `AgentJobs.start/2`
4. Replace `Rho.Comms.publish` in generators with `emit` callback on RunSpec
5. Create narrow internal tools if needed (or reuse existing single-purpose ones)
6. Delete all `build_lite_context`, `resolve_tools` helpers

### Phase D: Clean up plugin registration (~0.25d)

1. Remove `Rho.PluginRegistry.register(IdentityPlugin)` from `Application.start`
2. Register IdentityPlugin in `.rho.exs` agent configs or RunSpec.plugins instead
3. Keep `RhoFrameworks.Plugin` module — it's a legitimate plugin

### Phase E: Remove Comms from domain code (~0.25d)

1. Replace `Rho.Comms.publish` in `lenses.ex` with return values / effects
2. Web layer handles translating effects → PubSub topics
3. Delete direct Comms dependency from all frameworks modules

---

## Estimated Impact

| Metric | Before | After |
|--------|--------|-------|
| Core deps from frameworks | 7 (Config, LiteWorker, Comms, Context, PluginRegistry, DataTable, Tool) | 3 (RunSpec/Runner, DataTable, Tool) |
| `Rho.Config.agent_config()` calls | 4 | 0 |
| Manual `Rho.Context` construction | 3 sites | 0 |
| `Rho.Comms.publish` from frameworks | 4 sites | 0 |
| Global side effects in Application.start | 1 (IdentityPlugin) | 0 |
| Frameworks-owned config | 0 | 1 module (LLM config) |
| Net lines deleted | ~200 | — |
| Net lines added | ~150 (LLM, Scope, AgentJobs) | — |

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| UI depends on specific Comms topics | Thin adapter in rho_web translates effects → current PubSub topics |
| LiteWorker.await used synchronously for semantic dedup | Direct `ReqLLM.generate_object` call is simpler than LiteWorker anyway |
| Proficiency fan-out needs stagger/backpressure | Keep `Process.sleep(@stagger_ms)` in AgentJobs, or use Task.Supervisor limits |
| Narrow internal tools may duplicate domain logic | Split at tool layer only — narrow tools call same Editor/Library functions |

---

## Summary

**rho_frameworks currently compensates for missing core primitives with workarounds.** The redesigned core (Session, RunSpec, ToolExecutor) makes those workarounds unnecessary.

The simplification is:
1. **LLM calls → direct ReqLLM** (no agent loop needed for one-shot calls)
2. **Agent jobs → RunSpec + Runner.run** (replaces LiteWorker)
3. **Config → frameworks-owned** (no Rho.Config reach-in)
4. **Events → emit/effects** (no direct Comms.publish)
5. **Runtime → Scope** (business context, not agent context)
6. **Plugins → explicit registration** (no global side effects)

Total effort: ~2.5 days. Result: frameworks becomes a boring domain library that occasionally spawns agent tasks.
