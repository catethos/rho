> **Superseded.** This refactor is complete. Mounts are now `Rho.Plugin`,
> lifecycle hooks are `Rho.Transformer` (6 typed stages), `Rho.MountInstance`
> is `Rho.PluginInstance`, `Rho.MountRegistry` is `Rho.PluginRegistry`,
> `Rho.Mount.Context` is `Rho.Context`, and `Rho.Lifecycle` is deleted.
> See CLAUDE.md for current architecture.

# Rho — Mount Architecture Refactor Plan

## Executive Summary

Rho is an Elixir/OTP agent framework. Over organic growth, its extension surface fragmented into 4+ separate paths (Extensions, Skills, Tools, Memory-provided tools, Sandbox tools) that are all conceptually the same thing: "contributions to the agent's turn loop." This refactor unifies them under a single model derived from first principles, informed by the [Recursive Language Models](https://arxiv.org/abs/2512.24601) (RLM) paper's insight that large state should live in addressable environments, not in the LLM's context window.

**One-sentence model:**
> A Rho agent is a journaled process that repeatedly projects a bounded working-memory view from its journal and mounted environments, reasons with the LLM via a pluggable reasoner strategy, acts through mounted environments, and commits results back to the journal.

**Core architectural law:**
> All durable meaning flows through the journal; all optional behavior arrives through mounts; all external interaction happens through transports. Large state lives in persistent mounted environments and is accessed programmatically — the prompt is a bounded projection, never the full state.

---

## Table of Contents

1. [Conceptual Foundation](#1-conceptual-foundation)
2. [Current Architecture Problems](#2-current-architecture-problems)
3. [Target Architecture](#3-target-architecture)
4. [Module Mapping: Current → Target](#4-module-mapping-current--target)
5. [Phase 1: Mount Behaviour & Registry](#phase-1-mount-behaviour--registry)
6. [Phase 2: Migrate Existing Modules to Mounts](#phase-2-migrate-existing-modules-to-mounts)
7. [Phase 3: Unify Tool Resolution in Turn Engine](#phase-3-unify-tool-resolution-in-turn-engine)
8. [Phase 4: Split Journal Store from Journal Capabilities](#phase-4-split-journal-store-from-journal-capabilities)
9. [Phase 5: Typed Hook Points (Replace Generic Event Dispatch)](#phase-5-typed-hook-points-replace-generic-event-dispatch)
10. [Phase 6: Reasoner Strategies](#phase-6-reasoner-strategies)
11. [Phase 7: Config Unification](#phase-7-config-unification)
12. [Phase 8: Cleanup & Rename](#phase-8-cleanup--rename)
13. [Phase 9: Generative UI — Visual Output as a Mount + Transport](#phase-9-generative-ui--visual-output-as-a-mount--transport)
14. [Appendix A: Conceptual Glossary](#appendix-a-conceptual-glossary)
14. [Appendix B: RLM Theoretical Foundation](#appendix-b-rlm-theoretical-foundation)
15. [Appendix C: Lessons from Pi](#appendix-c-lessons-from-pi-pi-coding-agent)

---

## 1. Conceptual Foundation

### The Cognitive OS Metaphor

Rho is best understood as an **event-sourced cognitive operating system**. Each session is a long-lived process with:

- A **journal** (tape) — the authoritative, append-only record of everything that happened
- A **turn engine** (agent loop) — the scheduler that repeatedly projects context, reasons via LLM, acts, and commits results
- A **reasoner strategy** — the algorithm the turn engine uses for the reason+act phase (direct tool-use loop, or recursive code-generation loop)
- A set of **mounts** — anything attached to the process that contributes behavior or state to a turn
- **Transports** — terminals (CLI, Web) that submit input and render output

This model explains every feature without inventing a special category for each one.

### The Three-Tier Memory Model

Inspired by the [RLM paper](https://arxiv.org/abs/2512.24601)'s out-of-core algorithm analogy — where a system with small fast memory processes large datasets via clever fetching — Rho's memory is explicitly three-tiered:

1. **Journal** (disk) — durable, replayable, authoritative. The append-only event log that IS the agent's memory. Unbounded.
2. **Mounted environments** (working memory) — persistent, addressable, non-authoritative working state. Python REPL variables, sandbox files, derived buffers. Session-scoped. State here is operationally persistent but not part of the agent's durable meaning until referenced or materialized in the journal.
3. **Prompt projection** (cache/registers) — the bounded view sent to the LLM. Assembled on demand from journal + mount contributions + environment metadata. Always fits within the context window.

The key insight (shared with RLM): **large semantic material should live in addressable environments (tier 2), not in token space (tier 3)**. The model sees metadata and access paths, not payloads. This is what makes it possible to process data orders of magnitude beyond the context window.

**Commit discipline:** Environment state may persist operationally, but it is not part of the agent's durable meaning until committed to the journal. Important results — executed code, selected outputs, produced artifacts, final values from child frames — must be materialized in the journal for durability and auditability.

### Key Conceptual Definitions

#### Kernel
The irreducible core the agent cannot rewrite. Four components:

1. **Agent Process** (currently `Session.Worker`) — owns identity, lifecycle, turn queueing, child relationships, subscribers. A subagent is just a child process of the same kind, recursively instantiated.

2. **Turn Engine** (currently `AgentLoop`) — the outer execution loop:
   ```
   project → reason → act → commit → repeat
   ```
   - **Project**: assemble working set (journal + environment bindings + mount contributions), then render a bounded prompt projection from it
   - **Reason**: send projection to LLM via the active reasoner strategy, get response
   - **Act**: execute tool calls through mounted environments
   - **Commit**: append results to journal

3. **Journal** (currently Tape + Views + Anchors) — the append-only event log that IS the agent's memory. Views, anchors, and compaction are projection/checkpointing machinery over the journal. The journal stores immutable facts; the projection is a temporary working-memory window assembled on demand.

   Critical insight: **the prompt is not the state. The journal is the state. The prompt is a projection.**

4. **Reasoner Strategy** — the algorithm that drives the reason+act phase within a turn. The turn engine delegates to the active reasoner:
   - `Rho.Reasoner.Direct` (default) — today's standard loop: send tools + prompt to LLM, execute tool calls, repeat until LLM stops calling tools.
   - `Rho.Reasoner.Recursive` — RLM-style loop: the LLM writes code that runs in a persistent REPL, inspects large resources by reference, dispatches sub-LLM calls (`llm_query`), iterates until it signals convergence (`FINAL()`). Internally iterative with its own budget (max iterations, max sub-queries), but from the turn engine's perspective it's just one reason+act cycle.

   The reasoner is a kernel concept, not a mount, because it changes *how the turn itself executes* — the control structure of reasoning — rather than contributing resources to a turn. Mounts provide the substrates (REPL, tools, bindings) that reasoners operate over.

#### Mounts
Everything outside the kernel that contributes to turns. A mount may provide any subset of:

- **Tools** — callable functions the LLM can invoke
- **Prompt sections** — text fragments injected into the system prompt / context
- **Bindings** — large resources exposed by reference (name, kind, size, access path) rather than injected as text. The engine renders metadata in the prompt; the agent accesses the actual content programmatically via tools or REPL variables. This is the mechanism that enables RLM-style "context as environment variable" patterns.
- **Hook reactions** — typed callbacks at specific turn lifecycle points (policy-only: budgets, guardrails, result rewriting — never control flow for the reasoning loop itself)
- **Supervised resources** — OTP children needed by the mount

Mounts fall into natural categories (not enforced by the system, just conceptual):

| Category | Examples | What they contribute |
|----------|----------|---------------------|
| **Procedural memory** | Skills (SKILL.md files) | Prompt sections + skill loader tool |
| **Runtime environments** | Python REPL, Sandbox FS | Persistent session-scoped substrates; exposed as tools |
| **Actuators / sensors** | Bash, FS read/write/edit, Web fetch | Tools that act on / read from the world |
| **Journal capabilities** | Search, recall, anchor, compaction | Tools + policies that operate over the journal |
| **Policies** | Step budget, final response | Hook reactions that shape loop behavior |
| **Orchestration** | Subagent spawn/collect | Tools that fork child agent processes |

#### Runtime Environments (a special kind of mount)
Python REPL and Sandbox are not "just tools." They are **persistent computational substrates the process inhabits across turns**:

- **Python REPL** = a stateful scratchpad / external working memory. The agent can offload large data processing, store intermediate state outside the LLM context window and selectively extract useful parts, run analysis, generate visualizations. Cognitively: an external brain. OS-wise: a session-mounted coprocessor.

- **Sandbox** = a safe mutable workspace. An overlay filesystem (via AgentFS) where all writes are captured without touching the real workspace until explicitly committed. Cognitively: an embodied task environment. OS-wise: a mounted filesystem.

- **Bash** = a stateless command interface against the (possibly sandboxed) workspace. An actuator, not a persistent environment.

These runtimes have lifecycles tied to the session, are started on demand, and persist state across turns — which is what distinguishes them from stateless tool calls.

#### Transports
CLI and Web are not part of agent cognition. They are terminals that:
- Submit input into a process
- Subscribe to the process's event stream
- Render output

Transport concerns (auth, rendering, rate limiting) must not leak into the turn engine or mount interface.

#### Self-Evolution
Self-evolution is **not a special subsystem**. It is a natural use case of the same kernel + journal + mounts model:

> The process uses its mounted environments (Bash, FS tools, Python, Sandbox) to modify the artifacts that define its future mounts (SKILL.md files, capability modules, config).

The flow:
1. Agent writes a new skill/capability file (via FS tools or Sandbox)
2. On next turn boundary, the mount registry rescans and discovers it
3. New mount is loaded and contributes to future turns

No special "meta-agent" architecture needed.

#### Child Execution Frames (Subagents and Sub-calls)

Subagents and RLM-style `llm_query` sub-calls are both instances of the same abstraction: **a child execution frame**. Every child frame has:
- A source context / slice / objective
- Its own budget (steps, tokens, depth)
- Its own mount profile
- Lineage to a parent
- A return channel

The two profiles are:

| | Conversational child (subagent) | Computational child (sub-call) |
|---|---|---|
| **Scope** | Broad objective | Narrow instruction over a context slice |
| **Journal** | Own journal, may fork from parent | Ephemeral, no journal |
| **Budget** | Multiple turns, own step limit | Single LLM call, bounded output |
| **Return** | Via journal merge, message, or artifact | Returns a value/buffer to parent REPL |
| **Depth** | Recursive (child can spawn children) | Typically depth-1 (sub-call uses base LLM) |
| **Mount set** | Subset of parent's mounts | Minimal (just the LLM) |

A conversational child is a forked agent process of the same kind. A computational child is a lightweight sub-LLM call dispatched from within a REPL environment. Both are depth-controlled. The RLM paper found that depth-1 recursion (sub-calls use base LLM, not full RLM) is sufficient for most tasks — start conservative.

This gives a coherent process tree: root session → child sessions and/or sub-calls → optional fork/merge of journal.

---

## 2. Current Architecture Problems

### Problem 1: Four separate tool resolution paths
In `Session.Worker.resolve_all_tools/3`:
```elixir
config_tools = Rho.Config.resolve_tools(config.tools, context)    # path 1
memory_tools = state.memory_mod.provide_tools(state.memory_ref, context)  # path 2
hook_tools = Rho.HookRuntime.components(context).tools            # path 3
sandbox_tools = Rho.Tools.Sandbox.components(context).tools       # path 4
config_tools ++ memory_tools ++ hook_tools ++ sandbox_tools
```
Each path has different resolution mechanics, different context shapes, and different registration patterns.

### Problem 2: Three concepts that are really one
- **Extensions** (`Rho.Extension` behaviour + `HookRuntime`) — `components()` returns tools + prompt sections; `handle_event()` for lifecycle
- **Skills** (`Rho.Skill` + `Rho.Skills` extension) — discovers SKILL.md from disk, injects prompts, provides loader tool
- **Tool modules** (resolved via `Config.resolve_tools`) — each tool module has `components(context)` returning `%Components{}`

These are all "things that contribute tools and/or prompts to the turn loop." They should be one interface.

### Problem 3: Generic event dispatch is too loose
`HookRuntime.dispatch_event/1`:
- Takes arbitrary event maps
- Returns ad-hoc types: `:ok`, `:skip`, `{:override, String.t()}`, `{:inject, String.t()}`
- Mixes observation (logging) with control flow (overriding tool results, injecting messages)
- `dispatch_event/1` doesn't use scoped `plugins_for(context)` — it broadcasts to all entries
- The `{:inject, ...}` return type is not declared in the `Rho.Extension` behaviour spec

For self-evolution, generated capabilities need a **predictable contract**, not a loose event bus.

### Problem 4: Memory behaviour conflates storage and affordances
`Rho.Memory` has 12+ callbacks spanning:
- Storage: `append`, `bootstrap`, `build_context`, `history`, `reset`
- Affordances: `provide_tools` (search/recall/anchor/clear tools)
- Policies: `compact_if_needed`, `handoff`
- Infrastructure: `children`, `fork`, `merge`

The affordances (tools the LLM uses to interact with memory) should be mounts. The storage should be kernel.

### Problem 5: Config mixes tool names with extension modules
`.rho.exs` has both:
```elixir
tools: [:bash, :fs_read, :fs_write, :python],   # atoms → resolved via Config.resolve_tools
extensions: [MyExtension],                        # modules → registered via HookRuntime
```
These are the same concept expressed differently.

### Problem 6: No reasoner abstraction — reasoning strategy is hardcoded
The turn engine (`AgentLoop`) has exactly one reasoning strategy hardcoded: send tools+prompt to LLM, execute tool calls, repeat. There is no way to switch to an RLM-style recursive code-generation loop where the LLM writes code against a REPL, dispatches sub-LLM calls, and iterates to convergence. This means Rho cannot handle tasks that benefit from programmatic decomposition of large contexts — a capability the RLM paper shows yields 2× performance gains on information-dense tasks at comparable or lower cost.

### Problem 7: Mounts can only inject text — no "by reference" resources
Mounts contribute to the prompt exclusively via `prompt_sections/1` (text fragments) and `tools/1` (callable functions). There is no way for a mount to say "I have a 2.4MB corpus available as a Python variable" and have the engine render only metadata in the prompt while making the actual content accessible programmatically. Large resources are either stuffed into the context window (wasteful, lossy at scale) or invisible to the LLM.

---

## 3. Target Architecture

### Three layers, exhaustive

```
┌─────────────────────────────────────────────────────┐
│ TRANSPORTS                                          │
│   CLI · Web · (future: Telegram, Slack, API)        │
│   submit input / subscribe events / render output   │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│ KERNEL                                              │
│                                                     │
│  ┌─────────────┐  ┌───────────┐  ┌──────────────┐  │
│  │Agent Process │──│Turn Engine│──│   Journal    │  │
│  │lifecycle,    │  │project →  │  │append-only   │  │
│  │queue, subs,  │  │reason →   │  │event log,    │  │
│  │children     │  │act →      │  │projection,   │  │
│  │             │  │commit     │  │checkpointing │  │
│  └─────────────┘  └─────┬─────┘  └──────────────┘  │
│                          │                           │
│                    ┌─────▼──────┐                    │
│                    │  Reasoner  │                    │
│                    │  Strategy  │                    │
│                    │            │                    │
│                    │  Direct    │                    │
│                    │  Recursive │                    │
│                    └────────────┘                    │
│                          │                           │
└──────────────────────────┼───────────────────────────┘
                           │
     ┌─────────────────────▼───────────────────┐
     │ MOUNTS (one interface, many shapes)     │
     │                                         │
     │  Procedural:    skills                  │
     │  Runtime:       python, sandbox         │
     │  Actuators:     bash, fs, web_fetch     │
     │  Journal:       search, recall, anchor  │
     │  Policy:        step_budget             │
     │  Orchestration: subagent, sub-calls     │
     └─────────────────────────────────────────┘
```

### The Three-Tier Projection Model

Before each turn, the engine assembles context in two stages — not one:

1. **Assemble working set**: collect all available resources — journal entries, environment bindings (by reference), mount-provided tools and prompt sections.
2. **Render prompt projection**: from the working set, produce a bounded prompt that fits the context window. Large bindings appear as metadata (name, size, access path), not as inline content.

This two-stage model is what enables RLM-style processing: the LLM sees "you have a `context` variable, 2.4M chars, accessible in the Python REPL" and writes code to examine it — rather than the engine trying to stuff 2.4M chars into the prompt.

### The Mount behaviour

The `Rho.Mount` behaviour is the single packaging unit, but its callbacks operate on
two distinct **execution planes** (a lesson validated by the Pi agent framework,
where tools are LLM-visible but extensions/hooks are invisible to the model):

1. **LLM-visible affordances** — `tools`, `prompt_sections`, `bindings`.
   These shape what the model sees and can call.
2. **Invisible policy/lifecycle hooks** — `before_llm`, `before_tool`, `after_tool`, `after_step`.
   These run behind the scenes; the model never knows they exist.
   More privileged than affordances — self-evolved/generated mounts should be
   restricted to affordances only unless explicitly trusted.

```elixir
defmodule Rho.Mount do
  @moduledoc """
  Unified mount behaviour. A mount is anything attached to an agent process
  that contributes behavior or state to a turn.

  All callbacks are optional — a mount implements only what it needs.

  Callbacks are organized into two planes:

  - **Affordances** (tools, prompt_sections, bindings) — LLM-visible.
  - **Hooks** (before_llm, before_tool, after_tool, after_step) — invisible
    to the LLM, higher privilege. Used for policy, guardrails, and projection
    shaping. Must be side-effect-free on the journal (projection is ephemeral).
  """

  @type tool_def :: %{tool: ReqLLM.Tool.t(), execute: (map() -> {:ok, String.t()} | {:error, term()})}
  @type context :: map()
  @type mount_opts :: keyword()

  @type binding :: %{
    name: String.t(),          # e.g. "journal_view", "loaded_file"
    kind: :text_corpus | :structured_data | :filesystem | :session_state,
    size: non_neg_integer(),   # bytes or chars — lets engine decide metadata format
    access: :python_var | :tool | :resolver,  # how the agent accesses the content
    persistence: :turn | :session | :derived,  # lifetime
    summary: String.t()        # short human-readable description for the prompt
  }

  @type projection :: %{
    system_prompt: String.t(),
    messages: [map()],
    prompt_sections: [String.t()],
    bindings: [binding()],
    tools: [map()],
    meta: map()
  }

  # --- LLM-visible affordances ---

  @doc "Return tool definitions available in this turn."
  @callback tools(mount_opts(), context()) :: [tool_def()]

  @doc "Return prompt text fragments to append to the system prompt."
  @callback prompt_sections(mount_opts(), context()) :: [String.t()]

  @doc """
  Return bindings — large resources exposed by reference rather than inline.
  The engine renders metadata (name, size, summary, access path) in the prompt;
  the agent accesses actual content programmatically via the specified access method.
  This enables RLM-style "context as environment variable" patterns.
  """
  @callback bindings(mount_opts(), context()) :: [binding()]

  # --- Invisible policy hooks ---

  @doc """
  Called immediately before each LLM provider call with the assembled projection.
  Returns the (possibly modified) projection. Must be side-effect-free.

  Use cases: dynamic prompt shaping, message pruning/redaction, context
  injection, reasoner-specific projection adjustments.

  Inspired by Pi's `api.on("context", ...)` hook — the most important
  lifecycle point that was missing from the original design.

  This hook is also the natural home for **demand-driven context loading**
  (see "Lazy Context Loading via `before_llm`" pattern below). Instead of
  requiring the LLM to call a tool to load guidelines/skills/context, a
  mount's `before_llm` can inspect the projection and inject relevant
  context automatically — saving a round-trip and being more reliable.

  - `{:ok, projection}` — use as-is (default if not implemented)
  - `{:replace, projection}` — substitute the projection
  """
  @callback before_llm(projection(), mount_opts(), context()) ::
              {:ok, projection()} | {:replace, projection()}

  @doc """
  Called before a tool is executed. Return whether to allow the call.

  Use cases: permission gating, safety checks, budget enforcement,
  sandbox-only restrictions, arg validation at system boundaries.

  - `:ok` — allow the tool call (default if not implemented)
  - `{:deny, reason}` — block the call; reason is returned to the LLM as an error
  """
  @callback before_tool(call :: map(), mount_opts(), context()) ::
              :ok | {:deny, String.t()}

  @doc """
  Called after each tool execution. Return the effective result.
  - `{:ok, result}` — use as-is (default if not implemented)
  - `{:replace, new_result}` — substitute the tool result

  Policy-only: use for guardrails and result rewriting, NOT for driving
  reasoning loops. Reasoning control flow belongs in the Reasoner strategy.
  """
  @callback after_tool(call :: map(), result :: String.t(), mount_opts(), context()) ::
              {:ok, String.t()} | {:replace, String.t()}

  @doc """
  Called after each turn step (all tool calls in a step executed).
  - `:ok` — continue normally
  - `{:inject, message}` — inject a user-role message before the next LLM call
  - `{:inject, [messages]}` — inject multiple messages

  Policy-only: use for budget reminders and guardrails, NOT for driving
  reasoning loops. FINAL() is an engine-level halt signal, not a hook outcome.
  """
  @callback after_step(step :: integer(), max_steps :: integer(), mount_opts(), context()) ::
              :ok | {:inject, String.t() | [String.t()]}

  # --- Lifecycle ---

  @doc "Return OTP child specs for supervised resources this mount needs."
  @callback children(mount_opts(), context()) :: [Supervisor.child_spec()]

  @optional_callbacks tools: 2, prompt_sections: 2, bindings: 2,
                      before_llm: 3, before_tool: 3, after_tool: 4,
                      after_step: 4, children: 2
end
```

### Lazy Context Loading via `before_llm` — a general pattern

The `visualize_read_me` tool (Phase 9) and the `skill` tool (current Skills system) both follow the same pattern: the LLM calls a tool to load context it needs. But this has two problems:

1. **Wasted round-trip** — the LLM must spend a tool-call step just to load instructions before doing the real work.
2. **Unreliable** — the LLM might forget to call `read_me` / `skill` first, producing worse output.

The `before_llm` hook solves both. It fires before every LLM provider call, receives the full projection (system prompt, messages, tools, bindings), and can inject context based on what it observes. The mount inspects the projection to detect *intent* and loads relevant context automatically — no tool call needed, no wasted step, no chance the LLM forgets.

**The general pattern:**

```elixir
@impl Rho.Mount
def before_llm(projection, opts, context) do
  # Detect intent from projection: what tools are available, what was
  # recently discussed, what tools were just called, etc.
  signals = extract_signals(projection)

  # Load only the context sections that match the detected intent.
  # Deduplicate across sections (same as guideline module composition).
  sections = resolve_sections(signals, opts)

  case sections do
    [] ->
      {:ok, projection}

    sections ->
      {:replace, %{projection |
        prompt_sections: projection.prompt_sections ++ sections
      }}
  end
end
```

**Where this applies across Rho:**

| Mount | Signal (what `before_llm` observes) | Context injected |
|-------|-------------------------------------|-----------------|
| **Visualize** | `show_widget` is in the tool list | Design guidelines (chart, diagram, interactive — based on recent conversation) |
| **Skills** | Recent user message matches a skill's trigger pattern | Full skill body — no need for the `skill` tool call |
| **Python** | Python REPL has active session with variables | REPL usage patterns, variable summaries, "you have `df` (DataFrame, 50k rows)" |
| **Sandbox** | Sandbox is active with modified files | Sandbox state summary, commit workflow instructions |
| **Journal** | Conversation is long (many messages) | Search/recall tips: "You have 200+ messages. Use `search_history` to find specific context." |
| **Subagent** | Complex multi-part task detected | Decomposition hints: "Consider spawning subagents for independent subtasks." |

**Key design constraint:** `before_llm` must be **side-effect-free** and **cheap**. It runs on every LLM call. It should read cached/precomputed state, not do expensive discovery. The signals it inspects are already in the projection — no I/O needed.

**Relationship to the `read_me` / `skill` tools:** The tools don't disappear. They remain available as an explicit fallback — the LLM can still call them to load *additional* context modules it decides it needs mid-conversation. But the common case (first widget, obvious skill match) is handled automatically by `before_llm`, saving a step.

**Impact on Skills (Phase 2c):** The current `Rho.Skills.components/1` already does a primitive version of this — `expanded_hints/2` auto-expands skills referenced via `$skill-name` in the user message. But it runs at turn start, not before every LLM call, and only matches explicit `$` references. Moving this logic to `before_llm` enables richer signal detection: the mount can observe tool calls in the conversation history ("the agent just called `bash` with a `git` command → inject the `git-workflow` skill"), not just keyword matches in the initial message.

### Mount instances (not bare modules)

Inspired by Pi's tool factory pattern (`createBashTool("/workspace", { operations: { exec: ... } })`),
the registry stores **configured mount instances**, not bare module references.
This separates the tool schema the LLM sees from the execution backend:

```elixir
defmodule Rho.MountInstance do
  @moduledoc "A configured mount: module + instance opts + scope/priority."

  defstruct module: nil,
            opts: [],
            scope: :global,
            priority: 0

  @type t :: %__MODULE__{
    module: module(),
    opts: keyword(),       # e.g. [root: "/workspace", backend: Rho.Exec.Local]
    scope: :global | {:agent, atom()},
    priority: non_neg_integer()
  }
end
```

This enables:
- **Workspace-scoped tools**: `%MountInstance{module: Rho.Tools.Bash, opts: [root: "/sandbox/ws"]}`
- **Swappable backends**: `opts: [backend: Rho.Exec.Docker]` for sandboxed execution
- **Multiple instances of the same mount**: two FS mounts with different roots
- **Per-mount configuration**: `{:python, max_iterations: 20}` in config

### Unified resolution in the turn engine

Before a turn, the engine assembles the working set from mount instances, then projects:

```elixir
# Stage 1: Assemble working set from mount instances
instances = Rho.MountRegistry.active_mounts(context)

tools = Enum.flat_map(instances, fn %{module: mod, opts: opts} ->
  if function_exported?(mod, :tools, 2), do: mod.tools(opts, context), else: []
end)

prompt_sections = Enum.flat_map(instances, fn %{module: mod, opts: opts} ->
  if function_exported?(mod, :prompt_sections, 2), do: mod.prompt_sections(opts, context), else: []
end)

bindings = Enum.flat_map(instances, fn %{module: mod, opts: opts} ->
  if function_exported?(mod, :bindings, 2), do: mod.bindings(opts, context), else: []
end)

# Stage 2: Render bounded prompt projection
binding_sections = Enum.map(bindings, fn b ->
  "Available: `#{b.name}` (#{b.kind}, #{b.size} chars) — #{b.summary}. Access via #{b.access}."
end)

projection = %{
  system_prompt: base_system_prompt,
  messages: journal_messages,
  prompt_sections: prompt_sections ++ binding_sections,
  bindings: bindings,
  tools: tools,
  meta: %{step: step, max_steps: max_steps}
}

# Stage 3: Run before_llm hooks (projection shaping, invisible to LLM)
projection = Rho.MountRegistry.dispatch_before_llm(projection, context)

# Stage 4: Before each tool call, run before_tool hooks (deny/allow gating)
# Stage 5: After each tool call, run after_tool hooks (result rewriting)
# Stage 6: After each step, run after_step hooks (inject messages)
```

No more `config_tools ++ memory_tools ++ hook_tools ++ sandbox_tools`.

### The Reasoner behaviour

```elixir
defmodule Rho.Reasoner do
  @moduledoc """
  A reasoner strategy defines how the turn engine executes the reason+act
  phase. The turn engine delegates to the active reasoner after projection.
  """

  @type turn_result ::
    {:continue, [journal_entry]}    # more steps needed
    | {:done, [journal_entry]}      # turn complete, commit these entries
    | {:final, term(), [journal_entry]}  # explicit convergence (RLM FINAL())

  @doc """
  Execute one reason+act cycle given the current projection and available tools.
  """
  @callback run(projection :: map(), tools :: [map()], bindings :: [map()], context :: map()) ::
              turn_result()
end
```

- **`Rho.Reasoner.Direct`** — today's loop. Sends tools+prompt to LLM, executes tool calls, returns `{:continue, entries}` or `{:done, entries}`.
- **`Rho.Reasoner.Recursive`** — RLM-style. Loads bindings into REPL as variables, sends metadata-only prompt, LLM writes code, executes in REPL, dispatches `llm_query` sub-calls, loops internally until `FINAL()` or budget exhaustion. Has its own internal iteration/sub-query budget separate from the outer turn step budget.

---

## 4. Module Mapping: Current → Target

### Kernel (stays, may rename)

| Current module | Target role | Changes |
|----------------|-------------|---------|
| `Rho.Session.Worker` | Agent Process | Remove `resolve_all_tools/3` multi-path resolution; delegate to `MountRegistry` |
| `Rho.AgentLoop` | Turn Engine | Use single mount-provided tools/prompts/bindings; delegate reason+act to active Reasoner; replace `dispatch_event` with typed hook calls |
| (new) `Rho.Reasoner` | Reasoner behaviour | New behaviour defining `run/4` |
| (new) `Rho.Reasoner.Direct` | Default reasoner | Extract current AgentLoop reason+act logic into a Reasoner implementation |
| (new) `Rho.Reasoner.Recursive` | RLM reasoner | New: iterative code-gen loop over REPL with sub-LLM calls and FINAL() convergence |
| `Rho.Tape.Store` | Journal Store | No change — this is core |
| `Rho.Tape.Entry` | Journal Entry | No change |
| `Rho.Tape.View` | Journal Projection | Evolve: two-stage projection (working set → bounded prompt view) |
| `Rho.Tape.Service` | Journal Service | No change |
| `Rho.Session.Supervisor` | Process Supervisor | No change |

### Mounts (unified under `Rho.Mount`)

| Current module | Mount type | What it contributes |
|----------------|-----------|---------------------|
| `Rho.Tools.Bash` | Actuator | `tools/1` only |
| `Rho.Tools.FsRead` | Actuator | `tools/1` only |
| `Rho.Tools.FsWrite` | Actuator | `tools/1` only |
| `Rho.Tools.FsEdit` | Actuator | `tools/1` only |
| `Rho.Tools.WebFetch` | Actuator | `tools/1` only |
| `Rho.Tools.Python` | Runtime | `tools/1` only (backed by `Python.Interpreter` GenServer) |
| `Rho.Tools.Sandbox` | Runtime | `tools/1` only, context-dependent (only when sandbox active) |
| `Rho.Skills` | Procedural memory | `tools/1` + `prompt_sections/1` |
| `Rho.Plugins.Subagent` | Orchestration | `tools/1` + `after_tool/3` (completion checking) |
| `Rho.Plugins.StepBudget` | Policy | `tools/1` (final_response) + `after_step/3` (budget reminder) |
| `Rho.Builtin` | Policy | Error logging (observation-only, not a hook return) |
| `Rho.Tools.Anchor` | Journal capability | `tools/1` only (tool wrapping `Service.handoff`) |
| `Rho.Tools.SearchHistory` | Journal capability | `tools/1` only |
| `Rho.Tools.RecallContext` | Journal capability | `tools/1` only |
| `Rho.Tools.ClearMemory` | Journal capability | `tools/1` only |
| `Rho.Tools.Finish` | Policy | `tools/1` only (subagent-only) |
| `Rho.Tools.FinalResponse` | Policy | `tools/1` only (top-level-only) |

### To be replaced / removed

| Current module | Disposition |
|----------------|-------------|
| `Rho.Extension` | Replaced by `Rho.Mount` |
| `Rho.Extension.Components` | Replaced by direct `tools/1` + `prompt_sections/1` returns |
| `Rho.HookRuntime` | Replaced by `Rho.MountRegistry` (simpler: no generic event dispatch) |
| `Rho.Memory` behaviour | Split: storage stays in kernel; tool provision moves to journal capability mounts |
| `Rho.Memory.Tape.provide_tools/2` | Moves to individual journal capability mounts |
| `Config.resolve_tools/2` + `@tool_extensions` map | Replaced by mount resolution from config `mounts:` list |

### Transports (extended in Phase 9)

| Current module | Role | Phase 9 changes |
|----------------|------|-----------------|
| `Rho.CLI` | CLI transport | Add widget rendering via native window Port |
| `Rho.Web.Socket` | Web transport | Add widget/widget_delta frame types, sendPrompt |
| `Rho.Channel.Message` | Transport envelope | No change |
| `Rho.Debounce` | Transport buffering | No change |

---

## Phase 1: Mount Behaviour & Registry

**Goal**: Define the new `Rho.Mount` behaviour, `Rho.MountInstance` struct, and `Rho.MountRegistry` without breaking anything. Run both old and new systems in parallel.

- [x] Create `lib/rho/mount.ex` — the `Rho.Mount` behaviour with optional callbacks organized into two planes:
  - **Affordances** (LLM-visible): `tools/2`, `prompt_sections/2`, `bindings/2`
  - **Hooks** (invisible, higher privilege): `before_llm/3`, `before_tool/3`, `after_tool/4`, `after_step/4`
  - **Lifecycle**: `children/2`
  - All callbacks receive `mount_opts` as first arg (from the `MountInstance`)
- [x] Create `lib/rho/mount_instance.ex` — struct holding `module`, `opts`, `scope`, `priority`
- [x] Create `lib/rho/mount_registry.ex` — GenServer + ETS, analogous to current `HookRuntime` but storing `MountInstance` structs:
  - `register(mount_module, opts)` — register a mount instance with optional scope and config
  - `active_mounts(context)` — return ordered list of `MountInstance` structs matching context
  - `collect_tools(context)` — flat_map `tools/2` across active mounts (passing each instance's opts)
  - `collect_prompt_sections(context)` — flat_map `prompt_sections/2` across active mounts
  - `collect_bindings(context)` — flat_map `bindings/2` across active mounts (returns structured metadata, not content)
  - `dispatch_before_llm(projection, context)` — call `before_llm/3` in priority order, thread projection through
  - `dispatch_before_tool(call, context)` — call `before_tool/3` in priority order, short-circuit on `{:deny, ...}`
  - `dispatch_after_tool(call, result, context)` — call `after_tool/4` in priority order, short-circuit on `{:replace, ...}`
  - `dispatch_after_step(step, max_steps, context)` — call `after_step/4`, collect injections
  - `render_binding_metadata(bindings)` — render binding list as prompt-ready strings
- [x] Add `Rho.MountRegistry` to the supervision tree in `application.ex` (alongside existing `HookRuntime`)
- [x] Write tests for `MountRegistry`: registration, scoping, collection (including bindings), all dispatch hooks, mount instance opts passthrough, crash resilience (31 tests)

**Verification**: ✅ `MountRegistry` starts and passes unit tests. Full suite: 185 tests, 0 failures. Existing system unchanged.

---

## Phase 2: Migrate Existing Modules to Mounts

**Goal**: Make every existing tool/extension/skill module also implement `Rho.Mount`, without removing `Rho.Extension` yet. Dual-interface period.

### 2a: Actuator mounts (tools-only, simplest)
- [x] `Rho.Tools.Bash` — add `@behaviour Rho.Mount`, implement `tools/2` (delegates to existing `components/1`)
- [x] `Rho.Tools.FsRead` — same
- [x] `Rho.Tools.FsWrite` — same
- [x] `Rho.Tools.FsEdit` — same
- [x] `Rho.Tools.WebFetch` — same
- [x] `Rho.Tools.Python` — add `@behaviour Rho.Mount`, implement `tools/2` + `bindings/2` (expose REPL session state as a binding when active: name, variable count, access via `:python_var`). Added `Interpreter.session_info/1`. Keep `Python.Interpreter` GenServer as-is.
- [x] `Rho.Tools.Sandbox` — add `@behaviour Rho.Mount`, implement `tools/2` + `bindings/2` (expose sandbox workspace as a binding: path, file count, size). Context-dependent: return `[]` when no sandbox in context.

### 2b: Journal capability mounts
- [x] Create `Rho.Mounts.JournalTools` (`lib/rho/mounts/journal_tools.ex`) — a single mount that implements `tools/2` + `bindings/2`. Tools: anchor, search, recall, clear. Binding: expose the journal as a by-reference resource (entry count). Takes `tape_name` from context. This wraps `Memory.Tape.provide_tools/2`.

### 2c: Procedural memory mount
- [x] `Rho.Skills` — add `@behaviour Rho.Mount`, implement `tools/2` + `prompt_sections/2` (delegates to existing `components/1`)

### 2d: Policy mounts
- [x] `Rho.Plugins.StepBudget` — add `@behaviour Rho.Mount`, implement `tools/2` + `after_step/4` (mirrors `handle_event` matching on `:step_continue`)
- [x] `Rho.Builtin` — add `@behaviour Rho.Mount` (observation-only mount, no mount callbacks implemented)

### 2e: Orchestration mount
- [x] `Rho.Plugins.Subagent` — add `@behaviour Rho.Mount`, implement `tools/2` + `after_tool/4` (mirrors `handle_event` matching on `:tool_result` for completion checking)

### 2f: Registration
- [x] In `application.ex`, register all built-in mounts with `MountRegistry` after startup (mirroring current `HookRuntime.register` calls)
- [x] Write integration test (`test/rho/mount_integration_test.exs`): `MountRegistry.collect_tools(context)` returns the same tools as current `resolve_all_tools`

**Verification**: ✅ All existing tests still pass (192 tests, 0 failures). Both `HookRuntime` and `MountRegistry` coexist. Integration test confirms mount resolution produces the same tool set as old resolution.

---

## Phase 3: Unify Tool Resolution in Turn Engine

**Goal**: Replace the 4 tool resolution paths in `Session.Worker` with a single `MountRegistry` call. Implement two-stage projection. This is the real switchover.

- [x] In `Session.Worker.resolve_all_tools/3`, replace:
  ```elixir
  # OLD: 4 separate paths
  config_tools ++ memory_tools ++ hook_tools ++ sandbox_tools
  ```
  with:
  ```elixir
  # NEW: 1 path
  Rho.MountRegistry.collect_tools(context)
  ```
- [x] In `AgentLoop.run/3`, implement two-stage projection:
  ```elixir
  # OLD
  comps = Rho.HookRuntime.components(hook_context)
  prompt = comps.system_prompt || base_system_prompt
  sections = comps.prompt_sections
  ```
  ```elixir
  # NEW — Stage 1: assemble working set
  sections = Rho.MountRegistry.collect_prompt_sections(context)
  bindings = Rho.MountRegistry.collect_bindings(context)

  # NEW — Stage 2: render bounded projection
  # Bindings are rendered as metadata lines in the prompt, not as inline content
  binding_sections = Rho.MountRegistry.render_binding_metadata(bindings)
  all_sections = sections ++ binding_sections
  ```
- [x] Wire `dispatch_before_llm(projection, context)` into `AgentLoop` immediately before each LLM provider call
- [x] Wire `dispatch_before_tool(call, context)` into `AgentLoop` before each tool execution; on `{:deny, reason}`, return reason as error to the LLM without executing
- [x] Update `AgentLoop` tool result handling: replace `Rho.HookRuntime.dispatch_event(%{type: :tool_result, ...})` with `Rho.MountRegistry.dispatch_after_tool(call, result, context)`
- [x] Update `AgentLoop` step continue handling: replace `Rho.HookRuntime.dispatch_event(%{type: :step_continue, ...})` with `Rho.MountRegistry.dispatch_after_step(step, max_steps, context)`
- [x] Remove `Config.resolve_tools/2` and `@tool_extensions` map
- [x] Run full test suite

**Verification**: `mix rho.chat` works. All tools appear. Skills inject prompts. StepBudget injects reminders. Subagent completion notices work. Sandbox tools appear only when sandbox is active. Bindings from Python/Sandbox/Journal mounts appear as metadata in the prompt. `before_llm` hooks can reshape the projection. `before_tool` hooks can deny tool calls.

---

## Phase 4: Split Journal Store from Journal Capabilities

**Goal**: Clean separation between the journal (core storage) and the tools/policies that operate on it.

- [x] Simplify `Rho.Memory` behaviour to only storage concerns:
  ```
  memory_ref/2, bootstrap/1, append/4, append_from_event/2,
  build_context/1, info/1, history/1, reset/2
  ```
  Plus optional: `compact_if_needed/2`, `fork/2`, `merge/2`, `children/1`
- [x] Remove `provide_tools/2` from `Rho.Memory` behaviour
- [x] Remove `search/3` and `handoff/4` from `Rho.Memory` behaviour (these are mount-provided affordances, not storage contract)
- [x] Update `Rho.Memory.Tape` to drop removed callbacks
- [x] Ensure `Rho.Mounts.JournalTools` (from Phase 2b) calls `Rho.Tape.Service` directly instead of going through the memory behaviour for search/handoff
- [x] Update `Session.Worker` to no longer call `memory_mod.provide_tools`
- [x] Run tests

**Verification**: Memory backend is simpler. Journal tools still work via their mount. Tape search, anchor creation, recall all function correctly.

---

## Phase 5: Typed Hook Points (Replace Generic Event Dispatch)

**Goal**: Remove the loose `handle_event/1` and `dispatch_event/1` in favor of typed callbacks.

- [x] Audit all `dispatch_event` call sites in `AgentLoop`:
  - `:tool_result` → already replaced by `after_tool/3` in Phase 3
  - `:step_continue` → already replaced by `after_step/3` in Phase 3
  - `:error` → convert to Logger / observational emit only
- [x] Remove `dispatch_event/1` from `MountRegistry` (or never add it)
- [x] Remove `handle_event/1` from `Rho.Mount` (it was never added — `after_tool` and `after_step` replace it)
- [x] Keep the `emit` callback in `AgentLoop` for **observation-only** event streaming (to subscribers/transports). This is NOT a hook — it never returns control-flow instructions.
- [x] Remove `Rho.Extension` behaviour
- [x] Remove `Rho.Extension.Components` struct
- [x] Remove `Rho.HookRuntime` GenServer + ETS table
- [x] Remove registration of old-style extensions in `application.ex`
- [x] Run full test suite

**Verification**: No code references `Rho.Extension`, `Rho.HookRuntime`, or `dispatch_event`. All behavior now flows through `Rho.Mount` + `Rho.MountRegistry`.

---

## Phase 6: Reasoner Strategies

**Goal**: Introduce the `Rho.Reasoner` behaviour as a kernel concept. Extract current AgentLoop reason+act logic into `Rho.Reasoner.Direct`. Implement `Rho.Reasoner.Recursive` for RLM-style iterative code-generation. The turn engine delegates to the active reasoner rather than hardcoding the reasoning algorithm.

### 6a: Reasoner behaviour and Direct strategy
- [x] Create `lib/rho/reasoner.ex` — the `Rho.Reasoner` behaviour with `run/4` callback
- [x] Create `lib/rho/reasoner/direct.ex` — `Rho.Reasoner.Direct`, extracting the current reason+act loop from `AgentLoop` into a standalone module implementing `Rho.Reasoner`. This is a pure refactor — behavior is identical.
- [x] Update `AgentLoop` to delegate reason+act to `context.reasoner.run(projection, tools, bindings, context)` instead of inline logic
- [x] Default reasoner is `Rho.Reasoner.Direct` when not specified in config
- [x] Run full test suite — everything should pass unchanged

### 6b: Recursive (RLM) reasoner
- [ ] Create `lib/rho/reasoner/recursive.ex` — `Rho.Reasoner.Recursive`, implementing the RLM algorithm:
  1. Load bindings into the Python REPL as variables (requires Python mount to be active)
  2. Build metadata-only prompt: binding summaries + query + RLM system prompt (code-only output, `FINAL()`/`FINAL_VAR()` conventions)
  3. Send to LLM, extract Python code block from response
  4. Execute code in REPL, capture stdout/stderr
  5. If `FINAL()` was called, return `{:final, value, entries}`
  6. Otherwise, append execution output to conversation history, loop
  7. Enforce internal budget: `max_iterations` (default 20), `max_sub_queries` (default 50)
- [ ] Implement `llm_query(sub_context, instruction)` as a Python-callable function in the REPL runtime:
  - Dispatches a computational child frame (depth-1): sends `sub_context + instruction` to a sub-LLM call
  - Uses the config's sub-model (e.g., a cheaper/faster model for sub-calls)
  - Returns the text result to the REPL
- [ ] Implement `async_llm_query()` for parallel sub-calls via `asyncio.gather()`
- [ ] `FINAL()` is an engine-level halt signal: the Recursive reasoner converts it to `{:final, value, entries}` and the turn engine commits the entries and stops. It is NOT a hook outcome.
- [ ] Add `reasoner:` config key (`:direct` or `:recursive` or a module) — see Phase 7
- [ ] Write tests: basic iteration, FINAL convergence, sub-query dispatch, budget exhaustion, REPL error recovery

### 6c: Child execution frame abstraction
- [ ] Create `lib/rho/child_frame.ex` — shared abstraction for both subagent and sub-call dispatch:
  ```elixir
  defmodule Rho.ChildFrame do
    @type t :: %__MODULE__{
      objective: String.t(),
      context_slice: String.t(),
      budget: %{max_steps: integer(), max_tokens: integer(), max_depth: integer()},
      mount_profile: :minimal | :parent_subset | [module()],
      return_channel: :value | :journal_merge | :message
    }
  end
  ```
- [ ] Update `Rho.Plugins.Subagent` to create conversational child frames
- [ ] `Rho.Reasoner.Recursive` creates computational child frames for `llm_query` dispatch
- [ ] Both use depth tracking to prevent recursive explosion (start with max depth 1, as the RLM paper found sufficient)

**Verification**: `mix rho.chat` works with both `reasoner: :direct` (default, identical to current behavior) and `reasoner: :recursive` (new RLM mode). Recursive reasoner can load bindings, iterate, dispatch sub-queries, and converge via FINAL(). Child frames are depth-limited.

---

## Phase 7: Config Unification

**Goal**: Replace separate `tools:` + `extensions:` in `.rho.exs` with a single `mounts:` list.

- [x] Update `Rho.Config` to read `mounts:` key from agent config
- [x] Support both atoms (`:bash`, `:python`, `:skills`) and modules (`MyProject.ReviewPolicy`) in the `mounts:` list
- [x] Maintain `@mount_modules` map in Config (replacing `@tool_extensions`):
  ```elixir
  @mount_modules %{
    bash: Rho.Tools.Bash,
    fs_read: Rho.Tools.FsRead,
    fs_write: Rho.Tools.FsWrite,
    fs_edit: Rho.Tools.FsEdit,
    web_fetch: Rho.Tools.WebFetch,
    python: Rho.Tools.Python,
    skills: Rho.Skills,
    subagent: Rho.Plugins.Subagent,
    sandbox: Rho.Tools.Sandbox,
    journal: Rho.Mounts.JournalTools,
    step_budget: Rho.Plugins.StepBudget,
  }
  ```
- [x] Add backwards compatibility: if `.rho.exs` has `tools:` but no `mounts:`, auto-convert *(compat shim was added here, then removed in Phase 8a — `.rho.exs` must now use `mounts:` directly)*
- [x] Support per-mount keyword options in the `mounts:` list: `{:python, max_iterations: 20}` alongside bare atoms `:python`
- [x] Add `reasoner:` config key: `:direct` (default), `:recursive`, or a module implementing `Rho.Reasoner`
- [x] Add recursive reasoner config options: `max_iterations`, `max_sub_queries`, `max_depth`, `sub_model`
- [x] Update `.rho.exs` format:
  ```elixir
  %{
    default: [
      model: "openrouter:openai/gpt-oss-120b",
      system_prompt: "You are a helpful agent called Guagua.",
      reasoner: :direct,  # or :recursive for RLM mode
      mounts: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch,
               :python, :skills, :subagent, :journal, :step_budget],
      python_deps: ["matplotlib"],
      max_steps: 50
    ],
    research: [
      # Profile optimized for large-context tasks using RLM
      model: "openrouter:anthropic/claude-sonnet",
      reasoner: :recursive,
      reasoner_opts: [max_iterations: 20, max_sub_queries: 50, sub_model: "openrouter:openai/gpt-4o-mini"],
      mounts: [:bash, :fs_read, :python, :journal, :step_budget],
      max_steps: 10
    ]
  }
  ```
- [x] Remove `extensions:` config key (old extension system is gone); `tools:` compat fully removed in Phase 8a
- [x] Auto-register mounts from config in `application.ex` (replacing hardcoded `register_builtin_mounts`)
- [x] Run tests

**Verification**: `.rho.exs` uses `mounts:` and `reasoner:`. The `tools:` key is no longer supported (removed in Phase 8a). All mounts resolve correctly. Per-mount options are passed through. Reasoner selection works.

---

## Phase 8: Cleanup & Rename

**Goal**: Remove dead code, rename modules to match conceptual model (optional but recommended for clarity).

### 8a: Dead code removal
- [x] Delete `lib/rho/extension.ex` (already removed in Phase 5)
- [x] Delete `lib/rho/extension/components.ex` (already removed in Phase 5)
- [x] Delete `lib/rho/hook_runtime.ex` (already removed in Phase 5)
- [x] Remove `Config.resolve_tools/2` (already removed in Phase 3)
- [x] Remove `Memory.provide_tools` and `Memory.search` and `Memory.handoff` from behaviour (already removed — journal capabilities provided by `Rho.Mounts.JournalTools`)
- [x] Clean up remaining references in `CLAUDE.md`, `AGENTS.md`, `README.md`
- [x] Remove `erl_crash.dump` artifact

### 8b: Optional renames (can be deferred)
These renames align code with the conceptual model. Do them only if you want the vocabulary to match:

| Current | Proposed | Rationale |
|---------|----------|-----------|
| `Rho.Extension` | (deleted) | Replaced by `Rho.Mount` |
| `Rho.HookRuntime` | (deleted) | Replaced by `Rho.MountRegistry` |
| `Rho.Memory` | `Rho.JournalStore` | Clarifies it's the storage layer, not the full "memory" concept |
| `Rho.Memory.Tape` | `Rho.JournalStore.Tape` | Follows parent rename |
| `Rho.Tape.View.build_context` | `project_context` | Projection metaphor |

### 8c: Documentation
- [x] Update `README.md` architecture section *(completed during Phase 8a)*
- [x] Update `AGENTS.md` with new extension model *(completed during Phase 8a)*
- [x] Write `docs/mounts.md` — guide for writing custom mounts
- [ ] Write `docs/reasoners.md` — guide for the reasoner strategy system (Direct vs Recursive, writing custom reasoners) *(deferred — Phase 6 not yet implemented)*
- [ ] Update `build-plan.md` to reflect new structure *(low priority, deferred)*

**Verification**: No dead code. `mix compile --warnings-as-errors` clean. All tests pass. Docs reflect reality.

---

## Phase 9: Generative UI — Visual Output as a Mount + Transport

**Goal**: Give the agent the ability to produce interactive visual output (charts, diagrams, forms, data tables) that renders in a native window (CLI) or inline (Web), inspired by Claude's `show_widget` / Pi's Glimpse architecture. This is the natural extension of the mount model to UI-as-affordance.

### Why this belongs in the mount architecture

The refactor plan says *"all optional behavior arrives through mounts; all external interaction happens through transports."* Generative UI straddles both:

- The **tool the LLM calls** (`show_widget`) is a mount affordance — it contributes tools and prompt sections.
- The **rendering surface** (native window, WebSocket-pushed DOM) is a transport concern.
- The **design guidelines** loaded on demand (`read_me` modules) are the exact same pattern as Skills — procedural memory loaded lazily into context.

This means generative UI decomposes cleanly into existing primitives rather than requiring a new concept.

### Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│ Rho.Mounts.Visualize (mount)                                    │
│                                                                  │
│  tools/2:                                                        │
│    • visualize_read_me — lazy-load design guidelines by module   │
│    • show_widget — accept HTML/SVG, dispatch to transport        │
│                                                                  │
│  prompt_sections/2:                                              │
│    • Base rules: "Call visualize_read_me before first widget.    │
│      Structure code: style → HTML → script last."                │
│                                                                  │
│  bindings/2: (none — widgets are output, not input)              │
│                                                                  │
│  children/2:                                                     │
│    • Widget registry (tracks open windows / active widget slots) │
│                                                                  │
└────────────────────────┬─────────────────────────────────────────┘
                         │ show_widget dispatches to transport
                         ▼
┌────────────────────────────────────────────────────────┐
│ Transport layer — two rendering backends               │
│                                                        │
│  CLI: Glimpse / WKWebView native window                │
│    • Sub-50ms startup, bidirectional JSON               │
│    • Streaming: morphdom DOM diffing on deltas          │
│    • User interaction → tool result → journal           │
│                                                        │
│  Web: WebSocket push to client                         │
│    • New frame type: {"type": "widget", ...}            │
│    • Client renders via DOM injection (same as Claude)  │
│    • sendPrompt() → WebSocket message → session submit  │
│    • Streaming: toolcall_delta events with partial HTML  │
│                                                        │
└────────────────────────────────────────────────────────┘
```

### Demand-driven guidelines via `before_llm`

Claude's architecture requires the LLM to call `read_me` before `show_widget` — a wasted round-trip. Rho does better by using the `before_llm` hook (see "Lazy Context Loading via `before_llm`" pattern in §3).

The Visualize mount implements `before_llm/3` to detect when the agent is likely to produce visual output and automatically injects the relevant guideline modules:

```elixir
@impl Rho.Mount
def before_llm(projection, opts, _context) do
  # Only inject if show_widget is available and guidelines not already loaded
  has_widget_tool? = Enum.any?(projection.tools, &(&1.tool.name == "show_widget"))
  already_loaded? = Enum.any?(projection.prompt_sections, &String.contains?(&1, "Visual Creation"))

  if has_widget_tool? and not already_loaded? do
    # Detect which guideline modules to load from recent conversation
    modules = detect_visual_intent(projection.messages)
    # Default to [:interactive] if intent unclear but widget tool is available
    modules = if modules == [], do: [:interactive], else: modules

    sections = Rho.Visualize.Guidelines.get(modules)
    {:replace, %{projection |
      prompt_sections: projection.prompt_sections ++ [sections]
    }}
  else
    {:ok, projection}
  end
end

# Scan recent messages for visual intent signals
defp detect_visual_intent(messages) do
  recent_text = messages
    |> Enum.take(-5)
    |> Enum.map_join(" ", &to_string(&1[:content] || ""))
    |> String.downcase()

  []
  |> then(fn m -> if String.contains?(recent_text, ["chart", "graph", "plot", "data"]), do: [:chart | m], else: m end)
  |> then(fn m -> if String.contains?(recent_text, ["diagram", "flow", "architecture"]), do: [:diagram | m], else: m end)
  |> then(fn m -> if String.contains?(recent_text, ["interactive", "slider", "form", "widget"]), do: [:interactive | m], else: m end)
  |> then(fn m -> if String.contains?(recent_text, ["art", "illustration", "draw"]), do: [:art | m], else: m end)
  |> then(fn m -> if String.contains?(recent_text, ["mockup", "ui", "wireframe"]), do: [:mockup | m], else: m end)
end
```

The guideline system itself uses modular sections with deduplication:

```elixir
# Available modules: :interactive, :chart, :diagram, :art, :mockup
# Each module maps to sections of guidelines:
#   :chart  → core + ui_components + color_palette + charts (Chart.js patterns)
#   :diagram → core + color_palette + svg_setup + diagram_types
#   :art     → core + svg_setup + art_and_illustration
# Shared sections are deduplicated across modules.
```

The `visualize_read_me` tool still exists as a fallback — the LLM can explicitly request additional guideline modules mid-conversation if `before_llm`'s heuristic missed one. But the common path is zero-tool-call: guidelines appear automatically.

The guidelines cover:

- **Streaming-first structure**: style → HTML → script last (scripts don't execute via innerHTML until explicitly activated)
- **Color system**: named ramps with 7 stops, dark-mode-mandatory CSS variables
- **Typography**: two weights only (400, 500), sentence case, no gradients/shadows/blur (they flash during DOM diffs)
- **CDN allowlist**: cdnjs.cloudflare.com, cdn.jsdelivr.net, unpkg.com, esm.sh
- **Chart.js patterns**: canvas sizing, custom legends, number formatting
- **SVG patterns**: viewBox safety, font-width calibration, pre-built CSS classes

### The `show_widget` tool — transport-dispatched rendering

The tool accepts HTML/SVG and dispatches to the active transport for rendering. The mount doesn't know or care whether the transport is CLI (native window) or Web (inline DOM):

```elixir
def execute_show_widget(args, opts, context) do
  widget = %{
    title: args["title"],
    code: args["widget_code"],
    width: args["width"] || 800,
    height: args["height"] || 600,
    floating: args["floating"] || false
  }

  # Dispatch to transport via session event stream.
  # The transport decides how to render.
  emit = context.emit
  emit.(%{type: :widget_show, widget: widget})

  # Block until transport signals completion (user interaction or close).
  # Returns interaction data as tool result → committed to journal.
  receive do
    {:widget_result, data} -> {:ok, Jason.encode!(data)}
    {:widget_closed} -> {:ok, "Widget closed by user."}
  after
    120_000 -> {:ok, "Widget timed out."}
  end
end
```

### CLI transport: native window via Port / NIF

For the terminal, Rho spawns a native WKWebView window (macOS) or a lightweight browser window (Linux: WebKitGTK, Windows: WebView2) via an Erlang Port:

- **Startup**: `Port.open({:spawn_executable, visualize_bin}, [:binary, ...])` — sub-50ms on macOS
- **Streaming**: as `text_delta` events arrive during tool-call streaming, the CLI transport feeds partial HTML to the window via `port_command`, which uses morphdom to diff the DOM
- **Bidirectional**: window sends JSON messages back through the port; user interactions (slider values, form submissions, button clicks) become the tool result
- **Lifecycle**: window is tied to the tool call lifetime; closes on tool completion or user dismissal

```elixir
# In Rho.CLI, handle the new event type:
defp render(%{type: :widget_show, widget: widget}) do
  # Open native window, return port ref
  port = Rho.Visualize.Window.open(widget)
  IO.puts(IO.ANSI.cyan() <> "  [widget] #{widget.title} #{widget.width}×#{widget.height}" <> IO.ANSI.reset())
  # Store port for streaming updates and result collection
  Process.put(:active_widget_port, port)
end
```

### Web transport: inline rendering via WebSocket

For the web UI, the socket pushes a new frame type and the client renders inline (same architecture as Claude's generative UI):

```elixir
# In Rho.Web.Socket, new event → frame mapping:
defp event_to_frame(%{type: :widget_show, widget: widget}) do
  %{
    type: "widget",
    title: widget.title,
    widget_code: widget.code,
    width: widget.width,
    height: widget.height
  }
end

# Streaming partial HTML during tool call:
defp event_to_frame(%{type: :widget_delta, html: html}) do
  %{type: "widget_delta", html: html}
end
```

Client-side (the web frontend):
- On `widget`: create a container div, inject CSS variables, start incremental DOM parsing
- On `widget_delta`: call morphdom to diff partial HTML into the container (new nodes get a fade-in animation, unchanged nodes untouched)
- On `widget_complete`: activate script tags (clone into fresh elements for browser execution), load CDN libraries
- `sendPrompt(text)`: call WebSocket send with `{"type": "message", "content": text}` — lets widgets send follow-up messages to the agent

### Streaming architecture (both transports)

The streaming challenge is the same one Pi solved with Glimpse: the LLM generates `widget_code` token by token, and we want the visual to build up live rather than appearing all at once.

```
LLM generates show_widget tool call
  │
  ├─ tool_start event: transport opens rendering surface
  │
  ▼
text_delta events (repeated, every ~token)
  │
  ├─ AgentLoop accumulates partial widget_code from streaming JSON
  ├─ Debounce (150ms)
  ├─ Emit widget_delta with accumulated HTML so far
  │   └─ Transport feeds to morphdom → DOM diffing
  │   └─ New nodes get fade-in animation
  │   └─ Unchanged nodes stay untouched
  │
  ▼
tool call complete
  │
  ├─ Final widget_delta with complete HTML
  ├─ Emit widget_complete → transport activates script tags
  │   └─ Chart.js / D3 / etc. load from CDN
  │   └─ Charts render, event listeners attach
  │
  ▼
User interacts or closes
  │
  ├─ Transport sends {:widget_result, data} back to mount
  ├─ Tool result committed to journal
  └─ Journal has durable record: "user selected option B via widget"
```

Key implementation detail: `innerHTML` doesn't execute `<script>` tags. When the complete HTML arrives, scripts must be activated by cloning each `<script>` into a fresh element (which the browser will execute) and replacing the inert original.

### `sendPrompt()` — widgets that talk back

Claude's widgets have a `sendPrompt(text)` function that lets interactive elements send messages to the chat. In Rho, this maps to the transport's existing submit path:

- **Web**: `sendPrompt()` calls `window.glimpse?.send({type: 'prompt', text})` or the WebSocket directly, which routes to `Rho.Agent.Worker.submit/3`
- **CLI**: the native window sends a JSON message through the port, which the CLI GenServer routes to `Rho.Agent.Worker.submit/3`

This enables compound interactions: a widget showing analysis results with a "Dig deeper into section 3" button that automatically submits a follow-up prompt.

### Mount configuration in `.rho.exs`

```elixir
mounts: [
  :bash, :fs_read, :fs_write, :python, :skills,
  {:visualize, guidelines: [:chart, :interactive]}  # preload specific guideline modules
]
```

Or with all defaults:
```elixir
mounts: [:bash, :fs_read, :fs_write, :python, :skills, :visualize]
```

### Tasks

- [ ] Create `lib/rho/visualize/guidelines.ex` — modular guideline sections with lazy composition and deduplication (10 sections, 5 module profiles)
- [ ] Create `lib/rho/mounts/visualize.ex` — `@behaviour Rho.Mount` implementing `tools/2` (`visualize_read_me`, `show_widget`) + `prompt_sections/2` (base streaming/structure rules)
- [ ] Create `priv/visualize/` — the native window binary (Swift/WKWebView for macOS, or a cross-platform alternative)
- [ ] Create `lib/rho/visualize/window.ex` — Erlang Port wrapper for the native window binary (open, send HTML, receive messages, close)
- [ ] Create `lib/rho/visualize/shell.ex` — the shell HTML document: morphdom from CDN, `_setContent()` for DOM diffing, `_runScripts()` for script activation, fade-in animations, CDN CSP allowlist
- [ ] Update `Rho.AgentLoop` — accumulate partial `widget_code` from streaming tool call JSON; emit `widget_delta` events with debouncing
- [ ] Update `Rho.CLI` — handle `:widget_show`, `:widget_delta`, `:widget_complete` events; manage native window port lifecycle
- [ ] Update `Rho.Web.Socket` — add `event_to_frame` clauses for widget events; add client→server `sendPrompt` message type
- [ ] Add `:visualize` to `@mount_modules` in `Rho.Config`
- [ ] Write tests: guideline composition/deduplication, tool execution, widget event flow

**Verification**: `mix rho.chat` with `:visualize` mount — agent calls `visualize_read_me` before first widget, then `show_widget` renders a Chart.js chart in a native window (CLI) or inline (Web). User interaction data flows back as the tool result and is committed to the journal. Guidelines load lazily and deduplicate shared sections.

---

## Appendix A: Conceptual Glossary

| Term | Definition |
|------|-----------|
| **Agent Process** | A long-lived OTP process (GenServer) per session. Owns identity, lifecycle, turn queue, subscribers, child processes. Currently `Session.Worker`. |
| **Turn Engine** | The outer execution loop: project → reason → act → commit. Delegates reason+act to the active Reasoner strategy. Currently `AgentLoop`. |
| **Reasoner Strategy** | The algorithm that drives the reason+act phase within a turn. `Direct` = standard tool-use loop. `Recursive` = RLM-style iterative code-generation with sub-LLM calls. A kernel concept, not a mount. |
| **Journal** | The append-only event log that IS the agent's durable memory. Stores immutable entries (messages, tool calls, tool results, anchors). Currently the Tape system. Tier 1 of the three-tier memory model. |
| **Mounted Environment State** | Persistent, addressable, non-authoritative working state in runtime environments (Python REPL variables, sandbox files). Tier 2 of the three-tier memory model. Operationally persistent but not durable until committed to the journal. |
| **Projection** | A bounded working-memory view assembled on demand from the journal + mount contributions + binding metadata. The system prompt + context messages sent to the LLM. Tier 3 of the three-tier memory model. **The prompt is a projection, not the state.** |
| **Binding** | A large resource exposed by a mount by reference rather than inline. The engine renders metadata (name, kind, size, access path) in the prompt; the agent accesses the actual content programmatically. Enables RLM-style "context as environment variable" patterns. |
| **Checkpoint** | An anchor entry in the journal that captures a summary of prior context, enabling the projection to "start fresh" from that point. Enables bounded context windows over unbounded history. Analogous to out-of-core paging. |
| **Mount** | Anything attached to an agent process that contributes behavior or state to a turn. Provides tools, prompt sections, bindings, and/or typed hook reactions via the `Rho.Mount` behaviour. |
| **Runtime Environment** | A persistent session-scoped computational substrate exposed through a mount. Python REPL (stateful scratchpad / external working memory), Sandbox (overlay filesystem). Distinguished from stateless tools by having cross-turn state. The middle tier of the memory model. |
| **Actuator** | A mount that provides tools for acting on the world: Bash, FS read/write/edit, web fetch. Stateless per invocation. |
| **Procedural Memory** | A mount that contributes learned procedures / instructions to the prompt. Skills (SKILL.md files). |
| **Journal Capability** | A mount that provides tools for the agent to interact with its own journal: search, recall, anchor, clear. |
| **Policy Mount** | A mount that shapes loop behavior through typed hooks (`after_tool`, `after_step`). Step budget, final response. Hooks are policy-only — they never drive the reasoning loop. |
| **Transport** | A terminal that submits input to an agent process and renders its output. CLI, Web. Not part of cognition. Extended in Phase 9 to render interactive widgets. |
| **Generative UI** | Interactive visual output (charts, diagrams, forms) produced by the agent via the `show_widget` tool. A mount provides the tool; the transport provides the rendering surface. The mount is transport-agnostic — it emits widget events; the transport decides how to render (native window for CLI, inline DOM for Web). |
| **Widget** | An HTML/SVG fragment produced by `show_widget`. Rendered with streaming DOM diffing (morphdom). User interactions flow back as tool results committed to the journal. Ephemeral — tied to the tool call, not persisted across sessions. |
| **Self-evolution** | The agent using its actuator/runtime mounts to modify artifacts (SKILL.md files, capability modules) that define its future mounts. An emergent use case, not a special subsystem. |
| **Child Execution Frame** | The shared abstraction for both conversational subagents and computational sub-calls. Has an objective, budget, mount profile, lineage, and return channel. |
| **Conversational Child** | A child execution frame implemented as a forked agent process with its own journal and mount set. Broad scope, multiple turns. |
| **Computational Child** | A child execution frame implemented as a lightweight sub-LLM call (RLM `llm_query`). Narrow scope, single call, returns a value. Depth-1 by default. |

---

## Appendix C: Lessons from Pi (pi-coding-agent)

The [Pi agent framework](https://github.com/badlogic/pi-mono) (TypeScript, powers OpenClaw) was reviewed during this design phase. Pi's battle-tested patterns validated Rho's direction and contributed four concrete improvements incorporated above.

### What Pi validates

- **Unified extension model.** Pi's `createAgentSession` wires tools, extensions, and session management through one entry point. This confirms Rho's move from 4 fragmented paths to a single `MountRegistry`.
- **Event-sourced sessions.** Pi persists sessions as JSONL with tree-structured branching (each entry has `id` + `parentId`). This validates Rho's journal-as-truth model and suggests journal branching/forking is a natural future extension.
- **Separation of tools and extensions.** Pi makes an explicit distinction: tools are LLM-callable functions; extensions are invisible lifecycle hooks the model never sees. Rho adopts this as the affordance/hook plane separation within `Rho.Mount`.

### What Pi contributed to this design

1. **`before_llm` hook** (from Pi's `api.on("context", ...)`). Pi's most important extension point lets plugins rewrite the message array before every LLM call — for pruning oversized tool results, injecting dynamic reminders, redacting sensitive content. The original Rho design only had post-execution hooks (`after_tool`, `after_step`), which is too late for projection shaping. Now added as `before_llm/3`.

2. **`before_tool` hook** (from Pi's `tool_call` interception). Pi can intercept and gate tool calls before execution — for permission checks, safety guardrails, arg validation. The original Rho design could only rewrite results after the fact. Now added as `before_tool/3`.

3. **Mount instances with opts** (from Pi's tool factories). Pi's `createBashTool("/workspace", { operations: { exec: ... } })` cleanly separates the tool schema from the execution backend. This maps to Rho's `MountInstance` struct, enabling workspace-scoped tools, swappable backends (local/Docker/SSH), and multiple instances of the same mount module.

4. **Trust boundary for generated mounts.** Pi's extensions-are-invisible principle, combined with Rho's self-evolution goals, motivates an explicit privilege separation: self-authored/generated mounts should only access affordance callbacks (`tools`, `prompt_sections`, `bindings`), never hook callbacks (`before_llm`, `before_tool`, `after_tool`, `after_step`) unless explicitly trusted.

### What Pi has that Rho defers

- **`steer` vs `followUp` semantics.** Pi distinguishes interrupting the agent mid-run (`steer`, skips pending tools) from queuing input for after completion (`followUp`). Useful for real-time multi-user products. Deferred — this is an execution-control concern, not a mount concern.
- **Stream function middleware.** Pi's injectable `streamFn` enables per-provider customization (headers, caching, observability). In Rho, this belongs in the LLM client / reasoner layer, not the mount model. Deferred to the Reasoner phase.
- **Custom compaction strategies.** Pi's `session_before_compact` hook. In Rho, compaction is a journal/projection concern — potentially a future `before_compact` hook or a dedicated journal strategy, not a general mount hook.

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Breaking existing `.rho.exs` configs | Phase 7 added backwards compatibility for `tools:` key; compat shim removed in Phase 8a — `.rho.exs` must now use `mounts:` directly |
| Losing `{:override, ...}` control flow | `after_tool/3` with `{:replace, result}` covers the same case more explicitly |
| Mount ordering / priority changes | `MountRegistry` uses same priority-ordered ETS as `HookRuntime` |
| Python REPL lifecycle changes | Python.Interpreter GenServer is untouched; only the thin tool wrapper changes |
| Sandbox context-dependency breaks | `tools/1` receives full context including `sandbox` key; same guard as current `components/1` |
| Subagent completion checking breaks | `after_tool/3` replaces the current `handle_event(:tool_result)` pattern exactly |
| Test coverage gaps during migration | Phases 2–3 run both systems in parallel; integration test verifies mount resolution matches old resolution |
| Reasoner extraction breaks AgentLoop | Phase 6a is a pure refactor (extract Direct); full test suite must pass before 6b |
| Recursive reasoner cost explosion | Separate internal budgets (max_iterations, max_sub_queries, max_depth); start with depth-1 per RLM paper findings |
| Hidden state in REPL bypasses journal | Commit discipline: important results must be materialized in journal. Environment state is explicitly non-authoritative |
| Hooks used to drive reasoning loops | Hooks are typed as policy-only in the behaviour docs; FINAL() is an engine-level halt signal, not a hook outcome |
| Binding metadata bloats prompt | Bindings are rendered as single-line summaries; the engine caps total binding metadata size |
| `before_llm` mutates journal state | Typed as `projection → projection`; operates on ephemeral projection, never the journal. Enforce side-effect-free. |
| `before_tool` blocks legitimate calls | Deny returns reason string as LLM error; model can retry or explain. Start with allow-by-default. |
| Hook ordering ambiguity with Recursive reasoner | `before_llm` fires before each provider call made by the active reasoner; document scoping explicitly. |
| Generated mounts escalate to hook privilege | Registry enforces trust levels: untrusted mounts restricted to affordance callbacks only |
| Multiple instances of same mount module conflict | `MountInstance` stores independent opts; registry deduplicates by instance identity, not module |
| Native window unavailable on headless/Linux | Degrade gracefully: CLI falls back to static HTML-to-image rendering (wkhtmltoimage) or plain-text summary. Web transport always works. |
| Widget streaming flickers/flashes | Morphdom DOM diffing + debounce (150ms) + no gradients/shadows/blur rule in guidelines. Same solution Pi validated. |
| CDN libraries blocked in restricted environments | CSP allowlist is configurable per mount opts. Offline mode: bundle common libraries in `priv/visualize/vendor/`. |
| `show_widget` tool call blocks the agent loop | Tool execution runs in a Task; the turn engine continues. Timeout (120s) prevents indefinite blocking. |

---

## Summary of Changes by File Count

| Phase | Files created | Files modified | Files deleted | Risk |
|-------|:---:|:---:|:---:|------|
| Phase 1 | 3 | 1 | 0 | Low |
| Phase 2 | 1 | ~12 | 0 | Low |
| Phase 3 | 0 | 2 | 0 | **Medium** |
| Phase 4 | 0 | 3 | 0 | Low |
| Phase 5 | 0 | 2 | 3 | **Medium** |
| Phase 6 | 4 | 3 | 0 | **Medium** |
| Phase 7 | 0 | 3 | 0 | Low |
| Phase 8 | 2 | 3 | 3 | Low |
| Phase 9 | 5 | 4 | 0 | **Medium** |

---

## Appendix B: RLM Theoretical Foundation

This appendix documents the key insights from the [Recursive Language Models paper](https://arxiv.org/abs/2512.24601) (Zhang, Kraska, Khattab — MIT CSAIL, 2025) that inform this refactor.

### Core Insight: Prompt as Environment

RLM's fundamental move is treating the prompt as **a variable in an external environment** rather than as LLM input. The model writes code to programmatically examine, decompose, and recursively call itself over snippets of the prompt. This enables processing inputs 100× beyond the context window.

### The Out-of-Core Analogy

RLM draws from **out-of-core algorithms** in database systems: a system with small fast memory (context window) can process arbitrarily large datasets (prompts) by cleverly managing how data is fetched into memory. This maps directly to Rho's three-tier memory model:

| Out-of-core | RLM | Rho |
|---|---|---|
| Disk | Full prompt as REPL variable | Journal (tier 1) |
| Temp tables / scratch | REPL variables, buffers | Mounted environment state (tier 2) |
| RAM / cache | Metadata + code output in context | Prompt projection (tier 3) |

### Key Findings Relevant to Rho

1. **REPL alone is powerful.** Even without recursive sub-calls, just having REPL access to context-as-variable dramatically outperforms base LLMs and common scaffolds. This validates making Python a first-class runtime environment mount with bindings.

2. **Sub-calls add gains on dense tasks.** Recursive `llm_query` calls provide 10–59% improvement on information-dense tasks (OOLONG, OOLONG-Pairs) where semantic processing of every part is required.

3. **Depth-1 suffices.** The paper used max recursion depth of 1 (sub-calls use base LMs, not full RLMs) and found strong results across all benchmarks. Deeper recursion is future work. Start conservative.

4. **Cost efficiency.** RLMs are often cheaper than direct long-context calls because the model processes metadata + code output, not raw content. At the 50th percentile, costs are comparable or lower.

5. **Common agent strategies emerge naturally:**
   - **Filtering**: regex/keyword search to narrow the context
   - **Chunking**: uniform chunking with sub-LM calls per chunk
   - **Answer verification**: sub-LM calls with small context to verify correctness
   - **Variable stitching**: building up final answers across iterations via REPL variables

6. **Models need sufficient coding ability.** Smaller models without strong coding capabilities struggle as RLMs. The reasoner strategy should be paired with capable models.

### Structural Isomorphism: RLM ↔ Rho

| RLM concept | Rho equivalent |
|---|---|
| Prompt `P` stored outside token context | Journal/resources stored outside prompt (tier 1–2) |
| REPL state | Mounted environment state (tier 2) |
| Root history sees metadata, not full payload | Prompt is a projection with binding metadata (tier 3) |
| Code execution in REPL | Act step over internal environments |
| `llm_query(sub_context, instruction)` | Computational child execution frame |
| `FINAL()` / `FINAL_VAR()` | Engine-level convergence signal (`{:final, value, entries}`) |
| Stdout/metadata appended to history | Committed observations / summarized events in journal |
| Max iterations / max sub-queries | Reasoner-internal budget (separate from turn step budget) |

### Design Principle Derived

> **RLM is a specialized nested turn engine whose "world" is mostly internal computational mounts rather than external tools.** It validates the same architectural law as Rho — that large state should live in addressable environments, not in token space — and provides a concrete algorithm for exploiting this principle on information-dense tasks.
