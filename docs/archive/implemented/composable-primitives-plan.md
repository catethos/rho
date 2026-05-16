# Composable Primitives — Dual Execution Mode Architecture

## Design Principle

**Build well-designed fundamental blocks that can be assembled by a deterministic pipeline (FlowLive) for efficiency, and also be individually callable by the agent for maximum flexibility. Same blocks, two execution modes, shared state.**

FlowLive and the agent are not independent runners — they are **collaborative actors** operating on the same session state through the same primitives. DataTable is the shared workspace. Neither owns the data.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Execution Modes                          │
│                                                             │
│  ┌─────────────────────┐    ┌────────────────────────────┐  │
│  │  Agent Infra         │    │  FlowLive                  │  │
│  │  (strategy, tape,    │    │  (deterministic steps,     │  │
│  │   transformers,      │    │   state machine,           │  │
│  │   prompt assembly)   │    │   LiveView rendering)      │  │
│  │         │            │    │         │                   │  │
│  │  Tool Adapters       │    │  Direct function calls     │  │
│  │  (ToolResponse,      │    │  (plain {:ok, result})     │  │
│  │   Effects, JSON)     │    │                            │  │
│  └────────┬─────────────┘    └────────┬───────────────────┘  │
│           │                           │                      │
│           ▼                           ▼                      │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              Composable Primitives Layer               │  │
│  │                                                        │  │
│  │  Runtime ─── neutral context struct                    │  │
│  │  Library.Editor ─── table lifecycle                    │  │
│  │  Library.Skeletons ─── parse/transform (pure)          │  │
│  │  Library.Proficiency ─── LiteWorker fan-out            │  │
│  │  Library.Operations ─── composites                     │  │
│  └────────────────────────┬───────────────────────────────┘  │
│                           │                                  │
│                           ▼                                  │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              Existing Infrastructure                   │  │
│  │                                                        │  │
│  │  Library context (DB/domain)                           │  │
│  │  DataTable (per-session tables) ◄── SHARED STATE       │  │
│  │  LiteWorker (fan-out tasks)                            │  │
│  │  Comms/SignalBus (events)                              │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Collaboration Model

FlowLive and the agent collaborate through shared infrastructure:

1. **DataTable is the shared workspace** — both read/write the same tables via the same `session_id`
2. **Flow state is stored in DataTable metadata** — not private socket assigns — so the agent can read flow progress and FlowLive can resume after agent detours
3. **Comms signals are shared** — LiteWorker completions, progress updates visible to both
4. **FlowLive can delegate steps to the agent** — for complex/non-linear edits, then resume when done

---

## Module Specifications

### `RhoFrameworks.Runtime`

Neutral execution context that replaces `Rho.Context` in business logic. Agent infra fields (`tape_*`, `depth`, `prompt_format`, `subagent`, `agent_name`) are excluded — primitives don't need them.

```elixir
defmodule RhoFrameworks.Runtime do
  @enforce_keys [:mode, :organization_id, :session_id]
  defstruct [
    :mode,              # :agent | :flow
    :organization_id,
    :session_id,
    :user_id,
    :execution_id,      # flow_run_id or agent_id — stable for the execution
    :parent_agent_id,   # present in agent mode, nil in flow mode
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec from_rho_context(Rho.Context.t()) :: t()
  def from_rho_context(%Rho.Context{} = ctx)

  @spec new_flow(keyword()) :: t()
  def new_flow(attrs)

  @spec lite_parent_id(t()) :: String.t()
  def lite_parent_id(rt)
  # agent mode: returns parent_agent_id
  # flow mode: returns "flow:#{execution_id}"
end
```

### `RhoFrameworks.Library.Editor`

Session/table-backed editing. Absorbs DataTable orchestration currently spread across `create_library`, `save_to_library`, and `add_proficiency_levels` tools.

```elixir
defmodule RhoFrameworks.Library.Editor do
  @spec table_name(String.t()) :: String.t()
  # "library:#{name}" — single source of truth for naming convention

  @spec table_spec(String.t()) :: %{name: String.t(), schema: Schema.t(), schema_key: atom(), mode_label: String.t()}
  # Returns everything needed to set up or reference a library table

  @spec create(%{name: String.t(), description: String.t()}, Runtime.t()) ::
    {:ok, %{library: Library.t(), table: map()}} | {:error, term()}
  # Creates library record + ensures DataTable. No Effects, no ToolResponse.

  @spec read_rows(%{table_name: String.t()}, Runtime.t()) ::
    {:ok, [map()]} | {:error, term()}

  @spec append_rows(%{table_name: String.t(), rows: [map()]}, Runtime.t()) ::
    {:ok, %{count: non_neg_integer()}} | {:error, term()}

  @spec replace_rows(%{table_name: String.t(), rows: [map()]}, Runtime.t()) ::
    {:ok, %{count: non_neg_integer()}} | {:error, term()}

  @spec apply_proficiency_levels(%{table_name: String.t(), skill_levels: [map()]}, Runtime.t()) ::
    {:ok, %{updated_count: non_neg_integer(), skipped: [String.t()]}} | {:error, term()}
  # Matches by skill_name, updates proficiency_levels field. Absorbs SharedTools logic.

  @spec save_table(%{library_id: String.t() | nil, table_name: String.t()}, Runtime.t()) ::
    {:ok, %{library: Library.t(), saved_count: non_neg_integer(), draft_library_id: String.t() | nil}} | {:error, term()}
  # Reads rows from DataTable, persists to DB via Library context.
end
```

### `RhoFrameworks.Library.Skeletons`

Pure transformation — no IO, no side effects.

```elixir
defmodule RhoFrameworks.Library.Skeletons do
  @spec parse_json(String.t()) :: {:ok, [map()]} | {:error, term()}
  # JSON decode + validation (required keys, non-empty)

  @spec to_rows([map()]) :: [map()]
  # Normalize parsed skills into DataTable row shape
  # %{category: "", cluster: "", skill_name: "", skill_description: "", proficiency_levels: []}
end
```

### `RhoFrameworks.Library.Proficiency`

LiteWorker fan-out orchestration. Extracted from `save_and_generate` tool.

```elixir
defmodule RhoFrameworks.Library.Proficiency do
  @spec start_fanout(%{rows: [map()], levels: pos_integer(), table_name: String.t()}, Runtime.t()) ::
    {:ok, %{workers: [%{agent_id: String.t(), category: String.t(), count: pos_integer()}]}} | {:error, term()}
  # Groups rows by category, spawns staggered LiteWorkers

  @spec start_fanout_from_table(%{table_name: String.t(), levels: pos_integer()}, Runtime.t()) ::
    {:ok, %{workers: [map()]}} | {:error, term()}
  # Reads rows from DataTable first, then delegates to start_fanout/2

  @spec build_prompt(%{category: String.t(), skills: [map()], levels: pos_integer(), table_name: String.t()}) :: String.t()
  # Builds the proficiency writer prompt. Pure function.

  @spec resolve_tools(Runtime.t()) :: [Rho.Plugin.tool_def()]
  # Returns tool_defs for proficiency writers (SharedTools + Finish)
end
```

### `RhoFrameworks.Library.Operations`

Composite operations that chain primitives. Preserves current tool behavior as a single callable unit.

```elixir
defmodule RhoFrameworks.Library.Operations do
  @spec save_and_generate(%{skills_json: String.t(), levels: pos_integer(), library_name: String.t()}, Runtime.t()) ::
    {:ok, %{rows_added: non_neg_integer(), table_name: String.t(), workers: [map()]}} | {:error, term()}
  # Composes: Skeletons.parse_json → Skeletons.to_rows → Editor.append_rows → Proficiency.start_fanout
end
```

---

## Collaboration Mechanisms

### Flow State in DataTable

```elixir
# Schema for flow state tracking
def flow_state_schema do
  %Schema{
    name: "flow:state",
    mode: :dynamic,
    columns: [
      %Column{name: :flow_id, type: :string, required?: true},
      %Column{name: :current_step, type: :string, required?: true},
      %Column{name: :library_id, type: :string},
      %Column{name: :table_name, type: :string},
      %Column{name: :started_at, type: :string},
      %Column{name: :updated_at, type: :string}
    ],
    key_fields: [:flow_id]
  }
end
```

FlowLive writes progress after each step transition. The agent can read it to understand context. FlowLive can resume from it after reconnect or agent detour.

### Agent Delegation Step Type

```elixir
%{
  id: :complex_edit,
  type: :agent_delegate,
  task: "Merge categories X and Y in table library:MyLib",
  resume_when: fn params, rt ->
    # Poll DataTable state or check a signal flag
    :ready | :waiting
  end
}
```

FlowLive renders a chat panel or "open in chat" link. The agent operates on the same DataTable. When the user returns or a condition is met, the flow resumes.

### Bidirectional Awareness

- **Agent → Flow**: Agent reads `flow:state` table to know current step, avoids conflicting operations
- **Flow → Agent**: FlowLive subscribes to `rho.session.#{sid}.events.*` — sees agent edits to DataTable in real time
- **Shared LiteWorker events**: Both subscribe to `rho.task.completed` via Comms — FlowLive shows progress cards, agent reports status

---

## Phases

### Phase 1: Runtime + Editor Foundation

**Goal**: Extract the neutral context struct and the simplest primitive (`Editor.create` + `Editor.save_table`). Prove the pattern works for both execution modes.

**Tasks**:
1. Create `RhoFrameworks.Runtime` with `from_rho_context/1` and `new_flow/1`
2. Create `RhoFrameworks.Library.Editor` with:
   - `table_name/1` (absorb `LibraryTools.library_table_name/1`)
   - `table_spec/1`
   - `create/2` (absorb DB create + DataTable ensure from `create_library` tool)
   - `read_rows/2`
   - `save_table/2` (absorb logic from `save_to_library` tool)
3. Refactor `create_library` tool to call `Editor.create/2` + wrap in `ToolResponse`
4. Refactor `save_to_library` tool to call `Editor.save_table/2` + wrap in `ToolResponse`
5. Keep `LibraryTools.library_table_name/1` as a delegate to `Editor.table_name/1`
6. Write tests for `Runtime` and `Editor` functions independently (no agent needed)

**Acceptance Criteria**:
- [ ] `Editor.create/2` returns `{:ok, %{library: _, table: _}}` — no `ToolResponse`, no `Effect` structs
- [ ] `Editor.save_table/2` returns `{:ok, %{library: _, saved_count: _, ...}}` — plain data
- [ ] Existing agent chat creates a library exactly as before (tool adapter is transparent)
- [ ] `Editor.create/2` works when called with `Runtime.new_flow(...)` — same DB result
- [ ] `Editor` functions are independently testable without booting an agent
- [ ] `Runtime.from_rho_context/1` round-trips: agent tools pass, no missing fields
- [ ] All existing `LibraryTools` tests pass unchanged

### Phase 2: Skeletons + Proficiency Extraction

**Goal**: Extract the remaining primitives covering skeleton parsing and LiteWorker fan-out.

**Tasks**:
1. Create `RhoFrameworks.Library.Skeletons` with `parse_json/1` and `to_rows/1`
2. Create `RhoFrameworks.Library.Editor` additions:
   - `append_rows/2`
   - `replace_rows/2`
   - `apply_proficiency_levels/2` (absorb from `SharedTools.add_proficiency_levels`)
3. Create `RhoFrameworks.Library.Proficiency` with:
   - `build_prompt/1` (absorb `LibraryTools.build_proficiency_prompt/4`)
   - `resolve_tools/1` (absorb `LibraryTools.resolve_proficiency_tools/1`)
   - `start_fanout/2` (absorb staggered LiteWorker spawn loop)
   - `start_fanout_from_table/2`
4. Refactor `SharedTools.add_proficiency_levels` tool to:
   - JSON decode at the edge
   - Call `Editor.apply_proficiency_levels/2`
   - Wrap result in `{:ok, text}`
5. Create `RhoFrameworks.Library.Operations.save_and_generate/2` composing the primitives
6. Refactor `save_and_generate` tool to call `Operations.save_and_generate/2`

**Acceptance Criteria**:
- [ ] `Skeletons.parse_json/1` and `to_rows/1` are pure — no side effects, independently testable
- [ ] `Proficiency.start_fanout/2` works with both `Runtime` modes (agent and flow `lite_parent_id`)
- [ ] `Editor.apply_proficiency_levels/2` takes native Elixir maps, not JSON strings
- [ ] `Operations.save_and_generate/2` produces same result as current monolithic tool
- [ ] All existing tools pass — refactoring is transparent to the agent
- [ ] LiteWorker completion events work with synthetic `"flow:#{id}"` parent IDs
- [ ] Each primitive can be called in isolation (e.g., `start_fanout` without prior `save_and_generate`)

### Phase 3: FlowLive with Shared State

**Goal**: Build FlowLive that calls primitives directly and shares state with the agent via DataTable.

**Tasks**:
1. Define `RhoFrameworks.Flow` behaviour:
   - `id/0`, `label/0`, `steps/0`
2. Create flow state schema and `FlowRun` tracking in DataTable:
   - `flow:state` table with step progress
   - Write progress on each step transition
   - Resume from DataTable state on reconnect
3. Build `RhoWeb.FlowLive` — generic step runner:
   - Mount: resolve flow module, build `Runtime.new_flow(...)`, create session
   - Step rendering: `:form`, `:action`, `:table_review`, `:fan_out`
   - Step handlers call primitives directly (named function refs, not closures)
   - Subscribe to Comms for LiteWorker progress
4. Build `RhoWeb.FlowComponents` — step indicator, progress cards, form renderer
5. Create `RhoFrameworks.Flows.CreateFramework`:
   - Steps reference `Editor.create/2`, `Proficiency.start_fanout_from_table/2`, etc.
   - SkeletonGenerator as a new primitive (single LLM call, returns rows)
6. Add route: `live "/orgs/:slug/flows/:flow_id", FlowLive, :run`
7. Add entry point buttons to library list page

**Acceptance Criteria**:
- [ ] FlowLive creates a library end-to-end: intake → generate → review → proficiency → save
- [ ] FlowLive uses the same `session_id` as chat — DataTable is shared
- [ ] User can open chat mid-flow (during `:table_review`) and agent sees same rows
- [ ] Agent edits to the DataTable are visible in FlowLive on return (no sync needed)
- [ ] Flow state persists in DataTable — page refresh resumes at correct step
- [ ] LiteWorker progress shows in FlowLive via Comms subscription
- [ ] "Open in agent chat" link from FlowLive navigates to `/session/:session_id`
- [ ] Flow step definitions use named function refs: `run: {Library.Editor, :create, []}`

### Phase 4: Agent-Flow Collaboration

**Goal**: Enable FlowLive to delegate steps to the agent and the agent to be flow-aware.

**Tasks**:
1. Add `:agent_delegate` step type to FlowLive:
   - Renders inline chat or "open in chat" link
   - Subscribes to DataTable changes and/or Comms signals
   - Resumes when condition met or user clicks "continue"
2. Add flow-awareness to agent prompt sections:
   - Plugin reads `flow:state` table when present
   - Injects "You are assisting a flow at step X — the user is editing table Y" into prompt
   - Agent avoids conflicting operations (e.g., won't re-create the library)
3. Add "return to flow" navigation from chat when flow state exists
4. Handle edge cases:
   - User closes FlowLive tab while agent is editing
   - Agent modifies rows that FlowLive is displaying (live update via Comms)
   - Agent completes a step that FlowLive was waiting on

**Acceptance Criteria**:
- [ ] FlowLive can delegate a `:table_review` edit to the agent and resume after
- [ ] Agent prompt includes flow context when `flow:state` table exists
- [ ] Agent doesn't duplicate operations (e.g., won't create a second library)
- [ ] "Return to flow" link appears in chat when a flow is active
- [ ] DataTable edits from agent appear in FlowLive in real time
- [ ] Flow continues correctly after agent delegation completes

### Phase 5: Roles + Generalization

**Goal**: Mirror the pattern for role profiles. Extract shared patterns only if duplication is clear.

**Tasks**:
1. Create `RhoFrameworks.Roles.Editor`:
   - `create_draft/2`, `read_rows/2`, `save_profile/2`
   - Same `Runtime`-based interface as `Library.Editor`
2. Refactor `RoleTools` to be thin adapters over `Roles.Editor`
3. Create `RhoFrameworks.Flows.CreateRoleProfile` flow definition
4. Evaluate shared patterns:
   - If `Library.Editor` and `Roles.Editor` share >50% logic → extract `TableWorkspace` helper
   - If error humanization repeats → extract `OperationErrors`
   - If not → leave separate, duplication is fine
5. Add remaining flow definitions: `ForkTemplate`, `CombineLibraries`

**Acceptance Criteria**:
- [ ] `Roles.Editor` follows same `(params, Runtime.t()) -> {:ok, result} | {:error, reason}` contract
- [ ] `RoleTools` are thin adapters — same pattern as refactored `LibraryTools`
- [ ] CreateRoleProfile flow works end-to-end in FlowLive
- [ ] Decision on shared extraction is documented with rationale
- [ ] All existing role tools pass unchanged

---

## Task List

### Phase 1 — Runtime + Editor Foundation (Prove the Pattern)

| # | Task | Depends On | Est |
|---|------|-----------|-----|
| 1.1 | Create `RhoFrameworks.Runtime` struct + constructors | — | S |
| 1.2 | Create `Library.Editor` with `table_name/1`, `table_spec/1` | — | S |
| 1.3 | Implement `Library.Editor.create/2` | 1.1, 1.2 | M |
| 1.4 | Implement `Library.Editor.read_rows/2` | 1.1, 1.2 | S |
| 1.5 | Implement `Library.Editor.save_table/2` | 1.1, 1.2 | M |
| 1.6 | Refactor `create_library` tool → thin adapter over `Editor.create/2` | 1.3 | S |
| 1.7 | Refactor `save_to_library` tool → thin adapter over `Editor.save_table/2` | 1.5 | S |
| 1.8 | Delegate `LibraryTools.library_table_name/1` → `Editor.table_name/1` | 1.2 | S |
| 1.9 | Write tests for `Runtime` | 1.1 | S |
| 1.10 | Write tests for `Editor` (create, read, save — no agent) | 1.3, 1.4, 1.5 | M |
| 1.11 | Verify existing agent integration tests pass | 1.6, 1.7 | S |
| 1.12 | **Validation**: call `Editor.create/2` with `Runtime.new_flow(...)` from IEx, verify same DB result | 1.3 | S |

### Phase 2 — Skeletons + Proficiency Extraction

| # | Task | Depends On | Est |
|---|------|-----------|-----|
| 2.1 | Create `Library.Skeletons` with `parse_json/1`, `to_rows/1` | — | S |
| 2.2 | Implement `Editor.append_rows/2`, `replace_rows/2` | 1.2 | S |
| 2.3 | Implement `Editor.apply_proficiency_levels/2` | 1.2 | M |
| 2.4 | Refactor `SharedTools.add_proficiency_levels` → adapter over `Editor.apply_proficiency_levels/2` | 2.3 | S |
| 2.5 | Create `Library.Proficiency` with `build_prompt/1`, `resolve_tools/1` | — | S |
| 2.6 | Implement `Proficiency.start_fanout/2` (absorb LiteWorker spawn loop) | 2.5, 1.1 | M |
| 2.7 | Implement `Proficiency.start_fanout_from_table/2` | 2.6, 1.4 | S |
| 2.8 | Create `Library.Operations.save_and_generate/2` (composite) | 2.1, 2.2, 2.6 | M |
| 2.9 | Refactor `save_and_generate` tool → adapter over `Operations.save_and_generate/2` | 2.8 | M |
| 2.10 | Write tests for `Skeletons` (pure, no IO) | 2.1 | S |
| 2.11 | Write tests for `Proficiency.start_fanout/2` with flow-mode Runtime | 2.6 | M |
| 2.12 | Verify all existing tool tests pass | 2.4, 2.9 | S |

### Phase 3 — FlowLive with Shared State

| # | Task | Depends On | Est |
|---|------|-----------|-----|
| 3.1 | Define `RhoFrameworks.Flow` behaviour (`id/0`, `label/0`, `steps/0`) | — | S |
| 3.2 | Add flow state schema to `DataTableSchemas` | — | S |
| 3.3 | Build `RhoWeb.FlowComponents` (step indicator, form renderer, progress cards) | — | L |
| 3.4 | Build `RhoWeb.FlowLive` — generic step runner (mount, step dispatch, transitions) | 3.1, 3.3 | L |
| 3.5 | Implement flow state persistence (write to `flow:state` table, resume on reconnect) | 3.4, 3.2 | M |
| 3.6 | Create `RhoFrameworks.SkeletonGenerator` (single LLM call → returns rows) | — | M |
| 3.7 | Create `RhoFrameworks.Flows.CreateFramework` (step definitions with named function refs) | 3.1, all Phase 2 | M |
| 3.8 | Wire `:form` step type in FlowLive | 3.4 | M |
| 3.9 | Wire `:action` step type in FlowLive (Task.async + loading state) | 3.4 | M |
| 3.10 | Wire `:table_review` step type (mount DataTableComponent, action buttons) | 3.4 | M |
| 3.11 | Wire `:fan_out` step type (Comms subscription, progress tracking) | 3.4 | L |
| 3.12 | Add route + entry point buttons on library list page | 3.4 | S |
| 3.13 | End-to-end test: FlowLive creates a library from intake to save | 3.7 | L |

### Phase 4 — Agent-Flow Collaboration

| # | Task | Depends On | Est |
|---|------|-----------|-----|
| 4.1 | Add `:agent_delegate` step type to FlowLive | 3.4 | M |
| 4.2 | Add flow-awareness prompt section to `RhoFrameworks.Plugin` | 3.5 | M |
| 4.3 | Add "return to flow" navigation link in SessionLive | 3.5 | S |
| 4.4 | Handle real-time DataTable updates from agent in FlowLive (Comms subscription) | 3.4 | M |
| 4.5 | Edge case handling (tab close, concurrent edits, step completion by agent) | 4.1, 4.4 | M |
| 4.6 | Integration test: FlowLive delegates to agent, agent edits, flow resumes | 4.1 | L |

### Phase 5 — Roles + Generalization

| # | Task | Depends On | Est |
|---|------|-----------|-----|
| 5.1 | Create `RhoFrameworks.Roles.Editor` (mirror Library.Editor pattern) | Phase 1 | M |
| 5.2 | Refactor `RoleTools` to thin adapters | 5.1 | M |
| 5.3 | Create `RhoFrameworks.Flows.CreateRoleProfile` | 5.1, Phase 3 | M |
| 5.4 | Create `RhoFrameworks.Flows.ForkTemplate` | Phase 3 | M |
| 5.5 | Create `RhoFrameworks.Flows.CombineLibraries` | Phase 3 | L |
| 5.6 | Evaluate + document shared extraction decision | 5.1, 5.2 | S |

**Size key**: S = <2h, M = 2-4h, L = 4-8h

---

## Proving the Pattern (Phase 1 Validation)

After Phase 1, validate these properties before proceeding:

1. **Runtime carries enough context** — `from_rho_context/1` doesn't lose fields that primitives need. If `Editor.create/2` asks for something not in `Runtime`, the struct boundary is wrong.

2. **Primitives don't leak agent concerns** — No `ToolResponse`, `Effect`, or prompt-formatted error strings in the primitives layer. If they creep in, the adapter boundary is wrong.

3. **Tool adapters are genuinely thin** — Each should be ~10-15 lines: build Runtime, call primitive, wrap result. If an adapter grows fat, the primitive is missing functionality.

4. **DataTable sessions work across modes** — Call `Editor.create/2` from FlowLive with a `session_id`, then connect to the same session in chat. Agent should see the table. If not, session lifecycle needs work.

5. **Error shapes are ergonomic for both consumers** — Primitives return `{:error, :not_found}` or `{:error, {:validation, reason}}`. Tools humanize into strings. FlowLive renders into UI. If either is awkward, refine the error contract.

If all 5 hold, proceed to Phase 2. If any break, fix the abstraction before extracting more.

---

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| `Runtime` misses a field a primitive needs | Start minimal, add fields only when needed — `metadata` map as escape hatch |
| JSON strings leak past tool boundary | Convention: primitives accept native maps, JSON decode only in tool adapters |
| Effects leak into flow mode | Primitives return plain `{:ok, map()}` — `ToolResponse` only in tool adapters |
| Flow fan-out lacks parent agent id | `Runtime.lite_parent_id/1` returns synthetic `"flow:#{execution_id}"` |
| DataTable sessions break outside chat | FlowLive creates real `session_id` via `Primary.ensure_started/2` |
| Flow state lost on LiveView reconnect | Canonical state in `flow:state` DataTable, not socket assigns |
| Agent conflicts with active flow | Flow-awareness prompt section warns agent, guards against duplicate operations |
| Retry creates duplicates | Each primitive is idempotent — `ensure_table` is already idempotent, editor operations use stable IDs |
| Premature DB creation before review | `Editor.create/2` creates in draft state — final persistence via `save_table/2` only |

---

## Decision Log

| Decision | Rationale | Revisit When |
|----------|-----------|-------------|
| Primitives take `Runtime`, not `Rho.Context` | Decouples from agent infra | Never — this is the core boundary |
| Start with Library path only | Proves pattern with least risk | After Phase 2 completes |
| Named function refs in flow steps, not closures | Testable, traceable, serializable | If steps need runtime-constructed behavior |
| DataTable as shared state (not separate flow store) | Reuses existing infra, enables agent collaboration for free | If flows need state DataTable can't express |
| No generic "primitive behaviour" yet | Only one proven path — convention is enough | If Library.Editor and Roles.Editor share >50% |
| Flow state in DataTable metadata | Survives reconnect, readable by agent | If flows need cross-session persistence (then use DB) |
