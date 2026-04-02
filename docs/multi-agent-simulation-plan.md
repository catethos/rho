# Multi-Agent Simulation with Bayesian World State

*A plan for extending Rho into an agent-based simulation platform where AI agents maintain probabilistic beliefs about a shared world, updated through interaction and observation.*

---

## 1. The Core Idea in Plain English

Imagine you want to simulate how a company responds to a market downturn. You create five AI agents: a CEO, a CFO, a VP of Engineering, a Head of Sales, and a Board Member. Each has a different personality, set of priorities, and partial view of the company.

Today, Rho can already spawn these agents and let them talk to each other. But that's just a group chat. The agents produce *narratives* — "I think we should cut costs" — not *predictions*. There's no shared reality that constrains what they can say, no way to run the scenario 100 times to see what usually happens, and no mechanism for agents to learn from what they observe.

The extension described here adds three things:

1. **A shared world state** — a structured data model (headcount, revenue, burn rate, morale scores) that represents the actual state of affairs. Agents can't just claim morale is high if layoffs just happened; the world state says otherwise.

2. **Bayesian belief updating** — each agent maintains a *probabilistic* internal model of the world. They don't know everything. The CFO has precise budget numbers but vague engineering estimates. When an agent uses a tool (reads a report, asks a question, runs an analysis), the result updates their internal beliefs using Bayes' rule. This is the mathematical machinery for "learning from evidence."

3. **Monte Carlo ensemble runs** — instead of running one simulation and treating its output as truth, we run hundreds with randomized starting conditions and stochastic events (someone quits unexpectedly, a deal falls through). The distribution of outcomes across runs *is* the prediction. "In 73% of runs, the company hits runway crisis by month 8" is a prediction. "The CEO decided to cut costs" is a story.

---

## 2. What Rho Already Has

Before describing what to build, here's what's already in place:

### 2.1 Agent Infrastructure (Ready)

Every agent in Rho is a GenServer process (`Agent.Worker`) with:
- A unique identity and role (`:ceo`, `:cfo`, etc.)
- An LLM reasoning loop that calls tools and processes results
- A persistent memory tape (append-only log of everything the agent has said and done)
- Registration in a shared registry for discovery

### 2.2 Inter-Agent Communication (Ready)

Agents communicate through a signal bus (`Rho.Comms`):
- **Direct messages**: Agent A sends a message to Agent B's inbox
- **Task delegation**: Agent A asks Agent B to do something and waits for the result
- **Broadcasting**: Send to all agents in a session
- **Causality tracking**: Every signal carries IDs linking cause to effect

### 2.3 Multi-Agent Coordination Tools (Ready)

The `MultiAgent` mount gives agents tools to:
- `spawn_agent` — create a new agent with a role
- `send_message` — communicate with another agent
- `delegate_task` / `await_task` — assign and wait for subtasks
- `list_agents` / `get_agent_card` — discover who else exists

### 2.4 Pluggable Reasoning (Ready)

The agent loop delegates to a `Reasoner` strategy:
- `Reasoner.Direct` — standard LLM tool-calling
- `Reasoner.Structured` — LLM outputs JSON actions
- Custom reasoners can be plugged in via config

### 2.5 Mount System for Extension (Ready)

All agent capabilities arrive through "mounts" — plugin modules that can:
- Provide tools the agent can call
- Contribute to the agent's system prompt
- Hook into lifecycle events (before/after LLM calls, tool execution)
- Run supervised child processes

**What's missing**: a simulation kernel (world state + physics), belief state per agent, Bayesian update mechanics, and an ensemble runner.

---

## 3. Architecture of the Extension

### 3.1 Conceptual Model

```
                    ┌─────────────────────────────┐
                    │    Simulation Runner         │
                    │  (runs N copies in parallel) │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │    World State (shared)       │
                    │  headcount: 150               │
                    │  revenue: $2.1M/mo            │
                    │  burn_rate: $1.8M/mo          │
                    │  morale: {eng: 0.6, sales: 0.8}│
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼──────┐ ┌──────▼───────┐ ┌──────▼──────┐
     │  CEO Agent    │ │  CFO Agent   │ │  VP Eng     │
     │               │ │              │ │  Agent      │
     │ Beliefs:      │ │ Beliefs:     │ │ Beliefs:    │
     │  morale ~0.7  │ │  burn ~1.8M  │ │  morale ~0.5│
     │  runway ~12mo │ │  runway ~10mo│ │  attrition  │
     │  (uncertain)  │ │  (precise)   │ │  risk: high │
     └───────────────┘ └──────────────┘ └─────────────┘
```

Each simulation tick:
1. The **Domain** computes stochastic events (someone quits, a deal closes)
2. Each **Agent** observes a partial, noisy view of the world
3. Each agent **updates their beliefs** based on what they observed
4. Each agent **decides** what to do (the LLM reasons over beliefs + observations)
5. The **Domain** resolves all decisions into state changes
6. Repeat

### 3.2 The Four New Components

#### Component 1: World State & Domain Physics (`Rho.Sim.Domain`)

The domain defines the "physics" of the simulation — the rules that govern how the world works. This is *not* an LLM. It's deterministic code with explicit randomness.

```
Domain behaviour:
  init(opts)                    → initial world state
  actors(state)                 → who acts this tick
  observe(actor, state)         → what this actor can see (partial observability)
  sample(state, rng)            → stochastic events (rolls of the dice)
  transition(state, actions, rolls) → next state + events
  metrics(state)                → numbers to track across runs
```

**Why not let the LLM handle world state?** Because LLMs hallucinate. If you ask an LLM "what's the company's burn rate after these decisions?", it will make up a plausible number. But plausible isn't correct. The domain enforces accounting identities: money spent is money gone. Headcount changed means salary costs changed. The LLM decides *what to do*; the domain computes *what happens*.

#### Component 2: Agent Belief State (`Rho.Sim.BeliefState`)

Each agent carries a probabilistic model of the world — not a point estimate ("morale is 0.7") but a distribution ("morale is Beta(7, 3), meaning I think it's probably around 0.7 but I'm not very sure").

```elixir
# Conceptual structure of an agent's belief state
%BeliefState{
  # Each belief is a probability distribution, not a single number
  variables: %{
    team_morale:  %Beta{alpha: 7, beta: 3},        # ~0.7, moderate confidence
    runway_months: %Normal{mu: 11, sigma: 2.5},    # ~11 months, uncertain
    competitor_threat: %Beta{alpha: 3, beta: 7},    # ~0.3, thinks it's low
    hiring_success_rate: %Beta{alpha: 12, beta: 4}  # ~0.75, fairly confident
  },
  # What the agent has observed so far (evidence log)
  observations: [
    {tick: 3, source: :quarterly_report, data: %{revenue: 2_100_000}},
    {tick: 5, source: :message_from_vp_eng, data: %{morale_concern: true}}
  ]
}
```

**Why probability distributions instead of single numbers?** Because uncertainty is information. If the CEO thinks morale is "about 0.7" with low confidence, they should gather more information before acting. If they're highly confident, they can act immediately. Single numbers hide this distinction. Distributions preserve it.

#### Component 3: Bayesian Update Engine (`Rho.Sim.Bayes`)

When an agent observes something — reads a report, receives a message, sees the result of a tool call — their beliefs update according to Bayes' rule:

```
P(world | evidence) ∝ P(evidence | world) × P(world)
  posterior              likelihood           prior

In English:
  What I now believe  =  How likely is this evidence  ×  What I believed before
                         if my old belief were true?
```

This happens automatically whenever an agent interacts with the world:

```
Agent action                    What updates
─────────────────────────────── ──────────────────────────────────────
CEO reads financial report      → revenue belief sharpens (low uncertainty)
VP Eng hears about 2 resignations → attrition belief shifts upward
CFO asks "what's our runway?"   → runway estimate updates from burn rate data
CEO gets message from Board     → urgency belief increases
Any agent uses a tool           → beliefs related to that tool's domain update
```

The key insight: **every tool use is an observation**. When an agent calls `read_financial_report` and gets back revenue numbers, that's evidence. The Bayesian update engine takes the evidence and adjusts the agent's beliefs accordingly. This is what we mean by "every interaction of external tool use can update the internal state in a Bayesian way."

**How it works mechanically:**

1. Agent decides to use a tool (LLM reasoning)
2. Tool executes against world state (Domain returns observation)
3. Observation is passed to `Rho.Sim.Bayes.update/3`
4. Update function computes new posterior distributions
5. Agent's belief state is replaced with updated beliefs
6. On the agent's next reasoning step, their system prompt includes their current beliefs
7. The LLM reasons over updated beliefs to make decisions

#### Component 4: Ensemble Runner (`Rho.Sim.Runner`)

One simulation run is an anecdote. To make predictions, we run many:

```
Ensemble of 200 runs
├── Run 1:   seed=42,    3 people quit in month 2, big deal closes month 4
├── Run 2:   seed=43,    1 person quits in month 3, deal falls through
├── Run 3:   seed=44,    nobody quits, two deals close
├── ...
└── Run 200: seed=241,   5 people quit in month 1, emergency mode

Aggregate results:
  Runway crisis by month 8:  73% of runs (146/200)
  Headcount below 120:       45% of runs
  Revenue growth > 10%:      12% of runs
  Most common CEO action:    "hiring freeze" (68% of runs)
```

The runner uses Elixir's `Task.Supervisor.async_stream` to run simulations in parallel across CPU cores. Each run gets a different random seed, producing different stochastic events. The *distribution of outcomes* across runs is the prediction.

### 3.3 How It Connects to Existing Rho

The simulation engine connects to Rho through three integration points:

```
Existing Rho                    New Simulation Layer
────────────────────────────    ────────────────────────────────
Agent.Worker (GenServer)    ←→  Carries BeliefState in agent state
                                Belief state injected into prompts

Mount system               ←→  Rho.Sim.Mount provides tools:
                                - observe_world (filtered by role)
                                - propose_action (structured output)
                                - query_beliefs (introspect own beliefs)
                                - inspect_state (debug tool)

Reasoner                   ←→  Sim.Reasoner wraps existing reasoner
                                Intercepts tool results for Bayesian update
                                Injects belief summaries into context

Signal bus                 ←→  Agent messages are observations too
                                Receiving a message updates beliefs
                                about the sender's state/intent

Session                    ←→  Sim.Session wraps Session
                                Manages world state lifecycle
                                Coordinates tick advancement
                                Collects metrics per step
```

---

## 4. The Simulation Loop in Detail

Here's what happens in one tick of a simulation, step by step:

### Step 1: Advance World Clock & Apply Stochastic Events

```
World state at tick 5:
  headcount: 148, revenue: $2.05M, burn: $1.78M, morale: {eng: 0.58, sales: 0.82}

Domain.sample() rolls the dice:
  → 1 engineer resigns (attrition roll: morale 0.58 → 8% monthly attrition → 1 hit)
  → Sales pipeline: 2 new leads (Poisson draw, lambda=2.1)
  → No market shock this month (shock probability: 5%, didn't trigger)
```

### Step 2: Each Agent Observes (Partial, Noisy)

Different agents see different things:

```
CEO observes:     {headcount_delta: -1, revenue_trend: "flat", board_sentiment: "concerned"}
CFO observes:     {exact_burn: 1_780_000, exact_revenue: 2_050_000, runway_months: 11.5}
VP Eng observes:  {eng_headcount: 89→88, open_reqs: 12, sprint_velocity: -5%, resignation: "senior_backend"}
Head of Sales:    {pipeline: +2 leads, close_rate: 0.18, quota_attainment: 0.72}
Board Member:     {quarterly_summary: "...", headcount_trend: "declining", competitor_raised: "$50M"}
```

### Step 3: Bayesian Belief Update

Each agent's belief state updates based on their observation:

```
VP Eng's belief update:
  Prior:    team_morale ~ Beta(7, 3)        → E[morale] = 0.70
  Evidence: senior engineer resigned, velocity dropped 5%
  Likelihood: P(resignation + velocity_drop | morale=x) is higher for low x
  Posterior: team_morale ~ Beta(7.2, 4.8)   → E[morale] = 0.60

  The VP Eng now believes morale is lower AND is more certain about it.
  (The Beta distribution got more concentrated around a lower value.)
```

### Step 4: LLM Decision Making

Each agent's LLM receives their updated beliefs as part of their prompt:

```
System prompt for VP Eng (injected by Sim.Mount):

You are the VP of Engineering. Current beliefs (your best estimates):
- Team morale: 0.60 (confidence: moderate, ↓ from 0.70 last tick)
- Attrition risk: HIGH (senior resignation observed)
- Sprint velocity: declining 5%
- Hiring pipeline: 12 open reqs, estimated 2-3 months to fill

You just observed: A senior backend engineer resigned. Sprint velocity dropped 5%.

What action do you propose? Choose from:
1. retention_package(target, amount) — offer retention bonus to at-risk engineers
2. adjust_hiring(role, priority) — change hiring priorities
3. reorganize_team(plan) — restructure teams
4. escalate(message) — raise concern to CEO
5. hold — take no action this tick
```

The LLM reasons over beliefs + observations and outputs a structured action:

```json
{
  "action": "escalate",
  "target": "ceo",
  "message": "We lost a senior backend engineer. Morale is trending down. I recommend immediate retention packages for our top 5 at-risk engineers before we lose more.",
  "secondary_action": "retention_package",
  "secondary_params": {"target": "top_5_at_risk", "amount": 15000}
}
```

### Step 5: Domain Resolves Actions

All agent proposals are collected and resolved by the domain:

```
Proposals:
  VP Eng:  escalate + retention_package($15k × 5 = $75k)
  CFO:     budget_cut(engineering_tools, $20k/mo)
  CEO:     hiring_freeze(all_non_critical)
  Sales:   increase_pipeline_spend($30k)

Domain.resolve_actions():
  → retention_package: approved (within VP Eng's authority)
  → budget_cut: approved (within CFO's authority)
  → hiring_freeze: approved (CEO authority), blocks Sales' pipeline spend
  → pipeline_spend: DENIED (conflicts with hiring_freeze)

Domain.transition():
  headcount: 148 → 147 (resignation applied)
  burn_rate: $1.78M → $1.74M (budget cut) + $75k one-time (retention)
  morale.eng: 0.58 → 0.61 (retention signal, partially offsets resignation)
  open_reqs: 12 → 12 (freeze doesn't close reqs, just pauses them)
```

### Step 6: Repeat

New world state feeds into the next tick. Agents observe, update beliefs, decide, act. Over 12-24 ticks (simulated months), patterns emerge.

---

## 5. The Bayesian Update Mechanism: How It Actually Works

This section explains the math for people who want to understand the mechanics without needing a statistics PhD.

### 5.1 What is a Belief?

A belief is a probability distribution over possible values. Instead of "morale = 0.7", the agent believes "morale is probably between 0.5 and 0.9, most likely around 0.7."

We represent this with standard probability distributions:
- **Beta(a, b)** — for quantities between 0 and 1 (morale, probability of success, etc.). The mean is a/(a+b). Higher a+b means more confident.
- **Normal(mu, sigma)** — for quantities that can be any number (revenue, headcount, etc.). mu is the center, sigma is the uncertainty.
- **Categorical(probs)** — for discrete choices ("market is growing/flat/shrinking" with probabilities [0.3, 0.5, 0.2]).

### 5.2 How Observations Update Beliefs

Bayes' rule says: new belief = (how well the evidence matches each possibility) × (old belief), normalized.

**Concrete example: updating morale belief after a resignation**

```
Prior belief: morale ~ Beta(7, 3)
  → "I think morale is around 0.7, but I'm not super sure"
  → Picture: a hill centered at 0.7, spread from about 0.4 to 0.95

Observation: one engineer resigned this month (out of 89)

Likelihood model: P(1 resignation | morale = x)
  = monthly_attrition_rate(x) × 89
  = (0.15 - 0.12x) × 89
  (lower morale → higher attrition rate, linear model)

Bayesian update:
  For each possible morale value x:
    posterior(x) ∝ likelihood(x) × prior(x)
    posterior(x) ∝ (0.15 - 0.12x) × x^6 × (1-x)^2

  After normalization, this is approximately Beta(7.2, 4.8)
  → "I now think morale is around 0.60, and I'm a bit more certain"
  → The hill shifted left (lower morale) and got slightly narrower
```

### 5.3 Why This Matters for Simulation Quality

Without Bayesian updating, agents either:
- **Know everything** (unrealistic — real decision-makers have partial information)
- **Know nothing** (the LLM just makes stuff up based on its system prompt)

With Bayesian updating:
- Agents have **calibrated uncertainty** — they know what they don't know
- Information **propagates through interactions** — when the VP Eng tells the CEO about morale, the CEO's morale belief updates
- Agents **learn at different rates** — the CFO updates quickly on financial data (precise observations), slowly on engineering morale (indirect signals)
- The simulation produces **realistic information asymmetry** — the same event (a resignation) affects each agent's beliefs differently based on what they can observe

### 5.4 Tool Use as Observation

This is the key architectural insight: **every tool call is an observation that triggers a Bayesian update**.

The existing Rho mount system has lifecycle hooks: `before_tool` and `after_tool`. We add a Bayesian update step in `after_tool`:

```
Agent calls tool         Tool returns result         Bayes update triggers
──────────────────────── ─────────────────────────── ──────────────────────────
read_financial_report    {revenue: 2.05M, burn: 1.78M}  Revenue/burn beliefs sharpen
check_team_pulse         {responses: [...], avg: 3.2/5}  Morale belief shifts down
ask_agent("cfo", ...)    "Runway is about 11 months"     Runway belief updates
market_research          {competitor_funding: $50M}       Threat belief shifts up
run_analysis(churn_model) {predicted_churn: 0.12}         Attrition belief calibrates
```

The mapping from "tool result" to "belief update" is defined by the domain. The domain knows which beliefs each type of observation affects and how to compute the likelihood.

---

## 6. Implementation Plan

### Phase 1: Simulation Kernel (Pure Functions, No Agents)

Build the engine that can run a simulation without any LLM involvement. Agents are replaced by simple rule-based policies.

**Deliverables:**
- `Rho.Sim.Domain` behaviour (world physics)
- `Rho.Sim.Policy` behaviour (actor decisions)
- `Rho.Sim.Engine` — pure tick loop: observe → decide → resolve → transition
- `Rho.Sim.Run` — simulation state struct
- `Rho.Sim.Context` — per-tick metadata
- One reference domain (e.g., workforce planning)
- One rule-based policy per actor role

**Why rule-based first?** Because it lets us validate the engine, domain, and metrics without paying for LLM calls. If the simulation produces garbage with deterministic policies, the problem is in the domain model, not the LLM.

### Phase 2: Belief State & Bayesian Updates

Add probabilistic belief tracking to the simulation.

**Deliverables:**
- `Rho.Sim.BeliefState` — per-agent belief distributions
- `Rho.Sim.Bayes` — update engine (conjugate updates for common distribution families)
- `Rho.Sim.ObservationModel` — maps domain observations to likelihood functions
- Integration with `Domain.observe/4` — observations trigger belief updates
- Belief state injected into policy `decide/4` calls

**Technical note on conjugate priors:** For common cases (Beta-Binomial for rates, Normal-Normal for quantities), Bayesian updates have closed-form solutions — no sampling or approximation needed. This keeps the update fast (microseconds, not milliseconds).

### Phase 3: LLM Policy Integration

Replace rule-based policies with LLM-backed policies. Each "policy" is now an agent that reasons over its beliefs.

**Deliverables:**
- `Rho.Sim.Policies.LLM` — policy that delegates `decide/4` to an LLM agent
- Belief state → prompt injection (mount that renders beliefs as natural language)
- Structured output parsing for agent proposals
- Action space constraints (agents can only propose valid actions for their role)
- Integration with existing `Agent.Worker` — simulation agents are real Rho agents

### Phase 4: Rho Integration & Ensemble Running

Connect the simulation engine to the existing Rho infrastructure.

**Deliverables:**
- `Rho.Sim.Mount` — tools for triggering simulations from within Rho
- `Rho.Sim.Runner` — parallel ensemble execution
- `Rho.Sim.Metrics` — aggregation across ensemble runs
- Seed management for reproducibility
- Integration with Observatory (web UI) for visualization

### Phase 5: Inter-Agent Communication as Bayesian Evidence

Make agent-to-agent messages update beliefs, not just trigger conversation turns.

**Deliverables:**
- Message content → observation mapping
- Trust-weighted updates (messages from trusted agents shift beliefs more)
- Information cascade detection (agents just echoing each other → correlated beliefs, which reduces ensemble diversity)
- Communication cost modeling (every message is a tick action that could have been something else)

---

## 7. What Makes This Different from "Just Running Agents"

| Property | Agents Chatting | Agent-Based Simulation with Bayesian State |
|----------|----------------|---------------------------------------------|
| World state | Implicit in conversation | Explicit, structured, enforced by domain |
| Agent knowledge | Whatever the LLM hallucinates | Probabilistic beliefs updated from evidence |
| Predictions | Narrative ("I think X will happen") | Distributional (X happens in 73% of runs) |
| Repeatability | Low (different every time) | High (same seed = same stochastic events) |
| Calibration | None (LLM confidence ≠ actual probability) | Built-in (Bayesian updates are calibrated by construction) |
| Information flow | Untracked (who told whom what?) | Explicit (observation log per agent, causal chain) |
| Scalability | Each agent = LLM call per turn | Rule-based agents free; LLM agents on critical path only |

---

## 8. Example: Running a Workforce Planning Simulation

```elixir
# Define the scenario
scenario = %{
  domain: Rho.Sim.Domains.Workforce,
  domain_opts: [
    initial_headcount: 150,
    initial_revenue: 2_100_000,
    initial_burn: 1_800_000,
    attrition_model: :morale_dependent,
    market_condition: :downturn
  ],
  agents: %{
    ceo:      {Rho.Sim.Policies.LLM, role: :ceo, model: "claude-sonnet-4-6"},
    cfo:      {Rho.Sim.Policies.LLM, role: :cfo, model: "claude-sonnet-4-6"},
    vp_eng:   {Rho.Sim.Policies.LLM, role: :vp_eng, model: "claude-sonnet-4-6"},
    sales:    {Rho.Sim.Policies.RuleBased, strategy: :aggressive_pipeline},
    board:    {Rho.Sim.Policies.RuleBased, strategy: :quarterly_review}
  },
  max_steps: 12,    # 12 simulated months
  ensemble: 100     # run 100 times
}

# Run the ensemble
{:ok, results} = Rho.Sim.Runner.run_ensemble(scenario, parallel: System.schedulers_online())

# Analyze results
results
|> Rho.Sim.Metrics.aggregate()
|> IO.inspect()

# => %{
#   runway_crisis_by_month_8: %{probability: 0.73, ci_95: [0.64, 0.81]},
#   headcount_at_month_12: %{mean: 128, median: 131, p10: 108, p90: 145},
#   most_common_ceo_action_month_1: {"hiring_freeze", 0.68},
#   revenue_growth: %{mean: -0.04, p10: -0.18, p90: 0.07},
#   agent_belief_divergence: %{
#     ceo_vs_cfo_runway: %{mean_kl: 0.34},  # CEO and CFO disagree on runway
#     vp_eng_morale_accuracy: %{mean_error: 0.08}  # VP Eng is well-calibrated on morale
#   }
# }
```

### What You Learn from This

1. **Distributional predictions**: "73% chance of runway crisis by month 8" is actionable. "The CEO decided to cut costs" is not.

2. **Belief dynamics**: You can see *how agents' beliefs evolved* — when did the CEO realize the situation was serious? Did the CFO's warnings get through? Where did information asymmetry cause bad decisions?

3. **Policy evaluation**: Swap the CEO's policy from LLM to a rule-based "always freeze hiring early" and re-run. Does it outperform the LLM? Now you can measure whether the AI's judgment adds value over simple heuristics.

4. **Intervention testing**: Schedule an intervention at month 3 — inject a board mandate to cut 10% headcount. How does the system respond across 100 runs? This is counterfactual analysis.

---

## 9. Key Design Decisions

### 9.1 Domain Physics Are Code, Not LLM

The world state transitions according to deterministic code with explicit randomness — not LLM generation. This is non-negotiable for three reasons:

- **Conservation laws**: Money spent is money gone. If the domain is an LLM, it might forget to subtract the cost of a hiring decision.
- **Reproducibility**: Same seed must produce same stochastic events. LLMs are not deterministic even at temperature 0.
- **Speed**: A domain tick takes microseconds. An LLM call takes seconds. For 100-run ensembles of 12 ticks each, that's 1200 domain transitions — needs to be fast.

### 9.2 LLMs Provide Policy, Not Physics

The LLM's job is to decide what to do, not to compute what happens. This maps exactly to the Domain/Policy split:

- **Domain** (code): "If you hire 5 engineers at $180k average, burn rate increases by $75k/month, new hires reach productivity after 3 months, and there's a 15% chance each one leaves within 6 months."
- **Policy** (LLM): "Given my beliefs about morale, runway, and competitive pressure, I propose: hire 3 senior engineers and 2 juniors, prioritize backend, and offer 10% above market to reduce attrition risk."

### 9.3 Beliefs Are Distributions, Not Point Estimates

Using `Beta(7, 3)` instead of `0.7` costs almost nothing computationally but provides:
- Uncertainty quantification (how sure is this agent?)
- Natural learning rates (uncertain beliefs update faster than confident ones)
- Information-theoretic metrics (KL divergence between agents' beliefs measures disagreement)
- Proper Bayesian updating without approximation (conjugate families)

### 9.4 Hybrid Agent Populations

Not every agent needs an LLM. A typical simulation might have:
- 2-3 LLM agents (key decision-makers whose reasoning you want to study)
- 5-10 rule-based agents (background actors with simple policies)
- This keeps LLM costs manageable while preserving realistic multi-agent dynamics

### 9.5 Observations Are the Interface Between Worlds

The Domain controls what each agent can see via `observe/4`. This is the only channel through which world state reaches agents. This makes information asymmetry explicit and auditable — you can inspect each agent's observation log to understand why they made the decisions they did.

---

## 10. Relation to Existing Plans

This plan synthesizes and extends two existing documents:

- **`docs/simulation-engine-plan.md`** — defines the Domain/Policy/Engine/Runner architecture. This plan adopts that architecture wholesale and adds the Bayesian belief layer on top.
- **`docs/cps-rewrite-plan.md`** — proposes a continuation-passing-style rewrite for probabilistic programming over agent traces (Sequential Monte Carlo). That plan is more ambitious and lower-level. This plan can be implemented *before* the CPS rewrite using the existing architecture, and the Bayesian belief mechanism would survive and benefit from the CPS rewrite when it happens.

The key addition here is the **Bayesian belief state per agent** and the insight that **tool use = observation = belief update**. This bridges the gap between "agents talk to each other" and "agents have calibrated probabilistic models of the world."
