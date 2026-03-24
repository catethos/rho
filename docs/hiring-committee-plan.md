# Hiring Committee Simulation — Implementation Plan (v2)

## Goal

Build a multi-agent "Hiring Committee" simulation with a dedicated Phoenix LiveView observatory as the **primary interface**. 3 evaluator agents independently score candidates, debate, and converge on a consensus shortlist — all visible in real-time through the web UI.

The web app is the demo. No CLI needed. Open a browser, click "Start", and watch.

This is the flagship demo for "why Elixir for AI agents."

---

## Key Design Decisions (from review)

These decisions were made after reviewing the plan against the actual Rho codebase:

1. **Deterministic Elixir coordinator, not an LLM facilitator.** The facilitator is a regular Elixir module (`Simulation`) that manages rounds, spawns evaluators, and drives the process. This avoids putting 80-step LLM orchestration burden on fragile `await_task` semantics (which loses results for already-finished agents).

2. **Structured `submit_scores` tool, not JSON text parsing.** Evaluators call a tool that publishes typed events. The observatory never parses freeform LLM text for scores.

3. **3 evaluators, 10 candidates, 2 rounds for V1.** Expand after the loop is stable. This keeps cost reasonable and iteration fast.

4. **Runtime state via `Worker.info/1`, not mutable ETS.** Avoids read-modify-write races on the shared registry table. The observatory polls `Worker.info(pid)` + `Process.info(pid, [...])` on a 500ms tick.

5. **No chaos/crash button in V1.** `Process.exit(pid, :kill)` bypasses `terminate/2`, leaks in-flight `Task.Supervisor.async_nolink` LLM calls, and produces ghost events. Defer until worker/task ownership is redesigned.

6. **No demographic fields in candidate data.** Use only job-relevant dimensions (experience, skills, salary, stability, timezone). Avoids ethics/reputation risk for a public demo.

7. **Subscribe before starting.** The observatory subscribes to events first, then triggers the simulation — no missed early events.

---

## Web Architecture Overview

The existing Rho web stack:
- **Phoenix LiveView** with inline CSS (`RhoWeb.InlineCSS`) and inline JS (`RhoWeb.InlineJS`)
- **No asset pipeline** — no esbuild, no Tailwind, no node_modules. CSS lives in `lib/rho_web/inline_css.ex`, JS in `lib/rho_web/inline_js.ex`
- **Light theme** with teal accents (`--teal: #5BB5A2`), Outfit font, Fragment Mono for code
- **Existing components:** `AgentComponents` (sidebar + tree), `ChatComponents` (message feed), `SignalComponents` (timeline toggle), `CoreComponents` (badges, dots)
- **Session projection** (`SessionProjection`) maps signal bus events → LiveView assigns
- **JS hooks** registered as `window.RhoHooks`, loaded via CDN Phoenix + LiveView

The hiring observatory will be a **new LiveView** at `/observatory/:session_id` with its own components, CSS section, and JS hooks — following all existing patterns.

---

## Phase 1: Infrastructure & Bug Fixes

### 1.1 Fix `send_message` sender identity

**File:** `lib/rho/mounts/multi_agent.ex`

Current bug: `execute_send_message/2` sends `from: target` instead of `from: sender`. Fix by threading `self_agent_id` through `send_message_tool/1`:

```elixir
defp send_message_tool(session_id, self_agent_id) do
  # ...
  execute: fn args ->
    execute_send_message(args, session_id, self_agent_id)
  end
end
```

And in the signal delivery:
```elixir
Worker.deliver_signal(target_pid, %{
  type: "rho.message.sent",
  data: %{message: message, from: self_agent_id}
})
```

Also publish an observable event for the signal timeline:
```elixir
Comms.publish("rho.session.#{session_id}.events.message_sent", %{
  from: self_agent_id,
  to: target,
  message: message
}, source: "/session/#{session_id}/agent/#{self_agent_id}")
```

### 1.2 Add `broadcast_message` tool to MultiAgent mount

**File:** `lib/rho/mounts/multi_agent.ex`

Add a `broadcast_message` tool that sends a message to all other agents in the session (excluding self). Internally loops over `Agent.Registry.list/1` and calls `Worker.deliver_signal/2` for each.

```elixir
%{
  name: "broadcast_message",
  description: "Send a message to all other agents in this session",
  parameters: %{message: :string}
}
```

The execute function:
```elixir
fn %{"message" => message} ->
  agents = Agent.Registry.list(session_id)
  targets = Enum.reject(agents, & &1.agent_id == self_agent_id)

  for agent <- targets do
    signal = %{type: "rho.message.sent", data: %{message: message, from: self_agent_id}}
    Worker.deliver_signal(agent.pid, signal)
  end

  # Publish observable event for the signal timeline
  Comms.publish("rho.session.#{session_id}.events.broadcast", %{
    from: self_agent_id,
    message: message,
    target_count: length(targets)
  }, source: "/session/#{session_id}/agent/#{self_agent_id}")

  {:ok, "Broadcast sent to #{length(targets)} agents"}
end
```

### 1.3 Add `session_id` to `rho.task.requested` event

**File:** `lib/rho/mounts/multi_agent.ex`

The existing `rho.task.requested` publish doesn't include `session_id`, which causes cross-session leaks for subscribers on `"rho.task.*"`. Add it:

```elixir
Comms.publish("rho.task.requested", %{
  task_id: task_id,
  session_id: params.session_id,  # <-- add this
  from_agent: params.parent_agent_id,
  to_agent: agent_id,
  task: task_prompt,
  context_summary: params.context_summary,
  max_steps: params.max_steps
}, source: "/session/#{params.session_id}/agent/#{params.parent_agent_id}")
```

### 1.4 Extend `Worker.info/1` with runtime fields

**File:** `lib/rho/agent/worker.ex`

Add runtime tracking fields to the Worker struct and expose them via `info/1`. This avoids ETS race conditions — the Worker GenServer is the single writer.

Add to struct:
```elixir
defstruct [
  # ... existing fields ...
  :current_tool,
  :current_step,
  :max_steps_configured,
  token_usage: %{input: 0, output: 0},
  last_activity_at: nil
]
```

Update `build_emit/2` to send metadata updates back to the Worker:
```elixir
emit = fn event ->
  # Notify the worker of runtime state changes
  case event.type do
    :step_start  -> send(worker_pid, {:meta_update, :current_step, event[:step]})
    :tool_start  -> send(worker_pid, {:meta_update, :current_tool, event[:name]})
    :tool_result -> send(worker_pid, {:meta_update, :current_tool, nil})
    :llm_usage   -> send(worker_pid, {:meta_update, :token_usage, event[:usage]})
    _ -> :ok
  end
  send(worker_pid, {:meta_update, :last_activity_at, System.monotonic_time(:millisecond)})
  # ... existing emit logic ...
end
```

Handle in the Worker:
```elixir
def handle_info({:meta_update, key, value}, state) do
  {:noreply, Map.put(state, key, value)}
end
```

Expose in `info/1`:
```elixir
info = %{
  # ... existing fields ...
  current_tool: state.current_tool,
  current_step: state.current_step,
  token_usage: state.token_usage,
  last_activity_at: state.last_activity_at
}
```

---

## Phase 2: Hiring Committee Simulation

### 2.1 Candidate data fixtures

**File:** `lib/rho/demos/hiring/candidates.ex`

Create 10 synthetic candidate profiles as structured data. **No demographic/protected fields.** Design for tension using job-relevant dimensions only:

| Archetype | Example | Creates Debate Between |
|-----------|---------|----------------------|
| Technical star, collaboration concern | Wei Zhang — 10x engineer, poor code reviews | Tech vs Culture evaluators |
| Over-budget superstar | Sarah Chen — ex-Stripe, wants $195K (band is $160-190K) | Tech vs Comp evaluator |
| Non-traditional path | Marcus Johnson — bootcamp grad, 6 years, strong portfolio | Experience vs Tech evaluators |
| Culture fit, weaker technical | Priya Sharma — great communicator, junior-level system design | Culture vs Tech evaluators |
| Career changer, high potential | Fatima Al-Rashid — 3 years in tech, ex-finance, fast learner | Experience vs Tech evaluators |
| Job hopper, high impact | Alex Rivera — 4 jobs in 5 years, promoted at each | Experience evaluator internal conflict |
| Senior but expensive | David Park — 15 years, wants $210K | Comp vs everyone |
| Remote/international | Olga Petrov — based in Berlin, UTC+1 timezone gap | Culture vs Tech evaluators |
| Perfect on paper, flat references | James Liu — great resume, references are lukewarm | Tech vs Culture evaluators |
| Solid all-rounder, nothing special | Rachel Kim — 5 years, solid skills, no red flags | Tests whether evaluators can rank "good but not great" |

Distribution: 3-4 clear "no", 3-4 strong debate candidates, 2-3 strong hires.

```elixir
defmodule Rho.Demos.Hiring.Candidates do
  def all do
    [
      %{
        id: "C01", name: "Sarah Chen",
        years_experience: 8, current_company: "Stripe",
        education: "MS CS, Stanford",
        skills: ["Elixir", "Go", "distributed systems", "PostgreSQL"],
        salary_expectation: 195_000,
        strengths: "Led payment pipeline migration (10M+ txns/day). Phoenix core team contributor.",
        concerns: "3 jobs in 4 years. References note difficulty with ambiguity.",
        work_style: "Remote, prefers async communication, strong writer"
      },
      # ... 9 more with similar structure (no demographic fields)
    ]
  end

  def format_all do
    all()
    |> Enum.map_join("\n---\n", fn c ->
      """
      **#{c.id}: #{c.name}**
      Experience: #{c.years_experience} years | Current: #{c.current_company}
      Education: #{c.education}
      Skills: #{Enum.join(c.skills, ", ")}
      Salary expectation: $#{Number.Delimit.number_to_delimited(c.salary_expectation, precision: 0)}
      Strengths: #{c.strengths}
      Concerns: #{c.concerns}
      Work style: #{c.work_style}
      """
    end)
  end
end
```

### 2.2 Structured score submission tool

**File:** `lib/rho/demos/hiring/tools.ex`

A dedicated tool that evaluator agents call to submit their scores. This publishes structured events that the observatory can consume reliably — no JSON text parsing.

```elixir
defmodule Rho.Demos.Hiring.Tools do
  alias Rho.Comms

  def submit_scores_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_scores",
          description: "Submit your candidate scores for the current round. Call this once with all scores.",
          parameter_schema: [
            round: [type: :integer, required: true, doc: "Current round number (1 or 2)"],
            scores: [type: :string, required: true, doc: "JSON array: [{\"id\": \"C01\", \"score\": 85, \"rationale\": \"...\"}, ...]"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        round = args["round"] || args[:round]
        raw_scores = args["scores"] || args[:scores]

        case Jason.decode(raw_scores) do
          {:ok, scores} when is_list(scores) ->
            Comms.publish("rho.hiring.scores.submitted", %{
              session_id: session_id,
              agent_id: agent_id,
              role: role,
              round: round,
              scores: scores
            }, source: "/session/#{session_id}/agent/#{agent_id}")

            {:ok, "Scores submitted for round #{round}: #{length(scores)} candidates scored."}

          _ ->
            {:error, "Invalid scores format. Must be a JSON array of {id, score, rationale} objects."}
        end
      end
    }
  end
end
```

### 2.3 Evaluator agent profiles

**File:** `.rho.exs` (add to agents map)

**Important:** Must use keyword lists, not maps. `Rho.Config.agent/1` uses `Keyword.merge/2`.

Must explicitly set `reasoner`, `provider`, etc. — these are NOT inherited from the `default` profile.

3 evaluator roles, each with a strong personality to create debate:

```elixir
technical_evaluator: [
  model: "openrouter:anthropic/claude-sonnet-4",
  system_prompt: """
  You are the Technical Evaluator on a hiring committee for Senior Backend Engineer.
  Focus: system design depth, coding ability, relevant stack experience (Elixir, distributed systems),
  open source contributions, and technical problem-solving.

  Score each candidate 0-100. You have strong opinions — defend technically exceptional
  candidates even when others raise concerns about job hopping or salary.

  When you receive messages from other evaluators, respond with counter-arguments if you disagree.
  Use send_message to address specific evaluators by role.

  When ready, use submit_scores to submit your ratings.
  """,
  mounts: [:multi_agent, :journal],
  reasoner: :structured,
  max_steps: 20
],

culture_evaluator: [
  model: "openrouter:anthropic/claude-sonnet-4",
  system_prompt: """
  You are the Culture & Collaboration Evaluator on a hiring committee for Senior Backend Engineer.
  Focus: communication skills, teamwork, mentoring ability, code review quality,
  work style compatibility, and long-term team fit.

  Score each candidate 0-100. You push back hard on "brilliant jerk" candidates.
  A technically strong engineer who damages team morale is a net negative.

  When you receive messages from other evaluators, engage constructively but hold your ground
  on culture concerns. Use send_message to address specific evaluators.

  When ready, use submit_scores to submit your ratings.
  """,
  mounts: [:multi_agent, :journal],
  reasoner: :structured,
  max_steps: 20
],

compensation_evaluator: [
  model: "openrouter:anthropic/claude-sonnet-4",
  system_prompt: """
  You are the Compensation & Budget Evaluator on a hiring committee for Senior Backend Engineer.
  Focus: salary expectations vs budget band ($160K-$190K), total compensation package,
  market rate analysis, and hire count constraints (maximum 3 offers).

  Score each candidate 0-100. Factor in budget fit heavily. An amazing candidate at $210K
  is a problem when you can only make 3 offers and others fit the band.

  You are pragmatic and numbers-driven. Push back when others want to "make exceptions"
  for over-budget candidates. Use send_message to debate specific cases.

  When ready, use submit_scores to submit your ratings.
  """,
  mounts: [:multi_agent, :journal],
  reasoner: :structured,
  max_steps: 20
]
```

### 2.4 Simulation coordinator (deterministic)

**File:** `lib/rho/demos/hiring/simulation.ex`

The coordinator is a GenServer that drives the process in explicit rounds. It spawns evaluator agents directly, manages round transitions, and publishes domain events.

```elixir
defmodule Rho.Demos.Hiring.Simulation do
  use GenServer

  alias Rho.Demos.Hiring.{Candidates, Tools}
  alias Rho.Agent.{Worker, Supervisor}
  alias Rho.Comms

  defstruct [
    :session_id,
    round: 0,
    evaluators: %{},          # role => agent_id
    scores: %{},              # {role, round} => [%{id, score, rationale}]
    status: :not_started,
    max_rounds: 2
  ]

  def start(opts \\ []) do
    session_id = opts[:session_id] || "hiring_#{System.unique_integer([:positive])}"
    GenServer.start(__MODULE__, session_id, name: via(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  def begin_simulation(session_id) do
    GenServer.cast(via(session_id), :begin)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(session_id) do
    # Subscribe to score submission events
    {:ok, _sub} = Comms.subscribe("rho.hiring.scores.submitted")
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_cast(:begin, %{status: :not_started} = state) do
    Comms.publish("rho.hiring.simulation.started", %{
      session_id: state.session_id
    }, source: "/session/#{state.session_id}")

    state = spawn_evaluators(state)
    state = start_round(state, 1)
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{type: "rho.hiring.scores.submitted", data: data}}, state) do
    # Only process events for our session
    if data.session_id == state.session_id do
      state = record_scores(state, data.role, data.round, data.scores)
      state = maybe_advance_round(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp spawn_evaluators(state) do
    roles = [:technical_evaluator, :culture_evaluator, :compensation_evaluator]

    evaluators =
      Map.new(roles, fn role ->
        agent_id = Rho.Session.new_agent_id()
        config = Rho.Config.agent(role)

        # Build tools: multi-agent tools + submit_scores
        tool_context = %{
          tape_name: "agent_#{agent_id}",
          workspace: File.cwd!(),
          agent_name: role,
          agent_id: agent_id,
          session_id: state.session_id,
          depth: 1,
          sandbox: nil
        }
        mount_tools = Rho.MountRegistry.collect_tools(tool_context)
        score_tool = Tools.submit_scores_tool(state.session_id, agent_id, role)
        finish_tool = Rho.Tools.Finish.tool_def()
        all_tools = mount_tools ++ [score_tool, finish_tool]

        # Bootstrap memory
        memory_mod = Rho.Config.memory_module()
        tape = "agent_#{agent_id}"
        memory_mod.bootstrap(tape)

        {:ok, _pid} = Supervisor.start_worker(
          agent_id: agent_id,
          session_id: state.session_id,
          workspace: File.cwd!(),
          agent_name: role,
          role: role,
          depth: 1,
          memory_ref: tape,
          max_steps: config.max_steps,
          system_prompt: config.system_prompt,
          tools: all_tools,
          model: config.model
        )

        {role, agent_id}
      end)

    %{state | evaluators: evaluators}
  end

  defp start_round(state, round_num) do
    prompt = round_prompt(round_num, state)

    Comms.publish("rho.hiring.round.started", %{
      session_id: state.session_id,
      round: round_num
    }, source: "/session/#{state.session_id}")

    # Submit prompt to each evaluator
    for {_role, agent_id} <- state.evaluators do
      pid = Worker.whereis(agent_id)
      if pid, do: Worker.submit(pid, prompt)
    end

    %{state | round: round_num}
  end

  defp round_prompt(1, _state) do
    """
    Evaluate the following candidates for Senior Backend Engineer.
    Salary band: $160,000 — $190,000. Maximum 3 offers.

    #{Candidates.format_all()}

    Score each candidate 0-100 based on your evaluation criteria.
    Use submit_scores with round: 1 when done.
    """
  end

  defp round_prompt(2, state) do
    # Build disagreement summary from round 1 scores
    summary = build_disagreement_summary(state)

    """
    Round 2: The committee has reviewed initial scores. Here are the key disagreements:

    #{summary}

    Reconsider your scores in light of other evaluators' perspectives.
    You may use send_message to debate specific candidates with other evaluators.
    Then use submit_scores with round: 2 for your revised ratings.
    """
  end

  defp record_scores(state, role, round, scores) do
    key = {role, round}
    %{state | scores: Map.put(state.scores, key, scores)}
  end

  defp maybe_advance_round(state) do
    expected = map_size(state.evaluators)
    submitted = state.scores
      |> Map.keys()
      |> Enum.count(fn {_role, r} -> r == state.round end)

    if submitted >= expected do
      if state.round >= state.max_rounds do
        # Simulation complete
        final = compute_final_shortlist(state)

        Comms.publish("rho.hiring.simulation.completed", %{
          session_id: state.session_id,
          shortlist: final
        }, source: "/session/#{state.session_id}")

        %{state | status: :completed}
      else
        start_round(state, state.round + 1)
      end
    else
      state
    end
  end

  defp build_disagreement_summary(state) do
    # Compare round 1 scores across evaluators and highlight big gaps
    # (implementation: group by candidate, find high variance)
    "See round 1 scores and identify where evaluators disagree by >20 points."
  end

  defp compute_final_shortlist(state) do
    # Average round 2 scores across evaluators, return top 3
    []
  end

  defp via(session_id), do: {:via, Registry, {Rho.AgentRegistry, "sim_#{session_id}"}}
end
```

---

## Phase 3: Observatory LiveView (The Main Event)

This is the primary deliverable. Everything else exists to feed data into this page.

### 3.1 Route

**File:** `lib/rho_web/router.ex`

```elixir
scope "/", RhoWeb do
  pipe_through :browser

  live "/observatory/:session_id", ObservatoryLive, :show
  live "/observatory", ObservatoryLive, :new          # landing page
  live "/session/:session_id", SessionLive, :show
  live "/", SessionLive, :new
end
```

### 3.2 Observatory LiveView

**File:** `lib/rho_web/live/observatory_live.ex`

The LiveView manages all state. No separate JS framework.

**Critical flow:** Subscribe first, then start simulation. The landing page creates a session ID, navigates to `/observatory/:session_id`, and only then triggers `Simulation.begin_simulation/1`.

**Assigns:**

```elixir
%{
  # Session
  session_id: nil | String.t(),
  simulation_status: :not_started | :running | :completed,

  # Agents (enriched with process stats)
  agents: %{agent_id => %{
    agent_id: String.t(),
    role: atom(),
    agent_name: atom(),           # display this, not role (primary agents have role: :primary)
    status: :idle | :busy | :stopped,
    depth: integer(),
    parent_id: String.t() | nil,
    # From Worker.info/1 (polled every 500ms)
    current_tool: String.t() | nil,
    current_step: integer() | nil,
    # From Process.info (polled every 500ms)
    message_queue_len: integer(),
    heap_size: integer(),
    reductions: integer(),
    prev_reductions: integer(),       # for computing delta/sec
    alive: boolean()
  }},

  # Signals (rolling buffer for timeline)
  signals: [%{
    id: String.t(),
    timestamp: integer(),
    from_agent: String.t(),
    to_agent: String.t() | :all,      # :all for broadcasts
    type: String.t(),
    preview: String.t()               # first 120 chars of message
  }],

  # Candidate scoreboard (pre-seeded from Candidates.all/0)
  scores: %{candidate_id => %{
    name: String.t(),
    technical: integer() | nil,
    culture: integer() | nil,
    compensation: integer() | nil,
    avg: float() | nil
  }},

  # Convergence tracking
  round: integer(),
  convergence_history: [float()],     # one entry per round

  # BEAM insight annotations
  insights: [%{text: String.t(), severity: :info | :highlight}],

  # UI state
  selected_agent: nil | String.t(),
  bus_subs: [sub_id]
}
```

**Key behaviors:**

```elixir
# Landing page — no session yet
def mount(%{}, _session, %{assigns: %{live_action: :new}} = socket) do
  {:ok, assign(socket, session_id: nil, simulation_status: :not_started),
   layout: {RhoWeb.Layouts, :app}}
end

# Observatory with session — subscribe first, then hydrate
def mount(%{"session_id" => sid}, _session, socket) do
  if connected?(socket) do
    # Subscribe to all relevant event channels
    {:ok, sub1} = Rho.Comms.subscribe("rho.agent.*")
    {:ok, sub2} = Rho.Comms.subscribe("rho.session.#{sid}.events.*")
    {:ok, sub3} = Rho.Comms.subscribe("rho.task.*")
    {:ok, sub4} = Rho.Comms.subscribe("rho.hiring.*")
    Process.send_after(self(), :tick, 500)

    socket = socket
      |> assign(:bus_subs, [sub1, sub2, sub3, sub4])
      |> hydrate_from_registry(sid)
      |> seed_scoreboard()
  end

  {:ok, assign(socket, session_id: sid), layout: {RhoWeb.Layouts, :app}}
end

# "Start Simulation" — create session, navigate, THEN begin
def handle_event("start_simulation", _params, socket) do
  session_id = "hiring_#{System.unique_integer([:positive])}"
  {:ok, _pid} = Rho.Demos.Hiring.Simulation.start(session_id: session_id)
  {:noreply, push_navigate(socket, to: "/observatory/#{session_id}")}
end

# After navigation mount completes and subscriptions are active, begin the simulation
def handle_event("begin_simulation", _params, socket) do
  Rho.Demos.Hiring.Simulation.begin_simulation(socket.assigns.session_id)
  {:noreply, assign(socket, simulation_status: :running)}
end

# Tick — poll BEAM process internals (the "only Elixir" moment)
def handle_info(:tick, socket) do
  agents = poll_process_stats(socket.assigns.agents)
  insights = generate_insights(agents)
  Process.send_after(self(), :tick, 500)
  {:noreply, assign(socket, agents: agents, insights: insights)}
end

defp poll_process_stats(agents) do
  Map.new(agents, fn {id, agent} ->
    case agent[:pid] && Process.alive?(agent.pid) do
      false ->
        {id, %{agent | alive: false}}
      true ->
        # Get BEAM internals
        proc_info = Process.info(agent.pid, [
          :message_queue_len, :heap_size, :reductions, :status
        ]) || []
        stats = Enum.into(proc_info, %{})

        # Get runtime state from Worker.info (best-effort, don't crash on timeout)
        worker_meta =
          try do
            Worker.info(agent.pid)
          catch
            :exit, _ -> %{}
          end

        delta = Map.get(stats, :reductions, 0) - (agent[:prev_reductions] || Map.get(stats, :reductions, 0))

        {id, agent
          |> Map.merge(stats)
          |> Map.put(:current_tool, worker_meta[:current_tool])
          |> Map.put(:current_step, worker_meta[:current_step])
          |> Map.put(:prev_reductions, Map.get(stats, :reductions, 0))
          |> Map.put(:reductions_per_sec, delta * 2)  # tick is 500ms
          |> Map.put(:alive, true)}
    end
  end)
end

# Auto-generate BEAM insight annotations
defp generate_insights(agents) do
  busy_count = agents |> Map.values() |> Enum.count(& &1.status == :busy)

  agent_insights =
    agents
    |> Map.values()
    |> Enum.flat_map(fn agent ->
      cond do
        agent[:message_queue_len] && agent.message_queue_len > 5 ->
          [%{text: "#{agent.agent_name} has #{agent.message_queue_len} queued messages — BEAM mailbox backpressure, zero infrastructure", severity: :highlight}]
        agent[:alive] == false ->
          [%{text: "#{agent.agent_name} process is down", severity: :highlight}]
        agent[:heap_size] && agent.heap_size > 100_000 ->
          [%{text: "#{agent.agent_name} heap at #{div(agent.heap_size * 8, 1024)}KB — BEAM tracks per-process, not per-thread", severity: :info}]
        true -> []
      end
    end)

  global_insights =
    cond do
      busy_count >= 3 ->
        [%{text: "#{busy_count} concurrent LLM calls — each in an isolated BEAM process, not OS threads", severity: :highlight}]
      map_size(agents) >= 3 ->
        [%{text: "#{map_size(agents)} agents, 1 Elixir process each. No Redis, no Celery, no external queue.", severity: :info}]
      true -> []
    end

  (global_insights ++ agent_insights) |> Enum.take(3)
end

# Signal handling — same pattern as SessionLive
def handle_info({:signal, %Jido.Signal{type: type, data: data}}, socket) do
  socket = RhoWeb.ObservatoryProjection.project(socket, type, data)
  {:noreply, socket}
end

# Pre-seed the scoreboard with all candidate rows
defp seed_scoreboard(socket) do
  scores = Map.new(Candidates.all(), fn c ->
    {c.id, %{name: c.name, technical: nil, culture: nil, compensation: nil, avg: nil}}
  end)
  assign(socket, scores: scores)
end
```

### 3.3 Observatory projection

**File:** `lib/rho_web/live/observatory_projection.ex`

Consumes only structured domain events. No freeform text parsing.

```elixir
defmodule RhoWeb.ObservatoryProjection do
  def project(socket, "rho.agent.started", data) do
    agent = %{
      agent_id: data.agent_id,
      role: data.role,
      agent_name: data[:agent_name] || data.role,
      status: :idle,
      depth: 0,
      pid: Rho.Agent.Worker.whereis(data.agent_id),
      current_tool: nil,
      current_step: nil,
      message_queue_len: 0,
      heap_size: 0,
      reductions: 0,
      prev_reductions: 0,
      alive: true
    }
    agents = Map.put(socket.assigns.agents, data.agent_id, agent)
    Phoenix.Component.assign(socket, :agents, agents)
  end

  def project(socket, "rho.agent.stopped", data) do
    agents = Map.update(socket.assigns.agents, data.agent_id, %{}, fn a ->
      %{a | alive: false, status: :stopped}
    end)
    Phoenix.Component.assign(socket, :agents, agents)
  end

  def project(socket, "rho.hiring.scores.submitted", data) do
    # Update scoreboard from structured event
    role_key = score_column(data.role)
    scores = Enum.reduce(data.scores, socket.assigns.scores, fn entry, acc ->
      id = entry["id"]
      score = entry["score"]
      Map.update(acc, id, %{}, fn row ->
        row
        |> Map.put(role_key, score)
        |> recompute_avg()
      end)
    end)
    Phoenix.Component.assign(socket, :scores, scores)
  end

  def project(socket, "rho.hiring.round.started", data) do
    socket
    |> Phoenix.Component.assign(:round, data.round)
    |> Phoenix.Component.assign(:simulation_status, :running)
  end

  def project(socket, "rho.hiring.simulation.completed", _data) do
    Phoenix.Component.assign(socket, :simulation_status, :completed)
  end

  # Signal timeline: broadcasts
  def project(socket, "rho.session." <> _ = type, data) when is_map(data) do
    cond do
      String.contains?(type, "broadcast") ->
        add_signal(socket, data[:from], :all, data[:message])

      String.contains?(type, "message_sent") ->
        add_signal(socket, data[:from], data[:to], data[:message])

      true -> socket
    end
  end

  def project(socket, _type, _data), do: socket

  # --- Helpers ---

  defp score_column(:technical_evaluator), do: :technical
  defp score_column(:culture_evaluator), do: :culture
  defp score_column(:compensation_evaluator), do: :compensation
  defp score_column(_), do: :other

  defp recompute_avg(row) do
    values = [row[:technical], row[:culture], row[:compensation]]
      |> Enum.reject(&is_nil/1)
    avg = if values == [], do: nil, else: Enum.sum(values) / length(values)
    Map.put(row, :avg, avg)
  end

  defp add_signal(socket, from, to, message) do
    signal = %{
      id: System.unique_integer([:positive]) |> to_string(),
      timestamp: System.monotonic_time(:millisecond),
      from_agent: from,
      to_agent: to,
      type: if(to == :all, do: "broadcast", else: "direct"),
      preview: String.slice(to_string(message || ""), 0, 120)
    }
    signals = [signal | socket.assigns.signals] |> Enum.take(100)
    Phoenix.Component.assign(socket, :signals, signals)
  end
end
```

### 3.4 Observatory components

**File:** `lib/rho_web/components/observatory_components.ex`

All pure server-rendered HTML + CSS. Use LiveView `push_event` + JS hooks only for auto-scroll.

#### Agent cards (top section)

```elixir
def agent_card(assigns) do
  ~H"""
  <div class={"obs-agent-card #{status_class(@agent.status)} #{if !@agent.alive, do: "dead"}"}
       phx-click="select_agent" phx-value-agent-id={@agent.agent_id}>
    <div class="obs-agent-header">
      <span class={"obs-status-dot #{status_class(@agent.status)}"}></span>
      <span class="obs-agent-role"><%= format_role(@agent.agent_name) %></span>
    </div>
    <div class="obs-agent-stats">
      <div class="obs-stat">
        <span class="obs-stat-label">mailbox</span>
        <span class={"obs-stat-value #{if @agent.message_queue_len > 3, do: "hot"}"}>
          <%= @agent.message_queue_len || 0 %>
        </span>
      </div>
      <div class="obs-stat">
        <span class="obs-stat-label">heap</span>
        <span class="obs-stat-value"><%= format_heap(@agent.heap_size) %></span>
      </div>
      <div class="obs-stat">
        <span class="obs-stat-label">work</span>
        <span class="obs-stat-value"><%= format_reductions(@agent.reductions_per_sec) %></span>
      </div>
    </div>
    <div :if={@agent.current_tool} class="obs-agent-tool">
      <span class="obs-tool-indicator"></span>
      <%= @agent.current_tool %>
    </div>
    <div :if={@agent.current_step} class="obs-agent-step">
      step <%= @agent.current_step %>
    </div>
  </div>
  """
end
```

#### Candidate scoreboard (right panel)

```elixir
def scoreboard(assigns) do
  ~H"""
  <div class="obs-scoreboard">
    <h3 class="obs-section-title">Candidate Scores</h3>
    <table class="obs-score-table">
      <thead>
        <tr>
          <th>Candidate</th>
          <th title="Technical">T</th>
          <th title="Culture">C</th>
          <th title="Compensation">$</th>
          <th>Avg</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{id, scores} <- sorted_scores(@scores)}>
          <td class="obs-candidate-name"><%= scores.name %></td>
          <td class={score_class(scores.technical)}><%= scores.technical || "—" %></td>
          <td class={score_class(scores.culture)}><%= scores.culture || "—" %></td>
          <td class={score_class(scores.compensation)}><%= scores.compensation || "—" %></td>
          <td class="obs-score-avg"><%= format_avg(scores.avg) %></td>
        </tr>
      </tbody>
    </table>
  </div>
  """
end

defp score_class(nil), do: "obs-score obs-score-pending"
defp score_class(n) when n >= 80, do: "obs-score obs-score-high"
defp score_class(n) when n >= 60, do: "obs-score obs-score-mid"
defp score_class(_), do: "obs-score obs-score-low"
```

#### Signal flow timeline (bottom panel)

```elixir
def signal_flow(assigns) do
  ~H"""
  <div class="obs-signal-flow" id="signal-flow" phx-hook="AutoScroll">
    <div :for={signal <- Enum.take(@signals, 50)} class="obs-signal-row">
      <span class="obs-signal-time"><%= format_time(signal.timestamp) %></span>
      <span class={"obs-signal-from obs-role-#{signal.from_agent}"}><%= signal.from_agent %></span>
      <span class="obs-signal-arrow">
        <%= if signal.to_agent == :all, do: "→ ALL", else: "→" %>
      </span>
      <span :if={signal.to_agent != :all} class="obs-signal-to">
        <%= signal.to_agent %>
      </span>
      <span class="obs-signal-preview"><%= signal.preview %></span>
    </div>
  </div>
  """
end
```

#### BEAM insights bar

```elixir
def insights_bar(assigns) do
  ~H"""
  <div :if={@insights != []} class="obs-insights">
    <div :for={insight <- @insights} class={"obs-insight obs-insight-#{insight.severity}"}>
      <span class="obs-insight-icon">
        <%= if insight.severity == :highlight, do: "!", else: "i" %>
      </span>
      <%= insight.text %>
    </div>
  </div>
  """
end
```

#### Convergence sparkline

Server-rendered SVG. No JS library needed.

```elixir
def convergence_chart(assigns) do
  points = assigns.convergence_history
  max_rounds = 4

  coords =
    points
    |> Enum.with_index()
    |> Enum.map(fn {value, i} ->
      x = (i + 1) / max_rounds * 280 + 20
      y = 80 - value * 70
      {x, y}
    end)

  polyline = coords |> Enum.map(fn {x, y} -> "#{x},#{y}" end) |> Enum.join(" ")

  assigns = assign(assigns, polyline: polyline, coords: coords, max_rounds: max_rounds)

  ~H"""
  <div class="obs-convergence">
    <h3 class="obs-section-title">Convergence</h3>
    <svg viewBox="0 0 300 90" class="obs-convergence-svg">
      <line x1="20" y1="10" x2="20" y2="80" stroke="var(--border)" stroke-width="0.5" />
      <line x1="20" y1="80" x2="290" y2="80" stroke="var(--border)" stroke-width="0.5" />
      <text x="5" y="15" fill="var(--text-muted)" font-size="8">100%</text>
      <text x="5" y="82" fill="var(--text-muted)" font-size="8">0%</text>
      <text :for={r <- 1..@max_rounds}
        x={r / @max_rounds * 280 + 20} y="90"
        fill="var(--text-muted)" font-size="7" text-anchor="middle">
        R<%= r %>
      </text>
      <polyline :if={@polyline != ""}
        points={@polyline}
        fill="none" stroke="var(--teal)" stroke-width="2" />
      <circle :for={{x, y} <- @coords}
        cx={x} cy={y} r="3" fill="var(--teal)" />
    </svg>
    <div class="obs-convergence-current">
      Round <%= length(@convergence_history) %> —
      <%= case List.last(@convergence_history) do
        nil -> "waiting..."
        v -> "#{round(v * 100)}% agreement"
      end %>
    </div>
  </div>
  """
end
```

### 3.5 Observatory layout (render function)

**File:** `lib/rho_web/live/observatory_live.ex`

```elixir
# Landing page
def render(%{session_id: nil} = assigns) do
  ~H"""
  <div class="obs-landing">
    <h1>Hiring Committee Observatory</h1>
    <p>Watch 3 AI agents evaluate 10 candidates and debate to consensus — in real-time.</p>
    <p class="obs-landing-subtitle">
      Every agent is a BEAM process. You'll see mailbox depth, heap size, and
      CPU reductions updating live — process-level introspection with zero external tooling.
    </p>
    <button class="obs-start-btn-large" phx-click="start_simulation">
      Start Simulation
    </button>
  </div>
  """
end

# Active observatory
def render(assigns) do
  ~H"""
  <div class="obs-layout">
    <header class="obs-header">
      <h1 class="obs-title">Hiring Committee Observatory</h1>
      <div class="obs-header-stats">
        <span>Round <%= @round %></span>
        <span><%= map_size(@agents) %> agents</span>
        <span><%= length(@signals) %> signals</span>
        <span class={"obs-status-badge obs-status-#{@simulation_status}"}>
          <%= @simulation_status %>
        </span>
        <button :if={@simulation_status == :not_started}
          class="obs-start-btn" phx-click="begin_simulation">
          Begin
        </button>
      </div>
    </header>

    <.insights_bar insights={@insights} />

    <div class="obs-main">
      <div class="obs-left">
        <div class="obs-agents-grid">
          <.agent_card :for={{_id, agent} <- @agents} agent={agent} />
        </div>
        <.signal_flow signals={@signals} />
      </div>

      <div class="obs-right">
        <.scoreboard scores={@scores} />
        <.convergence_chart convergence_history={@convergence_history} />
      </div>
    </div>
  </div>
  """
end
```

### 3.6 CSS for observatory

**File:** `lib/rho_web/inline_css.ex` (append to existing `css/0`)

Follow existing patterns: CSS custom properties, Outfit font, card-based layout.

```css
/* Observatory layout */
.obs-layout { display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
.obs-header { display: flex; justify-content: space-between; align-items: center;
  padding: 12px 20px; border-bottom: 1px solid var(--border); background: var(--bg-surface); }
.obs-main { display: flex; flex: 1; overflow: hidden; }
.obs-left { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.obs-right { width: 380px; border-left: 1px solid var(--border); overflow-y: auto; padding: 16px; }

/* Agent cards */
.obs-agents-grid { display: flex; flex-wrap: wrap; gap: 12px; padding: 16px; }
.obs-agent-card { background: var(--bg-surface); border: 1px solid var(--border);
  border-radius: 8px; padding: 12px; min-width: 140px; cursor: pointer;
  transition: border-color 0.2s, box-shadow 0.2s; }
.obs-agent-card.busy { border-color: var(--teal); box-shadow: 0 0 8px var(--teal-glow); }
.obs-agent-card.dead { border-color: var(--red); opacity: 0.6; }
.obs-stat-value.hot { color: var(--amber); font-weight: 600; }

/* Signal flow */
.obs-signal-flow { flex: 1; overflow-y: auto; padding: 12px 16px;
  font-family: 'Fragment Mono', monospace; font-size: 12px; }
.obs-signal-row { display: flex; gap: 8px; padding: 4px 0;
  border-bottom: 1px solid var(--border); }
.obs-signal-from { font-weight: 600; min-width: 60px; }
.obs-signal-preview { color: var(--text-secondary); overflow: hidden;
  text-overflow: ellipsis; white-space: nowrap; }

/* Scoreboard */
.obs-score-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.obs-score-table th { text-align: center; padding: 6px 4px; color: var(--text-muted);
  font-weight: 500; border-bottom: 1px solid var(--border); }
.obs-score-table td { text-align: center; padding: 6px 4px;
  border-bottom: 1px solid var(--border); }
.obs-score-high { color: var(--green); font-weight: 600; }
.obs-score-mid { color: var(--text-primary); }
.obs-score-low { color: var(--red); }
.obs-score-pending { color: var(--text-muted); }

/* Insights bar */
.obs-insights { display: flex; gap: 12px; padding: 8px 20px;
  background: var(--teal-dim); border-bottom: 1px solid var(--border); }
.obs-insight { font-size: 12px; color: var(--text-secondary); }
.obs-insight-highlight { color: var(--teal); font-weight: 500; }

/* Convergence */
.obs-convergence-svg { width: 100%; height: auto; }

/* Per-role colors for signal flow */
.obs-role-technical_evaluator { color: #5B8ABA; }
.obs-role-culture_evaluator { color: #B55BA0; }
.obs-role-compensation_evaluator { color: #D4A855; }

/* Landing page */
.obs-landing { display: flex; flex-direction: column; align-items: center;
  justify-content: center; height: 100vh; text-align: center; padding: 40px; }
.obs-landing h1 { font-size: 2rem; margin-bottom: 12px; }
.obs-landing-subtitle { color: var(--text-secondary); max-width: 500px; margin: 8px 0 24px; }
.obs-start-btn-large { background: var(--teal); color: white; border: none;
  padding: 14px 32px; border-radius: 8px; font-size: 16px; cursor: pointer;
  font-family: 'Outfit', sans-serif; font-weight: 500; }
.obs-start-btn-large:hover { opacity: 0.9; }

/* Status badge */
.obs-status-badge { font-size: 12px; padding: 2px 8px; border-radius: 4px;
  font-weight: 500; text-transform: uppercase; }
.obs-status-not_started { background: var(--bg-muted); color: var(--text-muted); }
.obs-status-running { background: var(--teal-dim); color: var(--teal); }
.obs-status-completed { background: var(--green-dim); color: var(--green); }
```

### 3.7 JS hooks

**File:** `lib/rho_web/inline_js.ex` (append to existing `js/0`)

```javascript
// Auto-scroll signal flow to bottom
window.RhoHooks.AutoScroll = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight;
    this.observer = new MutationObserver(() => {
      this.el.scrollTop = this.el.scrollHeight;
    });
    this.observer.observe(this.el, { childList: true });
  },
  destroyed() { this.observer.disconnect(); }
};
```

---

## Phase 4: Demo Polish

### 4.1 Linking from existing session UI

**File:** `lib/rho_web/live/session_live.ex`

```elixir
<a :if={@session_id} href={"/observatory/#{@session_id}"} target="_blank" class="obs-link">
  Observatory
</a>
```

### 4.2 Cost controls

Add to the landing page UI:
- Estimated cost per run (~$X based on model × rounds × candidates)
- Hard max round count (already capped at 2 in coordinator)
- Model selection dropdown (default: Sonnet for quality, option: Haiku for cheap testing)

---

## Phase 5: Stretch Goals (after V1 stable)

### 5.1 Expand to 5 evaluators + 15 candidates + 4 rounds

Add `experience_evaluator` and `dei_evaluator` roles. Increase candidate count. Only after V1 loop is proven reliable.

### 5.2 Chaos button (crash recovery demo)

Requires redesigning worker/task ownership so that killing a worker also cleanly cancels its in-flight `Task.Supervisor.async_nolink` LLM call. Until then, `Process.exit(:kill)` leaks ghost work.

**Prerequisite:** Worker links to its task process, or uses `Task.Supervisor.async` (linked) instead of `async_nolink`.

### 5.3 Agent personality slider

Add a slider per agent on the observatory to adjust "stubbornness" (1-10). Injects a system message into the agent's next turn via the signal bus.

### 5.4 Convergence algorithm

```elixir
defmodule Rho.Demos.Hiring.Convergence do
  def score(scores) do
    # For each candidate, compute coefficient of variation across evaluator scores
    # Average across all candidates. Invert: 1.0 = perfect agreement, 0.0 = total disagreement
    candidates_with_scores = scores
      |> Enum.filter(fn {_id, s} -> map_size(s) >= 2 end)

    if candidates_with_scores == [], do: 0.0, else: do_score(candidates_with_scores)
  end
end
```

### 5.5 LLM narrator agent

After the deterministic coordinator finishes, optionally spawn a single "narrator" agent that reads the full score history and produces a written summary/commentary for the UI. This gets the "agent explains the process" feel without risking orchestration reliability.

### 5.6 Replay mode

Use `Comms.replay/2` to replay a completed simulation at 2x speed.

### 5.7 Multi-node demo

Run evaluator agents on a second BEAM node. The observatory shows which node each agent runs on.

---

## Implementation Order

| # | Task | Files | Effort | Dependency | Status |
|---|------|-------|--------|------------|--------|
| 1 | Fix `send_message` sender identity | `multi_agent.ex` | 0.5h | — | DONE |
| 2 | Add `session_id` to `rho.task.requested` | `multi_agent.ex` | 0.5h | — | DONE |
| 3 | Add `broadcast_message` tool | `multi_agent.ex` | 1h | #1 | DONE |
| 4 | Extend `Worker.info/1` with runtime fields | `worker.ex` | 1h | — | DONE |
| 5 | Candidate data fixtures (10 candidates) | `demos/hiring/candidates.ex` | 1.5h | — | DONE |
| 6 | Structured `submit_scores` tool | `demos/hiring/tools.ex` | 1h | — | DONE |
| 7 | Evaluator agent profiles (keyword lists) | `.rho.exs` | 1h | — | DONE |
| 8 | Simulation coordinator GenServer | `demos/hiring/simulation.ex` | 3h | #3, #5, #6, #7 | DONE |
| 9 | **Headless end-to-end test** | test file | 2h | #8 | SKIPPED (manual test via UI) |
| 10 | Observatory route | `router.ex` | 0.5h | — | DONE |
| 11 | Observatory LiveView (mount, tick, subscribe-first flow) | `observatory_live.ex` | 3h | #4, #10 | DONE |
| 12 | Observatory projection (structured events only) | `observatory_projection.ex` | 2h | #11 | DONE |
| 13 | Agent card components | `observatory_components.ex` | 1.5h | #11 | DONE |
| 14 | Candidate scoreboard component | `observatory_components.ex` | 1.5h | #12 | DONE |
| 15 | Signal flow timeline component | `observatory_components.ex` | 1.5h | #11 | DONE |
| 16 | Convergence chart (SVG) | `observatory_components.ex` | 1h | #12 | DONE |
| 17 | BEAM insights bar | `observatory_components.ex` | 1h | #11 | DONE |
| 18 | Observatory CSS | `inline_css.ex` | 2h | #13-17 | DONE |
| 19 | AutoScroll JS hook | `inline_js.ex` | 0.5h | #15 | DONE (already existed) |
| 20 | Landing page + start flow | `observatory_live.ex` | 1h | #8, #11 | DONE |
| 21 | Link from SessionLive | `session_live.ex` | 0.5h | #10 | DONE |

**Total: ~25 hours**

**Critical path:**

```
#1-7 (parallel, 2h) → #8 (3h) → #9 headless test (2h) → #10,#11 (3h) → #12-17 (parallel, 3h) → #18-21 (3h)
```

**Milestone 1 — "Headless works" (~10h):** Tasks 1-9. The simulation runs end-to-end without any UI. Evaluators score candidates, coordinator advances rounds, structured events fire. Verified by test.

**Milestone 2 — "It's visible" (~18h):** Add tasks 10-17. Observatory shows agents, scores filling in, signal flow, convergence chart, BEAM stats ticking.

**Milestone 3 — "It's demo-ready" (~25h):** Add tasks 18-21. Styled, polished, with landing page, correct start flow, and links from existing UI.

**Milestone 4 — "It's impressive" (stretch):** Phase 5 goals — expand to 5 evaluators, add chaos button (after worker redesign), personality sliders, narrator agent.

---

## Risks & Guardrails

| Risk | Mitigation |
|------|-----------|
| LLM doesn't call `submit_scores` tool | System prompt is explicit. Add fallback: if evaluator finishes without submitting, coordinator re-prompts once. |
| Cross-session event leaks | Added `session_id` to `rho.task.requested`. Observatory filters by session. |
| Worker.info timeout during tick | Wrapped in `try/catch :exit`. Best-effort UI. |
| Cost runaway | 3 evaluators × 2 rounds × Sonnet = ~$2-5/run. Add Haiku option for testing. Cap rounds at 2. |
| `await_task` loses results | Not used. Deterministic coordinator listens for structured events instead. |
| ETS race conditions | Not used for runtime state. Worker owns its state, exposed via `info/1`. |
