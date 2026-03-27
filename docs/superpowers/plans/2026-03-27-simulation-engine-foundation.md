# Simulation Engine Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the domain-agnostic simulation kernel — behaviours, structs, engine, runner, and test infrastructure — that can run Monte Carlo ensembles of any agent-based simulation.

**Architecture:** Pure functional engine with two behaviours (Domain for physics, Policy for decisions). Engine.step/2 orchestrates one tick. Runner.run_many/1 parallelizes via Task.async_stream. All types are opaque term() — engine never inspects domain-specific data.

**Tech Stack:** Elixir 1.19, :rand module for reproducible RNG, Task.Supervisor for parallel runs.

**Spec:** `docs/superpowers/specs/2026-03-27-simulation-engine-foundation-design.md`

---

## Critical Context

- **All new files** under `lib/rho/sim/`. No existing files modified.
- **No domain knowledge** in any kernel file. No workforce, no hiring, no flight risk.
- **`transition` takes 6 args** (state, actions, rolls, derived, ctx, rng). The 6th arg is explicit RNG.
- **Context has NO `:rng` field.** Context is pure metadata.
- **No `status` on Run.** Return tags encode status.
- **No `on_step` or `meta` on Accumulator.** Keep it minimal.
- **`actors/2` default is `[]`** — supports actor-free simulations.
- **`apply_intervention/3` default raises** — forces domain to implement if interventions used.

---

## Task 1: Structs (Run, Accumulator, Context, StepError)

**Files:**
- Create: `lib/rho/sim/run.ex`
- Create: `lib/rho/sim/accumulator.ex`
- Create: `lib/rho/sim/context.ex`
- Create: `lib/rho/sim/step_error.ex`

- [ ] **Step 1:** Create `lib/rho/sim/run.ex` — defstruct with all fields from spec. Add `@type t`. No `status` field.
- [ ] **Step 2:** Create `lib/rho/sim/accumulator.ex` — defstruct + `trace/1` and `step_metrics/1` accessor functions that reverse. Use `@opaque t`.
- [ ] **Step 3:** Create `lib/rho/sim/context.ex` — defstruct with `@enforce_keys`. No `:rng` field.
- [ ] **Step 4:** Create `lib/rho/sim/step_error.ex` — defstruct with `:step`, `:phase`, `:actor`, `:module`, `:reason`, `:stacktrace`.
- [ ] **Step 5:** Verify: `mix compile`
- [ ] **Step 6:** Commit: `"feat(sim): add Run, Accumulator, Context, StepError structs"`

---

## Task 2: Domain Behaviour

**Files:**
- Create: `lib/rho/sim/domain.ex`

- [ ] **Step 1:** Create the module with `@callback` declarations for all 10 callbacks. `init/1` and `transition/6` required, rest optional via `@optional_callbacks`.
- [ ] **Step 2:** Add `__using__` macro with default implementations. `actors/2` returns `[]`. `apply_intervention/3` raises.
- [ ] **Step 3:** Add typespecs for all callback types (`actor_id`, `state`, `derived`, `observation`, `proposal`, `rolls`, `event`).
- [ ] **Step 4:** Verify: `mix compile`
- [ ] **Step 5:** Commit: `"feat(sim): add Domain behaviour with use macro and defaults"`

---

## Task 3: Policy Behaviour

**Files:**
- Create: `lib/rho/sim/policy.ex`

- [ ] **Step 1:** Create the module with `decide/4` required, `init/2` optional.
- [ ] **Step 2:** Add `__using__` macro with default `init/2` returning `{:ok, nil}`.
- [ ] **Step 3:** Verify: `mix compile`
- [ ] **Step 4:** Commit: `"feat(sim): add Policy behaviour with use macro"`

---

## Task 4: Test Stubs (CounterDomain + StubPolicy)

**Files:**
- Create: `test/support/sim/counter_domain.ex`
- Create: `test/support/sim/stub_policy.ex`

- [ ] **Step 1:** Create `CounterDomain` — `use Rho.Sim.Domain`, implements `init/1` (starts at 0), `transition/6` (increments count, passes rng through), `metrics/3` (returns count), `halt?/3` (stops at 10).
- [ ] **Step 2:** Create `StubPolicy` — `use Rho.Sim.Policy`, `decide/4` returns `{:ok, :noop, state}`.
- [ ] **Step 3:** Add `test/support` to compile paths in `mix.exs` if not already there:
```elixir
elixirc_paths: if Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]
```
- [ ] **Step 4:** Verify: `mix compile`
- [ ] **Step 5:** Commit: `"test(sim): add CounterDomain and StubPolicy test stubs"`

---

## Task 5: Engine — new/2

**Files:**
- Create: `lib/rho/sim/engine.ex`
- Create: `test/rho/sim/engine_test.exs`

- [ ] **Step 1:** Write test: `Engine.new(CounterDomain, domain_opts: [start: 0], policies: %{}, max_steps: 10, seed: 42)` returns `{:ok, {%Run{}, %Accumulator{}}}` with correct fields.
- [ ] **Step 2:** Write test: `Engine.new(NotAModule, ...)` returns error or raises.
- [ ] **Step 3:** Write test: policies with bare module normalize to `{Module, []}`.
- [ ] **Step 4:** Write test: policies non-empty but domain has no actors/2 → Logger.warning emitted.
- [ ] **Step 5:** Implement `Engine.new/2` — validation, normalization, domain.init, policy.init, RNG seeding, run_id generation.
- [ ] **Step 6:** Run tests: `mix test test/rho/sim/engine_test.exs`
- [ ] **Step 7:** Commit: `"feat(sim): implement Engine.new/2 with validation and normalization"`

---

## Task 6: Engine — step/2

**Files:**
- Modify: `lib/rho/sim/engine.ex`
- Modify: `test/rho/sim/engine_test.exs`

- [ ] **Step 1:** Write test: one step with CounterDomain — count goes from 0 to 1, metrics recorded.
- [ ] **Step 2:** Write test: step with interventions — intervention applied before derive.
- [ ] **Step 3:** Write test: step with actors + policies — observe, decide, resolve called in order.
- [ ] **Step 4:** Write test: step with unknown actor in actors/2 → StepError with phase :decide.
- [ ] **Step 5:** Write test: step where transition returns error → StepError with phase :transition.
- [ ] **Step 6:** Implement `Engine.step/2` following the 13-step algorithm from spec. Each phase wrapped in error handling producing StepError.
- [ ] **Step 7:** Run tests: `mix test test/rho/sim/engine_test.exs`
- [ ] **Step 8:** Commit: `"feat(sim): implement Engine.step/2 with full step algorithm"`

---

## Task 7: Engine — run/2

**Files:**
- Modify: `lib/rho/sim/engine.ex`
- Modify: `test/rho/sim/engine_test.exs`

- [ ] **Step 1:** Write test: run CounterDomain from 0 — halts at 10, returns `{:halted, {run, acc}}` with 10 step_metrics entries.
- [ ] **Step 2:** Write test: run with max_steps: 5 — returns `{:ok, {run, acc}}` at step 5, count is 5.
- [ ] **Step 3:** Write test: run with domain that errors at step 3 — returns `{:error, {3, %StepError{}, run, acc}}` with partial accumulator (2 metrics entries).
- [ ] **Step 4:** Implement `Engine.run/2` — loop step/2 until done/halted/error.
- [ ] **Step 5:** Run tests: `mix test test/rho/sim/engine_test.exs`
- [ ] **Step 6:** Commit: `"feat(sim): implement Engine.run/2 loop"`

---

## Task 8: Golden Test — Reproducibility

**Files:**
- Modify: `test/rho/sim/engine_test.exs`

- [ ] **Step 1:** Write test: same seed + same domain + same policies = identical step_metrics across two runs.
- [ ] **Step 2:** Write test: different seed = different step_metrics.
- [ ] **Step 3:** Create a `StochasticDomain` test stub that uses `sample/3` to produce random rolls, and `transition/6` to do action-contingent rolls. Verify reproducibility with this domain.
- [ ] **Step 4:** Run tests: `mix test test/rho/sim/engine_test.exs`
- [ ] **Step 5:** Commit: `"test(sim): golden reproducibility tests — same seed = identical output"`

---

## Task 9: Testing Module

**Files:**
- Create: `lib/rho/sim/testing.ex`

- [ ] **Step 1:** Implement `build_context/1` — returns a Context with sensible defaults, overridable.
- [ ] **Step 2:** Implement `assert_deterministic/2` — runs Engine twice with same seed, asserts identical step_metrics.
- [ ] **Step 3:** Implement `run_one_step/4` — convenience wrapper around Engine.new + Engine.step.
- [ ] **Step 4:** Rewrite golden test from Task 8 to use `Testing.assert_deterministic`.
- [ ] **Step 5:** Run tests: `mix test test/rho/sim/engine_test.exs`
- [ ] **Step 6:** Commit: `"feat(sim): add Testing module with context factory and determinism assertion"`

---

## Task 10: Runner — run_many/1

**Files:**
- Create: `lib/rho/sim/runner.ex`
- Create: `test/rho/sim/runner_test.exs`

- [ ] **Step 1:** Write test: `run_many` with 10 runs of CounterDomain — returns 10 completed results, 0 failures.
- [ ] **Step 2:** Write test: all 10 runs with same base_seed produce the same aggregate (deterministic ensemble).
- [ ] **Step 3:** Write test: reduce extracts final count from each run, aggregate computes mean.
- [ ] **Step 4:** Write test: one run with ErrorDomain — returns in failed list, other 9 complete.
- [ ] **Step 5:** Write test: keep_trace? false → accumulator trace is empty for all runs.
- [ ] **Step 6:** Implement `Runner.run_many/1` — Task.Supervisor.async_stream_nolink, seed derivation, reduce/aggregate, error collection.
- [ ] **Step 7:** Run tests: `mix test test/rho/sim/runner_test.exs`
- [ ] **Step 8:** Commit: `"feat(sim): implement Runner.run_many/1 with Monte Carlo ensemble"`

---

## Verification Checklist

After all tasks:

- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test test/rho/sim/` passes — all tests green
- [ ] Reproducibility: same seed = identical output (golden test)
- [ ] Error handling: bad domain/policy → StepError with phase/actor/module
- [ ] Runner: 10 runs complete in parallel, failures collected not dropped
- [ ] Zero domain-specific code in any file under `lib/rho/sim/`
