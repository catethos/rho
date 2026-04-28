# Swappable Decision-Policy Plan

**Date:** 2026-04-26
**Revision:** 2 — incorporates `Workbench` as the framework's domain API.
DataTable is downgraded from "canonical state" to "the editing surface
the Workbench mutates"; phase ordering reworked so Workbench lands first.
**Branch (suggested):** `feat/decision-policy`
**Sources:** `combined-simplification-plan.md` (the 13-phase refactor that
just landed), live audit of `apps/rho_frameworks/`, `apps/rho_web/`,
`apps/rho_baml/`.

---

## 1. Problem Statement

Today the `rho_frameworks` demo exposes the **same domain operations** through
two completely parallel paths:

| Path | Where | How decisions are made | Token cost |
|------|-------|------------------------|------------|
| **Wizard** | `RhoWeb.FlowLive` + `RhoFrameworks.Flows.CreateFramework` | Hard-coded list-index step machine in LiveView | Very low — UI routes |
| **Chat** | `RhoWeb.AppLive` + `:spreadsheet` agent | LLM tool-loop (`:typed_structured`, `max_steps: 50`) picks every next call | High — agent re-decides things the app already knows |

The user's pain: an agentic loop is unpredictable for decisions the app
already knows the answer to (latency, cost, and outcome all vary), while
a fixed wizard can't accommodate intent that doesn't fit the rails. Token
cost is part of it but secondary to control. The point of the policy
layer is **predictable behavior on known paths, agentic flexibility only
where it's needed** — quantified token wins (e.g. §4.1) are a side effect.

**Symptomatic smell that proves the duplication is real:**
[`SkeletonGenerator.build_task_prompt`](../apps/rho_frameworks/lib/rho_frameworks/skeleton_generator.ex)
literally instructs the LLM to *"call create_library, then save_skeletons,
then finish — one tool at a time"*. A fixed sequence is being smuggled into a
tool loop because the only shared abstraction we have is "tool".

---

## 2. Recommended Architecture (4 layers)

Treat the shared primitive as a **use case**, not a "step" or a "tool". A
flow step becomes a *node that references a use case + UI metadata + allowed
next edges*. Push the "deterministic vs agentic" decision into a tiny
**transition policy** layer. Underneath everything, the **Workbench** is
the single domain API for mutating a framework.

### 2.1 Workbench — the framework's domain API

The framework being edited *is* the bundle of named tables in a session
(`library`, `role_profile`, `meta`). DataTable is the editing surface;
**`RhoFrameworks.Workbench` is the domain API that wraps it**. Direct UI,
flow nodes, and chat tools all mutate the framework through Workbench —
nothing reaches `DataTable.*` directly outside `Workbench` and the
internal `RhoFrameworks.DataTableOps.*` helpers it delegates to.

```elixir
defmodule RhoFrameworks.Workbench do
  alias RhoFrameworks.Scope

  @spec add_skill(Scope.t(), map())            :: :ok | {:error, term()}
  @spec remove_skill(Scope.t(), id())          :: :ok | {:error, term()}
  @spec rename_cluster(Scope.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @spec set_meta(Scope.t(), map())             :: :ok | {:error, term()}
  @spec set_proficiency(Scope.t(), id(), 1..5, String.t()) :: :ok | {:error, term()}
  @spec load_framework(Scope.t(), framework_id) :: :ok | {:error, term()}
  @spec save_framework(Scope.t())              :: {:ok, framework_id} | {:error, term()}
  @spec snapshot(Scope.t())                    :: %{tables: %{atom() => [map()]}}
  …
end
```

Why Workbench instead of calling DataTable directly:

- **Invariants live here** — "every skill belongs to one cluster", "no
  duplicate skill names in a library", "proficiency levels 1–5". DataTable
  can't enforce these; Workbench can.
- **Single mutation surface** — three drivers (Direct UI, Flow, Chat agent)
  reach the framework through one API. No bypass.
- **Provenance enforcement** — Workbench reads `Scope` for `source:`
  (`:user | :flow | :agent`) and stamps it on the resulting `Rho.Events.Event`.
  This is what powers unified undo / replay (§11.3).
- **Persistence boundary** — `load_framework` hydrates Ecto → tables;
  `save_framework` snapshots tables → Ecto. Nothing else touches Ecto for
  framework data.

DataTable stays generic and unaware of frameworks. `RhoFrameworks.DataTableOps.*`
is internal — it converts a Workbench mutation into a `DataTable` row op
plus the right `Rho.Events` emission. Callers don't import it.

> **One Workbench per session.** A session edits exactly one framework
> at a time; the framework is implicit in the session_id, not an
> explicit argument. `Workbench.load_framework/2` replaces the session's
> tables with the loaded one — there is no "open in a new tab" semantic.
> Multi-framework operations (§10.2 `DiffFrameworks`, `MergeFrameworks`)
> read the source frameworks as **ephemeral read-only snapshots** and
> write to the single editing target.
>
> If multi-framework editing ever becomes a real requirement, the
> boundary is clean: Workbench gains a `workspace_id`, named tables get
> namespaced (`library:<id>`), and nothing else changes. Don't design
> for it now — no flow in the plan needs it.

### 2.2 Use-case layer — orchestrated work units

```
RhoFrameworks.UseCase           (behaviour)
RhoFrameworks.UseCases.LoadSimilarRoles
RhoFrameworks.UseCases.GenerateFrameworkSkeletons
RhoFrameworks.UseCases.GenerateProficiency
RhoFrameworks.UseCases.SaveFramework
…
```

```elixir
defmodule RhoFrameworks.UseCase do
  alias RhoFrameworks.Scope

  @doc "Run the use case. Mutations land via Workbench; return value is a small status payload."
  @callback run(map(), Scope.t()) ::
              :ok
              | {:ok, summary :: map()}
              | {:async, %{agent_id: String.t()}}
              | {:error, term()}

  @doc "Self-describe so flow renderer and chat tool wrapper share one source of metadata."
  @callback describe() :: %{
              required(:id)            => atom(),
              required(:label)         => String.t(),
              required(:cost_hint)     => :instant | :cheap | :agent,
              optional(:input_schema)  => module(),    # Zoi struct
              optional(:output_schema) => module(),
              optional(:doc)           => String.t()
            }
end
```

`describe/0` is **required** — `cost_hint` powers the UI badge in §3.6,
and the chat tool wrapper needs `label`/`doc` for prompt generation.
There is no useful default.

> **`cost_hint` is UI-only; routing is the dispatch signal.** The
> deterministic-vs-agentic choice is made by the node's `routing` value
> (§2.3, §2.4), not by `cost_hint`. A `:cheap` UseCase can be invoked
> from a `:fixed`, `:auto`, or `:agent_loop` node — `cost_hint` only
> controls what badge the user sees.

UseCases are **commands**: they don't compute and return a framework, they
mutate the Workbench and return a small summary (e.g. `%{skills_added: 12}`)
that FlowRunner can use to evaluate edge guards. Anything a caller wants
to "see" from the framework is read from the Workbench / DataTable.

These supersede the call-site duplication between `LibraryTools` and
flow `run: {Mod, Fun, []}` MFAs. Two consumers, one home:

- **Flow node** → `use_case: GenerateFrameworkSkeletons`
- **ReqLLM tool** → wraps `GenerateFrameworkSkeletons.run/2` via `WorkflowTools`

#### UseCases are not a fixed list — extension model

UseCases are plain modules implementing the behaviour. **There is no
registry, no plugin manifest, no central list to edit.** Adding one is
two steps: write the module, reference it from a flow node and/or
expose it via `WorkflowTools`. Everything else (UI badges, BAML router
prompts, chat tool descriptions) wires up automatically from
`describe/0`.

**Discovery mechanisms (no registry needed):**

| Mechanism | Used by | Coupling |
|-----------|---------|----------|
| Static reference from a flow node | `Flow.nodes/0` declares `use_case: MyUseCase` | Direct module reference |
| `WorkflowTools` registration | Chat agent — wraps a curated list as ReqLLM tools | Hand-edited list |
| Direct invocation | Tests, mix tasks, programmatic callers | None |

**Cross-domain scoping:** UseCases are per domain app, not global.
`RhoFrameworks.UseCases.*` is the framework domain; a future hiring
domain would ship `RhoHiring.UseCases.*`. The behaviour is shared (in
core or per-domain); the modules are not. This is consistent with the
plan's "parallel domain apps" theme.

##### Worked examples — adding a new UseCase

**Example 1 — domain operation (`SuggestClusterRename`)**

User notices a cluster name is awkward, wants an LLM-suggested rename.
This is a single BAML call, no agent loop:

```elixir
# apps/rho_frameworks/lib/rho_frameworks/use_cases/suggest_cluster_rename.ex
defmodule RhoFrameworks.UseCases.SuggestClusterRename do
  @behaviour RhoFrameworks.UseCase
  alias RhoFrameworks.{Scope, Workbench, LLM}

  @impl true
  def describe do
    %{
      id: :suggest_cluster_rename,
      label: "Suggest cluster rename",
      cost_hint: :cheap,
      input_schema: __MODULE__.Input,
      doc: "Propose a clearer cluster name based on the skills it contains."
    }
  end

  @impl true
  def run(%{cluster: old_name}, %Scope{} = scope) do
    skills = Workbench.snapshot(scope).tables[:library]
             |> Enum.filter(&(&1.cluster == old_name))

    with {:ok, %{name: new_name, reasoning: why}} <-
           LLM.SuggestClusterRename.call(%{cluster: old_name, skills: skills}) do
      :ok = Workbench.rename_cluster(scope, old_name, new_name)
      {:ok, %{old: old_name, new: new_name, reasoning: why}}
    end
  end
end
```

To use it:
- **From a flow:** add `%{id: :rename, use_case: SuggestClusterRename, ...}` to a `nodes/0` list.
- **From chat:** add it to the `WorkflowTools` list — the agent now has a `suggest_cluster_rename` tool.

No registry edit, no application config, no supervisor change.

**Example 2 — `:agent_loop` UseCase (`FindSimilarRolesAcrossFrameworks`)**

The framework-search variant from §4.4. Mutations land in a named
`similar_roles` table; downstream UseCases consume pinned rows:

```elixir
defmodule RhoFrameworks.UseCases.FindSimilarRolesAcrossFrameworks do
  @behaviour RhoFrameworks.UseCase
  alias RhoFrameworks.{Scope, Workbench}

  @impl true
  def describe do
    %{
      id: :find_similar_roles_across_frameworks,
      label: "Search existing frameworks",
      cost_hint: :agent,
      doc: "Find roles similar to the target across all loaded frameworks."
    }
  end

  @impl true
  def run(%{target_role: role}, %Scope{} = scope) do
    :ok = Workbench.ensure_table(scope, "similar_roles", schema())

    {:ok, agent_id} =
      RhoFrameworks.AgentJobs.start(%{
        agent: :role_searcher,
        scope: scope,
        tools: [:find_similar_frameworks, :query_role_library, :compute_role_similarity],
        input: %{target_role: role}
      })

    {:async, %{agent_id: agent_id}}
  end

  defp schema, do: RhoFrameworks.DataTableSchemas.similar_roles_schema()
end
```

The same Research panel renders findings, the same early-finish signal
works, the same provenance machinery applies — none of which this
module had to know about.

**Example 3 — composing UseCases**

UseCases are just modules; composition is just function calls. A
`BulkRenameClusters` UseCase iterates clusters from
`Workbench.snapshot/1` and calls `SuggestClusterRename.run/2` per
cluster — no special "composition mechanism" is needed.

##### When a registry would matter (out of scope for v1)

Two scenarios where a registry becomes useful — neither is in Phases 1–7:

1. **"Show me everything I can do"** in chat — let the agent enumerate
   all UseCases dynamically instead of relying on `WorkflowTools`'s
   curated list.
2. **Cross-flow dynamic composition** — one flow looking up another
   flow's UseCases by string name at runtime.

For v1, **explicit module references win.** They're greppable, dialyzer
can check them, and the dependency graph is visible. Add a registry
only if a real use case forces it.

### 2.3 Flow layer — node graph, not list

Evolve `RhoFrameworks.Flow`:

```elixir
defmodule RhoFrameworks.Flow do
  @type step_type :: :form | :action | :table_review | :fan_out | :select

  @type edge_def :: %{
          to: atom(),
          guard: atom() | nil,         # FlowRunner.guard?(name, state) -> boolean
          label: String.t() | nil      # human-readable, used by router + UI ("no matches")
        }

  @type routing :: :fixed | :auto | :agent_loop

  @type node_def :: %{
          id: atom(),
          label: String.t(),
          type: step_type(),
          use_case: module() | nil,
          input: {module(), atom(), list()} | nil,
          next: atom() | [edge_def()] | :done,
          routing: routing(),          # ← per-node policy hint, see §2.4
          config: map()
        }

  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback start() :: atom()
  @callback nodes() :: [node_def()]
end
```

Key changes vs today:

- `run: {Mod, Fun, []}` → `use_case: Module` (which delegates to Workbench)
- list-index `advance_step` → explicit `next:`
- per-step hard-coded param building in `FlowLive.build_step_params/2` →
  per-node `input: {Mod, Fun, args}` reading from Workbench snapshot
- new `routing` flag per node, with three values:
  - `:fixed` — single edge or first-satisfied-guard, deterministic, no LLM
  - `:auto` — multiple edges, picked by BAML router from allowed IDs
  - `:agent_loop` — needs runtime tool access to gather context or
    handle open-ended work; escalate to `AgentJobs` (see §2.4 / §4.4)
- `edge_def.label` is required for `:auto` nodes (the router needs human
  text to reason over) and surfaced in the UI's `<.routing_chip />`.

We do **not** build a generic graph engine. `nodes/0` stays a list of plain
maps; we just add explicit `next` so order isn't implicit.

### 2.4 Policy layer — where the deterministic-vs-agentic choice lives

The `routing` value on each node is the **explicit signal** the policy
acts on. There is no inference, no "the policy decides if it's
open-ended" — flow authors mark each node, and policies dispatch.

```elixir
defmodule RhoFrameworks.Flow.Policy do
  @callback choose_next(flow_mod, current_node, state, allowed_edges, opts) ::
              {:ok, atom() | :done, %{reason: String.t() | nil, confidence: float() | nil}}
              | {:error, term()}
end
```

Two implementations:

- `RhoFrameworks.Flow.Policies.Deterministic` — wizard. Always picks the
  first edge whose `guard` is satisfied (or the single edge). **Never
  calls an LLM, ignores `routing`.** Used in Guided mode.

- `RhoFrameworks.Flow.Policies.Hybrid` — chat / co-pilot. Dispatches on
  the node's `routing`:
  1. 0 or 1 valid outgoing edge → first edge (no LLM)
  2. `routing: :fixed` → first satisfied guard (no LLM)
  3. `routing: :auto` → if `state.user_override[node_id]` is set (the
     routing chip's "Override" pill writes the chosen edge_id here), use
     it directly; else cheap **BAML router**
     (`RhoFrameworks.LLM.ChooseNextFlowEdge`) constrained to allowed edge IDs
     and labels; returns `{edge_id, confidence, reasoning}`
  4. `routing: :agent_loop` → spawn `AgentJobs.start/1` with the node's
     allowed UseCases as tools; agent decides when it's done and which
     edge to take. Used for dynamic context gathering (§4.4) or
     genuinely open-ended work — these nodes are not necessarily
     leaves.

**Rule of thumb — flow authors choose the routing value:**

| Need | `routing` | Implementation |
|------|-----------|----------------|
| App already knows the answer (single edge or guarded) | `:fixed` | Deterministic code |
| Pick 1 of N options / structured single-shot | `:auto` | `RhoBaml.Function` (router) |
| **Dynamic context gathering with tools** (web search, doc lookup, prior-framework lookup) | `:agent_loop` | `AgentJobs` (lite worker) |
| Open-ended multi-step tool use (no fixed schema) | `:agent_loop` | `AgentJobs` (lite worker) |

> **`:agent_loop` is not just for "open-ended" leaves.** Its primary use
> is **dynamic context gathering**: a step that needs tool access at
> runtime to decide what context to pull in (web search, fetch a doc,
> look up an existing framework). The structured generation step that
> *follows* it stays a single BAML call — it just receives a richer
> input. See §4.4 for the canonical pattern.

`UseCase.describe().cost_hint` is **not** what selects the path — it
drives the UI badge in §3.6. Routing is an authoring-time decision, not
inferred at runtime.

### 2.5 FlowRunner — extract orchestration out of LiveView

Today `FlowLive` *is* the orchestrator (state, params, advance, retry, table
refresh, agent_id matching). Pull it out so chat can reuse it.

```elixir
defmodule RhoFrameworks.FlowRunner do
  @type state :: %{
          flow_mod:   module(),
          node_id:    atom(),
          intake:     map(),                  # transient form values not in tables
          summaries:  %{atom() => map()}      # per-node UseCase return summaries
        }

  @spec current_node(module(), state()) :: Flow.node_def()
  @spec build_input(Flow.node_def(), state(), Scope.t()) :: map()
  @spec run_node(Flow.node_def(), state(), Scope.t()) ::
          {:ok, summary :: map()}
          | {:async, %{agent_id: String.t()}}
          | {:error, term()}
  @spec choose_next(module(), Flow.node_def(), state(), module(), keyword()) ::
          {:ok, atom() | :done, %{reason: String.t() | nil, confidence: float() | nil}}
          | {:error, term()}
end
```

Crucially, **FlowRunner derives anything table-shaped from the Workbench**
(`Workbench.snapshot/1`); it does not hold its own copy of skills, role
profiles, or library rows. The only thing it owns is `intake` (transient
form values not yet persisted to the `meta` table) and the small
`summaries` map (per-node UseCase return values used to evaluate edge
guards). Drop today's `FlowLive.step_results` map for table-backed nodes.

`FlowLive` becomes a UI shell calling `FlowRunner`. The chat path can then
drive the same flow runner with `Hybrid` policy.

---

## 3. UX Plan

### 3.1 Mode toggle (the one big new affordance)

Single workspace, three modes:

| Mode | Policy | Tool theater | Best for |
|------|--------|--------------|----------|
| **Guided** | `Deterministic` | Hidden | Repeatable production flows, demos |
| **Co-pilot** | `Hybrid` | Visible only on `:auto`-routed nodes | Most users, most of the time |
| **Open** | `Hybrid` w/ unrestricted leaf escalation | Always visible | Power users, exploration, debugging |

The toggle is per-flow, not global. It's surfaced as a small control in the
flow header (next to the step indicator). State stored on the LV socket /
optionally persisted per user preference.

### 3.2 "Tool theater" — keep it, but gate it

The streaming text panel and tool-event log in `flow_components.ex`
(`action_step`'s `tool_events`, `streaming_text` assigns) are **valuable
signal in Open / Co-pilot modes**. Some users like watching the agent work;
it builds trust.

Recommendation: **don't delete the theater** — gate it.

```elixir
# in FlowLive render path
<%= if show_theater?(@mode, @step_def) do %>
  <.tool_event_log events={@tool_events} />
  <.streaming_text text={@streaming_text} />
<% end %>
```

`show_theater?/2`:

- Guided → false
- Co-pilot → true only when current node `routing == :auto` or
  `routing == :agent_loop`
- Open → always true

### 3.3 Reasoning chip on `:auto` edges

When the BAML router picks an edge, surface a one-line "why" with an
**override pill** that lets the user re-pick.

```
┌──────────────────────────────────────────────┐
│  Next: review (auto-selected, 95% confidence)│
│  ↳ "seed roles had high-quality skills, no   │
│     regeneration needed"                     │
│  [ Override ]                                │
└──────────────────────────────────────────────┘
```

The router function returns `{next_edge, confidence, reasoning}`; the LV
renders it via a new `<.routing_chip />` component.

### 3.4 Per-step "Ask" escape hatch

Every wizard step gets a small inline chat box scoped to the current node's
use case + state. The agent only sees tools relevant to *this* step's
surface area, so it can't run away. Cheap because the surface is tiny.

Implementation: a `<.step_chat />` component that opens a constrained
`AgentJobs.start/1` session whose `tools:` list is built from the current
node's `use_case` + a small `clarify` tool.

### 3.5 Smart entry from natural language

Type `"create a framework for backend engineers"` in the chat box. The chat
first matches against known flow entry points using a single
`RhoBaml.Function` classifier (`MatchFlowIntent`) — no tool loop. If matched
with high confidence, opens `CreateFramework` at `:intake` with prefilled
fields (`name`, `target_roles`).

> **Phase dependency:** this is Phase 9 (optional). Until it lands, NL
> entry falls back to UI buttons; §10's "from template / extend / merge"
> branches are still reachable via an explicit "Start from…" picker on
> the intake screen. §10's NL-driven examples assume Phase 9 has shipped.

### 3.6 Cost / time hints per step

Use the `cost_hint` from `UseCase.describe/0`:

| Hint | Badge | Tooltip |
|------|-------|---------|
| `:instant` | gray dot | Local computation, runs immediately |
| `:cheap` | green dot · `~$0.0002` | Single LLM call (BAML), seconds |
| `:agent` | amber dot · `~30s` | Multi-step agent, may take a while |

Renders in the step indicator and on action buttons.

### 3.7 Branching wizard (the natural consequence of explicit edges)

`CreateFramework` today is linear:

```
intake → similar_roles → generate → review → confirm → proficiency → save
```

With explicit `next` it can be:

```
intake → similar_roles
similar_roles --[no_matches]--> generate
similar_roles --[good_matches]--> pick_template → adapt_template → review → confirm → proficiency → save
generate → review → confirm → proficiency → save
```

The bracketed text is the `edge_def.label` from §2.3 — surfaced verbatim
in the routing chip when an `:auto` node picks an edge. The guard with
the same name (e.g. `guard: :no_matches`) decides whether the edge is
eligible.

The UI just renders the actual graph (use existing `step_indicator`, but
fed by `nodes()` + `next:` instead of list order).

### 3.8 Replay / debug view

A recorded path through the graph (which edges fired, which were
policy-selected, with confidence + reasoning) becomes a first-class artifact.
"Show me how this framework was built" replays the nodes. Implementation
piggybacks on existing `Rho.Events` log + DataTable snapshots.

---

## 4. Concrete Step UX (skeleton & proficiency)

### 4.1 Skeleton generation — biggest UX/perf win

**Today** (in `SkeletonGenerator.generate/2` →
`AgentJobs.start/1` with `:typed_structured`):

- 3 LLM turns
- Tool log shows `create_library ✓ → save_skeletons ✓ → finish ✓`
- Streaming text panel echoes the agent's chain-of-thought
- Data table populates **after** `save_skeletons` returns
- ~$0.001 per generation, ~10–20s

**After** (single `RhoBaml.Function`):

- 1 streaming structured call returning `%FrameworkSkeleton{name, description, skills: [%Skill{...}]}`
- Use case persists via `Workbench.add_skill/2` per partial (Workbench is the
  domain API; it delegates to `DataTableOps` and emits provenance-stamped events)
- Data table rows **stream in as BAML partials arrive** (verified in spike,
  see `combined-simplification-plan.md` Phase 0)
- ~$0.0002 per generation, ~3–5s

| Aspect | Today | After |
|---|---|---|
| Tool log entries | 3 | 0 |
| Streaming text | "I'll start by creating the library…" | empty (or progress label) |
| Table | Populates at end | Rows stream in |
| Latency / cost | ~3 turns, ~$0.001 | ~1 turn, ~$0.0002 |

**UX detail — progressive table fill:**

`RhoBaml.Function.stream/3` emits `:structured_partial` events as each
field/array element arrives. Pipe these into the existing
`refresh_data_table` path so rows appear one-by-one. Already half-wired in
`FlowLive.handle_text_delta/2`.

**Mode behavior for skeleton step (single implementation, three views):**

- Guided → just the streaming table fill, no tool log, no streaming text
- Co-pilot → table fill + a small "drafting skill 7 of 12…" status
- Open → table fill + a verbose progress log derived from `:structured_partial`
  events (which BAML field arrived, partial row contents). **Same code path
  as Guided/Co-pilot — Open is theater visibility, not a different impl.**

### 4.2 Proficiency fan-out — UX shape unchanged

This is genuinely parallel domain work (one writer per category). The
`fan_out_step` cards stay exactly as-is. Internally, each writer can become
a single `RhoBaml.Function` instead of a tool loop (the
`:proficiency_writer` agent only emits `add_proficiency_levels` once anyway —
see `.rho.exs` lines 102–115).

| Aspect | Today | After |
|---|---|---|
| Worker tiles | N (one per category) | N (unchanged) |
| Per-worker latency | 5–15s | 2–5s |
| Per-worker cost | ~$0.0005 | ~$0.0001 |
| UI | `progress_card` per worker | unchanged |

The events flowing through `Rho.Events` stay the same shape, so
`FlowLive.handle_worker_completed/2` and `mark_worker_completed/2` need no
changes.

### 4.3 `SkeletonGenerator` collapses into one UseCase

The current module conflates "spawn an agent that does steps" with the
business operation. Replace it with **one** UseCase:

- `RhoFrameworks.UseCases.GenerateFrameworkSkeletons` — calls
  `RhoFrameworks.LLM.GenerateSkeleton` (new BAML function), streams
  partials into `Workbench.add_skill/2` so rows appear progressively.
  **No tool loop. No agentic fallback.**

Open mode shows the same UseCase running, with extra UI surfacing of the
underlying `:structured_partial` events. There is no
`GenerateFrameworkSkeletonsAgentic` — keeping two implementations of one
operation reintroduces the duplication this whole refactor kills.

If a power-user genuinely needs free-form generation ("brainstorm 50
skills, no schema"), that's a separate UseCase or a chat session — not a
mode toggle on this one.

> **"No agentic fallback" applies to *this* UseCase, not to the flow.**
> §4.4 introduces an `:agent_loop` UseCase (`ResearchDomain`) *upstream*
> of skeleton generation, not as an alternative implementation of it.
> Research gathers context with tools; generation stays a single BAML
> call. Two distinct jobs, no duplication.

### 4.4 Research-augmented generation — the canonical `:agent_loop` pattern

The wizard's pre-determined context is a real limitation: an agent with
`web_fetch` / `doc_lookup` / `find_similar_frameworks` tools can pull in
context the wizard couldn't possibly load up-front (current trends,
domain-specific vocabulary, adjacent frameworks). But this **does not**
mean we need a `GenerateFrameworkSkeletonsAgentic` variant. The clean
pattern is **composition**: an agentic context-gathering UseCase
upstream of the BAML structured-generation UseCase.

```
intake → choose_starting_point
  ├─ scratch_quick      → generate_skeleton            → review → ...
  └─ scratch_researched → research_domain → generate_skeleton(seeds: research) → review → ...
                          ↑ routing: :agent_loop         ↑ routing: :fixed
                          tools: [web_fetch,             takes research blob
                                  doc_lookup,            as input
                                  find_similar_frameworks]
```

Two UseCases, two responsibilities:

- **`UseCases.ResearchDomain`** (`routing: :agent_loop`) — agent has
  research tools, runs a loop, decides when it has enough. Streams
  findings into the `research_notes` named table via Workbench. Returns
  `{:ok, %{findings_count: N, sources: [...]}}` when finished.
- **`UseCases.GenerateFrameworkSkeletons`** (`routing: :fixed`) —
  unchanged single BAML call. Reads pinned findings from
  `Workbench.snapshot(scope).tables[:research_notes]` and feeds them to
  the prompt's `research:` field. Streams structured skills into
  `library` table.

Why this works without reintroducing the duplication this refactor kills:

- These are not two implementations of skeleton generation. They are
  two distinct jobs (gather context vs. generate structured output).
- Both Quick and Researched paths end at the *same* BAML generation
  step — fed different context.
- Adding a new generation strategy (e.g. "researched + multi-pass") is
  composing a new node sequence, not a new generator.

**UI shape — research as a first-class artifact:**

The research step appears in the step indicator like any other node.
Its body is a streaming **Research panel**:

```
┌─ Research: backend engineer competencies ─────────────┐
│ ✓ Found 3 SFIA backend roles                          │
│ ✓ Identified 14 trending skill terms (2024–2026)     │
│ ✓ Pulled "Senior BE" job listings (12 sources)        │
│ ⋯ Searching: "backend engineer Kubernetes 2026"      │
│                                                        │
│ [ Pin/unpin ] [ Add note ] [ Continue early → ]       │
└────────────────────────────────────────────────────────┘
```

- Each finding = a row in `research_notes` (source URL + fact + tag),
  emitted via `Rho.Events` as the agent fetches.
- Pinning/unpinning a row toggles a `pinned: bool` cell — generation
  reads only pinned rows. Manual notes land with `source: :user`.
- "Continue early" sends an `early_finish` signal to the lite worker;
  whatever is pinned at that moment is the context.

**Tool theater earns its keep here.** For the research node the log is
not generic — it shows actual fetches: `Searched: "..."`, `Fetched:
docs.example.com/...`. The user can verify the agent didn't go off on
a tangent. This is the case §3.2 was protecting.

**Generation shows research as a sidebar.** When `generate_skeleton`
runs after research, the panel collapses to a sidebar of pinned
findings. If the BAML schema includes a `cited_findings: [int]` field
per skill, the UI can highlight which finding seeded which skill —
direct visual trace from context to output.

**Mode interactions:**

- Guided → research panel renders, theater hidden (findings only, no
  raw tool calls). Continue button visible. The Researched branch is
  only taken if the user explicitly picked it at intake.
- Co-pilot → full panel + theater. Default for most users.
- Open → same as Co-pilot + verbose `:structured_partial` log.

**Phase home:** §6 Phase 4's `:agent_loop` candidate is exactly this.
The plan currently says *"e.g. an 'explore variants' leaf"* — replace
that placeholder with `ResearchDomain` so all three routing paths land
on a real, useful node from day one.

#### Panel reuse — `ResearchDomain` is the template, not a one-off

The Research panel is generic by design. **Any `:agent_loop` step that
gathers structured findings into a named table reuses the same shell.**
A new flow doesn't ship new UI components, only new declarations. This
is the test of whether the §2 abstraction is right.

> **Phase scope.** Phase 4 ships `ResearchDomain` only.
> `FindSimilarRolesAcrossFrameworks` is a §10-style hypothetical used
> here to illustrate the reuse rule — it lands when the corresponding
> "extend existing framework" flow is built, not in Phases 1–7.

What varies per flow — three knobs, none of which are "UI design":

| Knob | Web-research (`ResearchDomain`) | Framework-search (`FindSimilarRolesAcrossFrameworks`) |
|------|---------------------------------|--------------------------------------------------------|
| Agent tools (`Rho.RunSpec`) | `[web_fetch, doc_lookup]` | `[find_similar_frameworks, query_role_library, compute_role_similarity]` |
| Findings table | `research_notes` (`source_url`, `fact`, `tag`, `pinned`) | `similar_roles` (`framework_id`, `role_name`, `match_score`, `notes`, `pinned`) |
| Downstream consumer | `GenerateSkeleton` reads `research:` field | `CloneSkillsFromRoles` reads `seed_roles:` (then `GenerateSkeleton` runs with `seeds:` populated) |

What stays identical:

- The streaming-rows panel shell + pin/unpin/add-note/continue-early controls
- Workbench provenance, replay, and undo machinery
- The early-finish signal to the lite worker
- The sidebar-during-generation layout

Authors declare the variation on the flow node:

```elixir
%{
  id: :research_step,
  type: :action,
  use_case: FindSimilarRolesAcrossFrameworks,  # or ResearchDomain, or …
  routing: :agent_loop,
  config: %{
    findings_table: "similar_roles",            # or "research_notes"
    findings_schema: SchemaModule
  },
  next: :review_matches
}
```

The panel reads `findings_table` from the node config and renders rows
from `Workbench.snapshot/1`. Visual variation (e.g. rendering
`match_score` vs `source_url`) lives in a per-schema row-renderer
function, not in a different panel.

**Worked example — framework-search flow:**

```
intake → choose_starting_point
  └─ search_existing → find_similar_roles → review_matches → clone_skills → adapt → review → ...
                       ↑ routing: :agent_loop
                       findings_table: "similar_roles"
```

Same panel, different findings:

```
┌─ Searching existing frameworks ───────────────────────┐
│ ✓ SFIA v8 — "Senior Backend Engineer" (89% match)    │
│ ✓ Internal — "Platform Engineer L5" (76% match)      │
│ ✓ NICE — "Backend Software Engineer" (71% match)     │
│ ⋯ Querying internal role library…                    │
│                                                        │
│ [ Pin/unpin ] [ Add note ] [ Continue early → ]       │
└────────────────────────────────────────────────────────┘
```

Pin semantics adapt to the downstream consumer: pinned roles flow into
`clone_skills` as `seed_roles:`, not as freeform `research:` text. The
generation sidebar shows pinned roles with the skills they contributed.

**Rule:** if you find yourself writing a bespoke panel for flow N+1,
something's wrong upstream — either the findings table schema is too
narrow, or the panel needs a row-renderer hook it doesn't have yet.
Fix it once at the panel level; every future flow benefits.

---

## 5. Critical anti-patterns to avoid

1. **`FlowLive` remains the real orchestration engine.** Then the chat path
   can never reuse it. Extract `FlowRunner` first.
2. **`LibraryTools` becomes the shared workflow API.** Tools are adapters,
   not the domain contract. UseCases own the domain.
3. **One mega-tool with `action: "..."` for routing-heavy workflows.** Fine
   for editor power tools (it's already what `manage_library` does); poor
   fit for bounded workflow routing — that belongs in a BAML router.
4. **Full agent loop for "choose next from 3 edges".** Use BAML, constrained
   to the allowed edge IDs.
5. **Hide router reasoning.** If the LLM picks an edge, the user must see
   *why* and be able to undo it in one click.
6. **Make the mode toggle global.** Toggles per-flow (or per-node) preserve
   the whole point of swappable decision points. A global "agentic mode"
   defeats it.
7. **Delete the tool theater.** It's signal in Open/Co-pilot modes; don't
   drop it, just gate it.
8. **Build a graph engine.** `nodes/0` returning a list of maps with `next:`
   is enough. Skip LangGraph-in-Elixir until you have ≥3 flows that share
   nodes.

---

## 6. Implementation Phases

### [x] Phase 1 — Workbench + DataTableOps + provenance (1d)

Foundation. The framework's domain API and unified mutation surface land
first; everything else is built on top.

1. **Add `source` and `reason` fields to `Rho.Events.Event`** —
   cross-app change (`apps/rho/`). All current consumers in `rho_stdlib`,
   `rho_frameworks`, `rho_web` must keep compiling. Default `source: nil`,
   `reason: nil`.
2. **Tag mutations in `DataTable.Server`** — read `source` from the
   calling process's `Rho.Context` (`:user | :flow | :agent`); stamp on
   every emitted event.
3. **Create `RhoFrameworks.DataTableOps.*`** — internal helpers, one
   module per mutation type (`AddSkill`, `RemoveSkill`, `RenameCluster`,
   `SetMeta`, `SetProficiencyLevel`, `ReorderRows`). Each wraps the
   relevant `DataTable` API and emits the standardized event.
4. **Create `RhoFrameworks.Workbench`** — domain API per §2.1. Delegates
   to `DataTableOps`; enforces invariants (cluster membership, level
   range, no duplicate skill names, etc.).
5. **Add the `meta` named table** — single-row schema for framework
   intake (`name`, `description`, `target_roles`).
6. **Migrate existing tools** (`LibraryTools`, `RoleTools`,
   `SharedTools.add_proficiency_levels`) to call `Workbench.*` instead of
   `DataTable.*`. They become thin adapters.
7. **Add provenance icon to the table renderer** — small badge per row
   (`flow_components.ex`).

**Verification:** `mix test`, wizard end-to-end, chat end-to-end. No
user-visible behavior change except provenance icons. The chat agent's
existing flow still works (it's now going through Workbench).

### [x] Phase 2 — UseCases + FlowRunner (table-derived) (1d)

UseCases as commands; FlowRunner reads framework state from the Workbench.

1. Create `RhoFrameworks.UseCase` behaviour with **required** `describe/0`
   per §2.2.
2. Create:
   - `UseCases.LoadSimilarRoles` (wraps `Roles.find_similar_roles` +
     dedup pre-filter from `CreateFramework.load_similar_roles`)
   - `UseCases.GenerateFrameworkSkeletons` (wraps current
     `SkeletonGenerator.generate` for now — Phase 6 swaps the impl)
   - `UseCases.GenerateProficiency` (wraps
     `Library.Proficiency.start_fanout_from_table`)
   - `UseCases.SaveFramework` (delegates to `Workbench.save_framework`)
3. UseCases use the command-style return: `:ok | {:ok, summary} | {:async, ...} | {:error, reason}`.
4. Repoint `CreateFramework.steps/0` to use UseCases.
5. Add `RhoFrameworks.Tools.WorkflowTools` exposing the same UseCases as
   ReqLLM tools. **Delete the now-redundant `LibraryTools` clauses** that
   overlap (Phase 1's migration made them dead).
6. Create `RhoFrameworks.FlowRunner` per §2.5. State derives from
   `Workbench.snapshot/1` for table-backed nodes; only `intake` and per-node
   `summaries` are held in the runner. Drop `FlowLive.step_results` for
   table-backed nodes.
7. `FlowLive` becomes a thin shell over FlowRunner.

**Verification:** `mix test`, wizard end-to-end, chat end-to-end. FlowRunner
has its own test module. No user-visible behavior change.

### [x] Phase 3 — Explicit edges + Policy behaviour (0.5d)

Introduce `next:`, `routing:`, `edge_def.label`; introduce `Flow.Policy`
with `Deterministic` impl only.

1. Update `RhoFrameworks.Flow` typespec for `node_def` and `edge_def` per §2.3.
2. Update `CreateFramework.steps/0` — add `next:` to every node
   (still single-edge, `routing: :fixed`).
3. Create `RhoFrameworks.Flow.Policy` behaviour per §2.4.
4. Create `RhoFrameworks.Flow.Policies.Deterministic`.
5. `FlowRunner.choose_next/5` uses the policy.
6. `FlowLive` uses `Deterministic` policy.

**Verification:** wizard behavior identical; new edge-based path is
exercised.

### [x] Phase 4 — BAML router + Hybrid policy (1d)

Add the BAML edge router and `Hybrid` policy supporting all three
`routing` values.

1. Define `RhoFrameworks.LLM.ChooseNextFlowEdge` (Zoi schema:
   `next_edge: atom`, `confidence: float`, `reasoning: string`). The
   prompt receives the current node label, allowed `{edge_id, label}`
   pairs, and a Workbench summary snapshot.
2. Create `RhoFrameworks.Flow.Policies.Hybrid` per §2.4 — dispatches on
   `routing: :fixed | :auto | :agent_loop`.
3. Add a fork to `CreateFramework`: `similar_roles` →
   `[no_matches] → generate` | `[good_matches] → pick_template → save`,
   with `routing: :auto` on the fork node.
4. **Add the `:agent_loop` candidate: `UseCases.ResearchDomain`.** The
   intake fork gains a `scratch_researched` branch that runs
   `ResearchDomain` (web search + doc lookup + framework lookup tools)
   before `generate_skeleton`. Findings stream into a new
   `research_notes` named table; pinned rows feed the BAML generator's
   `research:` input (§4.4). This exercises the third routing path on
   a node that does real, useful work — not a placeholder leaf.
5. Add the `<.research_panel />` component (streaming findings list,
   pin/unpin, add note, continue-early). Wire the early-finish signal
   into the lite worker so "Continue" is non-blocking on a slow agent.
6. Add `research_notes_schema/0` to `RhoFrameworks.DataTableSchemas`
   (columns: `source`, `fact`, `tag`, `pinned: bool`).

**Verification:** wizard exercises all three routing paths
(`:fixed`, `:auto`, `:agent_loop`) on `CreateFramework`.

### [x] Phase 5 — Mode toggle UI + tool theater gating (0.5d)

1. Add `:mode` (`:guided | :copilot | :open`) to `FlowLive` socket.
2. Header toggle component (3-way segmented control).
3. `show_theater?/2` predicate; gate `tool_events` / `streaming_text` rendering.
4. `<.routing_chip />` component for `:auto` decisions, with override
   pill — clicking "Override" writes the chosen edge_id into
   `state.user_override[node_id]` so the Hybrid policy short-circuits
   the BAML router on next evaluation (§2.4).
5. Direct edits stay always-available — the table + toolbar render
   regardless of mode (Option B in §11.4).
6. Add a "Suggest" button to the table toolbar — opens a constrained
   one-shot `RhoBaml.Function` call (no agent loop) that proposes
   N skills and streams them in via `Workbench.add_skill/2`. This is
   the Direct → escalate-once affordance from §11.3.
7. Persist mode preference per session (URL param + socket assign;
   per-user DB later if needed).

**Verification:** click through all 3 modes on `CreateFramework`; verify
tool log visibility matches §3.1; verify direct table edits work in all
three modes.

### [x] Phase 6 — Skeleton via BAML, single implementation (0.5d)

Replace the tool-loop skeleton generation with a BAML structured call.
**No agentic fallback retained.**

1. Create `RhoFrameworks.LLM.GenerateSkeleton` (Zoi schema:
   `%FrameworkSkeleton{name, description, skills: [%Skill{cluster, name, description, cited_findings: [int]}]}`).
   `cited_findings` is optional — populated only when `research:` input
   is provided, lets the UI trace each generated skill back to a
   research bullet (§4.4).
2. Rewrite `UseCases.GenerateFrameworkSkeletons.run/2` to call
   `LLM.GenerateSkeleton.stream/3` with optional `seeds:` and
   `research:` inputs (the latter read from
   `Workbench.snapshot.tables[:research_notes]` filtered to
   `pinned: true`), and pipe `:structured_partial` events into
   `Workbench.add_skill/2` so rows append progressively.
3. Delete `SkeletonGenerator.build_task_prompt` and the agent
   spawn path; the module either disappears or shrinks to a thin wrapper.
4. Open mode renders the same UseCase with verbose `:structured_partial`
   trace — same code path, more UI.

**Verification:** wizard end-to-end; latency/cost lower than the prior
tool-loop on representative seeds.

### [x] Phase 7 — Proficiency writer via BAML (0.5d)

Each fan-out worker becomes a `RhoBaml.Function` call instead of a tool loop.

1. Create `RhoFrameworks.LLM.WriteProficiencyLevels` (Zoi schema mirroring
   today's `add_proficiency_levels` tool args).
2. `UseCases.GenerateProficiency` spawns N tasks under
   `Rho.TaskSupervisor`, each calling `LLM.WriteProficiencyLevels.call/2`
   and writing results via `Workbench.set_proficiency/4`.
3. Each task emits `:task_completed` via `Rho.Events` so the existing
   fan-out card UI keeps working unchanged.
4. Drop `:proficiency_writer` agent from `.rho.exs` once nothing references it.

**Verification:** wizard proficiency step completes faster; UI looks
identical.

### [x] Phase 8 — Per-step "Ask" escape hatch (1d, optional polish)

Add `<.step_chat />` component scoped to a node's use case.

### [x] Phase 9 — Smart NL entry (0.5d, optional polish)

`RhoFrameworks.LLM.MatchFlowIntent` — single BAML classifier mapping a chat
message to `(flow_id, prefilled_intake)`. Unblocks §10's NL-driven examples
(`"make it like our SFIA framework but for product managers"` →
`extend_existing` with prefilled `library_id`).

---

## 7. Files / Modules Summary

### Create
```
apps/rho_frameworks/lib/rho_frameworks/workbench.ex               — domain API (Phase 1)
apps/rho_frameworks/lib/rho_frameworks/data_table_ops/            — internal mutation helpers (Phase 1)
  add_skill.ex
  remove_skill.ex
  rename_cluster.ex
  set_meta.ex
  set_proficiency_level.ex
  reorder_rows.ex
apps/rho_frameworks/lib/rho_frameworks/data_table_schemas.ex      — add `meta_schema/0` (Phase 1), `research_notes_schema/0` (Phase 4)
apps/rho_frameworks/lib/rho_frameworks/use_case.ex                — behaviour (Phase 2)
apps/rho_frameworks/lib/rho_frameworks/use_cases/
  load_similar_roles.ex
  generate_framework_skeletons.ex
  generate_proficiency.ex
  save_framework.ex
  research_domain.ex                 — :agent_loop UseCase (Phase 4)
apps/rho_frameworks/lib/rho_frameworks/flow_runner.ex             — Phase 2
apps/rho_frameworks/lib/rho_frameworks/flow/policy.ex             — behaviour (Phase 3)
apps/rho_frameworks/lib/rho_frameworks/flow/policies/
  deterministic.ex                — Phase 3
  hybrid.ex                       — Phase 4
apps/rho_frameworks/lib/rho_frameworks/llm/
  generate_skeleton.ex            — RhoBaml.Function (Phase 6)
  write_proficiency_levels.ex     — RhoBaml.Function (Phase 7)
  choose_next_flow_edge.ex        — BAML router    (Phase 4)
  match_flow_intent.ex            — BAML classifier (Phase 9, optional)
apps/rho_frameworks/lib/rho_frameworks/tools/workflow_tools.ex    — adapters (Phase 2)
apps/rho_web/lib/rho_web/components/
  routing_chip.ex                 — Phase 5
  research_panel.ex               — Phase 4 (streaming findings, pin/unpin)
  step_chat.ex                    — Phase 8 (optional)
```

### Modify
```
apps/rho/lib/rho/events/event.ex                                  — add `source` + `reason` (Phase 1, cross-app impact)
apps/rho_stdlib/lib/rho_stdlib/data_table/server.ex                — stamp source on emitted events (Phase 1)
apps/rho_frameworks/lib/rho_frameworks/tools/library_tools.ex     — call Workbench (Phase 1); drop overlapping clauses (Phase 2)
apps/rho_frameworks/lib/rho_frameworks/tools/role_tools.ex        — call Workbench (Phase 1)
apps/rho_frameworks/lib/rho_frameworks/tools/shared_tools.ex      — `add_proficiency_levels` calls Workbench (Phase 1)
apps/rho_frameworks/lib/rho_frameworks/flow.ex                    — node_def + routing + edge_def.label (Phase 3)
apps/rho_frameworks/lib/rho_frameworks/flows/create_framework.ex  — use_case + next + branch (Phases 2–4)
apps/rho_frameworks/lib/rho_frameworks/skeleton_generator.ex      — collapse to wrapper or delete (Phase 6)
apps/rho_frameworks/lib/rho_frameworks/library/proficiency.ex     — UseCase wrapper (Phase 7)
apps/rho_web/lib/rho_web/live/flow_live.ex                        — thin shell, mode toggle (Phase 2/5)
apps/rho_web/lib/rho_web/components/flow_components.ex            — gate theater + provenance icon (Phase 1/5)
.rho.exs                                                          — drop :proficiency_writer (Phase 7)
```

> **Cross-app impact callout:** Phase 1's change to `Rho.Events.Event`
> ripples through every consumer that pattern-matches on the struct
> (rho_stdlib, rho_web, rho_frameworks, anything subscribing in tests).
> The defaults (`source: nil`, `reason: nil`) keep existing matchers
> working; new code reads them.

### Keep untouched
```
apps/rho/                       — runtime is fine post-13-phase-refactor (only Event struct changes)
apps/rho_baml/                  — already production-ready
RhoFrameworks.Scope
Rho.RunSpec / Rho.Runner
RhoFrameworks.AgentJobs         — still needed for `:agent_loop` nodes (research, etc.)
RhoFrameworks.Library.Editor / Operations / Roles  — read-only helpers; Workbench wraps writes
DataTable / DataTableSchemas    — generic substrate; only `Server` changes
FlowRegistry
```

### Eventually delete
```
SkeletonGenerator's prompt sequencing in build_task_prompt        (Phase 6)
.rho.exs `:proficiency_writer` config                             (Phase 7)
Direct DataTable.* calls outside Workbench / DataTableOps         (Phase 1, no-bypass rule)
```

> `LibraryTools` overlapping clauses are removed in Phase 2 (already
> listed under "Modify"). Not a separate "eventually" item.

---

## 8. Open Questions for the Implementer

1. **Where does mode preference live?** Per-user setting (DB), per-session
   (socket), per-flow-start (URL param)? Recommend per-session with URL
   override; persist later if needed.
2. **Do we need persisted flow state?** Today flow lives in LV memory; lost
   on disconnect. The new architecture *enables* persistence (since
   `FlowRunner` is pure) but doesn't require it. Defer.
3. **Should the chat path drive `FlowRunner` directly?** Yes eventually,
   but not in Phase 1–5. Once `Hybrid` policy exists, a future phase can
   make `:spreadsheet` agent operate as a flow driver instead of a free
   tool-loop.
4. **What's the contract between BAML partials and DataTable streaming?**
   Recommend: each partial emits `{:structured_partial, %{path: [...], value: ...}}`,
   FlowRunner translates to `{:dt_row_appended, row}` for the table.
5. **Is `:typed_structured` strategy still useful after Phase 6/7?** Yes —
   `:spreadsheet` agent in Open mode still uses it for free-form chat.
   Don't remove.

---

## 9. Background Context (for the implementer)

### What just happened (Phases 0–13 of `combined-simplification-plan.md`)

- `rho_baml` app added: Zoi schemas → BAML class generation, `RhoBaml.Function`
  for compile-time-defined LLM functions. Streaming partials work; cost is
  ~$0.0002/call against DeepSeek via OpenRouter.
- `Rho.Events` replaced `Rho.Comms` for agent events (Phoenix.PubSub-based,
  in `apps/rho/`).
- `RhoFrameworks.Scope` introduced to keep frameworks free of agent-infra
  leaks. Pass `Scope.t()` to all UseCases; tools convert via
  `Scope.from_context(ctx)`.
- `Rho.RunSpec` is the single declarative spec for an agent (model, tools,
  system_prompt, turn_strategy, max_steps). Legacy worker spawn paths gone.
- `RhoFrameworks.AgentJobs.start/1` is the canonical "spawn one async lite
  worker" API. Keep using it for `:agent_loop` nodes (e.g.
  `ResearchDomain`).

### Where the demo's two paths converge

Both paths already share:

- `Scope` struct
- `Library.Editor` / `Library.Operations` / `Roles` (pure business funcs)
- `AgentJobs.start/1` for async work
- `Rho.Events` for streaming events to the UI
- `DataTable` for shared session state

What they don't share is the **decision-point abstraction**. That's what
this plan adds.

### Gotchas from the 13-phase refactor (still apply)

- `function_exported?/3` requires `Code.ensure_loaded!/1` first.
- Group leader inheritance bites supervised processes (CLI / mix tasks).
- Avoid forever-pending `GenServer.call` for CLI entry points.

(See `AGENTS.md` at repo root for full notes.)

### Verification habits the user expects

- Run `mix test` after each phase
- Run the wizard end-to-end (`/orgs/:slug/flows/create-framework`) after
  each phase
- Run the chat end-to-end (`/orgs/:slug/chat`) after each phase

---

## 10. Composing Flows — Reuse, Templates, Extension

The architecture must support workflows beyond "create from scratch":
referencing/extending an existing framework, merging two, etc. **No new
mechanism needed** — these fall out of branching node-graphs + composable
UseCases.

> **Phase home.** The UseCases and flows in this section are *not* part
> of Phases 1–9. They are added per-flow as those flows are built, on
> top of the foundation Phases 1–7 establish. §10 specifies the shape so
> nothing in Phases 1–7 accidentally precludes them.

### 10.1 New flow shape — branched intake

`CreateFramework` becomes a graph that forks after the intake stage:

```
intake → choose_starting_point
  ├─ scratch           → generate → review → confirm → proficiency → save
  ├─ from_template     → pick_template → adapt_template → review → confirm → proficiency → save
  ├─ extend_existing   → load_library → identify_gaps → generate(scope=gaps) → merge → review → ...
  └─ merge_frameworks  → pick_two → diff → resolve_conflicts → review → save
```

`choose_starting_point` is the canonical example of a `routing: :auto`
node — high payoff for a BAML router:

- User typed `"make it like our SFIA framework but for product managers"`
  → router picks `extend_existing` and prefills `library_id: "SFIA v8"`
  *(requires Phase 9's `MatchFlowIntent` classifier to extract the
  `library_id` from prose; until then, the user picks via UI)*
- User clicked "Start fresh" in Guided mode → policy picks `scratch`
  deterministically based on UI selection

### 10.2 New UseCases needed (each a thin wrapper over `Workbench` +
`Library.Operations`)

```
RhoFrameworks.UseCases.LoadExistingFramework     ← calls Workbench.load_framework/2
RhoFrameworks.UseCases.IdentifyFrameworkGaps     ← BAML function (cheap), reads Workbench.snapshot
RhoFrameworks.UseCases.AdaptFrameworkSkeleton    ← variant w/ seed_skills: from Workbench
RhoFrameworks.UseCases.DiffFrameworks            ← reads two Workbench snapshots, wraps Library.Operations.diff
RhoFrameworks.UseCases.MergeFrameworks           ← writes resolved rows via Workbench, wraps Library.Operations.combine
RhoFrameworks.UseCases.ResolveConflicts          ← interactive step; user edits land via Workbench like any direct edit
```

Each follows the §2.2 command contract — mutations land in the Workbench,
return value is a small summary. `LoadExistingFramework` is the canonical
example: input `framework_id`; effect: `library` and `role_profile` tables
in the session are now hydrated from Ecto; return: `{:ok, %{skill_count: N, role_count: M}}`.

### 10.3 Skeleton generation accepts seed input

`UseCases.GenerateFrameworkSkeletons.run/2` should accept an optional
`seed_skills:` and `scope: :full | :gaps_only`:

- `scope: :full` (default) — generates all skills from scratch
- `scope: :gaps_only` + `seed_skills:` — only generates skills covering
  identified gaps; merges with the seeds

The corresponding BAML function (`LLM.GenerateSkeleton`) gets a `seeds`
field in its prompt and is told *"do not regenerate skills already present
in seeds; fill the gaps listed below"*.

### 10.4 No new UI primitives

See §4.4 "Panel reuse" — the rule is identical: write 1–3 UseCases,
declare a `nodes/0` list, register in `Flows.Registry`. Same components,
same FlowRunner, same policy. If a flow seems to need a new component,
something is wrong upstream.

### 10.5 Sub-flows (deferred — only if needed)

If shared sub-paths emerge (e.g. `review → confirm → proficiency → save`
appears in 3+ flows), promote it to a sub-flow module that other flows
can `include:`. Don't do this preemptively. ≥3 flows sharing nodes is the
trigger.

---

## 11. Direct Manipulation — Workbench as the Single Substrate

The original framing of "deterministic vs agentic" was incomplete.
**There are three interaction modes**, all mutating the same framework
through the same domain API.

### 11.1 The three modes

| Mode | Driver | Token cost | Best for |
|------|--------|-----------|----------|
| **Direct** (toolbar + table cells) | User clicks/types in cells | **Zero** | Tweaks, typos, manual cleanup, "I know exactly what I want" |
| **Guided** (Flow + Deterministic policy) | App routes through nodes | Low | Repeatable production workflows |
| **Agentic / Co-pilot** (Hybrid policy or chat) | LLM routes / picks tools | High | Open-ended, ambiguous intent |

> **Naming reconciliation with §3.1.** §3.1's toggle (Guided / Co-pilot /
> Open) controls how a *flow* drives the table. Direct is not a fourth
> flow mode — it's the always-on baseline editing surface that all three
> drivers mutate through Workbench. "Open" in §3.1 means Co-pilot with
> unrestricted agent_loop escalation allowed; "Agentic" here is the
> umbrella term for both Co-pilot and Open.

These are not mutually exclusive. They share a single substrate
(the **Workbench**, backed by DataTable, scoped by `Scope`) and can be
mixed mid-task.

### 11.2 Architectural reframing

The Workbench architecture (single domain API, three drivers, provenance-
stamped events) is fully specified in §2.1 and §11.3 below covers only
what's *new* about the modes mixing. To avoid restating §2.1, the short
version: every Direct toolbar action, Guided flow node, and Agentic chat
tool reaches the framework through one `Workbench.*` call, with `Scope`
carrying `source: :user | :flow | :agent`. See §2.1 for the API surface
and invariant rules; see §6 Phase 1 for the implementation sequence.

### 11.3 UX implications — modes that *mix*

#### Mid-flow direct edits
Skeleton generates 12 skills → user spots a typo in a cluster name →
clicks the cell, fixes it → "Continue" still works because the flow reads
from the table, not its own copy. **No flow restart needed.**

#### Direct → escalate-once
User editing in Direct mode realizes they want 5 more skills →
clicks "Suggest more skills" → fires a *single* `RhoBaml.Function` call
(not a full agent loop) → rows stream in → user keeps editing.

This is implemented as a small "ask" affordance on the table toolbar that
opens a constrained `RhoBaml.Function` call, not a chat session.

#### Agent → observed in Direct
Chat says "remove all skills with proficiency < 2" → agent calls
`RemoveSkill` tool N times → user watches rows disappear in the same
table view they were editing.

#### Unified undo / replay
Every mutation (Direct, Guided, Agentic) is a `Rho.Events` event with
provenance:

```elixir
%Rho.Events.Event{
  kind: :dt_row_added,
  data: %{...},
  source: :user | :flow | :agent,
  actor: "user_id" | "flow_id:node_id" | "agent_id",
  reason: nil | "added by skeleton generation" | "user said: 'add devops'"
}
```

One undo stack works across all modes. A future replay view (see §3.8 —
not in Phases 1–9, deferred polish) trivially extends to show direct edits
interleaved with flow steps and agent tool calls.

### 11.4 UI — the mode toggle becomes 3-way (or implicit)

Two options, recommend Option B:

**Option A — explicit 3-way toggle**: `Direct | Guided | Co-pilot`
in the flow header. Switching to Direct hides the step indicator and
shows just the table + toolbar.

**Option B — Direct is always present, Guided/Co-pilot are overlays**
(recommended). The DataTable + toolbar are always visible. Guided/Co-pilot
modes add a side panel with the step indicator + flow controls. The user
never *leaves* the table; they just toggle whether the flow drives it or
they do.

Option B matches mental model better: the framework being edited *is* the
table. Modes are just different drivers.

### 11.5 Implementation pointers

This is implemented across Phases 1, 2, and 5 — see §6 for the canonical
sequence:

- Phase 1 — Workbench, DataTableOps, `Rho.Events.Event` `source` /
  `reason` fields, provenance icon in the table renderer.
- Phase 2 — FlowRunner derives table-backed state from
  `Workbench.snapshot/1`; `FlowLive.step_results` shrinks to `intake` +
  per-node UseCase summaries only.
- Phase 5 — table toolbar "Suggest" button (Direct → escalate-once),
  routing chip with override, mode toggle.

### 11.6 Anti-patterns to avoid

1. **Two different "add skill" code paths** — toolbar button and agent
   tool both go through `Workbench.add_skill/2`.
2. **Calling `DataTable.*` directly for framework tables** —
   `library` / `role_profile` / `meta` are Workbench-managed. Direct
   `DataTable.*` calls bypass invariants and provenance.
3. **Flow has its own copy of skill data** — re-introduces the
   duplication this refactor is killing. FlowRunner reads from
   `Workbench.snapshot/1`.
4. **Direct edits silently drop out of replay/undo** — they must emit
   events with `source: :user`.
5. **Hiding the table when in Guided mode** — defeats the point of
   shared substrate. Keep it visible at all times (Option B in §11.4).

---

## 12. Definition of Done

- [ ] Phases 1–7 merged
- [ ] All framework mutations go through `Workbench.*` — no direct
      `DataTable.*` calls for `library` / `role_profile` / `meta` outside
      `Workbench` and `DataTableOps` (verified via grep + a Credo rule)
- [ ] `Rho.Events.Event` carries `source` and `reason`; provenance icons
      visible in the table renderer
- [ ] FlowRunner derives table-backed state from `Workbench.snapshot/1`;
      `FlowLive.step_results` no longer holds skill / role data
- [ ] Single skeleton implementation (`UseCases.GenerateFrameworkSkeletons`);
      no `Agentic` variant; runs at <5s and <$0.0003 across all three modes
- [ ] Proficiency fan-out per-worker latency cut by ≥50%
- [ ] Wizard mode toggle works; tool theater visibility matches §3.1 matrix;
      direct table edits remain available in all three modes
- [ ] At least one `:auto`-routed edge and one `:agent_loop`-routed node
      in `CreateFramework` (`ResearchDomain` per Phase 4); routing chip
      surfaces reasoning + override
- [ ] No duplicate business logic between `LibraryTools`, `WorkflowTools`,
      and any flow node
- [ ] All existing tests pass; new modules (`Workbench`, `UseCase`s,
      `FlowRunner`, `Hybrid`) have tests
