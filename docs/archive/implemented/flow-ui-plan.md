# Flow UI Plan — Structured Framework Creation

## Problem

The spreadsheet agent burns 10-20 structured turns (Haiku) to orchestrate what is fundamentally a linear pipeline: collect inputs → generate skeleton → review → generate proficiency → save. Most turns are form-wizard behavior (asking questions, presenting options, waiting for approval) that doesn't need LLM intelligence.

## Design Principle

**Split interactive orchestration from generative work.** The LiveView handles the linear progression (forms, buttons, table review). LLM calls happen only for genuinely generative steps (skeleton creation, proficiency writing). Everything else is direct function calls to existing `Library.*` / `Roles.*` context functions.

---

## Architecture

```
FlowLive (generic LiveView)
  │
  ├── renders current step from flow definition
  ├── on form submit → calls step function → advances
  ├── on table action → calls step function → advances
  │
  ├── uses existing DataTable infra for review steps
  ├── uses existing LiteWorker for proficiency fan-out
  └── uses Comms signal bus for progress updates
```

### Two layers

1. **Flow definition** — a list of step descriptors. Pure data, no processes.
2. **FlowLive** — generic LiveView that interprets any flow definition.

### Step types

| Type | Rendered as | Advances when | LLM? |
|------|-------------|---------------|------|
| `:form` | Form fields | User submits | No |
| `:select` | Cards/checkboxes from a data source | User picks + continues | No |
| `:action` | Loading spinner | Function returns | Maybe (1 call) |
| `:table_review` | DataTableComponent | User clicks action button | No |
| `:fan_out` | Progress cards | All tasks complete | Yes (N calls) |

---

## Flow Definition Shape

```elixir
defmodule RhoFrameworks.Flows.CreateFramework do
  @behaviour RhoFrameworks.Flow

  @impl true
  def id, do: :create_framework

  @impl true
  def label, do: "Create Skill Framework"

  @impl true
  def steps do
    [
      # Step 1: Collect basic info
      %{
        id: :intake,
        type: :form,
        title: "New Framework",
        fields: [
          %{key: :name, type: :text, label: "Framework name", required: true},
          %{key: :description, type: :textarea, label: "Description"},
          %{key: :domain, type: :text, label: "Domain / industry",
            placeholder: "e.g. Software Engineering, Hospitality, Healthcare"},
          %{key: :target_roles, type: :tags, label: "Target roles",
            placeholder: "e.g. Backend Engineer, Data Scientist"},
          %{key: :skill_count, type: :range, label: "Number of skills",
            min: 6, max: 20, default: 10},
          %{key: :levels, type: :select, label: "Proficiency levels",
            options: [{2, "2 levels"}, {3, "3"}, {4, "4"}, {5, "5 (Dreyfus)"}],
            default: 5}
        ]
      },

      # Step 2: Find similar existing roles (optional enrichment)
      %{
        id: :similar_roles,
        type: :select,
        title: "Similar Roles",
        subtitle: "Select roles to draw inspiration from (optional)",
        load: fn params, ctx ->
          # Combine domain + target_roles into a search query
          query = "#{params.domain} #{Enum.join(params.target_roles || [], " ")}"
          case Roles.find_similar_roles(ctx.organization_id, query) do
            [] -> {:skip, "No similar roles found — continuing to generation."}
            roles -> {:ok, roles}
          end
        end,
        display: fn role -> %{
          title: role.name,
          subtitle: role.role_family,
          detail: "#{role.skill_count} skills"
        } end,
        result_key: :selected_roles,
        skippable: true
      },

      # Step 3: Create library in DB (instant, no UI)
      %{
        id: :create_library,
        type: :action,
        run: fn params, ctx ->
          case Library.create_library(ctx.organization_id, %{
            name: params.name,
            description: params.description || ""
          }) do
            {:ok, lib} ->
              table_name = "library:#{lib.name}"
              :ok = DataTable.ensure_table(ctx.session_id, table_name,
                DataTableSchemas.library_schema())
              {:ok, %{library: lib, table_name: table_name}}
            {:error, cs} ->
              {:error, "Failed: #{inspect(cs.errors)}"}
          end
        end
      },

      # Step 4: Generate skeleton (single LLM call)
      %{
        id: :generate_skeleton,
        type: :action,
        title: "Generating skill skeleton...",
        run: fn params, ctx ->
          RhoFrameworks.SkeletonGenerator.generate(
            name: params.name,
            domain: params.domain,
            target_roles: params.target_roles,
            skill_count: params.skill_count,
            selected_roles: params[:selected_roles],
            session_id: ctx.session_id,
            table_name: params.table_name
          )
        end
      },

      # Step 5: User reviews/edits skeleton in data table
      %{
        id: :review_skeleton,
        type: :table_review,
        title: "Review Skeleton",
        subtitle: "Edit skills, categories, and clusters. Then choose an action.",
        schema: :skill_library,
        actions: [
          %{label: "Generate Proficiency Levels", target: :generate_proficiency,
            style: :primary},
          %{label: "Save as-is", target: :save, style: :secondary}
        ]
      },

      # Step 6: Fan out proficiency generation
      %{
        id: :generate_proficiency,
        type: :fan_out,
        title: "Generating proficiency levels...",
        run: fn params, ctx ->
          # Read current rows from data table (user may have edited)
          rows = DataTable.get_rows(ctx.session_id, table: params.table_name)
          by_category = Enum.group_by(rows, & &1[:category])

          # Spawn LiteWorkers — reuse existing infra exactly
          tasks = Enum.map(by_category, fn {category, cat_skills} ->
            %{
              label: "#{category} (#{length(cat_skills)} skills)",
              run: fn ->
                LibraryTools.spawn_proficiency_writer(
                  category, cat_skills, params.levels,
                  params.table_name, ctx
                )
              end
            }
          end)

          {:ok, tasks}
        end
      },

      # Step 7: Save to library
      %{
        id: :save,
        type: :action,
        run: fn params, ctx ->
          Library.save_to_library(
            ctx.organization_id,
            params.library.id,
            ctx.session_id,
            table: params.table_name
          )
        end
      }
    ]
  end
end
```

---

## Other Flow Definitions

### Fork from Template

```elixir
defmodule RhoFrameworks.Flows.ForkTemplate do
  @behaviour RhoFrameworks.Flow

  def id, do: :fork_template
  def label, do: "Start from Template"

  def steps do
    [
      %{id: :pick_template, type: :form, title: "Choose Template",
        fields: [
          %{key: :source_key, type: :select, label: "Template",
            options: {Library, :list_template_keys, []}, required: true},
          %{key: :name, type: :text, label: "Your framework name", required: true}
        ]},
      %{id: :load_and_fork, type: :action,
        run: fn params, ctx ->
          # Load template → fork in one step
          with {:ok, %{library: template}} <-
                 Library.load_template(ctx.organization_id, params.source_key, ...),
               {:ok, %{library: forked}} <-
                 Library.fork_library(ctx.organization_id, template.id, params.name) do
            # Load into data table
            rows = Library.load_library_rows(forked.id)
            table_name = "library:#{forked.name}"
            :ok = DataTable.ensure_table(ctx.session_id, table_name,
              DataTableSchemas.library_schema())
            :ok = DataTable.replace_all(ctx.session_id, rows, table: table_name)
            {:ok, %{library: forked, table_name: table_name}}
          end
        end},
      %{id: :edit, type: :table_review, schema: :skill_library,
        actions: [
          %{label: "Generate Proficiency Levels", target: :proficiency},
          %{label: "Save", target: :save}
        ]},
      # Reuse same fan_out and save steps...
    ]
  end
end
```

### Combine Libraries

```elixir
defmodule RhoFrameworks.Flows.CombineLibraries do
  @behaviour RhoFrameworks.Flow

  def id, do: :combine_libraries
  def label, do: "Combine Libraries"

  def steps do
    [
      %{id: :pick_sources, type: :form, title: "Combine Libraries",
        fields: [
          %{key: :source_ids, type: :multi_select, label: "Libraries to combine",
            options: {Library, :list_libraries, []}, min: 2, required: true},
          %{key: :name, type: :text, label: "Combined framework name", required: true}
        ]},
      %{id: :preview, type: :action,
        run: fn params, ctx ->
          Library.combine_preview(ctx.organization_id, params.source_ids)
        end},
      # If conflicts → table_review with :combine_conflicts schema
      # If no conflicts → skip straight to commit
      %{id: :resolve_conflicts, type: :table_review, schema: :combine_conflicts,
        condition: fn params -> params.conflicts != [] end,
        actions: [%{label: "Commit", target: :commit}]},
      %{id: :commit, type: :action,
        run: fn params, ctx ->
          Library.combine_commit(ctx.organization_id, params)
        end}
    ]
  end
end
```

### New Role Profile

```elixir
defmodule RhoFrameworks.Flows.CreateRoleProfile do
  @behaviour RhoFrameworks.Flow

  def id, do: :create_role_profile
  def label, do: "Create Role Profile"

  def steps do
    [
      %{id: :intake, type: :form, title: "New Role Profile",
        fields: [
          %{key: :library_id, type: :select, label: "Skill Library",
            options: {Library, :list_libraries, []}, required: true},
          %{key: :name, type: :text, label: "Role name", required: true},
          %{key: :role_family, type: :text, label: "Role family"},
          %{key: :seniority_level, type: :select, label: "Seniority",
            options: [{1,"Junior"},{2,"Mid"},{3,"Senior"},{4,"Staff"},{5,"Principal"}]}
        ]},
      %{id: :pick_skills, type: :select, title: "Select Skills",
        load: fn params, _ctx ->
          skills = Library.browse_library(params.library_id)
          {:ok, skills}
        end,
        display: fn skill -> %{title: skill.name, subtitle: skill.category} end,
        group_by: :category,
        result_key: :selected_skills},
      %{id: :set_levels, type: :table_review, schema: :role_profile,
        title: "Set Required Levels",
        setup: fn params, ctx ->
          # Load selected skills into role_profile table
          rows = Enum.map(params.selected_skills, fn s ->
            %{category: s.category, cluster: s.cluster,
              skill_name: s.name, required_level: 3, required: true}
          end)
          :ok = DataTable.ensure_table(ctx.session_id, "role_profile",
            DataTableSchemas.role_profile_schema())
          :ok = DataTable.replace_all(ctx.session_id, rows, table: "role_profile")
        end,
        actions: [%{label: "Save Role Profile", target: :save}]},
      %{id: :save, type: :action,
        run: fn params, ctx ->
          rows = DataTable.get_rows(ctx.session_id, table: "role_profile")
          Roles.save_role_profile(ctx.organization_id,
            %{name: params.name, role_family: params.role_family,
              seniority_level: params.seniority_level},
            rows, library_id: params.library_id)
        end}
    ]
  end
end
```

---

## Reuse Map

### Existing functions called directly (no wrapper needed)

| Function | Used by flow step |
|----------|------------------|
| `Library.create_library/2` | create_framework :create_library |
| `Library.fork_library/3` | fork_template :load_and_fork |
| `Library.load_template/3` | fork_template :load_and_fork |
| `Library.save_to_library/4` | all library flows :save |
| `Library.combine_preview/2` | combine :preview |
| `Library.combine_commit/2` | combine :commit |
| `Library.browse_library/2` | role profile :pick_skills |
| `Library.list_libraries/2` | form field options |
| `Roles.find_similar_roles/2` | create_framework :similar_roles |
| `Roles.save_role_profile/4` | role profile :save |
| `DataTable.ensure_table/3` | multiple steps |
| `DataTable.replace_all/3` | loading rows into table |
| `DataTable.get_rows/2` | reading back edited rows |

### Existing infra reused as-is

| Component | How it's reused |
|-----------|----------------|
| `DataTableComponent` | Rendered inside `:table_review` steps |
| `DataTable.Server` | Session state for in-flight edits |
| `LiteWorker` | Proficiency fan-out (`:fan_out` step spawns them) |
| `Rho.Comms` | Progress events from LiteWorkers → FlowLive |
| `EffectDispatcher` | NOT used — FlowLive writes to DataTable directly |
| `DataTableSchemas` | Schema selection for table steps |
| Web schemas (`RhoWeb.DataTable.Schemas`) | DataTableComponent rendering |

### New code needed

| Module | Purpose | Size estimate |
|--------|---------|--------------|
| `RhoFrameworks.Flow` | Behaviour: `id/0`, `label/0`, `steps/0` | ~15 lines |
| `RhoFrameworks.SkeletonGenerator` | Single LLM call to generate skeleton | ~80 lines |
| `RhoWeb.FlowLive` | Generic flow runner LiveView | ~200 lines |
| `RhoWeb.FlowComponents` | Form renderer, card selector, progress cards | ~250 lines |
| `RhoFrameworks.Flows.CreateFramework` | Flow definition | ~80 lines |
| `RhoFrameworks.Flows.ForkTemplate` | Flow definition | ~40 lines |
| `RhoFrameworks.Flows.CombineLibraries` | Flow definition | ~50 lines |
| `RhoFrameworks.Flows.CreateRoleProfile` | Flow definition | ~60 lines |
| Extract `LibraryTools.spawn_proficiency_writer/5` | Public function from private tool code | ~20 lines refactor |

**Total new code: ~800 lines** (half is flow definitions which are mostly config)

---

## FlowLive Design

### Assigns

```elixir
%{
  flow_module: RhoFrameworks.Flows.CreateFramework,
  steps: [...],              # from flow_module.steps()
  current_step_index: 0,
  params: %{},               # accumulated across steps
  ctx: %{organization_id: ..., session_id: ..., user_id: ...},
  step_state: :idle | :loading | :error,
  step_error: nil,
  # For :fan_out steps
  tasks: [],                 # [{label, status, agent_id}]
  # For :select steps
  options: [],
  selected: MapSet.new()
}
```

### Lifecycle

```
mount(flow_id) → resolve flow_module → render step[0]
  │
  ├── :form step
  │     render fields → "submit" event → validate → merge into params → advance
  │
  ├── :select step
  │     call load/2 → render cards → "toggle"/"continue" events → merge → advance
  │     load returns {:skip, reason} → show flash, auto-advance
  │
  ├── :action step
  │     show spinner → Task.async(run/2) → handle_info({ref, result}) → merge → advance
  │     on error → show error, offer retry
  │
  ├── :table_review step
  │     init DataTable → render DataTableComponent + action buttons
  │     action button click → advance to target step (may skip ahead)
  │
  └── :fan_out step
        call run/2 → get task list → spawn each → subscribe to Comms
        show progress cards (label + status per task)
        all :done → advance
```

### DataTable integration

For `:table_review` steps, FlowLive needs to:
1. Ensure DataTable server is started for the session
2. Render `DataTableComponent` pointing at the right table name + schema
3. Subscribe to `rho.session.<sid>.events.data_table` for live updates
4. The component already handles inline editing, sorting, grouping

This is the same thing SessionLive does today — we just mount the component in a different context.

### Signal subscriptions (for fan_out)

```elixir
# On entering fan_out step:
Rho.Comms.subscribe("rho.session.#{session_id}.events.lite_done")

# handle_info for completion:
def handle_info(%{type: "rho.lite.done", data: %{agent_id: aid, result: result}}, socket) do
  tasks = update_task_status(socket.assigns.tasks, aid, :done)
  if all_done?(tasks), do: advance(socket), else: {:noreply, assign(socket, tasks: tasks)}
end
```

---

## SkeletonGenerator — The One LLM Call

```elixir
defmodule RhoFrameworks.SkeletonGenerator do
  @moduledoc """
  Generates a skill framework skeleton from intake parameters.
  Single LLM call — no agent loop.
  """

  @doc """
  Returns {:ok, rows} where rows are ready for DataTable.add_rows/3.
  Uses whatever model is configured for the spreadsheet agent.
  """
  def generate(opts) do
    prompt = build_prompt(opts)
    model = agent_model(:spreadsheet)

    # Use ReqLLM directly — structured output if supported, else parse JSON from text
    case ReqLLM.chat(model, messages: [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: prompt}
    ]) do
      {:ok, %{choices: [%{message: %{content: text}}]}} ->
        parse_skeleton(text, opts)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(opts) do
    similar_context = format_similar_roles(opts[:selected_roles])

    """
    Create a skill framework skeleton for: #{opts[:name]}
    Domain: #{opts[:domain] || "general"}
    Target roles: #{Enum.join(opts[:target_roles] || [], ", ")}
    Number of skills: #{opts[:skill_count] || 10}

    #{similar_context}

    Return a JSON array of skills. Each skill has:
    - category (3-6 MECE categories)
    - cluster (1-3 per category)
    - skill_name (concise, reusable name)
    - skill_description (1 sentence defining the competency boundary)

    Return ONLY the JSON array, no other text.
    """
  end

  defp parse_skeleton(text, opts) do
    # Extract JSON from response (handle code blocks, preamble, etc.)
    with {:ok, skills} <- extract_json_array(text) do
      rows = Enum.map(skills, fn s ->
        %{
          category: s["category"] || "",
          cluster: s["cluster"] || "",
          skill_name: s["skill_name"] || "",
          skill_description: s["skill_description"] || "",
          proficiency_levels: []
        }
      end)

      # Write to data table
      :ok = DataTable.add_rows(opts[:session_id], rows, table: opts[:table_name])
      {:ok, %{rows: rows, count: length(rows)}}
    end
  end
end
```

---

## UI Layout

### Flow page layout

```
┌─────────────────────────────────────────────────────┐
│  ← Back to Libraries    Create Skill Framework      │
│                                                     │
│  ┌─ Step indicator ──────────────────────────────┐  │
│  │  ● Intake  ○ Similar  ○ Generate  ○ Review    │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ Current step ────────────────────────────────┐  │
│  │                                               │  │
│  │  (form / cards / spinner / data table)        │  │
│  │                                               │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ Actions ─────────────────────────────────────┐  │
│  │           [Back]              [Continue →]     │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### For table_review steps, the data table fills the main area:

```
┌─────────────────────────────────────────────────────┐
│  ← Back to Libraries    Create Skill Framework      │
│  ● Intake  ● Similar  ● Generate  ● Review          │
│                                                     │
│  ┌─ DataTableComponent ─────────────────────────┐  │
│  │  Category: Technical                          │  │
│  │    Cluster: Data Engineering                  │  │
│  │      SQL          | Ability to write and...   │  │
│  │      Python       | Proficiency in...         │  │
│  │    Cluster: Infrastructure                    │  │
│  │      Kubernetes   | Container orchestr...     │  │
│  │  Category: Leadership                         │  │
│  │    ...                                        │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  [← Back]  [Save as-is]  [Generate Proficiency →]   │
└─────────────────────────────────────────────────────┘
```

### For fan_out steps:

```
┌─────────────────────────────────────────────────────┐
│  Generating proficiency levels...                   │
│                                                     │
│  ┌─ Technical (4 skills) ────── ✓ Complete ─────┐  │
│  ┌─ Leadership (3 skills) ───── ◌ Running... ───┐  │
│  ┌─ Domain (5 skills) ────────── ◌ Running... ──┐  │
│                                                     │
│  3 of 3 categories  [█████████░░░] 67%              │
└─────────────────────────────────────────────────────┘
```

---

## Entry Points

### From existing library list page

Add action buttons to `SkillLibraryShowLive` or the library index:

```
[+ Create Framework]  [Import Template]  [Combine Libraries]
```

Each navigates to `/orgs/:slug/flows/:flow_id`.

### Route

```elixir
live "/orgs/:slug/flows/:flow_id", FlowLive, :run
```

FlowLive resolves flow_id to a module:
```elixir
@flows %{
  "create-framework" => RhoFrameworks.Flows.CreateFramework,
  "fork-template" => RhoFrameworks.Flows.ForkTemplate,
  "combine" => RhoFrameworks.Flows.CombineLibraries,
  "role-profile" => RhoFrameworks.Flows.CreateRoleProfile
}
```

---

## Escape to Agent

If the user needs flexibility mid-flow (e.g., "actually merge these two categories"), the flow has a session_id and DataTable already running. Two options:

1. **Link to chat**: "Need more control? [Open in agent chat →]" navigates to `/session/:session_id` where the spreadsheet agent sees the same data table.
2. **Inline mini-chat**: A collapsible chat panel within FlowLive that sends messages to the spreadsheet agent. Heavier to build but seamless.

Recommend option 1 for v1 — it's zero additional code since SessionLive already handles this.

---

## Implementation Order

1. **`RhoFrameworks.Flow` behaviour** — the contract
2. **`RhoWeb.FlowComponents`** — form renderer, card selector, step indicator, progress cards
3. **`RhoWeb.FlowLive`** — generic runner
4. **`RhoFrameworks.Flows.CreateFramework`** — first flow definition
5. **`RhoFrameworks.SkeletonGenerator`** — single LLM call for skeleton
6. **Extract `spawn_proficiency_writer/5`** from LibraryTools into a public function
7. **Route + entry point buttons** in library list page
8. **Remaining flow definitions** (ForkTemplate, CombineLibraries, CreateRoleProfile)

Steps 1-6 are the MVP. Steps 7-8 extend coverage.

---

## Token Savings Estimate

| Flow | Agent turns (before) | LLM calls (after) | Savings |
|------|---------------------|-------------------|---------|
| Create framework | ~15-20 Haiku turns | 1 skeleton + N proficiency writers | ~80% |
| Fork template | ~5-8 turns | 0 (pure data) | 100% |
| Combine libraries | ~8-12 turns | 0 (pure data) | 100% |
| Create role profile | ~8-10 turns | 0 (pure data) | 100% |

The agent remains for: doc import (needs LLM extraction), consolidation (needs judgment), ad-hoc edits, and anything the user can't express through forms.
