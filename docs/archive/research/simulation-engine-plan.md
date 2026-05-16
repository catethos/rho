# Simulation Engine for Agent-Based Prediction

## The Problem

Rho already supports multi-agent coordination — agents can delegate tasks, send messages, and discover each other. But agents talking to each other is **not simulation**. It's recursive text generation. The output is a narrative, not a prediction.

Real agent-based simulation (ABM) produces **quantified, falsifiable predictions** because it has three properties that LLM-to-LLM chat lacks:

1. **An environment with rules.** Actions have consequences computed by a model, not narrated by an LLM. Budget spent is budget gone. An employee who leaves creates a real vacancy.
2. **Structured agent state.** Agents aren't just conversation histories — they have typed attributes (satisfaction: 0.72, tenure: 18 months, flight_risk: 0.31) that evolve according to rules + decisions.
3. **Statistical power through repetition.** One simulation run is an anecdote. Prediction requires running hundreds of simulations with stochastic variation and aggregating the distribution of outcomes.

The goal is to make Rho a platform where LLMs provide the **behavioral policy** (how agents decide), **generate structured world state from unstructured inputs** (how the world is bootstrapped), and a formal simulation engine provides the **world dynamics** (what happens as a consequence). The LLM is the brain *and* the parser; the environment is the physics.

---

## Domain-Agnostic Design

The simulation engine is built as **two small behaviours** — `Rho.Sim.Domain` (physics) and `Rho.Sim.Policy` (brain) — plus a pure functional engine and a parallel runner. Any domain can be simulated by implementing these two behaviours.

| Domain | State | Actors | Stochastic Elements |
|--------|-------|--------|---------------------|
| **Workforce planning** | Headcount, budget, projects, teams | Planner, managers, executives | Attrition rolls, hiring pipeline, demand shocks |
| **Supply chain** | Inventory, facilities, orders, routes | Buyers, suppliers, logistics | Lead time variance, demand fluctuation, disruptions |
| **Market simulation** | Order book, positions, cash | Traders, market makers, firms | Price shocks, news events, liquidity |
| **Epidemiology** | Populations, infection rates, capacity | Regions, policy makers | Transmission draws, mutation events |
| **Product adoption** | User cohorts, features, competitors | Product teams, marketing | Churn rolls, viral spread, competitor launches |

The engine doesn't know or care which domain it's running. It only knows: there's a state, there are actors, actors propose actions, and the domain resolves consequences.

---

## Architecture Overview

The engine is split into four layers with zero coupling between them:

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 4: Rho Integration                                       │
│  Rho.Sim.Mount — thin @behaviour Rho.Mount adapter              │
│  (tools: run_simulation, run_ensemble, inspect_run)             │
└───────────────────────────┬─────────────────────────────────────┘
                            │ calls
┌───────────────────────────▼─────────────────────────────────────┐
│  Layer 3: Runner / Job Control                                   │
│  Rho.Sim.Runner — Task.Supervisor.async_stream for ensemble      │
│  Rho.Sim.Backtest — checkpoint-based validation (separate)       │
│  (parallel Monte Carlo, seed derivation, reduce/aggregate)       │
└───────────────────────────┬─────────────────────────────────────┘
                            │ calls
┌───────────────────────────▼─────────────────────────────────────┐
│  Layer 2: Simulation Kernel (pure functions, no processes)       │
│                                                                  │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐ │
│  │ Rho.Sim.     │   │ Rho.Sim.     │   │ Rho.Sim.Engine       │ │
│  │ Domain       │   │ Policy       │   │ step/2, run/2        │ │
│  │ (behaviour)  │   │ (behaviour)  │   │ pure orchestration   │ │
│  └──────────────┘   └──────────────┘   └──────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                            │ uses
┌───────────────────────────▼─────────────────────────────────────┐
│  Layer 1: State Generation (offline, LLM-assisted)              │
│  Rho.Sim.StateGen — unstructured data → typed domain state      │
│  (CSV/JSON/text → Domain struct, LLM extraction, validation)    │
└─────────────────────────────────────────────────────────────────┘
```

### Module Overview

| Module | Role | Type |
|--------|------|------|
| `Rho.Sim.Domain` | Behaviour for world physics — state shape, transitions, stochastic rolls, observations, metrics. Optional `catalog/0` for Mount integration. | Behaviour |
| `Rho.Sim.Policy` | Behaviour for actor decisions — given an observation, propose an action | Behaviour |
| `Rho.Sim.Engine` | Pure orchestration over Domain + Policy. Pure for rule-based policies; side-effecting when LLM policies are used. | Module |
| `Rho.Sim.Run` | Core simulation state (domain state, policy states, RNG, interventions, params) | Struct |
| `Rho.Sim.Accumulator` | Trace and step metrics — output only, no behavioral inputs | Struct |
| `Rho.Sim.Context` | Per-step metadata (run_id, step, max_steps, seed) built from Run | Struct |
| `Rho.Sim.Runner` | Ensemble Monte Carlo via `Task.Supervisor.async_stream_nolink` | Module |
| `Rho.Sim.Backtest` | Checkpoint-based evaluation on top of Runner — separate from Runner | Module |
| `Rho.Sim.StateGen` | LLM-assisted generation of typed domain state from unstructured inputs | Module |
| `Rho.Sim.Mount` | Thin `@behaviour Rho.Mount` adapter exposing tools to Rho agents | Mount |
| `Rho.Sim.Domains.Workforce` | First domain implementation — workforce planning | Domain impl |
| `Rho.Sim.Policies.Workforce.*` | Workforce-specific policies (rule-based, LLM-assisted) | Policy impls |

---

## Core Behaviours

### `Rho.Sim.Domain` — The Physics

Follows Rho's convention of small behaviours with optional callbacks. Only `init/1` and `transition/5` are required; the engine supplies sensible defaults for everything else.

```elixir
defmodule Rho.Sim.Domain do
  @moduledoc """
  Behaviour for simulation domain physics.

  A domain defines: state shape, how state transitions given actions and
  stochastic draws, what actors can observe, and what metrics to extract.

  Only `init/1` and `transition/5` are required. All other callbacks have
  engine-supplied defaults.
  """

  @type actor_id :: term()
  @type state :: term()
  @type derived :: term()
  @type observation :: term()
  @type proposal :: term()
  @type action :: term()
  @type rolls :: map()
  @type event :: map()

  # --- Required ---

  @doc "Initialize domain state from options."
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Apply one simulation tick. Receives resolved actions and concrete random
  draws. Returns next state, emitted events, and updated RNG state.

  `actions` is whatever `resolve_actions/5` returned — the engine passes it
  through without inspecting its shape. This may be actor-keyed, merged into
  a single plan, or any other structure the domain defines.

  Transition may perform action-contingent rolls (e.g., "did this hire
  succeed?") using the RNG from `ctx.rng` and must return the updated RNG
  state for reproducibility. If no action-contingent rolls are needed, pass
  the RNG through unchanged.
  """
  @callback transition(
              state(),
              actions :: term(),
              rolls(),
              derived(),
              Rho.Sim.Context.t()
            ) :: {:ok, state(), [event()], :rand.state()} | {:error, term()}

  # --- Optional ---

  @doc "Who acts this tick? Default: Map.keys(run.policies)"
  @callback actors(state(), Rho.Sim.Context.t()) :: [actor_id()]

  @doc "Ephemeral projection derived from state (like a mount projection). Default: %{}"
  @callback derive(state(), Rho.Sim.Context.t()) :: derived()

  @doc """
  What a specific actor can observe. Use for partial observability.
  Default: %{actor: actor_id, state: state, derived: derived}
  """
  @callback observe(actor_id(), state(), derived(), Rho.Sim.Context.t()) :: observation()

  @doc """
  Produce concrete stochastic draws from explicit RNG state.
  All randomness MUST flow through this callback for reproducibility.
  Default: {%{}, rng}
  """
  @callback sample(state(), Rho.Sim.Context.t(), :rand.state()) :: {rolls(), :rand.state()}

  @doc """
  Turn policy proposals into executable actions. Use for contention resolution,
  market clearing, resource caps, priority ordering, etc.
  Default: pass proposals through unchanged.

  The return type is `term()` — not necessarily keyed by actor_id. The domain
  is free to merge, reshape, or re-key proposals into whatever structure
  `transition/5` expects. For example, a workforce domain might merge
  :hiring_manager and :finance proposals into a single %{plan: ...} key.
  A market domain might return %{order_book: ...} after matching orders.
  The engine passes the return value directly to `transition/5` as `actions`
  without inspecting its shape.

  `rolls` from `sample/3` are passed here so resolution can use stochastic
  draws (e.g., randomized tie-breaking in market clearing). If resolution
  needs its own RNG draws, include resolution-specific rolls in `sample/3`.
  """
  @callback resolve_actions(
              proposals :: %{optional(actor_id()) => proposal()},
              state(),
              derived(),
              rolls(),
              Rho.Sim.Context.t()
            ) :: term()

  @doc "Per-step metrics extracted from state. Default: %{}"
  @callback metrics(state(), derived(), Rho.Sim.Context.t()) :: map()

  @doc "Extra stop condition beyond max_steps. Default: false"
  @callback halt?(state(), derived(), Rho.Sim.Context.t()) :: boolean()

  @doc """
  Catalog of available scenarios, interventions, metrics, and default policies.
  Used by Rho.Sim.Mount to populate tool schemas and translate scenario
  descriptors into Runner opts. Each domain ships its own catalog.
  Default: %{}
  """
  @callback catalog() :: map()

  @optional_callbacks actors: 2,
                      derive: 2,
                      observe: 4,
                      sample: 3,
                      resolve_actions: 5,
                      metrics: 3,
                      halt?: 3,
                      catalog: 0
end
```

### `Rho.Sim.Policy` — The Brain

One required callback. A policy can be rule-based, LLM-backed, or hybrid. Policy state is carried in the `Run` struct, not in a process.

```elixir
defmodule Rho.Sim.Policy do
  @moduledoc """
  Behaviour for actor decision-making.

  A policy receives an observation and returns a proposal (a structured action
  from a constrained space). The domain's `resolve_actions/5` may modify the
  proposal before it reaches `transition/5`.

  Policy state is carried as data in the Run struct — no process needed.
  """

  @type actor_id :: term()
  @type observation :: term()
  @type proposal :: term()
  @type state :: term()

  @doc "Given an observation, propose an action. Returns updated policy state."
  @callback decide(
              actor_id(),
              observation(),
              Rho.Sim.Context.t(),
              state()
            ) :: {:ok, proposal(), state()} | {:error, term()}

  @doc "Initialize policy-local state. Default: {:ok, nil}"
  @callback init(actor_id(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @optional_callbacks init: 2
end
```

### Design Rationale: Two Behaviours, Not Five

Why not separate behaviours for observations, metrics, action resolution, etc.?

- **Follows Rho convention.** `Rho.Mount` is one behaviour with optional callbacks, not five separate behaviours. Same pattern here.
- **Keeps the engine simple.** The engine calls into exactly two modules per step. No registry of observers, no chain of resolvers.
- **Domain author controls the contract.** A workforce domain decides what observations look like. A market domain decides how orders clear. These are domain-internal concerns, not engine-level abstractions.
- **Avoids premature generalization.** If a pattern emerges across three domains, promote it to a behaviour then.

---

## Data Structures

### `Rho.Sim.Run` — Core Simulation State

The Run struct carries only what's needed for the simulation loop. Trace and
accumulated metrics live in a separate `Accumulator` passed alongside the run —
this keeps the core struct lean and avoids it becoming a dumping ground for
checkpoint/resume, streaming, or trace filtering concerns.

```elixir
defmodule Rho.Sim.Run do
  @moduledoc """
  Core simulation state for one run. Carries all inputs and mutable state.
  Kept minimal on purpose — trace/metrics live in Accumulator.
  """

  defstruct [
    :run_id,          # unique identifier for this run
    :domain,          # module implementing Rho.Sim.Domain
    :domain_state,    # opaque domain state (whatever init/1 returned)
    :policies,        # %{actor_id => {module, opts}} — policy modules per actor
    :policy_states,   # %{actor_id => term()} — policy-local state per actor
    :rng,             # :rand.state() — current RNG state
    :seed,            # original seed for reproducibility
    :max_steps,       # hard stop
    interventions: %{},  # %{step => [intervention]} — scheduled state mutations
    params: %{},      # user-supplied parameters (immutable, passed to Context)
    step: 0,
    status: :ready    # :ready | :running | :halted | :done | :error
  ]
end
```

**Interventions** are first-class in the kernel, not hidden in domain state. An intervention
is a scheduled mutation applied at the start of a step, before `derive/2`:

```elixir
# Interventions are domain-specific terms scheduled by step number.
# The engine calls domain.apply_intervention/3 for each one at the target step.
# Example:
%{
  3 => [{:freeze_hiring, %{}}],
  6 => [{:remove_headcount, %{role: :engineer, count: 2}}]
}
```

The `Domain` behaviour gets an optional callback for this:

```elixir
@doc """
Apply a scheduled intervention to state. Called by the engine at the
start of the target step, before derive/2. Default: raises if interventions
are scheduled but this callback is not implemented.
"""
@callback apply_intervention(state(), intervention :: term(), Rho.Sim.Context.t()) :: state()

@optional_callbacks [..., apply_intervention: 3]
```

### `Rho.Sim.Accumulator` — Trace and Metrics (Output Only)

Separated from Run so the engine can pass different accumulator strategies
(full trace for debugging, metrics-only for Monte Carlo, streaming for
LiveView observation) without changing the core loop.

**The Accumulator is output-only.** It does not carry behavioral inputs like `params` —
those belong in `Run`. The Accumulator collects what happened; `Run` determines what
will happen.

```elixir
defmodule Rho.Sim.Accumulator do
  @moduledoc """
  Collects step-by-step trace and metrics alongside a Run.
  Output only — no behavioral inputs. Params/config live in Run.
  """

  defstruct [
    trace: [],            # [{step, trace_entry}] — opt-in, prepend order (reverse on read)
    step_metrics: [],     # [{step, metrics_map}] — opt-in, prepend order
    on_step: nil,         # optional fn(step_data, acc) -> acc — custom accumulation hook
    meta: %{}             # arbitrary output metadata
  ]

  # Both trace and step_metrics prepend for O(1) append during the run loop.
  # Call Enum.reverse/1 when reading chronologically (e.g., for display).
  #
  # step_metrics collection is opt-in. For Monte Carlo ensemble runs, the
  # runner typically uses :reduce to extract only final-state summaries and
  # skips per-step metrics entirely. Per-step metrics are useful for single
  # traced runs and checkpoint-based backtesting.
  #
  # on_step semantics: SUPPLEMENTS the default prepend behavior, does not
  # replace it. The engine always prepends metrics (and trace if enabled),
  # then calls on_step with the updated accumulator. This means callers
  # get the default behavior for free and use on_step for extras (streaming
  # to LiveView, running averages, reservoir sampling, etc.).
  #
  # Signature: fn(%{step: n, metrics: m, events: e, ...}, %Accumulator{}) -> %Accumulator{}
end
```

### `Rho.Sim.Context` — Per-Step Metadata

Built by the engine from `Run` fields at each step. Not user-constructed.

```elixir
defmodule Rho.Sim.Context do
  @moduledoc """
  Per-step context passed to all Domain and Policy callbacks.
  Built by the engine from Run — not user-constructed.
  """

  @enforce_keys [:run_id, :step, :max_steps, :seed]
  defstruct [:run_id, :step, :max_steps, :seed, :rng, params: %{}]

  # :rng is the current :rand.state() — included so transition/5 can
  # perform action-contingent rolls without breaking reproducibility.
  # Set by the engine after sample/3 updates the RNG.
  #
  # :params is copied from Run.params (immutable user-supplied config).
  #
  # The engine builds TWO contexts per step:
  #   pre_ctx  — step = current step, rng = pre-sample state
  #              used for: derive, actors, sample, observe, decide, resolve_actions
  #   post_ctx — step = current step + 1, rng = post-transition state
  #              used for: metrics, halt?
  # This avoids the off-by-one problem where metrics/halt see the wrong step.
end
```

---

## Pure Functional Engine

The engine is a pure module — no GenServer, no process per run. This makes it trivially testable, fast for Monte Carlo, and free of state-copying overhead.

### `Rho.Sim.Engine`

```elixir
defmodule Rho.Sim.Engine do
  @moduledoc """
  Pure functional simulation orchestration.

  step/2 advances one tick. run/2 loops until done/halted/error.
  Run and Accumulator are passed separately — Run carries simulation state,
  Accumulator carries trace/metrics/metadata.
  No processes, no side effects, no GenServer.
  """

  @type result :: {Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()}

  @spec new(module(), keyword(), %{term() => {module(), keyword()}}, keyword()) ::
          {:ok, result()} | {:error, term()}

  @spec step(Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()) ::
          {:ok, result()} | {:halted, result()} | {:error, term()}

  @spec run(Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()) ::
          {:ok, result()} | {:error, term()}
end
```

### Step Algorithm

Each call to `step/2` executes this sequence:

1. Build `pre_ctx` from run (step = current, rng = current, params from `run.params`)
2. **Apply interventions:** if `run.interventions[step]` exists, fold each through `domain.apply_intervention(state, intervention, pre_ctx)` — mutates state before the tick begins
3. `derived = domain.derive(state, pre_ctx)` — ephemeral projection (default: `%{}`)
4. `actors = domain.actors(state, pre_ctx)` — who acts this tick. **Default: `Enum.sort(Map.keys(run.policies))`** — sorted for deterministic ordering. Map key iteration order is not a reproducibility contract.
5. `{rolls, rng} = domain.sample(state, pre_ctx, rng)` — stochastic draws (default: `{%{}, rng}`)
6. For each actor (in order):
   - `obs = domain.observe(actor, state, derived, pre_ctx)` — what the actor sees
   - `{:ok, proposal, new_policy_state} = policy.decide(actor, obs, pre_ctx, policy_state)`
7. `actions = domain.resolve_actions(proposals, state, derived, rolls, pre_ctx)` — contention resolution with access to rolls (default: pass-through, ignoring rolls)
8. Update `pre_ctx` with post-sample rng: `%{pre_ctx | rng: rng}` — so `transition/5` can do action-contingent rolls
9. `{:ok, next_state, events, rng} = domain.transition(state, actions, rolls, derived, pre_ctx)` — physics
10. Build `post_ctx` from run (step = current + 1, rng = post-transition rng)
11. `next_derived = domain.derive(next_state, post_ctx)` — re-derive for accurate post-transition metrics
12. `metrics = domain.metrics(next_state, next_derived, post_ctx)` — extract numbers (default: `%{}`)
13. Append `{step, metrics}` to accumulator (if `keep_metrics?`); append trace entry if `keep_trace?` is set
14. Check halt: `step + 1 >= max_steps` or `domain.halt?(next_state, next_derived, post_ctx)`
15. Return updated `{%Run{}, %Accumulator{}}`

**Randomness discipline (v1):** All randomness flows through `domain.sample/3` and `domain.transition/5`. Policies MUST be deterministic in v1 — they receive no RNG argument. This is an explicit design constraint, not an oversight. LLM-backed policies are inherently non-deterministic (model versioning, temperature); acknowledging this rather than pretending RNG threading would fix it. If a future domain needs stochastic rule-based policies, extend `decide/4` to `decide/5` with an RNG argument then.

**Note on the double `derive` call:** Step 3 computes derived state for observations and action resolution (pre-transition). Step 11 recomputes it for metrics and halt checks (post-transition). This costs one extra `derive/2` call per step. If `derive/2` is expensive for a domain, cache or skip the post-transition derive and accept that metrics see stale derived state — but document that choice in the domain.

**Note on `derived` in `transition/5`:** The `derived` passed to `transition/5` reflects **pre-action state** (computed at step 3, before actors decided). Domain authors should know that if actions change something that `derived` depends on (e.g., resolve_actions caps a hire count), the `derived` values may be stale for transition purposes. If this matters, recompute the relevant values inside `transition/5` from `state` directly.

#### Async decide for LLM policies

Step 5 calls `decide/4` sequentially for each actor. With rule-based policies this is negligible, but an LLM-backed policy blocks the entire step on an HTTP round-trip. With multiple LLM actors, latency compounds linearly.

**Design decision:** The engine stays pure — it does not spawn tasks internally. LLM latency is handled at the **policy level**, not the engine level:

- **Single LLM actor per step (common case):** No parallelism needed. The step blocks on one LLM call. Acceptable.
- **Multiple LLM actors per step:** The policy module can internally batch or parallelize. A `BatchLLMPolicy` wrapper could collect observations for all actors, make one batched LLM call, and distribute responses. The engine just sees a normal `decide/4` call.
- **If engine-level parallelism is truly needed:** Add an opt-in `parallel_decide?: true` flag to `Engine.new/4`. When set, the engine wraps step 5 in `Task.async_stream` over actors. This is a controlled impurity at the engine boundary, not a fundamental architecture change. Defer until profiling proves sequential decide is the bottleneck.

#### Action-contingent randomness

`sample/3` runs at step 4, before actors decide at step 5. This works for **exogenous** randomness (attrition rates, demand shocks) but not for **action-contingent** randomness ("if the hiring manager's plan is approved, roll for hiring success").

**Solution:** `transition/5` returns an updated RNG state alongside next state and events:

```elixir
@callback transition(
            state(),
            actions :: term(),
            rolls(),
            derived(),
            Rho.Sim.Context.t()
          ) :: {:ok, state(), [event()], :rand.state()} | {:error, term()}
```

This keeps `sample/3` for exogenous draws (attrition, shocks — things that happen regardless of actions) and lets `transition/5` do action-contingent rolls (hiring success, transfer approval) using the RNG state from the run. Reproducibility is preserved because the RNG state is threaded explicitly, not pulled from process dictionary.

**Alternatively**, domains can roll speculatively in `sample/3` — pre-roll hiring outcomes for all roles even if no hiring happens, and ignore unused rolls. This is simpler but wastes entropy and gets awkward as the action space grows. Choose per domain based on action space size.

### Trace Levels

Full trace storage for hundreds of Monte Carlo runs causes memory blowup. Trace is opt-in:

```elixir
# In Runner opts:
keep_trace?: false    # default — summary metrics only
keep_trace?: true     # store full step-by-step trace (for debugging single runs)
```

When `keep_trace?` is false, the engine still computes metrics each step but discards observations, proposals, and events.

---

## Ensemble Runner

### `Rho.Sim.Runner`

Not a behaviour — a concrete orchestration module using `Task.Supervisor`.

```elixir
defmodule Rho.Sim.Runner do
  @moduledoc """
  Monte Carlo ensemble runner. Spawns N simulation runs in parallel,
  each with a deterministically derived seed, and reduces results.
  """

  @spec run_many(keyword()) :: {:ok, map()} | {:error, term()}

  # Required opts:
  #   :domain        — module implementing Rho.Sim.Domain
  #   :domain_opts   — keyword opts passed to domain.init/1
  #   :policies      — %{actor_id => {policy_module, opts}}
  #   :runs          — number of Monte Carlo runs
  #
  # Optional opts:
  #   :task_supervisor — (default: starts one inline)
  #   :max_steps       — (default: 100)
  #   :base_seed       — (default: :erlang.monotonic_time())
  #   :max_concurrency — (default: System.schedulers_online())
  #   :keep_trace?     — (default: false)
  #   :reduce          — fn %Run{} -> term() — extract what matters from each run
  #   :aggregate       — fn [term()] -> term() — combine reduced results
end
```

### Error Handling

Errors can occur in `transition/5` (domain logic bug), `decide/4` (LLM API failure), or `init/1` (bad config).

**Single run:** If `transition/5` or `decide/4` returns `{:error, term()}`, the engine marks the run as `status: :error` and returns `{:error, {step, reason, run, acc}}`. The caller gets the run state at the point of failure for debugging.

**Ensemble:** The runner uses `Task.Supervisor.async_stream_nolink` which isolates failures. Failed runs are collected separately:
```elixir
%{
  completed: [result, ...],       # successful reduce outputs
  failed: [{run_index, reason}],  # failed runs with index + error
  total: 500,
  success_count: 497,
  failure_count: 3
}
```
The caller decides whether 497/500 is acceptable. The runner does **not** silently drop failures or abort the ensemble — it always reports both.

**Policy error recovery:** Transient API errors (timeouts, rate limits) should be retried within `decide/4` by the policy implementation, not by the engine. If retries exhaust, the policy has two options:

1. **Return `{:error, reason}`** — the engine marks the run as failed. Acceptable for ensemble runs where losing a few runs is fine.
2. **Fall back to a rule-based default** — the policy itself handles degradation. For single traced runs the user is watching, this is strongly preferred:

```elixir
def decide(actor, obs, ctx, state) do
  case llm_call_with_retry(obs, state.llm_opts, max_retries: 3) do
    {:ok, proposal} ->
      {:ok, proposal, state}
    {:error, _reason} ->
      # Fallback: use a simple heuristic instead of failing the run
      fallback = state.fallback_policy.decide(actor, obs, ctx, state.fallback_state)
      fallback
  end
end
```

The engine does not have a `default_action/2` callback — fallback logic belongs in the policy, not the domain. This keeps the engine simple and lets each policy define its own degradation strategy.

### Seed Derivation

Each run gets a deterministic seed derived via `:rand.seed(:exsss, {base_seed, run_index, 0})`. This avoids correlated PRNG streams that can occur with simple `base_seed + run_index` arithmetic. Same base seed + same run count = identical ensemble. This lets you reproduce any individual run from the ensemble.

### Reducer Pattern

The runner is domain-agnostic. It doesn't know what "attrition" or "headcount" means. The caller supplies a reduce function:

```elixir
Rho.Sim.Runner.run_many(
  domain: Rho.Sim.Domains.Workforce,
  domain_opts: [headcount: %{engineer: 50, pm: 10}, budget: 1_000_000],
  policies: %{
    hiring_manager: {Rho.Sim.Policies.Workforce.TargetGap, target_buffer: 0.10},
    finance: {Rho.Sim.Policies.Workforce.BudgetCap, cost_per_head: 150_000}
  },
  runs: 500,
  max_steps: 12,
  reduce: fn {%Run{domain_state: state}, _acc} ->
    %{
      total_headcount: Enum.sum(Map.values(state.headcount)),
      total_backlog: Enum.sum(Map.values(state.backlog)),
      budget_remaining: state.budget
    }
  end,
  aggregate: fn results ->
    %{
      mean_headcount: results |> Enum.map(& &1.total_headcount) |> mean(),
      p5_backlog: results |> Enum.map(& &1.total_backlog) |> percentile(5),
      p95_backlog: results |> Enum.map(& &1.total_backlog) |> percentile(95)
    }
  end
)
```

---

## First Domain: Workforce Planning

### Why Workforce First

Workforce planning sits at the intersection of quantitative and qualitative reasoning:

| Aspect | Quantitative (domain handles) | Qualitative (LLM policy handles) |
|--------|-------------------------------|----------------------------------|
| Headcount | Budget arithmetic, capacity math | — |
| Attrition | Tenure curves, compensation gaps | "Why would this person leave?" |
| Hiring | Pipeline funnel rates, time-to-fill | "Would this candidate accept?" |
| Reorgs | Reporting structure changes | "How does morale shift when the team is split?" |
| Skill gaps | Inventory vs. requirement delta | "Can this person stretch into the role?" |

### Concrete Questions It Should Answer

**Aggregate-level (v1 domain state supports these):**
- "If we freeze hiring for Q3, how much backlog accumulates?"
- "What happens to capacity utilization if attrition increases 20%?"
- "What's the budget impact of backfilling at market rate vs. redistributing work?"

**Individual-level (requires richer domain state — v2):**
- "If we lose 2 senior engineers, which teams break first?"
- "If we promote 3 people this cycle vs. 1, what's the 12-month retention impact?"

Each answer should be a **distribution** (simulated backlog band: 8-14%, P(budget overrun) = 0.34), not a narrative.

> **Scope note:** The v1 workforce domain uses aggregate state (`%{role => count}`) with two
> actors (`:hiring_manager` and `:finance`) that exercise multi-actor contention via
> `resolve_actions/5`. This is sufficient for headcount/capacity/budget questions and validates
> multi-actor dynamics. Questions about specific teams or individuals require a richer state
> model (individual employee structs, team assignments) which belongs in a v2 domain
> implementation using the same `Rho.Sim.Domain` behaviour.

### `Rho.Sim.Domains.Workforce`

```elixir
defmodule Rho.Sim.Domains.Workforce do
  @behaviour Rho.Sim.Domain

  defstruct [
    month: 0,
    horizon: 12,
    headcount: %{},       # %{role => count}
    demand: %{},          # %{role => required_capacity}
    backlog: %{},         # %{role => unmet_demand}
    open_reqs: %{},       # %{role => count}
    budget: 0,
    attrition_rate: %{},  # %{role => base_rate}
    productivity: %{}     # %{role => output_per_head}
  ]

  @impl Rho.Sim.Domain
  def init(opts), do: {:ok, struct!(__MODULE__, opts)}

  # Two actors to exercise multi-actor dynamics and resolve_actions contention:
  # :hiring_manager proposes hires, :finance approves/caps based on budget.
  @impl Rho.Sim.Domain
  def actors(_state, _ctx), do: [:hiring_manager, :finance]

  @impl Rho.Sim.Domain
  def derive(state, _ctx) do
    capacity = Map.new(state.headcount, fn {role, hc} ->
      {role, hc * Map.get(state.productivity, role, 1.0)}
    end)

    gap = Map.new(state.demand, fn {role, demand} ->
      {role, demand - Map.get(capacity, role, 0)}
    end)

    utilization = Map.new(state.demand, fn {role, demand} ->
      cap = max(Map.get(capacity, role, 0), 1)
      {role, demand / cap}
    end)

    %{capacity: capacity, gap: gap, utilization: utilization}
  end

  @impl Rho.Sim.Domain
  def observe(:hiring_manager, state, derived, _ctx) do
    # Hiring manager sees demand/capacity gaps but not exact budget
    %{
      month: state.month,
      headcount: state.headcount,
      demand: state.demand,
      backlog: state.backlog,
      gap: derived.gap,
      utilization: derived.utilization
    }
  end

  def observe(:finance, state, derived, _ctx) do
    # Finance sees budget and headcount but not team-level demand details
    %{
      month: state.month,
      budget: state.budget,
      headcount: state.headcount,
      open_reqs: state.open_reqs,
      total_gap: Enum.sum(Map.values(derived.gap))
    }
  end

  @impl Rho.Sim.Domain
  def sample(state, _ctx, rng) do
    {attrition, rng} = roll_attrition(state, rng)
    {demand_shock, rng} = roll_demand_shock(state, rng)
    {%{attrition: attrition, demand_shock: demand_shock}, rng}
  end

  # Contention resolution: hiring_manager proposes hires, finance caps them.
  @impl Rho.Sim.Domain
  def resolve_actions(proposals, state, _derived, _rolls, _ctx) do
    hire_request = proposals[:hiring_manager] || %{hires: %{}}
    budget_decision = proposals[:finance] || %{approved_budget: state.budget}

    # Finance caps hiring to what budget allows
    approved_hires = cap_hires_to_budget(hire_request.hires, budget_decision.approved_budget, state)

    %{plan: %{hires: approved_hires, budget_spent: hiring_cost(approved_hires, state)}}
  end

  @impl Rho.Sim.Domain
  def transition(state, %{plan: plan}, rolls, _derived, %{rng: rng} = _ctx) do
    # Action-contingent roll: did each approved hire succeed?
    {hire_outcomes, rng} = roll_hiring_success(plan, state, rng)

    next_state =
      state
      |> apply_attrition(rolls.attrition)
      |> apply_demand_shock(rolls.demand_shock)
      |> apply_hiring_plan(plan, hire_outcomes)
      |> deduct_budget(plan.budget_spent)
      |> recompute_backlog()
      |> advance_month()

    events = [
      %{type: :month_advanced, month: next_state.month},
      %{type: :plan_applied, plan: plan, hire_outcomes: hire_outcomes}
    ]

    {:ok, next_state, events, rng}
  end

  @impl Rho.Sim.Domain
  def metrics(state, derived, _ctx) do
    %{
      month: state.month,
      total_headcount: Enum.sum(Map.values(state.headcount)),
      total_backlog: Enum.sum(Map.values(state.backlog)),
      avg_utilization: avg(Map.values(derived.utilization)),
      total_gap: Enum.sum(Map.values(derived.gap))
    }
  end

  @impl Rho.Sim.Domain
  def halt?(state, _derived, _ctx), do: state.month >= state.horizon

  # --- Private helpers ---
  # roll_attrition/2, roll_demand_shock/2, normalize_plan/2,
  # apply_attrition/2, apply_demand_shock/2, apply_hiring_plan/2,
  # recompute_backlog/1, advance_month/1
end
```

### Workforce Policies

#### Rule-Based (Strategy A: cheapest, fastest)

For Monte Carlo ensembles where speed matters more than decision nuance.

```elixir
defmodule Rho.Sim.Policies.Workforce.TargetGap do
  @behaviour Rho.Sim.Policy

  @impl Rho.Sim.Policy
  def decide(:hiring_manager, observation, _ctx, state) do
    hires = observation.gap
      |> Enum.filter(fn {_role, gap} -> gap > 0 end)
      |> Map.new(fn {role, gap} -> {role, ceil(gap * (1 + state.buffer))} end)

    {:ok, %{hires: hires}, state}
  end

  @impl Rho.Sim.Policy
  def init(:hiring_manager, opts) do
    {:ok, %{buffer: Keyword.get(opts, :target_buffer, 0.10)}}
  end
end

defmodule Rho.Sim.Policies.Workforce.BudgetCap do
  @behaviour Rho.Sim.Policy

  @impl Rho.Sim.Policy
  def decide(:finance, observation, _ctx, state) do
    # Approve budget proportional to gap severity, capped by remaining budget
    approved = min(observation.budget, observation.total_gap * state.cost_per_head)
    {:ok, %{approved_budget: approved}, state}
  end

  @impl Rho.Sim.Policy
  def init(:finance, opts) do
    {:ok, %{cost_per_head: Keyword.get(opts, :cost_per_head, 150_000)}}
  end
end
```

#### LLM-Assisted (Strategy B: richer reasoning, selective use)

For key decision points where rule-based isn't enough — e.g., a finance actor deciding where to cut during a budget reduction.

```elixir
defmodule Rho.Sim.Policies.Workforce.LLMFinance do
  @behaviour Rho.Sim.Policy

  @impl Rho.Sim.Policy
  def decide(:finance, observation, _ctx, state) do
    prompt = """
    You are a #{state.style} executive. Budget: $#{observation.budget}.
    Teams: #{inspect(observation.headcount)}
    Open reqs: #{inspect(observation.open_reqs)}
    Total capacity gap: #{observation.total_gap}

    Decide how much budget to approve for hiring this month.
    Return ONLY a JSON object: {"approved_budget": <number>}
    """

    case llm_call_with_retry(prompt, state.llm_opts, max_retries: 3) do
      {:ok, response} ->
        case parse_budget_decision(response) do
          {:ok, approved} ->
            {:ok, %{approved_budget: approved}, state}
          {:error, _} ->
            # Schema validation failed — fall back to rule-based
            approved = min(observation.budget, observation.total_gap * state.cost_per_head)
            {:ok, %{approved_budget: approved}, state}
        end
      {:error, _reason} ->
        # LLM unavailable — fall back to rule-based
        approved = min(observation.budget, observation.total_gap * state.cost_per_head)
        {:ok, %{approved_budget: approved}, state}
    end
  end
end
```

The LLM picks from a **constrained action space** and must return the same proposal shape
that the rule-based policy would — `%{approved_budget: number}`. The domain resolves
consequences. The LLM never narrates what happens — it only decides what to do. Fallback
to rule-based logic on parse failure or LLM unavailability keeps runs from dying.

**Cost control:** A 12-month simulation with 500 runs:
- Rule-based policies → 0 LLM calls, runs in seconds
- LLM executive policy, **naively 12 calls/run × 500 = 6,000 calls** (decide is invoked every tick)
- With novelty gating: hash the observation, skip LLM if a similar observation was seen in the same run → ~3 novel decisions/run → 1,500 calls. At $0.003/call: ~$4.50

**Novelty gating mechanism:** Before calling the LLM, extract **decision-relevant features** from the observation and check if a similar state was seen before. This is a policy-level concern — implement in the `decide/4` body using policy state:

```elixir
def decide(actor, obs, ctx, %{cache: cache} = state) do
  # Domain-specific: extract only the features that should change a decision.
  # Trivial differences (month 3 vs 4, budget $999k vs $998k) should map
  # to the same key. Quantize continuous values to decision-relevant buckets.
  key = decision_key(obs)

  case Map.get(cache, key) do
    nil ->
      {:ok, proposal} = llm_call(obs, state.llm_opts)
      {:ok, proposal, %{state | cache: Map.put(cache, key, proposal)}}
    cached_proposal ->
      {:ok, cached_proposal, state}
  end
end

# Example: quantize budget to $100k buckets, gap to integer bands
defp decision_key(obs) do
  {
    div(trunc(obs.budget), 100_000),
    Enum.map(obs.gap, fn {role, g} -> {role, round(g)} end) |> Enum.sort()
  }
end
```

The `decision_key/1` function is the critical piece — it defines what "novel" means for this policy. Exact observation hashing is wrong because trivially different observations (month 3 vs month 4) hash differently but should produce the same decision. The "~3 novel decisions/run" estimate assumes effective quantization here.

---

## LLM Integration Points

The LLM touches the simulation in **five** places — not just as a decision-maker, but as a
parser, generator, and interpreter. The key insight is that most real-world simulation inputs
exist as unstructured data (org charts, spreadsheets with notes, strategy docs, Slack threads),
and the LLM is the bridge between messy reality and typed domain state.

### 1. State Generation from Unstructured Data (offline, before simulation)

**This is the highest-leverage LLM integration point.** Real organizations don't have their
workforce data neatly formatted as `%{role => count}` maps. They have:

- Org chart PDFs, HRIS exports with free-text job titles
- Strategy decks describing planned growth ("double the platform team by Q4")
- Slack threads about who's thinking of leaving
- Compensation data in spreadsheets with inconsistent role names
- Job postings, recruiter pipeline notes

`Rho.Sim.StateGen` uses the LLM to extract typed domain state from these inputs:

```elixir
defmodule Rho.Sim.StateGen do
  @moduledoc """
  LLM-assisted generation of typed domain state from unstructured inputs.
  Runs offline (before simulation), not in the simulation loop.
  """

  @doc """
  Generate domain state from a natural language description.
  The domain module provides the target schema via its struct definition.
  """
  @spec from_description(module(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}

  @doc """
  Generate domain state from structured data (CSV, JSON) with LLM-assisted
  field mapping and normalization. Handles inconsistent role names, missing
  fields, unit conversions, etc.
  """
  @spec from_data(module(), map() | list(), keyword()) ::
          {:ok, term()} | {:error, term()}

  @doc """
  Generate domain state from mixed inputs — combine structured data with
  qualitative context. E.g., HRIS export + "morale is low on the platform
  team, 2 seniors are interviewing elsewhere."
  """
  @spec from_mixed(module(), [input()], keyword()) ::
          {:ok, term()} | {:error, term()}
end
```

**Examples:**

```
# From description alone:
StateGen.from_description(Workforce,
  "200-person series C startup. 60% engineering (half frontend, half backend),
   20% product/design, 20% G&A. $15M annual people budget. High growth —
   planning to hire 40 engineers in the next year. Current attrition is
   elevated at ~18% annualized, mostly among mid-level backend engineers.",
  validate: true
)
# => {:ok, %Workforce{headcount: %{frontend_eng: 60, backend_eng: 60, ...}, ...}}

# From HRIS export + qualitative context:
StateGen.from_mixed(Workforce, [
  {:csv, "headcount_export.csv"},
  {:text, "The VP of Engineering just resigned. Platform team lead is
           likely to follow. Budget was just cut 15% for next quarter."}
], field_mapping: :auto)
```

The LLM handles: role name normalization ("Sr. Software Engineer" → `:senior_engineer`),
inference of missing fields (estimating attrition rates from tenure distribution),
and synthesis of qualitative signals into quantitative initial state.

**`from_mixed` produces an explicit changelog** showing where qualitative context modified the
structured baseline. This is critical for auditability — when the LLM decides "VP resigned"
means "attrition_rate for senior_eng goes from 0.12 to 0.25", the user should see that
inference, not just the final state:

```elixir
{:ok, state, changelog} = StateGen.from_mixed(Workforce, [...])
# changelog:
# [
#   %{field: [:attrition_rate, :senior_eng], from: 0.12, to: 0.25,
#     reason: "VP resignation increases senior flight risk"},
#   %{field: [:budget], from: 15_000_000, to: 12_750_000,
#     reason: "Budget cut 15% for next quarter"}
# ]
```

**Validation:** `StateGen` always validates the generated state against the domain's struct
definition. If the LLM produces invalid state (negative headcount, budget that doesn't
sum correctly), it retries with the validation errors in context, or returns `{:error, _}`.

### 2. Policy Authoring (offline, before simulation)

Use the LLM to **generate** rule-based policy implementations from qualitative descriptions:

```
"You are an ambitious senior engineer with 3 years at the company.
Generate a decide/4 function that returns :stay, :resign, or :request_transfer.
Inputs: satisfaction (0-1), workload (0-1.5), months_overloaded (int),
        promotion_recency (months), competing_offer (bool)"
```

The LLM produces a decision function. A human reviews it. It becomes a `Rho.Sim.Policy`
implementation. This happens once per policy, not per simulation tick.

Similarly, the LLM can generate **domain transition parameters** from qualitative descriptions:

```
"Based on industry data for Series C startups in 2024:
 What are realistic attrition rates by role and tenure band?
 What's a realistic hiring funnel conversion rate?
 What's a typical time-to-productivity for new hires?"
```

The LLM produces parameter values that the domain's `init/1` consumes. This is offline
calibration — the LLM helps set up the simulation, not run it.

### 3. Key Decision Points (runtime, selective)

For high-impact decisions where rule-based isn't enough (see LLM-Assisted policy above).
Use sparingly — only for actors whose decisions have outsized impact on outcomes.
Only in single traced runs or tiny ensembles until backtesting proves value over rules.

### 4. World Event Generation (offline, optional)

Beyond actor decisions, the LLM can generate **realistic exogenous event distributions**
that replace or augment the domain's `sample/3` simple distributions. This runs **offline
before the ensemble**, not per-step.

**How it works:**

1. The user or agent describes the scenario context to the LLM
2. The LLM generates a **discrete probability distribution** over plausible events
3. This distribution is stored in `Run.params` as domain-specific scenario data
4. The domain's `sample/3` reads from `ctx.params` and samples from the LLM-generated
   distribution using the deterministic RNG — preserving reproducibility

```elixir
# Step 1-2: Pre-ensemble, offline LLM call via StateGen or scenario design
events = Rho.Sim.StateGen.generate_event_distribution(Workforce,
  "Series C startup in a tightening market. Likely scenarios for engineering
   demand over the next 12 months, given recent layoffs at competitors and
   a possible acquisition.",
  event_type: :demand_shock,
  count: 4
)
# => %{demand_shock_distribution: [
#      {0.4, %{demand_change: 0.05, label: "steady growth"}},
#      {0.3, %{demand_change: -0.15, label: "market contraction"}},
#      {0.2, %{demand_change: 0.25, label: "competitor collapse, talent influx"}},
#      {0.1, %{demand_change: -0.30, label: "acquisition disruption"}}
#    ]}

# Step 3: Stored in Run.params when the ensemble is configured
Runner.run_many(
  domain: Workforce,
  domain_opts: [...],
  params: events,  # → copied to Run.params → ctx.params
  ...
)

# Step 4: Domain's sample/3 reads the distribution from ctx.params
def sample(state, ctx, rng) do
  dist = ctx.params[:demand_shock_distribution]
  if dist do
    {shock, rng} = weighted_sample(dist, rng)  # deterministic via RNG
    {%{demand_shock: shock.demand_change}, rng}
  else
    # Fallback: simple normal distribution
    {val, rng} = :rand.normal_s(0, 0.1, rng)
    {%{demand_shock: val}, rng}
  end
end
```

**Key constraint:** The LLM call happens once per ensemble setup, not per step or per run.
The generated distribution is data, sampled deterministically by the RNG. This means:
- Reproducibility is preserved (same seed → same sample from the distribution)
- Cost is O(1) LLM calls per ensemble, not O(steps × runs)
- The LLM adds domain-contextual realism without entering the simulation loop

### 5. Scenario Design & Result Explanation (human-in-the-loop)

A Rho agent (full `Agent.Worker`) helps the user **design** scenarios and **interpret** results.

**How the agent constructs tool arguments:** The `run_ensemble_tool` does **not** accept raw Elixir opts. It accepts a high-level scenario descriptor that the Mount translates:

```elixir
# What the agent calls (structured tool args):
%{
  "domain" => "workforce",
  "scenario" => "hiring_freeze",
  "initial_state" => %{
    "headcount" => %{"engineer" => 50, "pm" => 10},
    "budget" => 1_000_000
  },
  "interventions" => [%{"step" => 3, "type" => "freeze_hiring"}],
  "runs" => 500,
  "steps" => 12,
  "metrics" => ["total_headcount", "total_backlog", "budget_remaining"]
}
```

The Mount translates this into `domain_opts`, selects appropriate default policies for the domain, and maps metric names to reduce/aggregate functions. The agent never generates Elixir code.

**Domain-side registration:** Each domain module exports a `catalog/0` function that returns its available scenarios, interventions, metrics, and default policies. This is where the translation glue lives — in the domain, not the mount:

```elixir
# In Rho.Sim.Domains.Workforce:
def catalog do
  %{
    name: "workforce",
    scenarios: %{
      "hiring_freeze" => %{
        description: "Freeze all hiring for a period",
        params: [:step],
        # Data descriptors, not closures — serializable and introspectable.
        # The Mount dispatches on :type to build interventions.
        intervention: %{type: :set_policy, policy: %{hiring_freeze: true}},
        default_policies: %{
          hiring_manager: {TargetGap, []},
          finance: {BudgetCap, []}
        }
      },
      "key_departure" => %{
        description: "Remove a key role at a given step",
        params: [:role, :step],
        intervention: %{type: :remove_headcount, count: 1},
        default_policies: %{hiring_manager: {TargetGap, []}, finance: {BudgetCap, []}}
      }
    },
    metrics: %{
      # Named metric keys → {module, function, arity} or MFA tuples.
      # Avoids closures so catalog is serializable and cacheable.
      "total_headcount" => {__MODULE__, :metric_total_headcount, 1},
      "total_backlog" => {__MODULE__, :metric_total_backlog, 1},
      "budget_remaining" => {__MODULE__, :metric_budget_remaining, 1}
    }
  }
end

# Named metric functions — called by the Mount via apply/3
def metric_total_headcount(%{domain_state: s}), do: Enum.sum(Map.values(s.headcount))
def metric_total_backlog(%{domain_state: s}), do: Enum.sum(Map.values(s.backlog))
def metric_budget_remaining(%{domain_state: s}), do: s.budget

# Intervention builder — called by the Mount to translate catalog descriptors + user params
# into the %{step => [intervention]} map that Run.interventions expects.
def build_intervention(%{type: :set_policy, policy: policy}, %{step: step}) do
  {step, {:set_policy, policy}}
end
def build_intervention(%{type: :remove_headcount, count: n}, %{role: role, step: step}) do
  {step, {:remove_headcount, role, n}}
end
```

**Why data descriptors, not closures:** Catalog data may be serialized (cached, sent to LiveView via Comms, used in tool schema generation). Closures don't serialize. Using MFA tuples for metrics and data maps for interventions keeps the catalog introspectable and portable. The domain provides a `build_intervention/2` function that the Mount calls to translate descriptors + user params into concrete interventions.

The Mount calls `domain_module.catalog()` to populate `list_scenarios_tool` responses and to translate scenario descriptors into `Runner.run_many` opts. Each new domain ships its own catalog — no changes to the mount needed.

**Pre-built scenario templates** make this easier — the agent picks from a catalog:

```
User: "I'm worried about what happens if we lose the platform team lead"
Agent: [calls list_scenarios tool, finds "key_departure" template]
Agent: "I'll run 500 simulations comparing baseline vs. departure at month 2.
        Metrics: team capacity, backlog growth, time-to-backfill.
        Ready to simulate?"
User: "Go"
Agent: [calls run_ensemble tool with scenario template + overrides]
Agent: "Median backlog increases 40% (p5: 15%, p95: 85%).
        Time-to-backfill: 3.2 months median. Here's why..."
```

---

## Integration with Existing Rho

### Simulation Mount (`Rho.Sim.Mount`)

A thin `@behaviour Rho.Mount` adapter — no simulation logic, just wiring tools to Engine/Runner.

```elixir
defmodule Rho.Sim.Mount do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_opts, _ctx) do
    [
      list_scenarios_tool(),     # list available domains, scenarios, and metrics
      run_simulation_tool(),     # single run — returns metrics + optional trace (synchronous)
      run_ensemble_tool(),       # N runs — blocking for small, async for large (see below)
      get_job_status_tool(),     # poll a running/completed async job
      inspect_run_tool(),        # drill into a traced run's step-by-step log
      explain_outcome_tool()     # LLM explains why a distribution looks the way it does
    ]
  end

  @impl Rho.Mount
  def children(_opts, _ctx) do
    [{Task.Supervisor, name: Rho.Sim.TaskSupervisor}]
  end
end
```

**Async job semantics:** `run_ensemble_tool()` supports two modes:

1. **Blocking (default for small ensembles):** If `runs ≤ 100` or estimated wall time < 30s, the tool blocks and returns results directly. No job_id, no polling. This is the common case for interactive use.
2. **Async (for large ensembles):** If `runs > 100` or the caller passes `async: true`, the tool returns a job_id immediately. When the job completes, the runner delivers a signal to the agent's mailbox via `Worker.deliver_signal/2` — the same mechanism the multi-agent mount uses for `await_task`. The agent wakes up and processes the result as a new turn. The `get_job_status_tool` exists for manual polling but is rarely needed.

This avoids both the "spin in a tool-call loop wasting tokens" problem and the "return to user with nothing triggering a check" problem.

**Job registry:** An ETS table (`Rho.Sim.JobRegistry`) tracks running and completed jobs:
```elixir
# ETS entry per job:
{job_id, %{
  status: :running | :done | :error,
  started_at: DateTime.t(),
  progress: {completed_runs, total_runs},
  result: nil | ensemble_result,
  error: nil | term()
}}
```
The Mount's `children/2` starts the ETS table owner. The runner updates progress in ETS as runs complete. `Rho.Comms` publishes progress events for LiveView subscribers, but the agent polls via the `get_job_status` tool (Comms is pub/sub, not query-reply).

### Observatory Integration

Extend the existing Phoenix LiveView observatory to visualize simulation results:

- **Distribution plots** — histograms of outcome metrics across runs
- **Timeline view** — step through a traced run tick by tick
- **Scenario comparison** — side-by-side metrics for baseline vs. intervention
- **Sensitivity analysis** — which input parameters most affect outcomes

### Data Ingestion via `Rho.Sim.StateGen`

All data ingestion flows through `Rho.Sim.StateGen` (see LLM Integration Points §1):

- **Structured import** — `StateGen.from_data/3` loads CSV/JSON with LLM-assisted field mapping and normalization
- **Description-based generation** — `StateGen.from_description/3` generates plausible initial state from natural language: "200-person series C startup, 60% engineering, high growth"
- **Mixed inputs** — `StateGen.from_mixed/3` combines structured data with qualitative context (HRIS export + "morale is low, 2 seniors interviewing elsewhere")
- **Scenario templates** — pre-built common scenarios per domain (hiring freeze, supply disruption, market crash)

---

## Calibration and Validation

This is what separates a toy from a tool. **Validation comes before any claim of "prediction."**

### Terminology

Until backtested, outputs are **"scenario-conditioned forecasts"** or **"simulated outcome bands"**, not predictions. Many runs of a guessed model reduce Monte Carlo noise around your assumptions — they do not create truth.

### Backtesting

1. Load domain state from T-12 months (or appropriate historical horizon)
2. Run simulation forward with no interventions — just baseline
3. Compare simulated distributions vs. actual outcomes
4. Tune domain parameters until simulated bands bracket reality

### Parameter Sensitivity

Sweep parameter ranges, measure outcome variance. Focus calibration effort on high-sensitivity parameters. Each domain defines its own sensitivity targets:

- **Workforce:** attrition curve shape, hiring funnel rates, workload-to-satisfaction decay
- **Supply chain:** lead time distributions, demand elasticity, safety stock levels
- **Markets:** volatility regime parameters, liquidity curves

### Backtest Harness

Backtesting is a separate module (`Rho.Sim.Backtest`), not part of `Runner`. The runner runs
ensembles; the backtest module orchestrates checkpoint-based evaluation on top of it.

```elixir
Rho.Sim.Backtest.run(
  domain: Rho.Sim.Domains.Workforce,
  # Checkpoints: [{step, actual_state}] — known ground truth at specific steps
  checkpoints: [{0, initial_state}, {6, midpoint_state}, {12, final_state}],
  policies: %{hiring_manager: {TargetGap, []}, finance: {BudgetCap, []}},
  runs: 500,
  # Compare simulated metrics at each checkpoint against actual
  compare: fn simulated_metrics, actual_state, step ->
    %{
      headcount_error: abs(simulated_metrics.total_headcount - actual_headcount(actual_state)),
      backlog_error: abs(simulated_metrics.total_backlog - actual_backlog(actual_state))
    }
  end
)
```

**Comparison semantics:** The backtest compares **at checkpoint steps only** (not every intermediate step). The runner collects the ensemble distribution of metrics at each checkpoint step, then applies the `compare` function against the known actual state at that step. This yields per-checkpoint error distributions.

If the simulation drifts badly by an early checkpoint (e.g., step 6), later checkpoints will also show large errors — this is expected and useful. It tells you the model diverged early, not just that the final state is wrong. To diagnose early drift, use multiple checkpoints rather than just the final one.

---

## Implementation Sequence

### Milestone 0: Contracts + Invariants + Reproducibility Tests

**Build:** `Rho.Sim.Domain`, `Rho.Sim.Policy`, `Rho.Sim.Context`, `Rho.Sim.Run`, `Rho.Sim.Accumulator` — the type contracts. Define intervention scheduling in `Run`. Define success criteria and acceptable error bands for workforce metrics.

**Test:** Golden tests for reproducibility: same seed + same domain + same policies + same actor order = identical output. These tests gate every subsequent milestone.

**Why first:** The contracts must be tight before any implementation builds on them. The reproducibility golden tests are the single most important test suite in the project.

### Milestone 1: Engine + Runner + Workforce + Interventions

**Build:** `Rho.Sim.Engine` (step/run with intervention support), `Rho.Sim.Runner` (ensemble), `Rho.Sim.Domains.Workforce`, rule-based policies (`TargetGap`, `BudgetCap`), `Domain.apply_intervention/3`.

**Test:** Initialize a workforce state, advance 12 steps with a simple policy. Verify: state transitions correct, metrics computed, interventions applied at correct steps, same seed = same outcome. Then run 500 simulations of a hiring freeze (intervention at step 3) — verify ensemble aggregation and memory bounds.

**Why together:** The engine without the runner isn't useful to anyone, and the runner is ~50 lines of `Task.async_stream`. Interventions are included here because the entire UX revolves around scenario comparison (baseline vs. intervention), and they must be part of the kernel from the start.

### Milestone 2: Backtest + Calibration + Sensitivity

**Build:** `Rho.Sim.Backtest` (checkpoint-based evaluation, separate from Runner), parameter sweep, sensitivity analysis.

**Test:** Backtest workforce domain against historical data (or synthetic ground truth for initial validation). Tune domain parameters until simulated distributions bracket reality. Identify high-sensitivity parameters.

**Why second:** Validation before exposure. If the engine produces confident nonsense, better to find out before users see it. This also validates whether the workforce domain's aggregate state model is sufficient or if finer granularity is needed.

### Milestone 3: StateGen + LLM-Assisted State Generation

**Build:** `Rho.Sim.StateGen` — `from_description/3`, `from_data/3`, `from_mixed/3`. Schema validation against domain structs. Retry-with-feedback loop for invalid LLM output.

**Test:** Generate workforce state from (1) natural language description, (2) CSV export, (3) mixed inputs. Validate that generated state passes domain struct validation. Round-trip test: generate state → run simulation → verify no crashes or nonsensical metrics.

**Why here:** StateGen is the bridge between real-world data and the simulation. Without it, every simulation requires hand-crafted initial state. This is also the safest LLM integration point — it runs offline, can be validated, and doesn't affect reproducibility.

### Milestone 4: Second Stress-Test Domain

**Build:** A deliberately adversarial second domain that tests what workforce doesn't. Best candidates:

- **Simple market domain** — tests `resolve_actions/5` with real contention (order matching, clearing prices). Multiple actors competing for the same resource.
- **Epidemic/diffusion domain** — tests larger actor populations and simple local interactions (if `actors/2` returns different lists per step).

Keep it small — this is an API stress test, not a product. If the kernel abstractions crack, fix them now before the API hardens.

**Test:** Run the second domain through the same engine. Verify the behaviours are truly general. If `resolve_actions/5` or intervention scheduling doesn't work cleanly for the second domain, revise the kernel.

**Why before Mount:** Freezing the user-facing API on abstractions validated by only one domain is how you get workforce-specific assumptions baked into the "generic" kernel.

### Milestone 5: Mount + CLI Integration

**Build:** `Rho.Sim.Mount`, `Rho.Sim.JobRegistry` (ETS), `get_job_status` tool, progress via `Rho.Comms`. `catalog/0` integration. `StateGen` exposed via tools (generate_state_tool).

**Test:** User can say "simulate a hiring freeze for Q3" through the Rho CLI and get a distribution of outcomes. User can generate initial state from a description or data file.

**Why here:** Now the engine, validation, state generation, and abstractions are all proven. Safe to expose to users.

### Milestone 6: Selective LLM Augmentation (Runtime)

**Build:** LLM-backed policies for high-impact actors. Novelty gating / decision caching (see cost control section). Cost tracking. LLM-generated event distributions (see §4 of LLM Integration Points).

**Test:** Compare ensemble outcomes with rule-based vs. LLM-assisted policies. The LLM version should measurably improve backtest accuracy or decision realism. Only for single traced runs or tiny ensembles initially.

**Why last for runtime LLM:** Only add LLM to the inner loop after you can prove it adds value over rules. The offline LLM uses (StateGen, policy authoring, parameter generation) are already available from earlier milestones.

### Milestone 7: Serialization + Observatory

**Build:** Serialization for ensemble results. LiveView components for distribution plots, timeline scrubber, scenario comparison. Step-by-step streaming for single traced runs via `Rho.Comms` → LiveView subscribe. Job cancellation/timeout/TTL for async ensemble jobs.

**Test:** Can results be saved and reloaded? Can a non-technical stakeholder look at the dashboard and understand the forecast?

---

## Key Design Principles

### 1. LLM is the brain and the parser, not the physics

The LLM never computes consequences. The domain's `transition/5` determines what happens. The LLM contributes in three ways: (a) generating typed domain state from unstructured inputs (offline, via StateGen), (b) authoring policy implementations from qualitative descriptions (offline), and (c) optionally making high-impact decisions at runtime via `Policy.decide/4`. The domain physics are always deterministic code.

### 2. Pure orchestrator, honest about impurity

The simulation engine is a pure orchestrator for pure domains and rule-based policies — no GenServer, no process per run. However, LLM-backed policies are side-effecting and non-deterministic. The engine does not pretend otherwise. Processes only appear in Runner (for parallelism), Mount (for Rho integration), and StateGen (for LLM calls).

### 3. Domain-agnostic kernel, domain-specific implementations

The engine doesn't know what "attrition" or "inventory" means. It only knows: state, actors, proposals, actions, transitions. Domain knowledge lives entirely in `Domain` and `Policy` implementations.

### 4. Reproducibility (with explicit limits)

Same seed + same domain + same rule-based policies = same outcome. All randomness flows through `Domain.sample/3` and `Domain.transition/5`. Actor ordering is deterministic (sorted, not map iteration order). LLM-backed policies introduce non-determinism that RNG threading cannot fix (model versioning, temperature, API behavior). This is acknowledged, not papered over.

### 5. Cost scales with fidelity, not population

Rule-based policies cost nothing. LLM policies cost per call. You choose the fidelity level per actor, not per simulation. Most actors should be rule-based; LLM is reserved for high-impact decision points.

### 6. Simulated actors are data, not processes

Simulated actors are structs + policy functions, **not** `Rho.Agent.Worker` processes. The existing multi-agent system (max 10 agents per session, full LLM loops) is designed for a handful of conversational workers, not hundreds of simulated entities. Only the user-facing orchestrator belongs in Rho's agent world.

### 7. Validate before claiming prediction

Outputs are "scenario-conditioned forecasts" until backtested. Many runs of a guessed model only reduce Monte Carlo noise — they don't create truth.

---

## Open Questions

1. **Granularity of time steps.** Monthly is natural for workforce planning but may miss fast dynamics. Weekly increases cost 4x. Adaptive ticking adds complexity. Different domains may want different granularities — the engine should be time-unit-agnostic.

2. **Partial observability.** `Domain.observe/4` supports it, but v1 implementations can expose full state. Add noise/filtering when calibration shows omniscient policies produce unrealistic outcomes.

3. **Dynamic actor populations.** The v1 design works for **fixed controller actors** (hiring_manager, finance), not agent populations. `Domain.actors/2` returning different lists per step handles simple cases, but full dynamic populations (actors created mid-run needing policy init) may require a `policy_for/3` hook. This is the main limitation that makes v1 closer to "state-transition simulator with controller policies" than true ABM. Be explicit about this in docs. The second stress-test domain (Milestone 4) should probe this boundary.

4. **Event-time vs. fixed-tick simulation.** The current engine uses fixed ticks. Irregular-time simulations (event-driven, variable step size) would need a different engine mode. Don't build until a domain needs it.

5. **Cross-run LLM decision batching.** Sharing cached LLM decisions across runs in the same ensemble is statistically tricky — it can compromise run independence if the policy is treated as stochastic. Defer until LLM costs are proven to be a bottleneck AND the independence implications are understood.

6. **Privacy/compliance.** Workforce simulation involves sensitive data. Keep PII out of the engine by default — use anonymized IDs, role/team abstractions, no protected attributes. The privacy boundary is at the **LLM call**, not the output: if a user passes an HRIS CSV with names and the LLM processes it, PII transits through the LLM even if the generated domain state is clean. `StateGen` needs a **local pre-processing step** that strips/anonymizes PII from inputs before the LLM sees them (e.g., replace names with role-based IDs, redact emails/SSNs). This pre-processor is domain-specific. Define explicit boundaries in domain implementations.

7. **Serialization format.** `:erlang.term_to_binary` works for internal persistence but isn't portable. If ensemble results need to be shared across systems or stored long-term, domains may need to implement a serialization protocol. Defer until there's a concrete need.

8. **StateGen validation depth.** Schema validation catches structural errors (wrong types, missing fields), but semantic validation (are these attrition rates plausible? does the budget sum make sense?) is domain-specific. Each domain may need a `validate/1` optional callback that `StateGen` calls after structural validation. How much validation is enough before v1?

9. **Stochastic rule-based policies.** v1 policies must be deterministic (no RNG argument). If a domain needs stochastic rule-based decisions (e.g., probabilistic strategy selection), the options are: (a) extend `decide/4` to `decide/5` with RNG, (b) encode the stochasticity as domain-level rolls in `sample/3` and pass relevant rolls via the observation. Option (b) keeps the policy pure but makes observations heavier. Wait for a concrete need.

10. **Async job lifecycle.** The ETS-based job registry needs cancellation, timeout policies, partial result semantics, and TTL for completed jobs. These are straightforward to implement but need clear semantics defined before Milestone 5.

---

## Resolved Decisions

- **Accumulator is output-only.** `params` moved to `Run`. Accumulator carries trace and metrics, not behavioral inputs.
- **`resolve_actions` receives `rolls`.** Arity changed from 4 to 5. Stochastic resolution (market clearing, randomized tie-breaking) is now expressible.
- **`transition/5` accepts `term()` for actions**, not `%{actor_id => action}`. This matches the fact that `resolve_actions/5` can reshape proposals into any structure.
- **Actor ordering is sorted**, not map iteration order. Reproducibility requires deterministic ordering.
- **Context has pre/post split.** The engine builds `pre_ctx` (for derive/decide/resolve) and `post_ctx` (for metrics/halt) to avoid the off-by-one problem.
- **Interventions are first-class in the kernel** via `Run.interventions` and `Domain.apply_intervention/3`, not hidden in catalog functions.
- **Backtesting is a separate module** (`Rho.Sim.Backtest`), not part of `Runner`.
- **`catalog/0` is an optional callback** on `Domain`, not hidden coupling between Mount and domain modules.
- **Accumulator extensibility via `on_step`** is confirmed. It supplements default prepend behavior. Signature: `fn(step_data, acc) -> acc`.
