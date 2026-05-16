> **Not implemented.** This was an exploratory design doc. Rho's architecture
> took a different path (Runner + TurnStrategy + Transformer pipeline).
> Retained for reference only.

# Rho CPS Rewrite Plan (v2)

*A unified foundation for agent execution, probabilistic programming, and simulation*

*v2: Revised after critique review. Addresses process cloning gap, side-effect isolation, BEAM protocol correctness, migration risk, and the incremental-vs-rewrite tradeoff.*

## 1. Why This Rewrite

### 1.1 The Current Architecture's Ceiling

Rho's current architecture works for single-agent ReAct loops. But it has a structural ceiling that prevents three capabilities the system needs:

**Probabilistic programming over agent traces.** Running N agent traces in parallel with reweighting and resampling (Sequential Monte Carlo) requires the ability to fork, score, and kill execution paths mid-run. The current architecture can't do this because effects (LLM calls, tool execution, tape writes) are fired imperatively inside the Reasoner. Nothing can intercept an LLM call between "the program wants it" and "it happens." There's no place to insert scoring, no way to fork at a choice point, no way to replay a trace with different random draws.

**Proper simulation.** Agent-based modelling and approximate Bayesian computation require running the same program under different parameter settings and scoring the outcomes. This needs the same fork/score/resample capability. Without it, multi-agent "simulation" is just running agents once and hoping for the best.

**Execution strategy swapping.** Testing, replay, cost analysis, and caching all require the ability to substitute how effects are executed without changing the agent program. The current design tangles "what the agent does" with "how it's done" — the Reasoner calls `ReqLLM.stream_text` directly, tool execution happens inline, tape writes are scattered across Recorder calls.

These aren't feature requests. They're structural capabilities that the current architecture cannot support without fundamental change. Adding SMC as a "new Reasoner" would require the Reasoner to internally manage a particle population, re-implementing process management that the BEAM already provides. Adding probabilistic primitives would require threading log-probabilities through every function in the call chain. Each addition fights the architecture rather than building on it.

### 1.2 The Accidental Complexity

The current codebase has ~50 modules for what is conceptually a simple system: a program that calls an LLM, executes tools, and records what happened. The complexity comes from layered indirection:

- **Mount system** (7 callbacks, GenServer registry, ETS, instances) conflates four separate concerns: providing tools, contributing prompt sections, injecting policy hooks, and declaring child processes. A tool that just runs bash commands must implement a behaviour, register in a GenServer, and be discovered through ETS.

- **Runtime threading** — a 13-field struct (`AgentLoop.Runtime`) is built once and threaded through every function. It carries the model, tools, emit callback, tape config, mount context, lifecycle hooks, reasoner module, and generation options as a single bundle. Functions pull out the 2-3 fields they need and ignore the rest.

- **Lifecycle closures wrapping MountRegistry dispatch** — the `Lifecycle` struct captures four closures that each call `MountRegistry.dispatch_*`, which iterates ETS entries, filters by scope, and calls mount callbacks. This is three layers of indirection between "before this tool runs" and the actual policy check.

- **Memory abstraction wrapping Tape** — `Rho.Memory` is a behaviour. `Rho.Memory.Tape` implements it by delegating to `Tape.Service`, which delegates to `Tape.Store` (SQLite), with `Tape.View` (ETS-cached projections), `Tape.Entry` (data struct), `Tape.Fork`, and `Tape.Compact` as separate modules. Six modules for an append-only log with read projections.

- **Recorder as single write point** — a module whose only job is to check "is there a tape?" before writing. This exists because tape writes are scattered across the AgentLoop and need a consistent gate.

None of these layers are wrong in isolation. Each was a reasonable design decision. But together they create a system where understanding "what happens when the agent calls a tool" requires reading across AgentLoop, Reasoner.Direct, Lifecycle, MountRegistry, and the specific Mount implementation.

### 1.3 The Theoretical Foundation

The paper *Intelligent Agent Systems: A Unified Theory from Algebraic Effects to Production* establishes that the core abstractions required for agent systems — continuation passing style, algebraic effects, probabilistic inference, and actor-model concurrency — are manifestations of a single structure: **the separation of a program's intent from the strategy used to execute it**.

The key claims that motivate this rewrite:

1. **An LLM agent is a probabilistic program whose effects are handled by an external interpreter.** The ReAct loop is CPS with the LLM as the function being continued and tool results as continuation arguments.

2. **The BEAM process model provides natural suspension semantics.** A process blocked on `receive` is a suspended computation. The BEAM scheduler drives computations by delivering messages. This gives us one-shot coroutine yield/resume. It does NOT give us cloneable or replayable continuations — that requires explicit trace recording and replay (see Section 3.6).

3. **Algebraic effects separate programs from handlers.** A program declares effects (LLM call, tool invoke, sample, observe). A handler gives those effects meaning (production: real API call; SMC: fork N times; test: return fixture). The program is polymorphic in its handler.

4. **SMC over agent traces requires effects as interceptable values.** Without this, running N agents in parallel is correlated best-of-N sampling — the paper (Section 9.2) proves this gives false confidence because all samples are conditioned on the same prompt.

### 1.4 The CQRS Parallel

The rewrite follows the same structural pattern as CQRS (Command Query Responsibility Segregation):

| CQRS Concept | Rho CPS Equivalent |
|---|---|
| Command (describes intended write) | Effect (`{:tool, "bash", %{cmd: "ls"}}`) |
| Command Handler (interprets command) | Handler function |
| Event (immutable record of what happened) | Tape entry |
| Event Store (append-only log) | Tape (SQLite) |
| Projection (derived read model) | `to_messages()` — context window from tape entries |
| Middleware pipeline | `handler \|> log_tools() \|> step_budget(30)` |

Where it goes beyond CQRS: the interpreter can run the same program N times (SMC) by spawning N processes and driving them independently, resuming each from recorded traces after resampling. This is the capability that enables probabilistic programming.

### 1.5 What This Plan Is Not

This plan does not claim:

- That BEAM processes are cloneable continuations. They are not. Resampling requires trace replay, not process cloning (Section 3.6).
- That SMC works for arbitrary side-effecting programs. It does not. SMC is restricted to pure or read-only programs unless per-particle sandboxing is implemented (Section 3.7).
- That middleware replaces all mount capabilities. It replaces hooks only. Tool provision, prompt contribution, and child processes are separate concerns with separate solutions (Section 2.3).
- That the simplified Agent shown here is feature-complete. It is the core; features like turn queuing, signal bus integration, and delegated-agent collection are re-added in Phase 4 (Section 5).

---

## 2. Design Principles

### 2.1 Programs Yield Effects, Interpreters Handle Them

The entire architecture follows one rule: **a program never executes a side effect directly.** It calls `perform(effect)`, which suspends the program and hands the effect to an interpreter. The interpreter calls a handler function, gets a result, and resumes the program.

This is the only abstraction. Everything else — ReAct loops, tool execution, tape persistence, multi-agent coordination, probabilistic inference — is either a specific program or a specific handler.

### 2.2 Processes Are Suspended Computations (Not Cloneable Continuations)

Each program runs in its own BEAM process. `perform()` sends a message to the interpreter and blocks on `receive`. The process is a suspended computation — its stack, locals, and program counter are frozen in memory, waiting for the handler's result.

**What this gives us:**
- Programs are normal Elixir code with normal control flow — no continuation nesting, no monadic macros
- The BEAM scheduler is the CPS trampoline
- Each SMC particle runs in its own process

**What this does NOT give us:**
- Process cloning (BEAM processes cannot be duplicated)
- Implicit serialization/replay (must be built explicitly via trace recording)
- Automatic fork-from-midpoint (must replay from start with recorded responses)

The resampling mechanism for SMC is **trace replay**: record the sequence of `(effect, handler_response)` pairs for each particle, and when resampling, start a fresh process that replays the cloned particle's recorded responses before switching to live execution. See Section 3.6.

### 2.3 Separation of Mount Concerns

The current Mount behaviour conflates four concerns. The rewrite separates them:

| Concern | Current (Mount) | Rewrite |
|---|---|---|
| Tool provision | `tools/2` callback | Tool modules return `Rho.Tool` structs, listed in config |
| Prompt contribution | `prompt_sections/2` callback | Prompt sections passed to `Rho.Prompt.build/3` at startup |
| Policy hooks | `before_tool/3`, `after_tool/4`, etc. | Middleware wrapping the handler function |
| Child processes | `children/2` callback | Declared in config, started by supervisor |

Middleware replaces **only the hook callbacks**, not all mount capabilities. This is a narrowing of scope, not a claim that everything is middleware.

### 2.4 One Module, One Job

No module wraps another module that wraps another module. The Tape is one module, not six. Tools are structs, not behaviour implementations registered in a GenServer. Config loads a file and returns a map.

---

## 3. Architecture

### 3.1 Module Map

```
lib/rho/
  rho.ex                     — public API
  effect.ex                  — effect type documentation
  program.ex                 — perform/1, spawn_program/2
  interpreter.ex             — single + population drivers
  trace.ex                   — effect trace recording + replay
  handler.ex                 — production handler builder
  middleware.ex              — composable handler wrappers

  programs/
    react.ex                 — standard ReAct agent loop
    react_structured.ex      — structured output variant

  tool.ex                    — tool struct
  tools/
    bash.ex                  — shell execution
    fs_read.ex               — file reading
    fs_write.ex              — file writing
    fs_edit.ex               — file editing
    web_fetch.ex             — HTTP requests
    python.ex                — Python execution
    finish.ex                — agent completion signal

  tape.ex                    — append-only conversation log
  tape/
    store.ex                 — SQLite backend (internal)
    compact.ex               — summarization (internal)

  prompt.ex                  — prompt section assembly
  config.ex                  — .rho.exs loading
  structured_output.ex       — JSON parsing (kept, it's good)

  agent.ex                   — agent GenServer
  agent/
    registry.ex              — ETS-based discovery
    supervisor.ex            — DynamicSupervisor

  comms.ex                   — signal bus (kept)
  comms/
    signal_bus.ex            — jido_signal wrapper (kept)
```

### 3.2 Data Flow

```
User input
  |
  v
Rho.Agent (GenServer)
  |  1. Load config
  |  2. Build tools from config
  |  3. Build handler = production(model, tools, tape, emit)
  |  4. Apply middleware from config
  |  5. Build program = ReAct.run(messages, tools, opts)
  |
  v
Rho.Interpreter.run(program, handler)
  |
  |  Spawns program process
  |
  |  Program process              Interpreter              Handler
  |  ---------------              -----------              -------
  |  perform({:tape_read})    --> handler.()           --> Tape.to_messages()
  |                           <-- [messages]
  |
  |  perform({:llm, ...})     --> handler.()           --> ReqLLM.stream_text()
  |                           <-- {:ok, response}          (streams text_delta via emit)
  |
  |  perform({:tool, ...})    --> handler.()           --> tool.execute.(args)
  |                           <-- {:ok, output}
  |
  |  perform({:tape_write})   --> handler.()           --> Tape.append()
  |                           <-- :ok
  |
  |  return {:ok, text}
  |
  v
Rho.Agent receives result, transitions to :idle
```

### 3.3 Effect Vocabulary

```elixir
# Core effects — present from day one
{:llm, messages, opts}                    # Call LLM, return response
{:tool, name, args}                       # Execute a tool
{:parallel, [effect]}                     # Execute effects concurrently
{:emit, event}                            # Publish an observable event

# Tape effects — conversation persistence
{:tape_read, opts}                        # Read messages from tape
{:tape_write, kind, payload}              # Append entry to tape
{:tape_compact}                           # Summarize and prune old entries

# Multi-agent effects — added when multi-agent is needed
{:spawn, role, task, opts}                # Start a child agent
{:send, target, message}                  # Message another agent
{:recv}                                   # Block until message arrives

# Probabilistic effects — added when inference is needed
{:sample, name, distribution}             # Draw from a prior
{:observe, name, log_score}               # Condition on evidence (reweight)
```

Effects are tagged tuples. No struct, no module — pattern matching is sufficient. New effect types are added by extending the handler, not by modifying core modules.

**Note on `{:parallel, effects}`:** This is a control-flow combinator, not a normal effect. The handler MUST apply middleware to each sub-effect — the handler receives the full middleware-wrapped pipeline, not a raw inner handler. See Section 3.5 for the correct implementation.

### 3.4 Program Runtime

```elixir
defmodule Rho.Program do
  @moduledoc """
  CPS runtime using BEAM processes as suspended computations.

  A program is a function that calls perform() at effect points.
  perform() sends the effect to the interpreter and blocks until
  resumed with the handler's result. The process is the suspended
  computation — but NOT a cloneable continuation. Forking requires
  trace replay (see Rho.Trace).
  """

  @doc """
  Yield an effect to the interpreter. Blocks until resumed.

  Uses a unique ref per effect to prevent mailbox interference
  from stale or unrelated messages.
  """
  def perform(effect) do
    interpreter = Process.get(:rho_interpreter)
    ref = make_ref()
    send(interpreter, {:effect, self(), ref, effect})
    receive do
      {:resume, ^ref, result} -> result
      {:kill, ^ref} -> exit(:killed)
    end
  end

  @doc """
  Spawn a program as a monitored process (not linked).
  The interpreter monitors the process and handles crashes
  as trace termination, not interpreter crashes.
  """
  def spawn_program(fun, interpreter_pid) do
    pid = spawn(fn ->
      Process.put(:rho_interpreter, interpreter_pid)
      result = fun.()
      send(interpreter_pid, {:done, self(), result})
    end)
    _ref = Process.monitor(pid)
    pid
  end
end
```

Key differences from v1:
- **Ref-tagged messages** prevent mailbox interference. Each `perform` generates a unique ref; the `receive` only matches that exact ref.
- **`spawn` + `monitor` instead of `spawn_link`**. A crashing program doesn't take down the interpreter. The interpreter receives `{:DOWN, ...}` and treats it as a failed trace.

### 3.5 Interpreter

```elixir
defmodule Rho.Interpreter do
  alias Rho.Program

  @doc "Run one program to completion with a handler."
  def run(program_fn, handler) do
    pid = Program.spawn_program(program_fn, self())
    drive(pid, handler, Rho.Trace.new())
  end

  defp drive(pid, handler, trace) do
    receive do
      {:effect, ^pid, ref, effect} ->
        result = handler.(effect)
        trace = Rho.Trace.record(trace, effect, result)
        send(pid, {:resume, ref, result})
        drive(pid, handler, trace)

      {:done, ^pid, value} ->
        {:ok, value, trace}

      {:DOWN, _monitor_ref, :process, ^pid, reason} ->
        {:error, {:program_crashed, reason}, trace}
    end
  end

  @doc """
  Run N copies of a program as a particle population.

  Synchronizes at :observe effects — all particles must reach
  an observe point before resampling occurs. Non-observe effects
  are handled independently per particle (no lockstep).

  Requires: program must be pure or use read-only tools.
  Side-effecting tools (bash, fs_write) will produce incorrect
  results without per-particle sandboxing.
  """
  def run_smc(program_fn, handler, opts \\ []) do
    n = opts[:particles] || 20
    threshold = opts[:resample_threshold] || 0.5

    particles =
      for i <- 1..n do
        pid = Program.spawn_program(program_fn, self())
        %{id: i, pid: pid, log_weight: 0.0, status: :alive,
          trace: Rho.Trace.new(), pending_ref: nil}
      end

    smc_loop(particles, handler, threshold, program_fn)
  end

  # SMC loop: drive particles independently, synchronize at :observe barriers.
  defp smc_loop(particles, handler, threshold, program_fn) do
    live = Enum.filter(particles, &(&1.status == :alive))
    if live == [] do
      collect_results(particles)
    else
      # Drive all live particles until they hit :observe or :done
      {particles, all_done} = advance_to_barrier(particles, handler)

      if all_done do
        collect_results(particles)
      else
        # All live particles are now at an :observe barrier.
        # Resample if ESS is low, then resume all.
        particles = maybe_resample(particles, threshold, program_fn, handler)
        particles = resume_observers(particles)
        smc_loop(particles, handler, threshold, program_fn)
      end
    end
  end

  # Drive each particle forward, handling non-observe effects immediately,
  # until each particle either hits :observe, :done, or crashes.
  defp advance_to_barrier(particles, handler) do
    # Each particle is driven by its own receive loop.
    # Non-observe effects are handled inline. :observe effects cause the
    # particle to pause (its ref is stored in pending_ref).
    particles = Enum.map(particles, fn
      %{status: :alive} = p -> drive_until_observe(p, handler)
      p -> p
    end)

    all_done = Enum.all?(particles, &(&1.status in [:done, :dead]))
    {particles, all_done}
  end

  defp drive_until_observe(particle, handler) do
    receive do
      {:effect, pid, ref, {:observe, name, log_score}} when pid == particle.pid ->
        %{particle |
          log_weight: particle.log_weight + log_score,
          trace: Rho.Trace.record(particle.trace, {:observe, name, log_score}, :ok),
          pending_ref: ref}

      {:effect, pid, ref, {:sample, name, dist}} when pid == particle.pid ->
        value = Rho.Distribution.draw(dist)
        trace = Rho.Trace.record(particle.trace, {:sample, name, dist}, value)
        send(pid, {:resume, ref, value})
        drive_until_observe(%{particle | trace: trace}, handler)

      {:effect, pid, ref, effect} when pid == particle.pid ->
        result = handler.(effect)
        trace = Rho.Trace.record(particle.trace, effect, result)
        send(pid, {:resume, ref, result})
        drive_until_observe(%{particle | trace: trace}, handler)

      {:done, pid, value} when pid == particle.pid ->
        %{particle | status: :done, trace: Rho.Trace.finalize(particle.trace, value)}

      {:DOWN, _ref, :process, pid, reason} when pid == particle.pid ->
        %{particle | status: :dead, trace: Rho.Trace.finalize(particle.trace, {:crash, reason})}
    end
  end

  defp resume_observers(particles) do
    Enum.map(particles, fn
      %{status: :alive, pending_ref: ref, pid: pid} = p when ref != nil ->
        send(pid, {:resume, ref, :ok})
        %{p | pending_ref: nil}
      p -> p
    end)
  end

  defp maybe_resample(particles, threshold, program_fn, handler) do
    live = Enum.filter(particles, &(&1.status == :alive))
    ess = compute_ess(live)

    if ess < length(live) * threshold do
      resample_via_trace_replay(particles, program_fn, handler)
    else
      particles
    end
  end

  defp compute_ess(particles) do
    weights = Enum.map(particles, & &1.log_weight)
    if weights == [], do: 0.0, else: ess_from_log_weights(weights)
  end

  defp ess_from_log_weights(log_weights) do
    max_w = Enum.max(log_weights)
    normalized = Enum.map(log_weights, fn w -> :math.exp(w - max_w) end)
    sum = Enum.sum(normalized)
    sum_sq = normalized |> Enum.map(&(&1 * &1)) |> Enum.sum()
    if sum_sq == 0, do: 0.0, else: sum * sum / sum_sq
  end

  defp collect_results(particles) do
    %{
      results: Enum.map(particles, fn p -> {p.id, p.trace} end),
      ess: compute_ess(Enum.filter(particles, &(&1.status != :dead))),
      weights: Enum.map(particles, & &1.log_weight)
    }
  end
end
```

Key differences from v1:
- **Ref-tagged protocol** — every effect/resume pair uses `make_ref()`.
- **Monitor, not link** — interpreter receives `{:DOWN, ...}` on crash.
- **Barrier synchronization at `:observe`** — particles advance independently until they all hit an `:observe` effect. Non-observe effects are handled inline without waiting for other particles. Resampling happens only at observe barriers.
- **No lockstep assumption** — particles can take different numbers of steps between observe points.

### 3.6 Trace Recording and Replay (Resampling Mechanism)

BEAM processes cannot be cloned. When SMC resamples — killing a low-weight particle and replacing it with a copy of a high-weight particle — we cannot duplicate the surviving process. Instead, we use **trace replay**:

1. Every particle records its `(effect, response)` history in a `Rho.Trace`.
2. When resampling, the interpreter kills the low-weight process and starts a fresh process running the same program.
3. The fresh process is driven by a **replay handler** that feeds it the cloned particle's recorded responses.
4. Once the replay catches up to the current point, the process switches to the live handler and continues normally.

```elixir
defmodule Rho.Trace do
  @moduledoc """
  Records the (effect, response) history of a program execution.
  Used for replay-based resampling in SMC, testing, and debugging.
  """

  defstruct entries: [], length: 0, result: nil

  def new, do: %__MODULE__{}

  def record(trace, effect, response) do
    %{trace |
      entries: [{effect, response} | trace.entries],
      length: trace.length + 1}
  end

  def finalize(trace, result) do
    %{trace | result: result, entries: Enum.reverse(trace.entries)}
  end

  @doc """
  Build a replay handler from a recorded trace.
  Returns responses from the trace until exhausted,
  then delegates to the live handler.
  """
  def replay_handler(trace, live_handler) do
    # Use a mutable reference to track replay position
    ref = :atomics.new(1, signed: false)
    entries = :persistent_term.put({:trace_replay, ref}, trace.entries)

    fn effect ->
      pos = :atomics.get(ref, 1)
      recorded = Enum.at(trace.entries, pos)

      case recorded do
        {^effect, response} ->
          # Still replaying — return recorded response
          :atomics.put(ref, 1, pos + 1)
          response

        nil ->
          # Replay exhausted — switch to live handler
          live_handler.(effect)

        {different_effect, _response} ->
          # Program diverged from recorded trace — this is a bug
          raise "Trace replay divergence at position #{pos}: " <>
                "expected #{inspect(different_effect)}, got #{inspect(effect)}"
      end
    end
  end
end
```

The `resample_via_trace_replay` function in the interpreter:

```elixir
defp resample_via_trace_replay(particles, program_fn, live_handler) do
  live = Enum.filter(particles, &(&1.status == :alive))
  indices = systematic_resample(Enum.map(live, & &1.log_weight), length(live))

  Enum.zip(live, indices)
  |> Enum.map(fn {particle, source_idx} ->
    source = Enum.at(live, source_idx)

    if source.id == particle.id do
      # Keep this particle, reset weight
      %{particle | log_weight: 0.0}
    else
      # Replace: kill old process, replay from source trace
      Process.exit(particle.pid, :kill)

      replay_handler = Rho.Trace.replay_handler(source.trace, live_handler)
      new_pid = Program.spawn_program(program_fn, self())

      # Drive the new process through replay until it catches up
      replayed_trace = drive_replay(new_pid, replay_handler, source.trace.length)

      %{particle |
        pid: new_pid,
        log_weight: 0.0,
        trace: replayed_trace,
        pending_ref: nil}
    end
  end)
end
```

**Constraints on trace replay:**
- Programs must be deterministic given the same handler responses (Invariant 7). If a program uses `System.monotonic_time()` or `:rand.uniform()` directly (not through `{:sample, ...}`), replay will diverge.
- The replay handler raises on divergence. This is a correctness check, not a performance concern — divergence indicates a bug.

### 3.7 Side-Effect Isolation — What SMC Can and Cannot Run

**Hard constraint: SMC is only valid for programs whose effects are either pure or isolated.**

| Effect | Safe for SMC? | Why |
|---|---|---|
| `{:llm, ...}` | Yes (cacheable) | Same input → same output. Cache across particles. |
| `{:tool, "fs_read", ...}` | Yes | Read-only, no mutation |
| `{:sample, ...}` | Yes | Each particle draws independently |
| `{:observe, ...}` | Yes | Reweighting is the point |
| `{:emit, ...}` | Needs care | Must be scoped per-particle or suppressed |
| `{:tool, "bash", ...}` | No | Mutates external state, non-idempotent |
| `{:tool, "fs_write", ...}` | No | Mutates filesystem |
| `{:tool, "python", ...}` | No | Arbitrary side effects |
| `{:tape_write, ...}` | Per-particle | Each particle needs its own trace, not a shared tape |
| `{:spawn, ...}` | No | Creates real processes with real side effects |
| `{:send, ...}` | No | Messages real agents |

**For SMC, the handler MUST:**
1. Use `Middleware.cache_llm()` — so N particles don't make N identical LLM calls
2. Use per-particle in-memory traces instead of shared SQLite tape
3. Either deny write-effecting tools or provide per-particle sandboxing
4. Suppress or scope `:emit` events (no duplicate UI events from particles)

**Recommended approach:** Build separate handler constructors for SMC that enforce these constraints:

```elixir
def smc_handler(opts) do
  production(opts)
  |> Middleware.cache_llm()
  |> Middleware.deny_tools(["bash", "fs_write", "fs_edit", "python"])
  |> Middleware.suppress_emit()
end
```

Attempting to run SMC with a production handler that has write-effecting tools should raise at construction time, not fail silently at runtime.

### 3.8 Handler + Middleware

```elixir
defmodule Rho.Handler do
  @moduledoc """
  Builds handler functions from configuration.
  A handler is fn(effect) -> result.
  """

  def production(opts) do
    model = opts[:model]
    tool_map = Map.new(opts[:tools] || [], fn t -> {t.name, t} end)
    tape = opts[:tape]
    emit = opts[:emit] || fn _ -> :ok end
    # Capture the fully-built handler for {:parallel} dispatch
    self_ref = make_ref()

    handler = fn
      {:llm, messages, llm_opts} ->
        tools = Enum.map(opts[:tools] || [], & &1.req_tool)
        stream_opts = Keyword.merge(llm_opts, [tools: tools])
        process_opts = [on_result: fn chunk -> emit.(%{type: :text_delta, text: chunk}) end]

        case stream_with_retry(model, messages, stream_opts, process_opts) do
          {:ok, response} -> {:ok, parse_llm_response(response)}
          {:error, reason} -> {:error, reason}
        end

      {:tool, name, args} ->
        case Map.fetch(tool_map, name) do
          {:ok, tool} -> tool.execute.(args)
          :error -> {:error, "unknown tool: #{name}"}
        end

      {:parallel, effects} ->
        # Retrieve the fully-wrapped handler (including middleware)
        # so parallel sub-effects go through the same pipeline.
        wrapped = Process.get({:rho_handler, self_ref})
        effects
        |> Task.async_stream(
          fn effect -> wrapped.(effect) end,
          max_concurrency: 5,
          timeout: 120_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      {:emit, event} ->
        emit.(event)
        :ok

      {:tape_read, read_opts} ->
        if tape, do: Rho.Tape.to_messages(tape, read_opts), else: []

      {:tape_write, kind, payload} ->
        if tape, do: Rho.Tape.append(tape, kind, payload), else: :ok

      {:tape_compact} ->
        if tape, do: Rho.Tape.compact(tape, model), else: :ok

      {:sample, _name, dist} ->
        Rho.Distribution.draw(dist)

      {:observe, _name, _log_score} ->
        :ok
    end

    # Store self-reference for {:parallel} dispatch after middleware is applied
    Process.put({:rho_handler, self_ref}, handler)
    handler
  end

  @doc """
  Finalize a handler after middleware is applied.
  Updates the self-reference so {:parallel} dispatches through middleware.
  """
  def finalize(handler, self_ref) do
    Process.put({:rho_handler, self_ref}, handler)
    handler
  end
end
```

**Note on `{:parallel}`:** The v1 plan had a bug where parallel sub-effects bypassed middleware. The fix: the handler stores a self-reference that is updated after middleware wrapping, so `{:parallel}` dispatches through the full pipeline. This is admittedly awkward — an alternative is to make `{:parallel}` an interpreter-level concern rather than a handler concern, so the interpreter dispatches sub-effects through the handler individually.

```elixir
defmodule Rho.Middleware do
  @moduledoc """
  Composable handler wrappers. Each middleware takes a handler
  and returns a new handler with added behavior.

  Usage: handler |> log_tools() |> deny_tools(["rm"]) |> step_budget(30)
  """

  require Logger

  @doc "Log tool calls with timing."
  def log_tools(handler) do
    fn
      {:tool, name, _args} = effect ->
        t0 = System.monotonic_time(:millisecond)
        result = handler.(effect)
        ms = System.monotonic_time(:millisecond) - t0
        Logger.info("[tool] #{name} (#{ms}ms)")
        result
      effect ->
        handler.(effect)
    end
  end

  @doc "Block specific tools."
  def deny_tools(handler, denied) do
    denied_set = MapSet.new(denied)
    fn
      {:tool, name, _args} ->
        if MapSet.member?(denied_set, name),
          do: {:error, "tool '#{name}' is denied"},
          else: handler.({:tool, name, _args})
      effect ->
        handler.(effect)
    end
  end

  @doc "Inject budget warning before last N steps."
  def step_budget(handler, max, warn_at \\ 2) do
    counter = :counters.new(1, [:atomics])
    fn
      {:emit, %{type: :step_start, step: step}} = effect ->
        :counters.add(counter, 1, 1)
        result = handler.(effect)
        remaining = max - step
        if remaining <= warn_at and remaining > 0 do
          handler.({:emit, %{type: :budget_warning, remaining: remaining}})
        end
        result
      effect ->
        handler.(effect)
    end
  end

  @doc """
  Cache identical LLM calls. Uses a per-instance ETS table
  (no name collision across concurrent runs).
  """
  def cache_llm(handler) do
    cache = :ets.new(:llm_cache, [:set, :public])
    fn
      {:llm, messages, opts} = effect ->
        key = :erlang.phash2({messages, opts})
        case :ets.lookup(cache, key) do
          [{^key, result}] -> result
          [] ->
            result = handler.(effect)
            :ets.insert(cache, {key, result})
            result
        end
      effect ->
        handler.(effect)
    end
  end

  @doc "Suppress all :emit effects (for SMC particles)."
  def suppress_emit(handler) do
    fn
      {:emit, _event} -> :ok
      effect -> handler.(effect)
    end
  end

  @doc "Record all effects to a trace log (for replay/debugging)."
  def trace(handler, trace_pid) do
    fn effect ->
      result = handler.(effect)
      send(trace_pid, {:trace, effect, result})
      result
    end
  end
end
```

### 3.9 ReAct Program

```elixir
defmodule Rho.Programs.ReAct do
  @moduledoc """
  Standard ReAct (Reason + Act) agent loop expressed as a CPS program.

  Yields effects for every interaction with the outside world:
  LLM calls, tool execution, tape reads/writes, and event emission.
  The handler determines HOW each effect is executed.
  """

  import Rho.Program

  @terminal_tools MapSet.new(["finish", "end_turn", "create_anchor", "clear_memory"])

  def run(initial_messages, tools, opts \\ []) do
    fn ->
      max_steps = opts[:max_steps] || 30

      # Read existing context from tape, or use initial messages
      context = case perform({:tape_read, []}) do
        [] -> initial_messages
        messages -> messages
      end

      loop(context, tools, max_steps, 1)
    end
  end

  defp loop(_context, _tools, max, step) when step > max do
    {:error, :max_steps}
  end

  defp loop(context, tools, max, step) do
    perform({:emit, %{type: :step_start, step: step, max_steps: max}})

    case perform({:llm, context, []}) do
      {:error, reason} ->
        perform({:emit, %{type: :error, reason: reason}})
        {:error, reason}

      {:ok, %{text: text, tool_calls: [], usage: usage}} ->
        perform({:emit, %{type: :llm_usage, step: step, usage: usage}})
        perform({:tape_write, :message, %{"role" => "assistant", "content" => text}})
        {:ok, text}

      {:ok, %{text: text, tool_calls: calls, usage: usage}} ->
        perform({:emit, %{type: :llm_usage, step: step, usage: usage}})

        if text && String.trim(text) != "" do
          perform({:emit, %{type: :llm_text, text: text}})
        end

        results = execute_tools(calls)

        perform({:tape_write, :tool_step, %{
          "assistant_text" => text,
          "calls" => serialize_calls(calls),
          "results" => serialize_results(results)
        }})

        # Check for terminal tools
        called_names = MapSet.new(calls, fn {name, _, _} -> name end)
        terminal = MapSet.intersection(called_names, @terminal_tools)

        if MapSet.size(terminal) > 0 do
          answer = extract_terminal_answer(calls, results, text)
          {:ok, answer}
        else
          maybe_compact()
          context = perform({:tape_read, []})
          loop(context, tools, max, step + 1)
        end
    end
  end

  defp execute_tools([{name, args, call_id}]) do
    [execute_one(name, args, call_id)]
  end

  defp execute_tools(calls) do
    effects = Enum.map(calls, fn {name, args, call_id} ->
      perform({:emit, %{type: :tool_start, name: name, args: args, call_id: call_id}})
      {:tool, name, args}
    end)

    results = perform({:parallel, effects})

    Enum.zip(calls, results)
    |> Enum.map(fn {{name, _args, call_id}, result} ->
      {status, output} = normalize_result(result)
      perform({:emit, %{type: :tool_result, name: name, status: status,
                        output: output, call_id: call_id}})
      result
    end)
  end

  defp execute_one(name, args, call_id) do
    perform({:emit, %{type: :tool_start, name: name, args: args, call_id: call_id}})
    t0 = System.monotonic_time(:millisecond)
    result = perform({:tool, name, args})
    latency = System.monotonic_time(:millisecond) - t0
    {status, output} = normalize_result(result)
    perform({:emit, %{type: :tool_result, name: name, status: status,
                      output: output, call_id: call_id, latency_ms: latency}})
    result
  end

  defp maybe_compact, do: perform({:tape_compact})

  defp normalize_result({:ok, output}), do: {:ok, output}
  defp normalize_result({:error, reason}), do: {:error, to_string(reason)}
  defp normalize_result({:final, output}), do: {:ok, output}

  defp extract_terminal_answer(calls, results, fallback_text) do
    Enum.zip(calls, results)
    |> Enum.find_value(fn
      {{"finish", args, _}, _} -> args["result"]
      _ -> nil
    end) || fallback_text
  end

  # Ensure tape payloads use string keys consistently
  defp serialize_calls(calls) do
    Enum.map(calls, fn {name, args, call_id} ->
      %{"name" => name, "args" => args, "call_id" => call_id}
    end)
  end

  defp serialize_results(results) do
    Enum.map(results, fn
      {:ok, output} -> %{"status" => "ok", "output" => output}
      {:error, reason} -> %{"status" => "error", "output" => to_string(reason)}
    end)
  end
end
```

### 3.10 Tool, Tape, Config, Agent, Prompt

These modules are unchanged from v1 (Sections 3.8-3.12 of the original plan). The Tool struct, Tape consolidation, Config simplification, Agent GenServer, and Prompt assembly remain as designed. See Appendix A for the full code.

The Agent GenServer shown in v1 was intentionally minimal to illustrate the architecture. The full implementation will re-add:
- **Turn queuing** — queue submissions when busy, process on idle
- **Turn IDs + correlation** — unique ID per turn for event correlation
- **Signal bus integration** — publish events to `Rho.Comms`, subscribe to inbox
- **Delegated-agent collection** — waiters list, `collect/2` with deferred reply
- **Mailbox delivery** — inter-agent message processing when idle
- **Status reporting** — current tool, current step, token usage, last activity

These are additive — they don't change the core `start_turn → build handler → build program → Interpreter.run` flow. They are scheduling and observability concerns layered on top of the CPS core.

---

## 4. What This Enables

### 4.1 Probabilistic Programming

With the CPS foundation in place, probabilistic programming is more effect types handled by the SMC interpreter:

```elixir
defmodule Rho.Programs.BayesianExtraction do
  import Rho.Program

  def run(documents, schema) do
    fn ->
      # Sample model parameters — inference explores these
      threshold = perform({:sample, :threshold, Beta.new(2, 5)})
      noise = perform({:sample, :noise, Gamma.new(1, 0.1)})

      for doc <- documents do
        # LLM extracts structured data — cached across particles
        {:ok, extracted} = perform({:llm, extraction_prompt(doc, schema), []})

        # Condition on model fit — triggers resampling when ESS drops
        predicted = model_predict(threshold, extracted)
        perform({:observe, :fit, log_likelihood(predicted, extracted.value, noise)})
      end

      %{threshold: threshold, noise: noise}
    end
  end
end

# Run inference — note: smc_handler denies write-effecting tools
result = Rho.Interpreter.run_smc(
  BayesianExtraction.run(documents, schema),
  Rho.Handler.smc_handler(model: model, tools: read_only_tools),
  particles: 100
)
```

The LLM call is cached across particles (same document → same extraction). Only `:sample` values differ between particles. `:observe` effects trigger the barrier synchronization and potential resampling.

### 4.2 Execution Strategy Swapping

The same ReAct program runs under different interpreters without modification:

```elixir
program = Rho.Programs.ReAct.run(messages, tools, max_steps: 30)

# Production: single trace, real LLM, real tools
Rho.Interpreter.run(program, production_handler)

# Testing: single trace, fixture responses
Rho.Interpreter.run(program, test_handler)

# Replay: single trace, read effects from recorded log
Rho.Interpreter.run(program, Rho.Trace.replay_handler(recorded_trace, nil))

# Cost estimation: count LLM calls without executing them
Rho.Interpreter.run(program, cost_counter_handler)
```

### 4.3 Hierarchical Allocation

The paper's hierarchical allocation pattern (cheap model first, escalate on uncertainty):

```elixir
def hierarchical_extract(document, schema) do
  program = extraction_program(document, schema)

  coarse = Rho.Interpreter.run_smc(
    program,
    Rho.Handler.smc_handler(model: :haiku),
    particles: 10
  )

  cond do
    coarse.ess / 10 > 0.85 ->
      {:high_confidence, best_result(coarse)}

    coarse.ess / 10 > 0.50 ->
      refined = Rho.Interpreter.run_smc(
        program,
        Rho.Handler.smc_handler(model: :sonnet),
        particles: 20
      )
      {:moderate_confidence, best_result(refined)}

    true ->
      {:low_confidence_escalate, best_result(coarse)}
  end
end
```

---

## 5. Migration Path

The migration is incremental, not big-bang. Each phase is independently valuable and testable. The existing system continues working throughout.

### Phase 1: Effect Boundary in Current Architecture (Week 1-2)

**Do not rewrite AgentLoop yet.** Extract an effect boundary inside the existing Reasoner by replacing direct `ReqLLM`, tool execution, and tape writes with calls to an `Executor` module:

```elixir
defmodule Rho.Executor do
  def run_llm(messages, opts, ctx), do: ...
  def run_tool(name, args, ctx), do: ...
  def read_tape(ctx), do: ...
  def write_tape(kind, payload, ctx), do: ...
  def emit(event, ctx), do: ...
end
```

This proves effects are interceptable without destabilizing the runtime. Build:
- Production executor (current behavior)
- Test executor (fixture responses)
- Cost-counting executor

**Deliverable:** Existing test suite passes. Test executor enables deterministic agent loop tests.

### Phase 2: CPS Foundation — New Path Alongside Old (Week 2-3)

Build `Rho.Program`, `Rho.Interpreter`, `Rho.Trace`, `Rho.Handler`, `Rho.Middleware` as **new modules alongside the existing code.** Do not touch AgentLoop.

Write `Rho.Programs.ReAct` expressing the current ReAct logic as a CPS program.

**Tests:**
- `Interpreter.run(ReAct.run(...), Handler.production(...))` produces the same output as `AgentLoop.run(...)` for identical inputs
- Middleware composition works correctly
- Programs yield effects in expected order
- Trace recording captures complete `(effect, response)` history
- Trace replay reproduces identical program behavior

**Deliverable:** Two working execution paths. Both pass the same test suite.

### Phase 3: Tool and Config Simplification (Week 3-4)

- `Rho.Tool` struct replaces mount-based tool definitions
- `Rho.Config` v2 loads tools as module list
- `Rho.Prompt` assembles prompts from sections
- Old mount-based tools and new struct-based tools coexist

### Phase 4: Agent Migration (Week 4-5)

- Rewrite `Agent.Worker` to use `Interpreter.run` internally
- Re-add features from current Worker: turn queuing, turn IDs, signal bus, delegated-agent collection, mailbox delivery, status reporting
- **Parity tests:** every current behavior (events, prompt shaping, tape behavior, cancellation, subagents) must be covered before removing old code
- Remove `AgentLoop`, `Runtime`, `Recorder`, `Lifecycle`, `MountRegistry`, `MountInstance`, `Reasoner`, `Reasoner.Direct`

### Phase 5: Tape Consolidation (Week 5-6)

- Merge tape modules into `Rho.Tape` with internal Store and Compact
- Benchmark `to_messages` against current `Tape.View` ETS-cached projection on long sessions (100+ entries). If performance regresses, add caching.
- Remove `Memory` behaviour and `Memory.Tape`

### Phase 6: SMC Prototype — Pure Programs Only (Week 6-8)

Build SMC on a **small, pure program first** — structured extraction using only `:llm`, `:sample`, and `:observe` effects. No filesystem, no bash, no multi-agent, no streaming, no shared tape.

**Requirements before declaring SMC working:**
- Trace replay produces identical program behavior (correctness test)
- Resampling correctly replaces low-weight particles with replayed high-weight traces
- ESS computation matches reference implementation
- `smc_handler` rejects write-effecting tools at construction time
- Per-particle in-memory traces (not shared SQLite)

If SMC can't work correctly on the pure subset, it won't work on full ReAct agents. Validate here before scaling.

### Phase 7: Cleanup (Week 8-9)

- Remove all deprecated modules
- Update `.rho.exs` format
- Update web transport and CLI
- Final test pass

---

## 6. Removed Modules

| Module | Lines | Replacement |
|---|---|---|
| `Rho.Mount` | 100 | Tool struct + middleware + prompt sections |
| `Rho.MountRegistry` | 250 | Tools resolved at startup |
| `Rho.MountInstance` | 30 | Gone |
| `Rho.Lifecycle` | 66 | Middleware composition |
| `Rho.AgentLoop` | 350 | `Rho.Interpreter` |
| `Rho.AgentLoop.Runtime` | 40 | Handler closure |
| `Rho.AgentLoop.Tape` | 20 | `Rho.Tape` directly |
| `Rho.AgentLoop.Recorder` | 100 | `:tape_write` effect |
| `Rho.Reasoner` | 33 | `Rho.Programs.*` |
| `Rho.Reasoner.Direct` | 243 | `Rho.Programs.ReAct` + `Rho.Handler` |
| `Rho.Memory` | 50 | Gone (Tape IS memory) |
| `Rho.Memory.Tape` | 80 | Gone |
| `Rho.Tape.Entry` | 94 | Inline in `Rho.Tape` |
| `Rho.Tape.Service` | 263 | Inline in `Rho.Tape` |
| `Rho.Tape.View` | 218 | `Rho.Tape.to_messages/2` (benchmark first) |
| `Rho.Plugins.StepBudget` | 25 | `Middleware.step_budget/2` |
| **Total removed** | **~1962** | |

| New Module | Lines (est.) | Role |
|---|---|---|
| `Rho.Program` | 20 | CPS runtime (ref-tagged) |
| `Rho.Interpreter` | 200 | Single + population driver |
| `Rho.Trace` | 60 | Recording + replay |
| `Rho.Handler` | 100 | Production + SMC handler builders |
| `Rho.Middleware` | 100 | Composable wrappers |
| `Rho.Programs.ReAct` | 120 | Agent loop as program |
| `Rho.Tool` | 30 | Tool struct |
| `Rho.Tape` | 100 | Unified tape (with optional caching) |
| `Rho.Prompt` | 30 | Prompt assembly |
| `Rho.Agent` | 200 | GenServer (with re-added features) |
| `Rho.Config` (v2) | 60 | Simplified config |
| **Total new** | **~1020** | |

Net reduction: ~940 lines, with execution strategy swapping (Phase 2) and SMC (Phase 6) as new capabilities.

---

## 7. Invariants

These properties must hold after the rewrite:

1. **Programs never execute side effects directly.** Every interaction with the outside world goes through `perform()`. This is the foundational invariant — if a program calls `ReqLLM` or `System.cmd` directly, the entire CPS architecture breaks.

2. **Handlers are pure functions from effects to results.** A handler's only input is the effect; its only output is the result. Handlers may have internal state (closures, ETS), but they don't receive the program's state or continuation.

3. **The interpreter is the only module that manages program processes.** No other module calls `Program.spawn_program` or sends `:resume`/`:kill` messages.

4. **Middleware composes by wrapping.** `middleware(handler)` returns a new handler. The middleware chain is built once at startup, not modified during execution.

5. **The tape is append-only.** Entries are never modified or deleted (compaction writes a summary anchor and marks old entries as superseded, but doesn't delete them). This ensures traces are replayable.

6. **Effects are tagged tuples.** No structs, no protocols — just `{:atom, ...}` pattern-matched in handlers. This keeps the effect vocabulary extensible without code changes to core modules.

7. **Programs are deterministic given the same handler responses.** If you replay a handler's response sequence, the program produces the same effects in the same order. This is what makes trace replay, testing, and SMC resampling possible. Programs must not use `System.monotonic_time()`, `:rand.uniform()`, or other ambient state directly — any source of randomness must go through `{:sample, ...}`.

8. **SMC only runs on pure or read-only programs.** Write-effecting tools (bash, fs_write, python) are denied by the SMC handler at construction time. Per-particle isolation for write effects is a future capability, not an assumed one.

9. **Resampling is trace replay, not process cloning.** BEAM processes cannot be duplicated. Resampling kills the old process, starts a fresh one, and drives it with recorded responses from the source particle's trace until it catches up to the current point.

10. **The perform/resume protocol uses unique refs.** Every `perform` generates a `make_ref()` and the corresponding `receive` matches only that ref. This prevents mailbox interference from stale messages, monitoring signals, or concurrent effects.

---

## 8. Open Questions and Risks

### 8.1 Tape.View Performance

The current `Tape.View` uses ETS caching for incremental context assembly. The simplified `Tape.to_messages/2` recomputes from SQLite on every call. For long sessions (100+ entries), this may regress. **Mitigation:** Benchmark in Phase 5 before removing View. Add ETS caching to the new Tape if needed.

### 8.2 Interpreter Bottleneck at Scale

For SMC with large N (100+ particles), the interpreter process receives effects from all particles. This could become a serial bottleneck. **Mitigation options:**
- Per-particle interpreter processes (each drives one particle, a coordinator manages the population)
- Batched dispatch (collect effects from all particles, handle in parallel, resume all)
- Only relevant for Phase 6+; single-program mode (Phase 2) has no bottleneck

### 8.3 Trace Replay Fidelity

Trace replay assumes programs are deterministic given handler responses. If a program reads the clock, accesses ETS, or uses `:rand` directly, replay will diverge. **Mitigation:** The replay handler raises on divergence (fail fast). Document the constraint clearly.

### 8.4 Streaming Inside Handlers

LLM streaming (emitting `text_delta` events during the LLM call) happens inside the handler, not as effects yielded by the program. This means streaming is a side effect of the handler, invisible to the interpreter and trace. **Implication:** Trace replay of LLM calls will not reproduce streaming events. This is acceptable — streaming is a UI concern, not a semantic one. The final response is what matters for replay fidelity.

### 8.5 Feature Parity Risk

The migration removes existing code before new code is proven. **Mitigation:** Phase 4 requires parity tests covering events, prompt shaping, tape behavior, cancellation, and subagents before any module is deleted. Phase 1's Executor refactor provides the safety net — if the CPS path fails, the Executor boundary still provides strategy swapping.

---

## Appendix A: Tool, Tape, Config, Agent, Prompt (Unchanged from v1)

### Tool Definition

```elixir
defmodule Rho.Tool do
  defstruct [:name, :description, :schema, :execute, :req_tool]

  def new(opts) do
    t = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      description: Keyword.fetch!(opts, :description),
      schema: Keyword.get(opts, :schema, []),
      execute: Keyword.fetch!(opts, :execute)
    }
    %{t | req_tool: build_req_tool(t)}
  end

  defp build_req_tool(t) do
    ReqLLM.Tool.new(
      name: t.name,
      description: t.description,
      parameter_schema: t.schema
    )
  end
end
```

### Tape

```elixir
defmodule Rho.Tape do
  defstruct [:ref, :db_path]

  def new(session_id, workspace) do
    ref = "#{session_id}_#{:erlang.phash2(workspace)}"
    db_path = Path.join(tape_dir(), "#{ref}.db")
    Rho.Tape.Store.ensure_created(db_path)
    %__MODULE__{ref: ref, db_path: db_path}
  end

  def append(tape, kind, payload) do
    Rho.Tape.Store.append(tape.db_path, %{
      kind: kind,
      payload: payload,
      date: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def to_messages(tape, _opts \\ []) do
    tape.db_path
    |> Rho.Tape.Store.entries_since_last_anchor()
    |> Enum.flat_map(&entry_to_messages/1)
  end

  def compact(tape, model) do
    Rho.Tape.Compact.run(tape.db_path, model)
  end

  def fork(tape) do
    new_ref = tape.ref <> "_fork_#{System.unique_integer([:positive])}"
    new_path = Path.join(tape_dir(), "#{new_ref}.db")
    Rho.Tape.Store.copy(tape.db_path, new_path)
    %__MODULE__{ref: new_ref, db_path: new_path}
  end

  def info(tape), do: Rho.Tape.Store.info(tape.db_path)

  defp entry_to_messages(%{kind: :message, payload: %{"role" => "user", "content" => c}}),
    do: [ReqLLM.Context.user(c)]
  defp entry_to_messages(%{kind: :message, payload: %{"role" => "assistant", "content" => c}}),
    do: [ReqLLM.Context.assistant(c)]
  defp entry_to_messages(%{kind: :tool_step, payload: payload}),
    do: build_tool_step_messages(payload)
  defp entry_to_messages(_), do: []

  defp tape_dir, do: Path.join(System.get_env("HOME", "/tmp"), ".rho/tapes")
end
```

### Config

```elixir
defmodule Rho.Config do
  @defaults %{
    model: "anthropic/claude-sonnet-4-20250514",
    system_prompt: "You are a helpful assistant.",
    tools: [Rho.Tools.Bash, Rho.Tools.FsRead, Rho.Tools.FsWrite, Rho.Tools.FsEdit],
    middleware: [],
    max_steps: 30,
    program: Rho.Programs.ReAct
  }

  def load(agent_name \\ :default) do
    @defaults |> Map.merge(load_rho_exs(agent_name)) |> Map.merge(load_env())
  end

  def build_tools(config, context \\ []) do
    Enum.map(config.tools, fn
      mod when is_atom(mod) -> mod.tool(context)
      {mod, opts} -> mod.tool(Keyword.merge(context, opts))
    end)
  end

  def build_middleware(config, handler) do
    Enum.reduce(config.middleware, handler, fn
      :logging, h -> Rho.Middleware.log_tools(h)
      :step_budget, h -> Rho.Middleware.step_budget(h, config.max_steps)
      {:deny_tools, names}, h -> Rho.Middleware.deny_tools(h, names)
      {mod, opts}, h -> mod.wrap(h, opts)
    end)
  end

  defp load_rho_exs(agent_name) do
    case File.read(".rho.exs") do
      {:ok, content} ->
        {config, _} = Code.eval_string(content)
        case config do
          %{agents: agents} -> Map.get(agents, agent_name, %{})
          map when is_map(map) -> map
          _ -> %{}
        end
      {:error, _} -> %{}
    end
  end

  defp load_env do
    %{}
    |> maybe_put(:model, System.get_env("RHO_MODEL"))
    |> maybe_put(:max_steps, parse_int(System.get_env("RHO_MAX_STEPS")))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
  defp parse_int(nil), do: nil
  defp parse_int(s), do: String.to_integer(s)
end
```

### Prompt Assembly

```elixir
defmodule Rho.Prompt do
  defstruct [:key, :body, priority: 50]

  def build(base_prompt, tools, extras \\ []) do
    sections = [
      %__MODULE__{key: :system, body: base_prompt, priority: 0},
      %__MODULE__{key: :tools, body: render_tools(tools), priority: 50}
      | extras
    ]

    sections
    |> Enum.reject(&is_nil(&1.body))
    |> Enum.sort_by(& &1.priority)
    |> Enum.map_join("\n\n", & &1.body)
  end

  defp render_tools([]), do: nil
  defp render_tools(tools) do
    tool_text =
      tools
      |> Enum.map(fn t -> "- #{t.name}: #{t.description}" end)
      |> Enum.join("\n")

    "## Available Tools\n#{tool_text}"
  end
end
```
