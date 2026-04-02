# ELTV Simulation: Technical Implementation Plan

*Detailed engineering plan for building the multi-agent workforce simulation with Bayesian belief updating and Employee Lifetime Value computation on top of Rho's existing agent infrastructure.*

---

## 1. Architecture Overview

The implementation is organized into five layers, each independently testable. Lower layers have zero dependency on higher layers.

```
┌────────────────────────────────────────────────────────────────────┐
│  Layer 5: Rho Integration                                          │
│  Rho.Sim.Mount — tools for agents to trigger/inspect simulations   │
│  Rho.Sim.LiveView — Observatory integration for visualization      │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
┌──────────────────────────────▼─────────────────────────────────────┐
│  Layer 4: ELTV Computation                                         │
│  Rho.Sim.ELTV — per-employee and portfolio-level lifetime value    │
│  Rho.Sim.Metrics.Workforce — domain-specific aggregations          │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
┌──────────────────────────────▼─────────────────────────────────────┐
│  Layer 3: Bayesian Belief Engine                                   │
│  Rho.Sim.Belief — probability distributions + conjugate updates    │
│  Rho.Sim.ObservationModel — maps observations → likelihood fns     │
│  Rho.Sim.BeliefState — per-agent belief portfolio                  │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
┌──────────────────────────────▼─────────────────────────────────────┐
│  Layer 2: Simulation Kernel                                        │
│  Rho.Sim.Domain (behaviour) — world physics                        │
│  Rho.Sim.Policy (behaviour) — actor decisions                      │
│  Rho.Sim.Engine — pure functional tick loop                        │
│  Rho.Sim.Runner — parallel Monte Carlo ensemble execution          │
│  Rho.Sim.Run / Rho.Sim.Accumulator / Rho.Sim.Context — data       │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
┌──────────────────────────────▼─────────────────────────────────────┐
│  Layer 1: Workforce Domain                                         │
│  Rho.Sim.Domains.Workforce — individual-level employee model       │
│  Rho.Sim.Policies.Workforce.* — rule-based and LLM policies       │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. Layer 1: Workforce Domain (Individual-Level)

The existing simulation-engine-plan defines a v1 workforce domain with aggregate state (`%{role => count}`). ELTV requires individual-level modeling. This is the v2 domain.

### 2.1 World State Structure

```elixir
defmodule Rho.Sim.Domains.Workforce do
  @behaviour Rho.Sim.Domain

  defmodule Employee do
    @moduledoc "Individual employee state. Evolves each tick."
    defstruct [
      :id,                    # unique identifier (matches real employee ID)
      :name,                  # for readability in traces
      :role,                  # :senior_engineer, :pm, :sales_rep, etc.
      :team,                  # :payments, :platform, :growth, etc.
      :manager_id,            # employee_id of direct manager
      :hire_date,             # tick when hired (or 0 for initial employees)
      :comp_annual,           # total annual compensation (salary + equity + benefits)
      :comp_market_ratio,     # comp / market_rate_for_role — refreshed each tick
      :performance,           # :low | :meets | :exceeds | :exceptional
      :satisfaction,          # float 0.0-1.0, driven by satisfaction model
      :flight_risk,           # float 0.0-1.0, computed from satisfaction + market + personal
      :productivity,          # float 0.0-1.0, ramp curve for new hires, 1.0 at full speed
      :ramp_months_remaining, # 0 when fully productive
      :tenure_months,         # months since hire_date
      :months_since_promo,    # months since last promotion
      :equity_cliff_months,   # months until next vesting cliff (0 = just vested)
      :knowledge_domains,     # MapSet of domain strings: "payments_api", "billing_core"
      :status,                # :active | :notice | :departed
      :departure_tick,        # nil or tick when they left
      :departure_reason       # nil | :voluntary | :involuntary | :rif
    ]
  end

  defmodule Requisition do
    @moduledoc "Open hiring requisition."
    defstruct [
      :id,
      :role,
      :team,
      :priority,              # :critical | :high | :normal | :backfill
      :opened_tick,
      :pipeline_stage,        # :sourcing | :screening | :interviewing | :offer | :filled | :cancelled
      :pipeline_candidates,   # count of candidates in pipeline
      :days_in_stage,
      :target_comp
    ]
  end

  defmodule State do
    @moduledoc "Complete workforce domain state."
    defstruct [
      :tick,                  # current simulation month
      :employees,             # %{employee_id => Employee.t()}
      :requisitions,          # %{req_id => Requisition.t()}
      :teams,                 # %{team_name => %{lead_id:, knowledge_domains:}}
      :market,                # %{role => %{median_comp:, demand_index:, supply_index:}}
      :budget,                # %{total:, spent_ytd:, retention_pool:, recruiting_pool:}
      :programs,              # %{program_name => %{type:, started_tick:, target_ids:, cost:}}
      :org_events,            # [{tick, event}] — layoffs, reorgs, announcements (observable)
      :knowledge_graph        # %{domain_string => [employee_id]} — who knows what
    ]
  end
end
```

### 2.2 Domain Callbacks

```elixir
# --- Required ---

@impl Rho.Sim.Domain
def init(opts) do
  # opts contains: :employees (list of Employee maps), :market, :budget, :teams
  # Builds State struct, computes initial knowledge_graph, sets tick=0
  {:ok, %State{...}}
end

@impl Rho.Sim.Domain
def transition(state, actions, rolls, derived, ctx) do
  state
  |> apply_departures(rolls.departures)          # employees who rolled to leave
  |> apply_market_moves(rolls.market_shifts)     # comp ratio changes
  |> apply_life_events(rolls.life_events)        # personal events affecting satisfaction
  |> apply_actions(actions)                      # HR decisions: retention, hiring, reorgs
  |> advance_requisitions(rolls.pipeline_rolls)  # pipeline progression
  |> update_satisfaction_model()                 # recompute satisfaction from all factors
  |> update_flight_risk()                        # recompute flight risk from satisfaction + market
  |> update_productivity()                       # ramp curves for new hires
  |> update_knowledge_graph()                    # recompute who knows what
  |> advance_tick()
  |> wrap_result(ctx.rng)
end

# --- Optional ---

@impl Rho.Sim.Domain
def actors(state, _ctx) do
  # Dynamic actor list based on org structure
  [:chro, :recruiting_lead] ++
    (state.teams |> Map.keys() |> Enum.map(&{:hiring_manager, &1}))
end

@impl Rho.Sim.Domain
def observe(actor, state, derived, _ctx) do
  # Role-based partial observability
  case actor do
    :chro ->
      %{
        headcount_by_role: derived.headcount_summary,
        attrition_rate_trailing: derived.trailing_attrition,
        engagement_survey: derived.lagged_survey,       # 1 quarter lag
        budget: state.budget,
        open_reqs: map_size(state.requisitions),
        recent_departures: derived.recent_departures,   # names only, no flight_risk
        org_events: state.org_events
      }

    {:hiring_manager, team} ->
      team_employees = derived.team_rosters[team]
      %{
        team_members: Enum.map(team_employees, &employee_summary/1),
        team_morale: derived.team_morale[team],
        open_reqs: team_reqs(state.requisitions, team),
        velocity: derived.team_velocity[team],
        # Managers see their direct reports' satisfaction signals (noisy)
        satisfaction_signals: noisy_satisfaction(team_employees, ctx)
      }

    :recruiting_lead ->
      %{
        all_reqs: Enum.map(state.requisitions, &req_summary/1),
        pipeline_health: derived.pipeline_metrics,
        market_rates: state.market,
        time_to_fill_avg: derived.avg_time_to_fill,
        offer_acceptance_rate: derived.offer_acceptance_rate
      }
  end
end

@impl Rho.Sim.Domain
def sample(state, _ctx, rng) do
  # All randomness flows through here (except action-contingent rolls in transition)
  {departures, rng} = roll_departures(state, rng)
  {market_shifts, rng} = roll_market_shifts(state, rng)
  {life_events, rng} = roll_life_events(state, rng)
  {pipeline_rolls, rng} = roll_pipeline_progression(state, rng)

  rolls = %{
    departures: departures,           # %{employee_id => :stays | :leaves}
    market_shifts: market_shifts,     # %{role => delta}
    life_events: life_events,         # [{employee_id, event}]
    pipeline_rolls: pipeline_rolls    # %{req_id => :advance | :stall | :drop}
  }

  {rolls, rng}
end
```

### 2.3 Departure Model (Core of ELTV)

The departure model is the most important piece — it determines when employees leave, which drives ELTV distributions.

```elixir
defmodule Rho.Sim.Domains.Workforce.DepartureModel do
  @moduledoc """
  Computes monthly departure probability for each employee.

  P(leave | employee) = sigmoid(
    β₀                                    # base rate
    + β₁ × (1 - satisfaction)             # low satisfaction → higher risk
    + β₂ × market_demand                  # hot market → more options
    + β₃ × (1 - comp_market_ratio)        # underpaid → higher risk
    + β₄ × months_since_promo_factor      # stalled career → higher risk
    + β₅ × equity_cliff_factor            # cliff approaching → stay; past → go
    + β₆ × team_departure_contagion       # colleagues left recently → higher risk
    + β₇ × manager_quality                # bad manager → higher risk
  )

  Coefficients are calibrated from historical data. Defaults from
  industry research (e.g., tenure curves from BLS, Visier benchmarks).
  """

  @default_coefficients %{
    base:                 -3.5,    # ~3% monthly base attrition at neutral
    satisfaction:          2.0,    # satisfaction is the strongest predictor
    market_demand:         0.8,    # hot market lifts attrition ~2x
    comp_ratio:            1.5,    # underpaid by 20% → noticeable risk increase
    promo_stall:           0.6,    # >24 months since promo starts to bite
    equity_cliff:         -1.0,    # within 6 months of cliff: strong retention
    contagion:             0.4,    # each recent team departure adds ~1% risk
    manager_quality:       0.3     # poor manager adds ~1% risk
  }

  @spec flight_risk(Employee.t(), State.t(), map()) :: float()
  def flight_risk(employee, state, coefficients \\ @default_coefficients) do
    features = extract_features(employee, state)
    logit = Enum.reduce(coefficients, 0.0, fn {feature, beta}, acc ->
      acc + beta * Map.get(features, feature, 0.0)
    end)
    sigmoid(logit)
  end

  # Returns %{employee_id => :stays | :leaves} given RNG
  @spec roll_departures(State.t(), :rand.state()) :: {map(), :rand.state()}
  def roll_departures(state, rng) do
    Enum.reduce(state.employees, {%{}, rng}, fn {id, emp}, {results, rng} ->
      if emp.status != :active do
        {Map.put(results, id, :stays), rng}
      else
        risk = flight_risk(emp, state)
        {roll, rng} = :rand.uniform_s(rng)
        outcome = if roll < risk, do: :leaves, else: :stays
        {Map.put(results, id, outcome), rng}
      end
    end)
  end
end
```

### 2.4 Satisfaction Model

```elixir
defmodule Rho.Sim.Domains.Workforce.SatisfactionModel do
  @moduledoc """
  Updates employee satisfaction each tick based on multiple factors.
  Satisfaction is a weighted combination, not a single driver.
  Output: float 0.0 - 1.0
  """

  @weights %{
    comp_fairness:     0.25,   # comp_market_ratio mapped to [0,1]
    growth:            0.20,   # inverse of months_since_promo, capped
    manager:           0.20,   # manager satisfaction score (inherited from manager employee)
    team_morale:       0.15,   # average satisfaction of teammates (feedback loop)
    workload:          0.10,   # backlog per person on team
    stability:         0.10    # inverse of recent org changes affecting this employee
  }

  @spec compute(Employee.t(), State.t(), map()) :: float()
  def compute(employee, state, derived) do
    factors = %{
      comp_fairness: clamp(employee.comp_market_ratio, 0.5, 1.5) |> normalize(0.5, 1.5),
      growth: growth_score(employee),
      manager: manager_score(employee, state),
      team_morale: derived.team_morale[employee.team] || 0.5,
      workload: workload_score(employee, state, derived),
      stability: stability_score(employee, state)
    }

    weighted_sum = Enum.reduce(@weights, 0.0, fn {factor, weight}, acc ->
      acc + weight * Map.get(factors, factor, 0.5)
    end)

    # Satisfaction has inertia — doesn't swing wildly tick to tick
    # Exponential moving average with α = 0.3
    alpha = 0.3
    alpha * weighted_sum + (1 - alpha) * employee.satisfaction
  end
end
```

### 2.5 Knowledge Graph & Bus Factor

```elixir
defmodule Rho.Sim.Domains.Workforce.KnowledgeGraph do
  @moduledoc """
  Tracks which employees hold knowledge of which domains.
  Used to compute bus factor, knowledge loss on departure,
  and productivity impact of attrition.
  """

  @spec build(map()) :: %{String.t() => [employee_id]}
  def build(employees) do
    Enum.reduce(employees, %{}, fn {id, emp}, graph ->
      Enum.reduce(emp.knowledge_domains, graph, fn domain, g ->
        Map.update(g, domain, [id], &[id | &1])
      end)
    end)
  end

  @spec bus_factor(String.t(), %{String.t() => [employee_id]}) :: non_neg_integer()
  def bus_factor(domain, graph) do
    length(Map.get(graph, domain, []))
  end

  @spec knowledge_loss(employee_id, %{String.t() => [employee_id]}) :: [String.t()]
  def knowledge_loss(employee_id, graph) do
    # Returns domains where this employee is the ONLY or one of few holders
    Enum.filter(graph, fn {_domain, holders} ->
      employee_id in holders and length(holders) <= 2
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec productivity_impact(employee_id, State.t()) :: float()
  def productivity_impact(employee_id, state) do
    critical_domains = knowledge_loss(employee_id, state.knowledge_graph)
    # Each critical domain lost reduces team velocity
    # Bus factor 1 → full impact; bus factor 2 → half impact
    Enum.reduce(critical_domains, 0.0, fn domain, acc ->
      holders = Map.get(state.knowledge_graph, domain, [])
      impact = 1.0 / max(length(holders), 1)
      acc + impact * domain_weight(domain, state)
    end)
  end
end
```

### 2.6 File Structure

```
lib/rho/sim/
├── domain.ex                          # @behaviour definition
├── policy.ex                          # @behaviour definition
├── engine.ex                          # pure functional tick loop
├── run.ex                             # %Run{} struct
├── accumulator.ex                     # %Accumulator{} struct
├── context.ex                         # %Context{} struct
├── runner.ex                          # Monte Carlo ensemble
├── belief.ex                          # probability distributions (Layer 3)
├── belief_state.ex                    # per-agent belief portfolio (Layer 3)
├── observation_model.ex               # observation → likelihood (Layer 3)
├── eltv.ex                            # ELTV computation (Layer 4)
├── mount.ex                           # Rho.Sim.Mount (Layer 5)
├── domains/
│   └── workforce.ex                   # Domain implementation
│       ├── state.ex                   # State, Employee, Requisition structs
│       ├── departure_model.ex         # Flight risk + departure rolls
│       ├── satisfaction_model.ex      # Satisfaction computation
│       ├── knowledge_graph.ex         # Knowledge tracking + bus factor
│       ├── recruiting_pipeline.ex     # Requisition state machine
│       └── market_model.ex            # External market dynamics
└── policies/
    └── workforce/
        ├── rule_based.ex              # Deterministic policies per role
        ├── llm.ex                     # LLM-backed policy wrapper
        └── hybrid.ex                  # Rule-based with LLM for edge cases
```

---

## 3. Layer 2: Simulation Kernel

Adopts the design from `docs/simulation-engine-plan.md` with no modifications. The behaviours, engine, runner, and data structures are as specified there.

### 3.1 Key Implementation Details

**Engine.step/2** — exact sequence per tick:

```
1. Build pre_ctx from run
2. Apply interventions for this tick (if any)
3. derived = domain.derive(state, pre_ctx)
4. actors = domain.actors(state, pre_ctx)     # sorted for determinism
5. {rolls, rng} = domain.sample(state, pre_ctx, rng)
6. For each actor (sequential, deterministic order):
     obs = domain.observe(actor, state, derived, pre_ctx)
     {:ok, proposal, new_policy_state} = policy.decide(actor, obs, pre_ctx, policy_state)
7. actions = domain.resolve_actions(proposals, state, derived, rolls, pre_ctx)
8. {:ok, next_state, events, rng} = domain.transition(state, actions, rolls, derived, ctx_with_rng)
9. post_ctx with step+1
10. metrics = domain.metrics(next_state, domain.derive(next_state, post_ctx), post_ctx)
11. Update accumulator (metrics, optional trace)
12. Check halt condition
13. Return updated {Run, Accumulator}
```

**Runner.run_many/1** — parallel Monte Carlo:

```elixir
def run_many(opts) do
  domain = opts[:domain]
  n = opts[:runs]
  base_seed = opts[:base_seed] || :erlang.monotonic_time()
  max_concurrency = opts[:max_concurrency] || System.schedulers_online()
  reduce = opts[:reduce] || fn {run, acc} -> {run, acc} end
  aggregate = opts[:aggregate] || &Function.identity/1

  results =
    0..(n - 1)
    |> Task.Supervisor.async_stream_nolink(
      Rho.TaskSupervisor,
      fn run_index ->
        seed = {base_seed, run_index, 0}
        rng = :rand.seed_s(:exsss, seed)

        {:ok, {run, acc}} = Engine.new(domain, opts[:domain_opts], opts[:policies],
          max_steps: opts[:max_steps], rng: rng, seed: seed,
          interventions: opts[:interventions] || %{},
          params: opts[:params] || %{})

        case Engine.run(run, acc) do
          {:ok, result} -> {:ok, reduce.(result)}
          {:error, reason} -> {:error, {run_index, reason}}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: opts[:timeout] || 300_000
    )
    |> Enum.reduce(%{completed: [], failed: []}, fn
      {:ok, {:ok, result}}, acc -> %{acc | completed: [result | acc.completed]}
      {:ok, {:error, err}}, acc -> %{acc | failed: [err | acc.failed]}
      {:exit, reason}, acc -> %{acc | failed: [{:exit, reason} | acc.failed]}
    end)

  {:ok, %{
    results: aggregate.(results.completed),
    completed: length(results.completed),
    failed: results.failed,
    failure_count: length(results.failed),
    total: n
  }}
end
```

### 3.2 Tests for Kernel

```
test/rho/sim/
├── engine_test.exs                # step/2, run/2 with toy domain
├── runner_test.exs                # ensemble with deterministic domain
├── domain_test.exs                # behaviour contract tests
└── domains/
    └── workforce_test.exs         # workforce domain unit tests
        ├── departure_model_test.exs
        ├── satisfaction_model_test.exs
        └── knowledge_graph_test.exs
```

Key property tests:
- **Determinism**: Same seed → same trajectory (for rule-based policies)
- **Conservation**: Budget spent = sum of all costs; headcount = hires - departures
- **Monotonicity**: Higher satisfaction → lower flight risk (all else equal)
- **Bus factor**: Removing an employee with unique knowledge → bus factor drops to 0

---

## 4. Layer 3: Bayesian Belief Engine

### 4.1 Probability Distributions

```elixir
defmodule Rho.Sim.Belief do
  @moduledoc """
  Probability distributions with conjugate Bayesian updates.
  Closed-form — no sampling or MCMC required.
  """

  # --- Distribution Types ---

  defmodule Beta do
    @moduledoc "Beta distribution for quantities in [0, 1]: rates, probabilities, morale."
    defstruct [:alpha, :beta]

    def new(alpha, beta) when alpha > 0 and beta > 0, do: %__MODULE__{alpha: alpha, beta: beta}
    def mean(%{alpha: a, beta: b}), do: a / (a + b)
    def variance(%{alpha: a, beta: b}), do: (a * b) / ((a + b) * (a + b) * (a + b + 1))
    def confidence(%{alpha: a, beta: b}), do: a + b  # higher = more confident
    def mode(%{alpha: a, beta: b}) when a > 1 and b > 1, do: (a - 1) / (a + b - 2)

    # Percentile via beta inverse CDF (use Erlang :math or approximation)
    def percentile(dist, p), do: beta_inv_cdf(dist.alpha, dist.beta, p)
  end

  defmodule Normal do
    @moduledoc "Normal distribution for unbounded quantities: headcount, revenue, cost."
    defstruct [:mu, :sigma]

    def new(mu, sigma) when sigma > 0, do: %__MODULE__{mu: mu, sigma: sigma}
    def mean(%{mu: mu}), do: mu
    def variance(%{sigma: s}), do: s * s
    def confidence(%{sigma: s}), do: 1.0 / s  # higher = more confident
  end

  defmodule Categorical do
    @moduledoc "Categorical distribution for discrete outcomes."
    defstruct [:categories, :probabilities]

    def new(cats, probs) when length(cats) == length(probs) do
      total = Enum.sum(probs)
      %__MODULE__{categories: cats, probabilities: Enum.map(probs, &(&1 / total))}
    end
    def mode(%{categories: cats, probabilities: probs}) do
      Enum.zip(cats, probs) |> Enum.max_by(&elem(&1, 1)) |> elem(0)
    end
  end

  # --- Conjugate Updates ---

  @doc """
  Update a Beta prior with binomial observations.

  Examples:
    - Observed 3 departures out of 40 employees this month
      update(Beta.new(2, 18), :binomial, %{successes: 3, trials: 40})
    - Observed a single event (departure = 1, no departure = 0)
      update(Beta.new(7, 3), :bernoulli, %{outcome: 1})
  """
  def update(%Beta{} = prior, :binomial, %{successes: s, trials: _n}) do
    %Beta{alpha: prior.alpha + s, beta: prior.beta + (_n - s)}
  end

  def update(%Beta{} = prior, :bernoulli, %{outcome: 1}) do
    %Beta{alpha: prior.alpha + 1, beta: prior.beta}
  end

  def update(%Beta{} = prior, :bernoulli, %{outcome: 0}) do
    %Beta{alpha: prior.alpha, beta: prior.beta + 1}
  end

  @doc """
  Update a Normal prior with Normal-distributed observation.
  Conjugate: Normal prior + Normal likelihood → Normal posterior.

  observation: %{value: float, noise_sigma: float}
  noise_sigma represents how noisy/unreliable this observation is.
  """
  def update(%Normal{} = prior, :normal, %{value: obs, noise_sigma: noise_sigma}) do
    prior_precision = 1.0 / (prior.sigma * prior.sigma)
    obs_precision = 1.0 / (noise_sigma * noise_sigma)
    post_precision = prior_precision + obs_precision
    post_mu = (prior_precision * prior.mu + obs_precision * obs) / post_precision
    post_sigma = :math.sqrt(1.0 / post_precision)
    %Normal{mu: post_mu, sigma: post_sigma}
  end

  @doc """
  Update a Categorical prior with an observed category.
  Uses Dirichlet-Categorical conjugacy (increment the observed category's count).
  """
  def update(%Categorical{} = prior, :observation, %{observed: category}) do
    idx = Enum.find_index(prior.categories, &(&1 == category))
    if idx do
      counts = Enum.map(prior.probabilities, &(&1 * 100))  # pseudo-counts
      updated_counts = List.update_at(counts, idx, &(&1 + 1))
      total = Enum.sum(updated_counts)
      %Categorical{prior | probabilities: Enum.map(updated_counts, &(&1 / total))}
    else
      prior  # unknown category, no update
    end
  end

  # --- Divergence Metrics ---

  @doc "KL divergence between two Beta distributions (measures belief disagreement)."
  def kl_divergence(%Beta{} = p, %Beta{} = q) do
    # KL(P || Q) for Beta distributions — closed form via digamma/lnbeta
    lnbeta(q.alpha, q.beta) - lnbeta(p.alpha, p.beta) +
      (p.alpha - q.alpha) * digamma(p.alpha) +
      (p.beta - q.beta) * digamma(p.beta) +
      (q.alpha - p.alpha + q.beta - p.beta) * digamma(p.alpha + p.beta)
  end
end
```

### 4.2 Belief State (Per-Agent)

```elixir
defmodule Rho.Sim.BeliefState do
  @moduledoc """
  A portfolio of probabilistic beliefs held by one agent.
  Each belief is a named probability distribution.
  """

  defstruct [
    beliefs: %{},          # %{belief_name => Belief.Beta | Belief.Normal | ...}
    observations: [],      # [{tick, source, data}] — audit log
    trust_weights: %{}     # %{source_agent => float 0.0-1.0} — how much to trust messages
  ]

  @doc "Initialize beliefs for a given role."
  def init(:chro, state) do
    %__MODULE__{
      beliefs: %{
        eng_attrition_rate: Belief.Beta.new(3, 47),          # ~6%, uncertain
        overall_morale: Belief.Beta.new(7, 3),               # ~0.7, moderate confidence
        runway_months: Belief.Normal.new(12, 4),             # ~12 months, wide uncertainty
        recruiting_velocity: Belief.Normal.new(45, 15),      # ~45 days to fill, uncertain
        market_comp_position: Belief.Beta.new(5, 5),         # ~P50, very uncertain
        retention_program_efficacy: Belief.Beta.new(2, 2)    # no idea yet
      },
      trust_weights: %{
        hiring_manager: 0.8,    # direct knowledge of their teams
        recruiting_lead: 0.7,   # good pipeline data, no team insight
        cfo: 0.6,               # knows budget, not people
        external_survey: 0.5    # useful but lagged
      }
    }
  end

  @doc """
  Apply a Bayesian update based on an observation.
  Returns updated BeliefState with observation logged.
  """
  def observe(belief_state, tick, source, observation, observation_model) do
    updates = observation_model.updates_for(source, observation)

    new_beliefs = Enum.reduce(updates, belief_state.beliefs, fn {name, update_spec}, beliefs ->
      case Map.get(beliefs, name) do
        nil -> beliefs
        prior ->
          trust = Map.get(belief_state.trust_weights, source, 0.5)
          posterior = apply_trusted_update(prior, update_spec, trust)
          Map.put(beliefs, name, posterior)
      end
    end)

    %{belief_state |
      beliefs: new_beliefs,
      observations: [{tick, source, observation} | belief_state.observations]
    }
  end

  # Trust-weighted update: scale the evidence by trust level.
  # Low trust → observation has less impact on posterior.
  defp apply_trusted_update(prior, {:binomial, %{successes: s, trials: n}}, trust) do
    # Scale effective sample size by trust
    effective_s = s * trust
    effective_n = n * trust
    Belief.update(prior, :binomial, %{successes: effective_s, trials: effective_n})
  end

  defp apply_trusted_update(prior, {:normal, %{value: v, noise_sigma: ns}}, trust) do
    # Lower trust → higher effective noise (less belief shift)
    effective_noise = ns / max(trust, 0.01)
    Belief.update(prior, :normal, %{value: v, noise_sigma: effective_noise})
  end
end
```

### 4.3 Observation Model (Domain-Specific Mapping)

```elixir
defmodule Rho.Sim.Domains.Workforce.ObservationModel do
  @moduledoc """
  Maps workforce observations to Bayesian update specifications.

  This is the bridge between "what happened in the world" and
  "how an agent's beliefs change."
  """

  @doc """
  Given an observation source and data, return a list of
  {belief_name, update_spec} tuples.
  """
  def updates_for(:domain_observation, %{departures_this_tick: deps, active_count: n}) do
    [
      {:eng_attrition_rate, {:binomial, %{successes: deps, trials: n}}}
    ]
  end

  def updates_for(:domain_observation, %{engagement_survey: score, sample_size: n}) do
    [
      {:overall_morale, {:normal, %{value: score, noise_sigma: 1.0 / :math.sqrt(n)}}}
    ]
  end

  def updates_for(:agent_message, %{from: _agent, content: content}) do
    # Parse structured content from agent messages
    # E.g., "Morale on platform team is low" → morale belief update
    parse_message_signals(content)
  end

  def updates_for(:tool_result, %{tool: "check_market_rates", result: %{percentile: p}}) do
    [
      {:market_comp_position, {:normal, %{value: p / 100, noise_sigma: 0.05}}}
    ]
  end

  def updates_for(:retention_outcome, %{target_id: _id, stayed: true}) do
    [
      {:retention_program_efficacy, {:bernoulli, %{outcome: 1}}}
    ]
  end

  def updates_for(:retention_outcome, %{target_id: _id, stayed: false}) do
    [
      {:retention_program_efficacy, {:bernoulli, %{outcome: 0}}}
    ]
  end
end
```

### 4.4 Integration with Policy.decide/4

The belief state lives inside the policy state and is updated each tick before the LLM makes a decision:

```elixir
defmodule Rho.Sim.Policies.Workforce.LLM do
  @behaviour Rho.Sim.Policy

  defstruct [:belief_state, :llm_opts, :role, :observation_model]

  @impl Rho.Sim.Policy
  def init(actor_id, opts) do
    {:ok, %__MODULE__{
      belief_state: BeliefState.init(opts[:role], nil),
      llm_opts: opts[:llm_opts] || %{model: "claude-sonnet-4-6"},
      role: opts[:role],
      observation_model: opts[:observation_model] || Workforce.ObservationModel
    }}
  end

  @impl Rho.Sim.Policy
  def decide(actor_id, observation, ctx, state) do
    # Step 1: Update beliefs from this tick's observation
    updated_beliefs = BeliefState.observe(
      state.belief_state, ctx.step, :domain_observation,
      observation, state.observation_model
    )

    # Step 2: Render beliefs as natural language for LLM prompt
    belief_prompt = render_beliefs(updated_beliefs, state.role)

    # Step 3: Render observation as natural language
    obs_prompt = render_observation(observation, state.role)

    # Step 4: Call LLM with beliefs + observation + action space
    prompt = build_prompt(state.role, belief_prompt, obs_prompt, ctx)
    {:ok, proposal} = call_llm(prompt, state.llm_opts, action_schema(state.role))

    # Step 5: Return proposal and updated policy state
    {:ok, proposal, %{state | belief_state: updated_beliefs}}
  end

  defp render_beliefs(belief_state, :chro) do
    """
    Your current beliefs (updated with latest evidence):
    - Engineering attrition rate: #{format_beta(belief_state.beliefs.eng_attrition_rate)} monthly
    - Overall morale: #{format_beta(belief_state.beliefs.overall_morale)}
    - Time to fill open reqs: #{format_normal(belief_state.beliefs.recruiting_velocity)} days
    - Market comp position: #{format_beta(belief_state.beliefs.market_comp_position)} (0=bottom, 1=top)
    - Retention program effectiveness: #{format_beta(belief_state.beliefs.retention_program_efficacy)}

    Confidence levels: #{confidence_summary(belief_state)}
    """
  end

  defp format_beta(%Belief.Beta{} = d) do
    mean = Belief.Beta.mean(d)
    p10 = Belief.Beta.percentile(d, 0.1)
    p90 = Belief.Beta.percentile(d, 0.9)
    "#{Float.round(mean, 2)} (80% CI: #{Float.round(p10, 2)}-#{Float.round(p90, 2)})"
  end
end
```

---

## 5. Layer 4: ELTV Computation

### 5.1 Per-Employee ELTV

```elixir
defmodule Rho.Sim.ELTV do
  @moduledoc """
  Compute Employee Lifetime Value from simulation results.

  ELTV = Σ (value_generated_t - cost_t) × discount_t
         for t = hire_tick to departure_tick (or simulation end)

  Computed per-employee, per-run. Aggregated across ensemble for distributions.
  """

  @monthly_discount_rate 0.005  # ~6% annual, applied monthly

  @doc """
  Compute ELTV for a single employee in a single simulation run.
  Requires the full trace of states from the run.
  """
  def compute_single(employee_id, trace, domain_state_at_end) do
    trace
    |> Enum.filter(fn {_tick, state} -> Map.has_key?(state.employees, employee_id) end)
    |> Enum.map(fn {tick, state} ->
      emp = state.employees[employee_id]
      value = monthly_value(emp, state)
      cost = monthly_cost(emp)
      discount = :math.pow(1 + @monthly_discount_rate, -tick)
      (value - cost) * discount
    end)
    |> Enum.sum()
  end

  @doc """
  Monthly value generated by an employee.
  Factors: base productivity × role multiplier × collaboration effects × knowledge premium.
  """
  def monthly_value(employee, state) do
    base = role_value_rate(employee.role)
    productivity_factor = employee.productivity    # 0-1, accounts for ramp
    knowledge_premium = knowledge_value(employee, state)
    collaboration = collaboration_multiplier(employee, state)

    base * productivity_factor * collaboration + knowledge_premium
  end

  @doc "Monthly cost: compensation + overhead + allocated management cost."
  def monthly_cost(employee) do
    comp_monthly = employee.comp_annual / 12
    overhead = comp_monthly * 0.25    # benefits, tools, office
    comp_monthly + overhead
  end

  @doc """
  Knowledge premium: extra value from being a critical knowledge holder.
  If this person is the only one who knows payments_api, they're worth more
  than their productivity alone — losing them would cost the team much more.
  """
  def knowledge_value(employee, state) do
    critical_domains = KnowledgeGraph.knowledge_loss(employee.id, state.knowledge_graph)
    Enum.reduce(critical_domains, 0.0, fn domain, acc ->
      holders = Map.get(state.knowledge_graph, domain, [])
      # Value is inversely proportional to number of holders
      # Sole holder of a critical domain: high premium
      scarcity = 1.0 / max(length(holders), 1)
      acc + domain_value_rate(domain) * scarcity
    end)
  end

  @doc """
  Replacement cost: the cost of losing this employee and backfilling.
  Included in ELTV calculation as a negative terminal event.
  """
  def replacement_cost(employee, state) do
    recruiting = avg_cost_per_hire(employee.role, state)
    ramp = ramp_cost(employee.role)                         # months × reduced productivity
    knowledge_loss = KnowledgeGraph.productivity_impact(employee.id, state)
    morale_cost = contagion_cost(employee, state)           # estimated downstream departures

    recruiting + ramp + knowledge_loss + morale_cost
  end
end
```

### 5.2 Portfolio-Level Aggregation

```elixir
defmodule Rho.Sim.ELTV.Portfolio do
  @moduledoc """
  Aggregate individual ELTVs into portfolio-level metrics.
  Operates on ensemble results (list of per-run ELTV maps).
  """

  @doc """
  From an ensemble of N runs, compute ELTV distribution per employee
  and portfolio-level risk metrics.
  """
  def analyze(ensemble_results) do
    # ensemble_results: [%{employee_id => eltv_value}] — one map per run

    per_employee = ensemble_results
    |> transpose()  # %{employee_id => [eltv_across_runs]}
    |> Map.new(fn {id, values} ->
      {id, %{
        mean: mean(values),
        median: percentile(values, 50),
        p10: percentile(values, 10),
        p90: percentile(values, 90),
        std: std(values),
        prob_negative: Enum.count(values, &(&1 < 0)) / length(values)
      }}
    end)

    total_per_run = Enum.map(ensemble_results, fn run_eltvs ->
      Enum.sum(Map.values(run_eltvs))
    end)

    %{
      per_employee: per_employee,
      portfolio: %{
        mean: mean(total_per_run),
        median: percentile(total_per_run, 50),
        p10: percentile(total_per_run, 10),
        p90: percentile(total_per_run, 90),
        std: std(total_per_run)
      },
      concentration_risk: concentration_risk(per_employee),
      eltv_at_risk: eltv_at_risk(per_employee)
    }
  end

  @doc "Top employees by ELTV concentration — portfolio depends heavily on these."
  def concentration_risk(per_employee) do
    sorted = per_employee
    |> Enum.sort_by(fn {_id, stats} -> -stats.mean end)

    total_eltv = sorted |> Enum.map(fn {_, s} -> s.mean end) |> Enum.sum()
    top_3_eltv = sorted |> Enum.take(3) |> Enum.map(fn {_, s} -> s.mean end) |> Enum.sum()
    top_10_eltv = sorted |> Enum.take(10) |> Enum.map(fn {_, s} -> s.mean end) |> Enum.sum()

    %{
      top_3_share: top_3_eltv / max(total_eltv, 1),
      top_10_share: top_10_eltv / max(total_eltv, 1),
      top_3: Enum.take(sorted, 3) |> Enum.map(&elem(&1, 0)),
      gini_coefficient: gini(Enum.map(sorted, fn {_, s} -> s.mean end))
    }
  end

  @doc "Expected ELTV lost to attrition in the simulation horizon."
  def eltv_at_risk(per_employee) do
    per_employee
    |> Enum.filter(fn {_id, stats} -> stats.prob_negative > 0.2 end)
    |> Enum.map(fn {id, stats} ->
      {id, %{expected_loss: abs(min(stats.p10, 0)), prob_departure: stats.prob_negative}}
    end)
    |> Enum.sort_by(fn {_, s} -> -s.expected_loss end)
  end
end
```

### 5.3 Intervention Comparison

```elixir
defmodule Rho.Sim.ELTV.Interventions do
  @moduledoc """
  Compare intervention strategies by running ensembles with and without
  each intervention and computing the ELTV delta.
  """

  @doc """
  Run baseline + N intervention scenarios, return comparative analysis.
  """
  def compare(base_opts, interventions) do
    # Run baseline ensemble
    {:ok, baseline} = Runner.run_many(base_opts)

    # Run each intervention as a separate ensemble
    results = Enum.map(interventions, fn {name, intervention_opts} ->
      merged = Keyword.merge(base_opts, intervention_opts)
      {:ok, result} = Runner.run_many(merged)
      {name, result}
    end)

    baseline_eltv = ELTV.Portfolio.analyze(baseline.results)

    comparisons = Enum.map(results, fn {name, result} ->
      intervention_eltv = ELTV.Portfolio.analyze(result.results)
      delta = intervention_eltv.portfolio.mean - baseline_eltv.portfolio.mean
      cost = intervention_cost(name, Keyword.get(base_opts, :domain_opts, []))

      {name, %{
        portfolio_eltv: intervention_eltv.portfolio,
        delta_eltv: delta,
        cost: cost,
        roi: delta / max(cost, 1),
        prob_positive_roi: prob_positive_roi(baseline.results, result.results)
      }}
    end)

    %{
      baseline: baseline_eltv,
      interventions: Map.new(comparisons),
      recommendation: best_intervention(comparisons)
    }
  end
end
```

---

## 6. Layer 5: Rho Integration

### 6.1 Simulation Mount

```elixir
defmodule Rho.Sim.Mount do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_opts, _context) do
    [
      run_simulation_tool(),
      run_ensemble_tool(),
      compare_interventions_tool(),
      inspect_run_tool(),
      get_eltv_report_tool()
    ]
  end

  defp run_simulation_tool do
    %{
      tool: ReqLLM.tool(
        name: "run_simulation",
        description: "Run a single workforce simulation with full trace for debugging.",
        parameter_schema: [
          scenario: [type: :string, required: true, doc: "Scenario description or preset name"],
          max_steps: [type: :integer, doc: "Simulation months (default: 12)"],
          seed: [type: :integer, doc: "Random seed for reproducibility"]
        ]
      ),
      execute: fn args -> execute_single_run(args) end
    }
  end

  defp run_ensemble_tool do
    %{
      tool: ReqLLM.tool(
        name: "run_ensemble",
        description: """
        Run a Monte Carlo ensemble of workforce simulations.
        Returns ELTV distributions and portfolio risk metrics.
        """,
        parameter_schema: [
          scenario: [type: :string, required: true],
          runs: [type: :integer, doc: "Number of parallel universes (default: 100)"],
          max_steps: [type: :integer, doc: "Months per run (default: 12)"],
          interventions: [type: :object, doc: "Scheduled interventions by tick"]
        ]
      ),
      execute: fn args -> execute_ensemble(args) end
    }
  end

  defp compare_interventions_tool do
    %{
      tool: ReqLLM.tool(
        name: "compare_interventions",
        description: """
        Compare multiple HR intervention strategies against a baseline.
        Returns ROI analysis with confidence intervals for each.
        """,
        parameter_schema: [
          scenario: [type: :string, required: true],
          interventions: [type: :array, required: true, doc: "List of intervention specs"],
          runs_per_scenario: [type: :integer, doc: "Runs per scenario (default: 100)"]
        ]
      ),
      execute: fn args -> execute_comparison(args) end
    }
  end

  defp get_eltv_report_tool do
    %{
      tool: ReqLLM.tool(
        name: "get_eltv_report",
        description: "Get Employee Lifetime Value report from the last ensemble run.",
        parameter_schema: [
          group_by: [type: :string, doc: "Group by: employee, team, role, or portfolio"],
          top_n: [type: :integer, doc: "Number of top results to show"]
        ]
      ),
      execute: fn args -> get_eltv_report(args) end
    }
  end
end
```

### 6.2 LLM Policy Integration with Agent.Worker

When an LLM policy needs to make a decision, it delegates to a real Rho agent:

```elixir
defmodule Rho.Sim.Policies.Workforce.LLMPolicy do
  @behaviour Rho.Sim.Policy

  @impl Rho.Sim.Policy
  def decide(actor_id, observation, ctx, state) do
    # Build prompt with belief state + observation
    prompt = build_decision_prompt(actor_id, observation, state.belief_state, ctx)

    # Use Rho's existing LLM infrastructure (ReqLLM) directly
    # No need to spawn a full Agent.Worker — just call the model
    messages = [
      %{role: "system", content: system_prompt(actor_id, state.role)},
      %{role: "user", content: prompt}
    ]

    # Structured output: force JSON response matching action schema
    case ReqLLM.chat(state.model, messages, response_format: action_schema(actor_id)) do
      {:ok, %{choices: [%{message: %{content: json}}]}} ->
        {:ok, proposal} = Jason.decode(json)
        updated_beliefs = BeliefState.observe(state.belief_state, ctx.step,
          :domain_observation, observation, state.observation_model)
        {:ok, proposal, %{state | belief_state: updated_beliefs}}

      {:error, reason} ->
        # Fallback to rule-based policy on LLM failure
        state.fallback.decide(actor_id, observation, ctx, state.fallback_state)
    end
  end
end
```

**Key design decision**: LLM policies call `ReqLLM` directly instead of spawning full `Agent.Worker` processes. Reasons:
- A simulation with 5 LLM actors, 12 ticks, 100 runs = 6,000 LLM calls. Spawning 6,000 GenServer processes with signal bus subscriptions, tape persistence, and mount dispatch would be massive overhead for what is essentially a single structured LLM call per decision.
- The agent infrastructure (Worker, mounts, tape) is designed for long-running conversational agents. Simulation policy decisions are one-shot: observation in, proposal out.
- If a policy *does* need multi-turn reasoning (rare), it can internally use `Rho.AgentLoop.run/3` as a function call without the Worker wrapper.

---

## 7. Implementation Phases

### Phase 1: Simulation Kernel + Toy Domain (2 weeks)

**Goal**: Engine runs, rule-based policies work, ensemble produces distributions.

**Deliverables**:
- `Rho.Sim.Domain` behaviour
- `Rho.Sim.Policy` behaviour
- `Rho.Sim.Engine` (step/2, run/2) — pure functions
- `Rho.Sim.Run`, `Rho.Sim.Accumulator`, `Rho.Sim.Context` structs
- `Rho.Sim.Runner` (run_many/1) — parallel via Task.Supervisor
- Toy domain: simple headcount model (aggregate, 2 roles, 2 actors)
- Rule-based policies for toy domain
- Property tests: determinism, conservation, halt conditions

**Acceptance criteria**:
- `Engine.run(run, acc)` completes for 100 steps with toy domain
- Same seed produces identical results
- `Runner.run_many(runs: 500)` completes in <5 seconds with rule-based policies
- Failed runs reported separately, don't crash ensemble

### Phase 2: Workforce Domain (Individual-Level) (3 weeks)

**Goal**: Realistic workforce simulation with individual employees.

**Deliverables**:
- `Rho.Sim.Domains.Workforce` (full domain with State, Employee, Requisition)
- Departure model with configurable coefficients
- Satisfaction model (multi-factor weighted)
- Knowledge graph + bus factor computation
- Recruiting pipeline state machine
- Market model (exogenous comp shifts)
- Rule-based policies: `:chro`, `:hiring_manager`, `:recruiting_lead`
- Scenario presets (growth phase, downturn, reorg)

**Acceptance criteria**:
- 150-employee company runs 12-month simulation in <1 second (rule-based)
- Attrition rates calibrate to ~15% annual when satisfaction is neutral
- Knowledge loss from departure visibly impacts team velocity in traces
- Cluster departures emerge naturally from contagion model

### Phase 3: Bayesian Belief Engine (2 weeks)

**Goal**: Agents maintain and update probabilistic beliefs.

**Deliverables**:
- `Rho.Sim.Belief` (Beta, Normal, Categorical + conjugate updates)
- `Rho.Sim.BeliefState` (per-agent belief portfolio, trust weights)
- `Rho.Sim.Domains.Workforce.ObservationModel` (observation → update mapping)
- Integration with `Policy.decide/4` (beliefs passed to policy state)
- Belief rendering as natural language (for LLM prompt injection)
- Belief divergence metrics (KL divergence between agents)

**Acceptance criteria**:
- Beta update: observing 5 departures in 50 people shifts attrition belief correctly
- Normal update: observing exact budget number sharpens runway belief
- Trust weighting: low-trust source produces smaller belief shift
- Beliefs converge toward true values over multiple ticks with honest observations

### Phase 4: ELTV Computation (2 weeks)

**Goal**: Compute individual and portfolio ELTV from ensemble results.

**Deliverables**:
- `Rho.Sim.ELTV` (per-employee value/cost/replacement computation)
- `Rho.Sim.ELTV.Portfolio` (aggregation, concentration risk, ELTV-at-risk)
- `Rho.Sim.ELTV.Interventions` (comparative analysis across scenarios)
- Value model calibration (role-based value rates, knowledge premiums)
- Report formatting (text output suitable for LLM consumption)

**Acceptance criteria**:
- ELTV distribution for a senior engineer with unique knowledge is right-skewed (high upside if stays, negative if leaves early)
- Portfolio concentration risk correctly identifies single-point-of-failure employees
- Intervention comparison shows measurable ELTV delta for retention packages
- Replacement cost model accounts for recruiting, ramp, knowledge loss, and contagion

### Phase 5: LLM Policies + Rho Integration (3 weeks)

**Goal**: LLM agents make decisions in simulation; tools exposed to Rho agents.

**Deliverables**:
- `Rho.Sim.Policies.Workforce.LLMPolicy` (LLM-backed decide/4)
- `Rho.Sim.Policies.Workforce.HybridPolicy` (rule-based with LLM for edge cases)
- `Rho.Sim.Mount` (tools: run_simulation, run_ensemble, compare_interventions, get_eltv_report)
- Prompt engineering for each HR role (action space, belief rendering, observation formatting)
- Fallback to rule-based on LLM failure
- Cost optimization: use cheaper models for routine decisions, expensive for critical ones

**Acceptance criteria**:
- LLM policy produces valid proposals that pass domain validation
- Hybrid policy falls back cleanly on LLM timeout/error
- `run_ensemble(runs: 100)` with 1 LLM actor + 2 rule-based completes in <10 minutes
- Rho agent can call `run_ensemble` tool and interpret ELTV report
- Intervention comparison produces actionable ROI numbers

### Phase 6: Observatory Integration (2 weeks)

**Goal**: Visualize simulation runs and ELTV distributions in the web UI.

**Deliverables**:
- LiveView components for: simulation progress, ELTV distributions, belief evolution, intervention comparison
- Integration with existing Observatory infrastructure
- Real-time streaming of ensemble progress via signal bus

---

## 8. Dependencies to Add

```elixir
# mix.exs — new dependencies

# Statistics (for percentile, mean, std, distribution functions)
{:statistex, "~> 1.0"},          # percentiles, descriptive stats

# No other external deps needed:
# - Beta/Normal CDF: implement via Erlang :math (sufficient for conjugate updates)
# - JSON: already have Jason
# - Parallel execution: already have Task.Supervisor
# - LLM calls: already have ReqLLM
```

Alternatively, implement percentile/mean/std inline (~30 lines) to avoid adding a dependency for basic statistics.

---

## 9. Configuration

### 9.1 Domain Configuration (passed as opts to domain.init/1)

```elixir
# Example scenario configuration
%{
  domain: Rho.Sim.Domains.Workforce,
  domain_opts: [
    employees: load_employees("data/current_roster.json"),
    market: %{
      senior_engineer: %{median_comp: 220_000, demand_index: 0.8, supply_index: 0.4},
      pm: %{median_comp: 180_000, demand_index: 0.6, supply_index: 0.6}
    },
    budget: %{total: 2_000_000, retention_pool: 500_000, recruiting_pool: 300_000},
    departure_coefficients: %{...},     # calibrated from historical data
    satisfaction_weights: %{...}        # tuned for this company
  ],
  policies: %{
    chro: {Rho.Sim.Policies.Workforce.LLMPolicy, role: :chro, model: "claude-sonnet-4-6"},
    hiring_manager_eng: {Rho.Sim.Policies.Workforce.RuleBased, strategy: :backfill_critical},
    hiring_manager_sales: {Rho.Sim.Policies.Workforce.RuleBased, strategy: :pipeline_growth},
    recruiting_lead: {Rho.Sim.Policies.Workforce.RuleBased, strategy: :fifo_priority}
  },
  runs: 200,
  max_steps: 12,
  interventions: %{
    3 => [{:deploy_retention, %{target: :top_10_flight_risk, amount: 30_000}}],
    6 => [{:market_comp_refresh, %{adjustment: 0.05}}]
  }
}
```

### 9.2 Adding Simulation Mount to .rho.exs

```elixir
# In .rho.exs agent config
%{
  default: [
    mounts: [:bash, :fs_read, :fs_write, :multi_agent, :simulation],
    # ...
  ]
}
```

And in `Rho.Config`:

```elixir
@mount_modules %{
  # existing mounts...
  simulation: Rho.Sim.Mount
}
```

---

## 10. Testing Strategy

### Unit Tests (Fast, No LLM)

| Module | Test Focus |
|--------|-----------|
| `Belief` | Conjugate updates produce correct posteriors |
| `BeliefState` | Trust weighting scales evidence correctly |
| `DepartureModel` | Flight risk monotonic in satisfaction, comp, etc. |
| `SatisfactionModel` | Weighted combination correct, inertia works |
| `KnowledgeGraph` | Bus factor computation, loss detection |
| `Engine` | Step sequence correct, halt conditions work |
| `ELTV` | Value/cost arithmetic, discount factor correct |
| `ELTV.Portfolio` | Aggregation, concentration risk, Gini coefficient |

### Integration Tests (Ensemble, No LLM)

| Test | What It Validates |
|------|-------------------|
| Determinism | Same seed → same ELTV distribution |
| Conservation | Budget spent = costs incurred; headcount tracks correctly |
| Convergence | Larger ensemble → tighter confidence intervals |
| Sensitivity | Higher attrition coefficient → more departures → lower ELTV |
| Intervention impact | Retention packages → measurably higher ELTV vs baseline |

### End-to-End Tests (With LLM, Slow)

| Test | What It Validates |
|------|-------------------|
| LLM policy validity | Proposals pass domain validation |
| Fallback | LLM timeout → rule-based fallback → run completes |
| Mount integration | Rho agent calls run_ensemble → gets ELTV report |
| Belief evolution | LLM decisions improve as beliefs sharpen |

---

## 11. Key Technical Risks

| Risk | Mitigation |
|------|-----------|
| LLM cost for large ensembles | Hybrid policies: rule-based for most actors, LLM for key decision-makers only. Budget: 1 LLM actor × 12 ticks × 100 runs = 1,200 calls ≈ $6 with Sonnet |
| LLM latency in ensemble | Parallelize across runs (not within). Each run's LLM calls are sequential, but runs execute concurrently. 100 runs × 12 ticks = 1,200 calls, ~10 min with 8 parallel runs |
| Non-determinism from LLM | Accept it. LLM decisions add variance, which the ensemble captures. Same seed only guarantees same stochastic events, not same LLM responses. This is a feature, not a bug — it models real decision-maker variability |
| Departure model calibration | Start with industry defaults (BLS data, Visier benchmarks). Expose coefficients as configuration. Let users calibrate from their own historical data |
| Memory for 200-run traces | Default: metrics-only (no full trace). Full trace only for single debugging runs. Metrics per run ≈ 12 maps × ~20 keys = ~2KB. 200 runs = 400KB |
| Beta CDF computation | Use Erlang `:math` for log-gamma. Implement regularized incomplete beta function (~40 lines). Or use a continued fraction approximation |
