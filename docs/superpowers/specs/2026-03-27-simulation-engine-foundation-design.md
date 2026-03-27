# Simulation Engine Foundation — Design Spec

## Goal

Build a domain-agnostic simulation kernel that can run Monte Carlo ensembles of any agent-based simulation. The kernel must NOT contain any domain-specific knowledge (no workforce, no flight risk, no hiring). Domain knowledge lives entirely in implementations of the `Domain` and `Policy` behaviours.

First domain implementation (Workforce + Flight Risk Cascade scenario) is a separate spec.

---

## Files

```
lib/rho/sim/
├── domain.ex          # behaviour — the world's rules
├── policy.ex          # behaviour — how actors decide
├── engine.ex          # step/2, run/2 — pure orchestration
├── run.ex             # struct — core simulation state
├── accumulator.ex     # struct — output (trace + metrics)
├── context.ex         # struct — per-step metadata
├── runner.ex          # Monte Carlo ensemble via Task.async_stream
├── step_error.ex      # struct — tagged error with phase/actor context
└── testing.ex         # test helpers — context factory, determinism assertion
```

---

## Structs

### `Rho.Sim.Run`

Core simulation state for one run. The engine operates on this + Accumulator.

```elixir
defmodule Rho.Sim.Run do
  @type t :: %__MODULE__{}

  defstruct [
    :run_id,
    :domain,          # module implementing Rho.Sim.Domain
    :domain_state,    # opaque — whatever domain.init/1 returned
    :policies,        # %{actor_id => {module, keyword()}} — normalized
    :policy_states,   # %{actor_id => term()} — policy-local state per actor
    :rng,             # :rand.state()
    :seed,            # original seed (integer) for reproducibility
    :max_steps,       # hard stop
    interventions: %{},  # %{pos_integer() => [term()]}
    params: %{},         # immutable user-supplied config → Context
    step: 0
  ]
  # No `status` field — the return tags from step/2 and run/2 encode status.
  # {:ok, _} = running/done, {:halted, _} = halted, {:error, _} = error.
end
```

### `Rho.Sim.Accumulator`

Output only — trace and metrics collected during a run. Separate from Run so the engine can pass different accumulator strategies without changing the core loop.

```elixir
defmodule Rho.Sim.Accumulator do
  @opaque t :: %__MODULE__{}

  defstruct [
    trace: [],          # [{step, trace_entry}] — prepend order, reverse on read
    step_metrics: []    # [{step, metrics_map}] — prepend order, reverse on read
  ]

  @doc "Returns trace in chronological order."
  def trace(%__MODULE__{trace: t}), do: Enum.reverse(t)

  @doc "Returns step metrics in chronological order."
  def step_metrics(%__MODULE__{step_metrics: m}), do: Enum.reverse(m)
end
```

- `trace` and `step_metrics` prepend for O(1) append during the run. Read via accessor functions that reverse.
- No `on_step` hook or `meta` field — streaming and custom accumulation are external concerns. Whoever calls `step/2` can stream/accumulate as needed. Add these when a real use case demands them (Mount/Observatory integration).

### `Rho.Sim.Context`

Per-step metadata built by the engine from Run fields. Not user-constructed.

```elixir
defmodule Rho.Sim.Context do
  @type t :: %__MODULE__{}

  @enforce_keys [:run_id, :step, :max_steps, :seed]
  defstruct [:run_id, :step, :max_steps, :seed, params: %{}]
end
```

Context is **pure metadata** — no mutable state. No `:rng` field (RNG is passed explicitly to `sample/3` and threaded through `Run.rng`). One context per step: step N's context has `step: N`. Metrics computed at step N describe the state after step N's transition.

### `Rho.Sim.StepError`

Tagged error with phase context for debugging.

```elixir
defmodule Rho.Sim.StepError do
  defstruct [:step, :phase, :actor, :module, :reason, :stacktrace]

  # step: which step the error occurred at
  # phase: :init | :intervention | :derive | :sample | :observe | :decide |
  #        :resolve | :transition | :metrics | :halt
end
```

When any phase fails, the engine wraps the error with which phase, which actor (if applicable), and which module caused it.

---

## Behaviours

### `Rho.Sim.Domain` — The World's Rules

Provides `use Rho.Sim.Domain` macro with default implementations for all optional callbacks. Domain authors write only what they need.

```elixir
defmodule Rho.Sim.Domain do
  @type actor_id :: term()
  @type state :: term()
  @type derived :: term()
  @type observation :: term()
  @type proposal :: term()
  @type rolls :: map()
  @type event :: map()

  # --- Required ---

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @callback transition(
              state(),
              actions :: term(),
              rolls(),
              derived(),
              Rho.Sim.Context.t(),
              :rand.state()
            ) :: {:ok, state(), [event()], :rand.state()} | {:error, term()}

  # --- Optional (defaults provided by `use Rho.Sim.Domain`) ---

  @callback actors(state(), Rho.Sim.Context.t()) :: [actor_id()]
  @callback derive(state(), Rho.Sim.Context.t()) :: derived()
  @callback observe(actor_id(), state(), derived(), Rho.Sim.Context.t()) :: observation()
  @callback sample(state(), Rho.Sim.Context.t(), :rand.state()) :: {rolls(), :rand.state()}
  @callback resolve_actions(
              proposals :: %{optional(actor_id()) => proposal()},
              state(),
              derived(),
              rolls(),
              Rho.Sim.Context.t()
            ) :: term()
  @callback metrics(state(), derived(), Rho.Sim.Context.t()) :: map()
  @callback halt?(state(), derived(), Rho.Sim.Context.t()) :: boolean()
  @callback apply_intervention(state(), intervention :: term(), Rho.Sim.Context.t()) :: state()

  @optional_callbacks actors: 2, derive: 2, observe: 4, sample: 3,
                      resolve_actions: 5, metrics: 3, halt?: 3,
                      apply_intervention: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour Rho.Sim.Domain

      def actors(_state, _ctx), do: []
      def derive(_state, _ctx), do: %{}
      def observe(_actor, state, derived, _ctx), do: %{state: state, derived: derived}
      def sample(_state, _ctx, rng), do: {%{}, rng}
      def resolve_actions(proposals, _state, _derived, _rolls, _ctx), do: proposals
      def metrics(_state, _derived, _ctx), do: %{}
      def halt?(_state, _derived, _ctx), do: false
      def apply_intervention(_state, intervention, _ctx) do
        raise "#{__MODULE__} does not implement apply_intervention/3 but received intervention: #{inspect(intervention)}"
      end

      defoverridable actors: 2, derive: 2, observe: 4, sample: 3,
                     resolve_actions: 5, metrics: 3, halt?: 3,
                     apply_intervention: 3
    end
  end
end
```

**Default for `actors/2` is `[]`** (no actors, no decisions). This supports pure state-transition simulations where the domain evolves purely through `sample + transition` with no policy decisions. The engine skips the decide loop if actors is empty.

**Events from `transition/5` are informational only.** They go to the Accumulator for trace and streaming. They do NOT trigger cascading state changes. All state changes happen inside `transition/5`.

**`actors/2` return order IS execution order.** The domain controls scheduling. If managers should decide before employees, the domain returns `[:manager | employees]`.

### `Rho.Sim.Policy` — How Actors Decide

```elixir
defmodule Rho.Sim.Policy do
  @type actor_id :: term()
  @type observation :: term()
  @type proposal :: term()
  @type state :: term()

  @callback decide(
              actor_id(),
              observation(),
              Rho.Sim.Context.t(),
              state()
            ) :: {:ok, proposal(), state()} | {:error, term()}

  @callback init(actor_id(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @optional_callbacks init: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Rho.Sim.Policy

      def init(_actor_id, _opts), do: {:ok, nil}

      defoverridable init: 2
    end
  end
end
```

The policies map supports **heterogeneous types per actor**:
```elixir
policies: %{
  hr: RetentionPolicy,                      # shorthand, normalized to {RetentionPolicy, []}
  manager: {TargetGap, threshold: 0.8},     # with options
  finance: {BudgetCap, cost_per_head: 150_000}
}
```

The engine normalizes shorthand `Module` → `{Module, []}` at `new/2` time.

---

## Engine

### `Rho.Sim.Engine`

Pure module. No GenServer, no processes, no side effects (except `on_step` which is observe-only).

```elixir
defmodule Rho.Sim.Engine do
  @type result :: {Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()}

  @type step_result ::
    {:ok, result()}
    | {:halted, result()}
    | {:error, {non_neg_integer(), Rho.Sim.StepError.t(), Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()}}

  @spec new(module(), keyword()) :: {:ok, result()} | {:error, term()}
  @spec step(Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()) :: step_result()
  @spec run(Rho.Sim.Run.t(), Rho.Sim.Accumulator.t()) :: {:ok, result()} | {:halted, result()} | step_result()
end
```

### `new/2`

```elixir
Engine.new(MyDomain,
  domain_opts: [...],
  policies: %{...},
  max_steps: 12,
  seed: 42,
  interventions: %{3 => [{:freeze_hiring, %{}}]},
  params: %{market_condition: :tight}
)
```

`new/2` does:
1. Validate domain module implements `Rho.Sim.Domain` behaviour (exports `init/1` + `transition/5`)
2. Validate each policy module implements `Rho.Sim.Policy` behaviour (exports `decide/4`)
3. Normalize policies: bare `Module` → `{Module, []}`
4. **Warning:** if policies are non-empty but domain does not export `actors/2`, emit `Logger.warning` ("policies provided but actors/2 defaults to [] — no actor will decide")
5. **Warning:** if interventions are non-empty but domain does not export `apply_intervention/3`, raise (default raises, so this is caught at runtime, but warn at init for clarity)
6. Call `domain.init(domain_opts)` → domain_state
7. Call `policy.init(actor_id, opts)` for each policy (if exported, else default `{:ok, nil}`) → policy_states
8. Generate `run_id`: `"run_#{seed}_#{System.unique_integer([:positive])}"`. Runner may override per run.
9. Seed RNG: `:rand.seed(:exsss, {seed, 0, 0})`
10. Return `{:ok, {%Run{...}, %Accumulator{}}}`

Fails fast with clear error messages if modules are invalid.

**Error handling strategy:** Callbacks returning `{:ok, _} | {:error, _}` (`init`, `transition`, `decide`) — errors detected via pattern matching. Callbacks returning raw values (`derive`, `actors`, `observe`, `sample`, `resolve_actions`, `metrics`, `halt?`) — wrapped in `try/rescue` to catch raises, then tagged with `StepError`.

### `step/2` Algorithm

One context per step. RNG passed explicitly, not via context.

```
1.  Build ctx from run (step: current_step, params: run.params, etc.)
2.  Apply interventions: if run.interventions[step] exists,
    fold each through domain.apply_intervention(state, intervention, ctx)
3.  derived = domain.derive(state, ctx)
4.  actors = domain.actors(state, ctx)
    — Validate each actor exists in run.policies. If not, error with clear message.
5.  {rolls, rng} = domain.sample(state, ctx, run.rng)
6.  For each actor (in order from step 4):
    a. obs = domain.observe(actor, state, derived, ctx)
    b. {:ok, proposal, new_policy_state} = policy.decide(actor, obs, ctx, policy_state)
7.  actions = domain.resolve_actions(proposals_map, state, derived, rolls, ctx)
8.  {:ok, next_state, events, rng} = domain.transition(state, actions, rolls, derived, ctx)
    — transition receives rng from step 5 via ctx (engine sets ctx.rng before calling)
    — transition returns updated rng for action-contingent rolls
9.  metrics = domain.metrics(next_state, derived, ctx)
    — Note: derived is from pre-transition state. If domain needs post-transition
      derived values for metrics, compute them inside metrics/3.
10. Update accumulator: prepend {step, metrics} to step_metrics.
    If keep_trace?, also prepend {step, %{events: events, ...}} to trace.
11. Check halt: step + 1 >= max_steps or domain.halt?(next_state, derived, ctx)
12. Update run: domain_state = next_state, rng = rng, step = step + 1,
    policy_states = updated from step 6
13. Return {Run, Accumulator}
```

**Simplifications from earlier version:**
- One context per step (no pre_ctx/post_ctx split)
- `derive/2` called once per step (not twice)
- `metrics/3` and `halt?/3` receive pre-transition `derived` — domain computes post-transition projections internally if needed
- RNG threaded: `run.rng` → `sample/3` → updated rng → set on ctx for `transition/5` → transition returns final rng → stored back on `run.rng`

**Step 8 note on RNG:** The engine sets `ctx.rng` to the post-sample RNG before calling `transition/5`. This is the only mutation of `ctx` during the step. It ensures `transition/5` can do action-contingent rolls from the correct position. Context still has no `:rng` in its struct definition — the engine adds it dynamically for transition only.

Actually, to keep Context truly immutable: pass `rng` as a 6th argument to `transition`. This changes the callback signature:

```elixir
@callback transition(state(), actions :: term(), rolls(), derived(), Context.t(), :rand.state())
  :: {:ok, state(), [event()], :rand.state()} | {:error, term()}
```

This matches `sample/3`'s pattern of explicit RNG and keeps Context as pure metadata.

Each phase is wrapped in error handling that produces a `StepError` tagged with the step number, phase name, actor (if applicable), and module.

If `actors/2` returns `[]`, steps 6-7 are skipped. `actions` passed to `transition` is `%{}` (empty proposals).

**Error handling strategy:** Callbacks returning `{:ok, _} | {:error, _}` (`init`, `transition`, `decide`) — errors detected via pattern matching. Callbacks returning raw values (`derive`, `actors`, `observe`, `sample`, `resolve_actions`, `metrics`, `halt?`) — wrapped in `try/rescue` to catch raises, then tagged with `StepError`.

### `run/2`

Loops `step/2` until:
- `step + 1 >= max_steps` → status `:done`
- `domain.halt?` returns true → status `:halted`
- Any phase returns `{:error, _}` → status `:error`

---

## Runner

### `Rho.Sim.Runner`

Concrete module. Runs N simulations in parallel via `Task.Supervisor.async_stream_nolink`.

```elixir
defmodule Rho.Sim.Runner do
  @spec run_many(keyword()) :: {:ok, map()} | {:error, term()}
end
```

**Options:**
- `:domain` (required) — module implementing Domain
- `:domain_opts` (required) — keyword opts for domain.init/1
- `:policies` (required) — %{actor_id => policy_entry}
- `:runs` (required) — number of Monte Carlo runs
- `:max_steps` (default: 100)
- `:base_seed` (default: `:erlang.monotonic_time()`)
- `:max_concurrency` (default: `System.schedulers_online()`)
- `:reduce` (required) — `fn {%Run{}, %Accumulator{}} -> term()` — extract per-run result
- `:aggregate` (optional) — `fn [term()] -> term()` — combine results
- `:interventions` (default: `%{}`)
- `:params` (default: `%{}`)
- `:keep_trace?` (default: false) — if false, Accumulator skips trace collection (metrics only). Prevents memory blowup in large ensembles.
- `:timeout` (default: 60_000) — per-run timeout in ms
- `:task_supervisor` (default: starts one inline)

**Seed derivation:** Each run gets: `:rand.seed(:exsss, {base_seed, run_index, 0})`. Same base_seed + same run count = identical ensemble.

**Return:**
```elixir
%{
  completed: [reduced_result, ...],
  failed: [{run_index, reason}, ...],
  total: 500,
  success_count: 497,
  failure_count: 3,
  aggregate: aggregate_result | nil
}
```

Failed runs are collected, not dropped. Caller decides if 497/500 is acceptable.

**Per-run timeout:** `Task.Supervisor.async_stream_nolink` with `:timeout` option. A stuck domain `transition/5` doesn't hang the entire batch.

---

## Testing Module

### `Rho.Sim.Testing`

Ships with the kernel for domain/policy authors.

```elixir
defmodule Rho.Sim.Testing do
  @doc "Build a Context with sensible defaults. Override any field."
  def build_context(overrides \\ [])

  @doc "Assert that two runs with the same seed produce identical traces."
  def assert_deterministic(domain, opts)

  @doc "Run a single step and return the result for inspection."
  def run_one_step(domain, domain_opts, policies, opts \\ [])
end
```

---

## Design Rules (enforced by the kernel)

1. **Events are informational only.** `transition/5` returns events → Accumulator. No cascading state changes from events.
2. **`actors/2` return order = execution order.** Domain controls scheduling.
3. **All randomness through explicit RNG.** `sample/3` for exogenous draws. `transition/5` may do action-contingent draws using `ctx.rng` and must return updated RNG.
4. **Engine never inspects opaque types.** `domain_state`, `observation`, `proposal`, `action`, `rolls`, `derived` — all `term()`. Engine passes them through.
5. **Policies are deterministic in v1.** No RNG argument to `decide/4`. LLM-backed policies are inherently non-deterministic — acknowledged, not papered over.
6. **Fail fast on invalid config.** `new/2` validates modules implement the correct behaviours before any simulation runs.
7. **Context is pure metadata.** No mutable state on Context. RNG passed explicitly to `sample/3` and `transition/6`.
8. **One context per step.** Step N's context has `step: N`. No pre/post split. Derive called once per step.

---

## What's NOT In This Spec

- **Any domain implementation** (Workforce, FlightRisk, etc.) — Spec 2
- **StateGen** (LLM → typed state) — Spec 3
- **Mount** (Rho.Mount adapter, tools, job registry) — Spec 4
- **Observatory visualization** — Spec 5
- **`catalog/0` callback** — added when Mount needs it (Spec 4)
- **Topology library** (grid, network) — v2, when a domain needs it
- **Parameter sweep module** — v2
- **Checkpointing/serialization** — v2
- **Parallel decide loop** — v2, when actor count > 1000

---

## Test Strategy

### Golden Tests (Milestone 0)

The most important tests in the project:

```elixir
test "same seed produces identical output" do
  Rho.Sim.Testing.assert_deterministic(StubDomain,
    domain_opts: [...],
    policies: %{actor_a: StubPolicy},
    max_steps: 10,
    seed: 12345
  )
end
```

### Unit Tests per Module

- **Domain behaviour:** test a stub domain's init, transition, derive independently
- **Policy behaviour:** test a stub policy's decide independently
- **Engine.step/2:** test with a minimal stub domain — verify step counter advances, metrics collected, halt condition respected
- **Engine.new/2:** test validation — bad module raises, missing callbacks detected
- **Runner.run_many/1:** test with 10 runs of a trivial domain — verify seed determinism, failure collection, reduce/aggregate
- **StepError:** test that errors are tagged with correct phase/actor/module
- **Accumulator:** test accessor functions reverse correctly

### Stub Domain for Testing

A trivial domain that increments a counter each step:

```elixir
defmodule Rho.Sim.Test.CounterDomain do
  use Rho.Sim.Domain

  def init(opts), do: {:ok, %{count: Keyword.get(opts, :start, 0)}}
  def transition(state, _actions, _rolls, _derived, _ctx, rng) do
    {:ok, %{state | count: state.count + 1}, [%{type: :incremented}], rng}
  end
  def metrics(state, _derived, _ctx), do: %{count: state.count}
  def halt?(state, _derived, _ctx), do: state.count >= 10
end
```

---

## Files Changed

| File | Action |
|------|--------|
| `lib/rho/sim/domain.ex` | Create |
| `lib/rho/sim/policy.ex` | Create |
| `lib/rho/sim/engine.ex` | Create |
| `lib/rho/sim/run.ex` | Create |
| `lib/rho/sim/accumulator.ex` | Create |
| `lib/rho/sim/context.ex` | Create |
| `lib/rho/sim/runner.ex` | Create |
| `lib/rho/sim/step_error.ex` | Create |
| `lib/rho/sim/testing.ex` | Create |
| `test/rho/sim/engine_test.exs` | Create |
| `test/rho/sim/runner_test.exs` | Create |
| `test/rho/sim/test/counter_domain.ex` | Create (test support) |
| `test/rho/sim/test/stub_policy.ex` | Create (test support) |

No existing files modified. The simulation kernel is entirely new code under `lib/rho/sim/`.
