# Architecture Review: First-Principles Analysis

## The Core Question

What does "implementing a feature on Rho" actually require, and where is the friction?

A feature = **Domain Logic** + **Agent Tools** + **UI Workspace** + **Signal Wiring**

Domain logic (Ecto contexts) is clean, standard Phoenix — no changes needed there. The friction lives in the other three layers: the **tool definition tax**, the **workspace registration ceremony**, and the **coupling between tools and UI**.

---

## Problem 1: The Tool Definition Tax

Every tool in `RhoFrameworks.Plugin` (1266 lines, 25+ tools) follows the same pattern:

```elixir
defp some_tool(org_id, session_id, agent_id) do
  %{
    tool: ReqLLM.tool(
      name: "some_tool",
      description: "Does something",
      parameter_schema: [
        param1: [type: :string, required: true, doc: "..."],
        param2: [type: :integer, doc: "..."]
      ],
      callback: fn _ -> :ok end
    ),
    execute: fn args ->
      p1 = args["param1"] || args[:param1]
      p2 = args["param2"] || args[:param2]
      case SomeContext.do_thing(org_id, p1, p2) do
        {:ok, result} -> {:ok, format(result)}
        {:error, reason} -> {:error, reason}
      end
    end
  }
end
```

**~40-60 lines per tool.** Of those, ~80% is boilerplate:
- `ReqLLM.tool()` wrapper with `callback: fn _ -> :ok end` (dead callback)
- `args["key"] || args[:key]` for every parameter
- `{:ok, Jason.encode!(...)}` wrapping
- Closure capture of `org_id`, `session_id`, `agent_id`

**First principle:** A tool IS a function with a schema. The definition should be ~5-10 lines.

### Proposal: `Rho.Tool` behaviour + thin macro

The DSL should be backed by an explicit behaviour. The macro handles declaration ergonomics only — runtime execution, encoding, and result handling stay in plain functions.

**Behaviour (the contract):**

```elixir
defmodule Rho.Tool do
  @callback spec() :: ReqLLM.Tool.t()
  @callback run(args :: map(), ctx :: Rho.Context.t()) :: Rho.Tool.result()
end
```

**Macro (ergonomic wrapper):**

```elixir
defmodule RhoFrameworks.Tools.LibraryTools do
  use Rho.Tool

  tool :list_libraries, "List all skill libraries in the org" do
    param :status, :string, doc: "Filter by status (draft/published/archived)"

    run fn args, ctx ->
      Library.list_libraries(ctx.organization_id, status: args[:status])
      |> Enum.map(&Map.take(&1, [:id, :name, :type, :skill_count]))
    end
  end

  tool :create_library, "Create a new mutable skill library" do
    param :name, :string, required: true, doc: "Library name"
    param :type, :string, doc: "Type: skill, psychometric, qualification"

    run fn args, ctx ->
      Library.create_library(ctx.organization_id, args[:name], type: args[:type])
    end
  end
end
```

What the macro does (keep it **shallow**):
1. Builds `ReqLLM.tool()` from the DSL (name, description, params)
2. Casts args using **declared schema keys only** (never `String.to_atom/1` on arbitrary input)
3. Exports `__tools__/1` that returns `[tool_def]` for a given context

What the macro does **NOT** do (keep at adapter boundary):
- Auto-wrap return values or call `Jason.encode!` — serialize at the transport layer
- Hide execution semantics — `run/2` is a plain function
- Inject complex runtime behavior — keep it debuggable

**Arg casting safety:** Never atomize arbitrary LLM input. Only map declared schema keys to existing atoms:

```elixir
def cast_args(raw_args, param_defs) do
  Enum.reduce_while(param_defs, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
    key = Atom.to_string(name)
    value = Map.get(raw_args, key, Map.get(raw_args, name))

    case cast_value(value, spec) do
      {:ok, casted} -> {:cont, {:ok, Map.put(acc, name, casted)}}
      {:error, reason} -> {:halt, {:error, {name, reason}}}
    end
  end)
end
```

**Impact:** Plugin.ex drops from 1266 lines to ~200. Each tool is 5-10 lines. Tools live near their domain context. Adding a tool is trivial. The behaviour ensures tools remain testable without the macro.

---

## Problem 2: The God Plugin

All 25+ tools live in `RhoFrameworks.Plugin`. This module:
- Builds all tools in `build_tools/1`
- Defines all prompt sections
- Contains all formatting helpers
- Has direct coupling to DataTable signals

**First principle:** A plugin should be an aggregator, not an implementation.

### Proposal: Plugin Composition

```elixir
defmodule RhoFrameworks.Plugin do
  @behaviour Rho.Plugin

  @impl true
  def tools(opts, context) do
    RhoFrameworks.Tools.LibraryTools.__tools__(context) ++
    RhoFrameworks.Tools.RoleTools.__tools__(context) ++
    RhoFrameworks.Tools.LensTools.__tools__(context)
  end

  @impl true
  def prompt_sections(_opts, _context) do
    [RhoFrameworks.PromptSections.skill_library_guide()]
  end
end
```

Or even simpler with a macro:

```elixir
defmodule RhoFrameworks.Plugin do
  use Rho.Plugin.Composite

  tools_from RhoFrameworks.Tools.LibraryTools
  tools_from RhoFrameworks.Tools.RoleTools
  tools_from RhoFrameworks.Tools.LensTools

  prompt_section :skill_library_guide, "..."
end
```

**Impact:** Clear separation. Library tools tested independently. Role tools tested independently. Plugin.ex is a thin aggregator.

---

## Problem 3: Tool-to-UI Coupling

Currently, tools publish directly to DataTable:

```elixir
# Inside a tool's execute function
DT.publish_schema_change(session_id, agent_id, columns)
DT.publish_replace_all(session_id, agent_id, rows)
stream_rows_progressive(session_id, agent_id, rows)
```

Every tool that wants to show data needs to know about DataTable's signal protocol, session_id, agent_id, and streaming mechanics.

**First principle:** Tools produce data. The framework routes it to the right UI surface. Tools should not know about UI components.

### Proposal: Typed Return Values via Effect Structs

Raw tuples (`{:table, ...}`, `{:workspace, ...}`) will become a god-switch as new surfaces are added. Instead, use small response + effect structs that separate content, UI intent, and transport concerns:

**Response and effect structs:**

```elixir
defmodule Rho.ToolResponse do
  defstruct text: nil, data: nil, effects: []
end

defmodule Rho.Effect.Table do
  defstruct workspace: :data_table, columns: [], rows: [], append?: false
end

defmodule Rho.Effect.OpenWorkspace do
  defstruct key: nil, surface: :overlay
end
```

**Tool usage:**

```elixir
# Instead of tools manually publishing to DataTable:
run fn args, ctx ->
  rows = Library.browse_library(ctx.organization_id, lib_id)
  %Rho.ToolResponse{
    text: "Loaded #{length(rows)} items",
    effects: [
      %Rho.Effect.OpenWorkspace{key: :data_table},
      %Rho.Effect.Table{columns: @library_columns, rows: rows}
    ]
  }
end

# Plain text stays the same:
run fn args, ctx ->
  {:ok, "Library created successfully"}
end
```

**Effect dispatch** uses pattern matching — simple and explicit:

```elixir
def dispatch_effect(%Rho.Effect.Table{} = effect, runtime), do: ...
def dispatch_effect(%Rho.Effect.OpenWorkspace{} = effect, runtime), do: ...
```

This only needs a behaviour/registry if apps must define new effect types independently (not expected initially).

**Streaming note:** A single `{:table, ...}` return is not sufficient for progressive streaming. If streaming matters, model it explicitly in effects (initial schema → chunked row appends → completion/error → cancellation).

**Impact:** Tools become pure domain functions. Zero UI coupling. A tool can return text *plus* UI effects. Each effect is independently testable. Adding a new data surface is a framework concern, not a tool concern.

---

## Problem 4: Workspace Registration Ceremony

Adding a workspace today requires touching 5+ files:

1. Create projection module (`RhoWeb.Projections.FooProjection`)
2. Create component module (`RhoWeb.FooComponent`)
3. Add to `@workspace_registry` in `SessionLive` (hardcoded map)
4. Add render clause in SessionLive template
5. Add `handle_event` clauses in SessionLive for workspace-specific events
6. Wire up in SignalRouter if workspace needs enrichment

SessionLive is 1772 lines because it absorbs every workspace's rendering and event handling.

**First principle:** A workspace should be self-contained. Define it once, the session discovers it.

### Proposal: Workspace Metadata Behaviour + LiveComponent Implementation

Don't reinvent LiveComponent with a custom `render/1` + `handle_event/3` behaviour — use the abstraction Phoenix already provides. Separate workspace metadata/registry from the rendering/event abstraction.

**Workspace metadata behaviour:**

```elixir
defmodule RhoWeb.Workspace do
  @callback key() :: atom()
  @callback label() :: String.t()
  @callback icon() :: String.t()
  @callback auto_open?() :: boolean()
  @callback default_surface() :: atom()
  @callback projection() :: module()
  @callback component() :: module()     # Points to a LiveComponent
end
```

**Workspace registration (metadata only):**

```elixir
defmodule RhoWeb.Workspaces.DataTable do
  @behaviour RhoWeb.Workspace

  def key, do: :data_table
  def label, do: "Skills Editor"
  def icon, do: "table"
  def auto_open?, do: true
  def default_surface, do: :overlay
  def projection, do: RhoWeb.Projections.DataTableProjection
  def component, do: RhoWeb.Workspaces.DataTableComponent
end
```

**LiveComponent (rendering + events — idiomatic Phoenix):**

```elixir
defmodule RhoWeb.Workspaces.DataTableComponent do
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <%!-- Full DataTable UI here — native phx-target={@myself} --%>
    """
  end

  def handle_event("cell_edit", params, socket) do
    {:noreply, DataTableProjection.apply_edit(socket, params)}
  end
end
```

SessionLive discovers workspaces via `RhoWeb.Workspace.Registry` and delegates rendering to the component:

```elixir
# In SessionLive mount:
workspaces = RhoWeb.Workspace.Registry.all()
ws_states = Map.new(workspaces, fn ws -> {ws.key(), ws.projection().init()} end)
```

```heex
<%!-- In SessionLive template — generic, not workspace-specific --%>
<%= for {key, ws_mod} <- @workspaces do %>
  <div class={ws_panel_classes(key, @shell)} id={"ws-#{key}"}>
    <.live_component module={ws_mod.component()} id={"ws-#{key}-component"}
      state={@ws_states[key]} session_id={@session_id} />
  </div>
<% end %>
```

**Registry strategy:** Prefer explicit registration (config list or compile-time `use RhoWeb.Workspace`) over runtime module scanning, which is brittle in releases and awkward in dev reload.

**State boundaries:** Keep truth clean:
- Projections own canonical workspace data
- LiveComponent owns ephemeral UI-local state only (selection, scroll, hover)
- Parent LiveView owns shell/layout state

**Impact:** SessionLive drops to ~800 lines. Adding a workspace = one metadata module + one LiveComponent. Zero changes to SessionLive.

---

## Problem 5: State Split Across Three Maps

Session state lives in three places:
- `assigns.agents` / `assigns.agent_messages` / `assigns.inflight` — SessionState projection
- `assigns.ws_states` — per-workspace projection state
- `assigns.shell` — UI chrome (open/closed, surface, pulse, unseen)

This means:
- Consistency across the three maps is manual
- SignalRouter must update all three on every signal
- Components receive pieces from different maps

**First principle:** State that changes together should live together.

### Proposal: Unified Signal Dispatch

Keep the three conceptual layers but unify the dispatch:

```elixir
# SignalRouter becomes a simple pipeline:
def route(signal, socket) do
  socket
  |> update_session_state(signal)      # Pure: SessionState.reduce
  |> update_workspace_states(signal)    # Pure: each projection.reduce
  |> update_shell(signal)               # Pure: Shell.record_activity
  |> apply_effects()                    # Impure: push_event, auto_open
end
```

The key insight: this is already roughly what happens, but it's spread across SignalRouter's `route/3` function with lots of intermediate state. Making it an explicit pipeline with each step as a pure function makes it testable and composable.

No structural change needed — just refactor SignalRouter to be a clean pipe.

---

## Problem 6: Context Threading

Tools need `organization_id`, `session_id`, `agent_id` — currently threaded through closures:

```elixir
defp build_tools(%{organization_id: org_id, session_id: sid, agent_id: aid}) do
  [some_tool(org_id, sid, aid), another_tool(org_id, sid, aid), ...]
end
```

Every tool captures these in a closure. 25 tools = 25 closures with the same captures.

**First principle:** Context is ambient. Tools shouldn't capture it — they should receive it.

### Proposal: Pass context to execute

Change the `execute` signature from `fn args -> result` to `fn args, context -> result`:

```elixir
# In Rho.Plugin:
@type tool_def :: %{
  tool: ReqLLM.Tool.t(),
  execute: (args :: map(), context :: Rho.Context.t() -> result())
}
```

Then in TurnStrategy.Direct, when executing tools:

```elixir
# Before (current):
tool.execute.(args)

# After:
tool.execute.(args, runtime.context)
```

**Impact:** No more closure captures. Tools are stateless functions. `Rho.Context` already carries organization_id, session_id, agent_id.

---

## Priority Order

Based on impact vs. effort, **reordered to stabilize runtime contracts before adding abstractions:**

| # | Change | Impact | Effort | Where | Rationale |
|---|--------|--------|--------|-------|-----------|
| 1 | Pass context to execute | High | Low | `apps/rho` (TurnStrategy) | Clean, low-risk contract fix |
| 2 | Schema-driven arg casting | High | Low | `apps/rho` (TurnStrategy) | Replace unsafe atom normalization with declared-key-only casting |
| 3 | Split Plugin.ex into tool modules | Very High | Medium | `apps/rho_frameworks` | Immediate maintainability win; reduces blast radius; creates migration units |
| 4 | SignalRouter → reducers + effects | Medium | Low | `apps/rho_web` | Creates the seam needed for typed UI results and workspace decoupling |
| 5 | `Rho.Tool` behaviour + macro DSL | Very High | Medium | `apps/rho` (new module) | Safer once runtime contract is stable; migrate one tool family first |
| 6 | Typed return values (effect structs) | High | Medium | `apps/rho` + `apps/rho_web` | Better after dispatch/effects boundary exists |
| 7 | Workspace metadata + LiveComponent | Very High | Medium | `apps/rho_web` | Most invasive; easier once routing is cleaner |

**Key reordering rationale:**
- **Plugin splitting moved earlier:** valuable even without the DSL — it reduces blast radius and creates independent migration/testing units.
- **SignalRouter refactor moved earlier:** typed returns and workspace decoupling are easier when you already have a clean "pure state updates + impure effects" boundary.
- **DSL moved later:** defining the runtime contract first avoids encoding current quirks into generated code.

**Pilot candidate:** Migrate `LibraryTools` + DataTable workspace + one typed table effect + one LiveComponent first — a full vertical slice without touching every tool.

---

## What This Unlocks

After these changes, adding a new domain feature (say, "Interview Scheduling") would look like:

```
1. Write Ecto schemas + context        (standard Phoenix, no changes)
2. Write tool module:                   (5-10 lines per tool via Rho.Tool macro)
   defmodule Interviews.Tools do
     use Rho.Tool
     tool :schedule_interview, "..." do
       param :candidate_id, :string, required: true
       run fn args, ctx -> Interviews.schedule(ctx.organization_id, args) end
     end
   end
3. Add to plugin:                       (1 line)
   tools_from Interviews.Tools
4. Add workspace (if needed):           (1 module, self-contained)
   defmodule InterviewWorkspace do
     use RhoWeb.Workspace
     # key, label, projection, render — all in one place
   end
```

vs. today:

```
1. Write Ecto schemas + context        (same)
2. Write 40-60 lines per tool in Plugin.ex
3. Thread org_id/session_id through closures
4. Manually publish to DataTable
5. Add workspace registry entry in SessionLive
6. Add render clause in SessionLive template
7. Add handle_event clauses in SessionLive
8. Wire up SignalRouter
```

---

## Migration Strategy

Support both old and new tool result paths during migration — never big-bang.

**Dual-support adapter:**

```elixir
def handle_tool_result(result, runtime) do
  case result do
    %Rho.ToolResponse{} -> dispatch_effects(result.effects, runtime)
    {:ok, text} when is_binary(text) -> legacy_text_result(text)
    {:error, reason} -> legacy_error_result(reason)
  end
end
```

**Tool name stability:** For agent systems, tool name/description/schema stability matters — renaming or reshaping tools degrades tool selection quality. Keep existing tool names stable and snapshot generated schemas in tests.

**Migration order:** Migrate one domain at a time (e.g., LibraryTools first), validate end-to-end, then proceed.

---

## Testing Strategy

Tests are needed at four levels:

### 1. Contract tests for `Rho.Tool`
- Generated `ReqLLM.tool()` schema matches expected shape
- Arg casting: required field errors, type coercion, unknown key rejection
- Tool names are stable (snapshot tests)

### 2. Unit tests for tool modules
- `run/2` happy path and error path with mock context
- Permission/context-sensitive behavior

### 3. Reducer/effect tests
- `SessionState.reduce/2` produces correct state
- Workspace projections update correctly
- Shell state transitions
- Effect emission from `Rho.ToolResponse`

### 4. LiveView integration tests
- Workspace registration and discovery via registry
- Event routing to the correct LiveComponent
- Typed table/workspace effects actually render correctly

---

## Observability

Add telemetry instrumentation around:

- **Tool execution:** duration, success/failure, arg validation failures
- **Effect dispatch:** effect type emitted, dispatch failures
- **Signal routing:** reducer latency, workspace projection errors
- **Workspace lifecycle:** registration, mount, unmount

---

## Guardrails

1. Never atomize arbitrary tool args — only cast declared schema keys
2. No auto-JSON encoding inside tool DSL — serialize at adapter boundary
3. Keep old and new tool result paths working during migration
4. Stabilize tool schemas/names with snapshot tests
5. Pilot on one tool family + one workspace first (LibraryTools + DataTable)
6. Instrument execution and dispatch before broad migration
