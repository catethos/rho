# Rho — Developer Context

## Project Overview

Rho is an Elixir-based AI agent framework structured as an **umbrella** with five apps. Agents are configured with plugins (tools, prompt sections, bindings), transformers (in-flight mutation + policy), tapes (append-only event history), skills, sandbox support, and signal-based multi-agent coordination.

## Umbrella Structure

```
rho/
├── apps/
│   ├── rho/              # Core agent runtime kernel (ZERO Phoenix/Ecto deps), mix tasks, .rho.exs loader
│   ├── rho_stdlib/        # Built-in tools & plugins
│   ├── rho_baml/          # BAML-driven structured-output helpers
│   ├── rho_web/           # Phoenix endpoint, LiveViews
│   └── rho_frameworks/    # Ecto/Postgres (pgvector) skill-assessment domain
├── config/
│   ├── config.exs
│   └── runtime.exs
└── mix.exs               # Umbrella root
```

## Three-Plane Architecture

- **Execution plane** — `Rho.Runner`, `Rho.TurnStrategy`, tapes, plugins, transformers. Core LLM reasoning loop. Lives in `apps/rho/`.
- **Coordination plane** — Event bus (`Rho.Events`), agent registry, multi-agent plugin. Lives in `apps/rho/` (bus) and `apps/rho_stdlib/` (multi-agent plugin).
- **Edge plane** — web (`apps/rho_web/`) and mix tasks (`apps/rho/lib/mix/tasks/`) adapters.

## App Boundaries

### `apps/rho/` — Core Runtime Kernel

No Phoenix or Ecto deps. Deps: `req_llm`, `jido_signal`, `jason`, `nimble_options`, `dotenvy`.

Key modules:
- `Rho.Session` — programmatic session API (single entry point for mix tasks, web, tests)
- `Rho.AgentConfig` — `.rho.exs` loader; normalizes legacy keys and exposes per-agent config queries
- `Rho.RunSpec` / `Rho.RunSpec.FromConfig` — explicit agent configuration struct (built from `AgentConfig`)
- `Rho.Runner` — outer agent loop (step budget, compaction, tape recording)
- `Rho.Runner.Runtime` — immutable run config struct (inlined in runner.ex)
- `Rho.Runner.TapeConfig` — tape configuration struct (inlined in runner.ex)
- `Rho.Recorder` — unified tape recording for the agent loop
- `Rho.ToolExecutor` — shared tool dispatch (transformer pipeline, timeout, normalization)
- `Rho.TurnStrategy` — behaviour for inner turn (LLM call, response classification)
- `Rho.TurnStrategy.Direct` / `Rho.TurnStrategy.TypedStructured` — implementations
- `Rho.ActionSchema` — tagged union builder for TypedStructured
- `Rho.SchemaCoerce` — schema-guided type coercion engine
- `Rho.Plugin` / `Rho.PluginInstance` / `Rho.PluginRegistry` — plugin system
- `Rho.Transformer` / `Rho.TransformerInstance` / `Rho.TransformerRegistry` — transformer pipeline
- `Rho.Context` — ambient state struct for plugin/transformer callbacks
- `Rho.PromptSection` — structured prompt section struct
- `Rho.Tape.*` — append-only event history
- `Rho.Agent.*` — Worker, Registry, Primary, Supervisor, EventLog
- `Rho.Events` / `Rho.Events.Event` — PubSub-based event bus (session + lifecycle topics)
- `Rho.Config` — core config (tape_module, agent_config, etc.)
- `Mix.Tasks.Rho.{Run,Trace,Smoke,Verify}` — mix tasks (run an agent, trace a tape, smoke-test, verify config)

### `apps/rho_stdlib/` — Built-in Tools & Plugins

Deps: `rho` (in_umbrella), `floki`, `erlang_python`, `xlsxir`, `live_render`, `yaml_elixir`.

Module namespaces:
- `Rho.Stdlib` — plugin module map and `resolve_plugin/1`
- `Rho.Stdlib.Tools.*` — Bash, FsRead/FsWrite/FsEdit (in fs.ex), WebFetch, Python, Sandbox, PathUtils, Finish, EndTurn, Anchor/SearchHistory/RecallContext/ClearMemory (in tape_tools.ex)
- `Rho.Stdlib.Plugins.*` — MultiAgent, StepBudget, LiveRender, PyAgent, Spreadsheet, DocIngest, Tape, Control, DataTable
- `Rho.Stdlib.DataTable` — client API for the per-session data table server (synchronous row ops, named tables). Callers pass `table: "name"` in opts; default is `"main"`. Entry points: `ensure_started/1`, `ensure_table/4`, `add_rows/3`, `get_rows/2`, `update_cells/3`, `replace_all/3`, `delete_rows/3`, `delete_by_filter/3`, `query_rows/2`, `get_table_snapshot/2`, `list_tables/1`, `summarize_table/2`, `set_active_table/2`, `get_active_table/1`, `set_selection/3`, `get_selection/2`, `clear_selection/2`.
- `Rho.Stdlib.DataTable.Server` — per-session `GenServer` that owns table state and publishes coarse invalidation events via `Rho.Events`. Uses `restart: :temporary` — a crashed server stays down with `{:error, :not_running}` returned to callers rather than silently restarting empty. Also tracks an `active_table` (user-visible focus) and per-table row `selections` (user's explicit checkbox picks, auto-pruned on row mutation) for `prompt_sections/2`.
- `Rho.Stdlib.DataTable.Schema` / `Rho.Stdlib.DataTable.Schema.Column` / `Rho.Stdlib.DataTable.Table` — pure data structs
- `Rho.Stdlib.DataTable.SessionJanitor` — listens for `rho.agent.stopped` and stops the matching server
- `Rho.Stdlib.DataTable.ActiveViewListener` — bridges LiveView-emitted `:view_focus` and `:row_selection` events into `DataTable.set_active_table/2` and `DataTable.set_selection/3` so the DataTable plugin's `prompt_sections/2` knows which table the user is looking at and which rows the user has selected.
- `Rho.Stdlib.Skill` / `Rho.Stdlib.Skill.Plugin` / `Rho.Stdlib.Skill.Loader`

#### Named tables

A single session can have multiple named data tables side-by-side. `"main"` is created eagerly with a permissive (dynamic) schema and accepts arbitrary LLM-generated fields. Domain tools declare strict schemas and opt in to named tables by calling `Rho.Stdlib.DataTable.ensure_table(session_id, "library", library_schema())` before writing rows. Example pattern (see `RhoFrameworks.Tools.LibraryTools.load_library`):

```elixir
:ok = DataTable.ensure_table(ctx.session_id, "library", DataTableSchemas.library_schema())
# return %Rho.Effect.Table{table_name: "library", schema_key: :skill_library, rows: rows}
# — EffectDispatcher writes rows to the "library" table and auto-switches the LV tab.
```

Agent-facing plugin tools (`get_table`, `add_rows`, `update_cells`, …) take an optional `table:` param that defaults to `"main"`. Agents that load a named table must pass `table:` on subsequent ops — there is no auto-tracking of "active" table server-side. The `:spreadsheet` agent's system prompt documents the per-path convention (`table: "library"` after `load_library`, `table: "role_profile"` after `load_role_profile` / `clone_role_skills` / `start_role_profile_draft`).

### `apps/rho_baml/` — BAML Structured-Output Library

Pure library — no application, no `priv/`, no supervision tree. Provides BAML-backed structured LLM calls for both static (compile-time) and dynamic (runtime) schemas.

Deps: `baml_elixir ~> 1.0.0-pre.27`, `zoi ~> 0.17`. No `in_umbrella` deps.

Key modules:
- `RhoBaml` — top-level helpers; `baml_path/1` resolves an OTP app's `priv/baml_src` via `:code.priv_dir/1`
- `RhoBaml.SchemaCompiler` — Zoi schema → BAML class string conversion. Handles primitives (`string`, `int`, `float`, `bool`), `array`, optional fields (`type?`), `@description("...")`, and nested struct/map types (emitted as separate classes). Also builds full `function ... -> Class` bodies via `build_function_baml/6`.
- `RhoBaml.Function` — `use` hook for static LLM function modules. A `__before_compile__` macro reads `@schema` (Zoi) and `@prompt`, writes `<consumer_app>/priv/baml_src/functions/<name>.baml` at compile time, and defines `call/2` + `stream/3` that delegate to `BamlElixir.Client.call/3` / `.sync_stream/4`. Supports `:llm_client` and `:collectors` overrides per call. Used by `RhoFrameworks.LLM.{RankRoles, ScoreLens, SemanticDuplicates}`.
- `RhoBaml.SchemaWriter` — runtime tool_defs → `.baml` file generation for `Rho.TurnStrategy.TypedStructured`. Emits a **discriminated union** of per-tool action classes (`RespondAction`, `ThinkAction`, plus one `<ToolName>Action` per visible tool). Each variant declares a literal `tool "<name>"` discriminant, only its own params (required-vs-optional preserved), and `thinking string?`. The `AgentTurn` function returns the union, so the LLM emits only the picked variant's fields — no `null` padding. `write!/3` accepts a `:model` option in `"provider:model_id"` format and generates a matching dynamic `client.baml` from a built-in provider map (openrouter, anthropic, openai, fireworks_ai, groq, google).

#### App ownership of BAML schemas

`rho_baml` owns no `.baml` files itself. Each consumer app keeps its own BAML tree:

- `apps/rho_frameworks/priv/baml_src/clients/` — hand-written client configs (OpenRouter, Anthropic)
- `apps/rho_frameworks/priv/baml_src/functions/` — generated by `RhoBaml.Function` at compile time
- `apps/rho/priv/baml_src/clients/` — own copy of client configs (duplicated, ~5 lines each)
- `apps/rho/priv/baml_src/dynamic/` — `action.baml` + `client.baml` written at runtime by `SchemaWriter` per TypedStructured turn

Adding a new static LLM function = add a module to a consumer app, not to `rho_baml`.

### `apps/rho_web/` — Phoenix Web Application

Deps: `rho`, `rho_stdlib`, `rho_frameworks` (in_umbrella), `phoenix`, `phoenix_live_view`, `bandit`.

- `RhoWeb.*` — endpoint, router, LiveViews, components
- `RhoWeb.Application` — starts PubSub, Endpoint

### `apps/rho_frameworks/` — Skill Assessment Domain

Deps: `rho`, `rho_stdlib` (in_umbrella), `ecto_sql`, `postgrex`, `pgvector`, `phoenix_ecto`, `bcrypt_elixir`.

- `RhoFrameworks.Repo` — Ecto Postgres repo (pgvector enabled)
- `RhoFrameworks.Accounts` / `.Accounts.User` / `.Accounts.UserToken`
- `RhoFrameworks.Frameworks` / `.Frameworks.Framework` / `.Frameworks.Skill`
- `RhoFrameworks.Plugin` — tool plugin for framework persistence
- `RhoFrameworks.DataTableSchemas` — declared `Rho.Stdlib.DataTable.Schema` values for the `"library"` and `"role_profile"` named tables. Domain tools pass these to `DataTable.ensure_table/4`.
- `RhoFrameworks.Tools.LibraryTools` / `.Tools.RoleTools` — `Rho.Tool` DSL modules. Library/role tools load into their respective named tables and return `:not_running`/empty errors actionably. (Note: `save_library` was deleted in the swappable-decision-policy refactor — see `RhoFrameworks.Tools.WorkflowTools` below.)
- `RhoFrameworks.Tools.WorkflowTools` — `Rho.Tool` wrappers around `RhoFrameworks.UseCases.*`. Adds chat-side tools `load_similar_roles`, `generate_framework_skeletons` (async — spawns the SkeletonGenerator worker), `generate_proficiency` (async fan-out — one writer per category), `save_framework`. These are the same UseCases the wizard's `RhoFrameworks.FlowRunner` invokes for `RhoFrameworks.Flows.CreateFramework`. `add_proficiency_levels` (in `SharedTools`) matches by `skill_name` to update existing skeleton rows with proficiency data after fan-out.
- `RhoFrameworks.Demos.Hiring.*`

## Plugin & Transformer Architecture

All optional behaviour arrives through **plugins** (`@behaviour Rho.Plugin`) and **transformers** (`@behaviour Rho.Transformer`). A single module may implement both.

### Plugin system

- `Rho.Plugin` — behaviour with three optional callbacks: `tools/2`, `prompt_sections/2`, `bindings/2`
- `Rho.PluginRegistry` — GenServer + ETS for plugin registration and capability collection
- `Rho.PluginInstance` — struct: `module`, `opts`, `scope`, `priority`

#### Prompt token budget rules

The final system prompt = agent `system_prompt` + all plugin `prompt_sections` + auto-generated tool schema. Three layers contribute text, so duplication wastes tokens. Follow these rules:

1. **`prompt_sections` must not restate tool descriptions or param docs** — the auto-generated schema already includes every tool's name, description, and parameter documentation verbatim. Never list tools or explain what they do in `prompt_sections`.
2. **`prompt_sections` are for context tools can't express** — data table schemas/modes, domain vocabulary, workflow sequencing, dynamic state (e.g. existing libraries).
3. **Don't stamp shared notes on every tool description** — if multiple tools need the same context (e.g. "pass `table:` for named tables"), put it in one `prompt_section` or the agent's `system_prompt` instead.
4. **Agent `system_prompt` owns workflow and rules** — step-by-step paths, key rules, behavioral guidelines. Plugins should not duplicate these.
5. **Param `doc:` should be minimal** — just the type hint and default, not usage instructions. Example: `"Table name (default: 'main')"` not `"Named table (default: 'main'). Pass 'library' / 'role_profile' after loads."`

### Transformer system

- `Rho.Transformer` — behaviour with `transform/3` callback
- `Rho.TransformerRegistry` — GenServer + ETS for transformer registration and stage dispatch
- `Rho.TransformerInstance` — struct: `module`, `opts`, `scope`, `priority`
- Six stages: `:prompt_out`, `:response_in`, `:tool_args_out`, `:tool_result_in`, `:post_step`, `:tape_write`

### Transformer Pipeline

| Stage | Returns | Purpose |
|-------|---------|---------|
| `:prompt_out` | `{:cont, data} \| {:halt, reason}` | Mutate prompt before LLM call |
| `:response_in` | `{:cont, data} \| {:halt, reason}` | Inspect/mutate LLM response |
| `:tool_args_out` | `{:cont, data} \| {:deny, reason} \| {:halt, reason}` | Validate/mutate tool args |
| `:tool_result_in` | `{:cont, data} \| {:halt, reason}` | Mutate tool result |
| `:post_step` | `{:cont, nil} \| {:inject, [msg]} \| {:halt, reason}` | After step completes |
| `:tape_write` | `{:cont, entry}` | Tape entry about to be appended |

## Context struct

```elixir
%Rho.Context{
  tape_name:      String.t() | nil,
  tape_module:    module(),
  workspace:      String.t(),
  agent_name:     atom(),
  depth:          non_neg_integer(),
  subagent:       boolean(),
  agent_id:       String.t() | nil,
  session_id:     String.t() | nil,
  prompt_format:  :markdown | :xml | nil,
  user_id:        String.t() | nil
}
```

## Runner + TurnStrategy

- **`Rho.Runner`** — outer loop: step budget, compaction, tape recording, tool execution (via `ToolExecutor`), transformer dispatch
- **`Rho.TurnStrategy`** — inner turn: LLM call, response classification into intents
- `Rho.Runner.Runtime` — immutable run config struct (fields: `model`, `turn_strategy`, `context`, `tape`, etc.)
- `Rho.Runner.TapeConfig` — tape configuration (name, module, compact threshold)
- `Rho.Recorder` — tape writes during the agent loop (messages, tool calls, results)
- `Rho.ToolExecutor` — shared tool dispatch with transformer pipeline integration

## Agent System

- `Rho.Agent.Worker` — unified GenServer for all agents
- `Rho.Agent.Registry` — ETS-backed discovery
- `Rho.Agent.Primary` — session namespace helper
- `Rho.Agent.Supervisor` — DynamicSupervisor for all agents
- `Rho.Events` / `Rho.Events.Event` — PubSub-based event bus

## Config System

- `.rho.exs` — per-agent config. Keys: `model`, `system_prompt`, `max_steps`, `max_tokens`, `provider`, `description`, `skills`, `prompt_format`, `avatar`
  - `plugins:` — list of plugin entries (atom shorthand, `{atom, opts}` tuple, or raw module)
  - `turn_strategy:` — strategy atom or module
- `Rho.AgentConfig` — full `.rho.exs` loader, normalizes legacy keys (see apps/rho/ key modules)
- `Rho.Config` — core-only config (`tape_module/0`)
- `Rho.Stdlib` — plugin module map and `resolve_plugin/1`

### Custom LLM Providers

Custom `ReqLLM` providers live in `apps/rho/lib/req_llm/providers/` and are registered via `config :req_llm, custom_providers: [...]` in `config/config.exs` (req_llm's auto-discovery only scans its own OTP app modules).

- `ReqLLM.Providers.FireworksAI` — Fireworks AI direct provider (`fireworks_ai:` prefix). OpenAI-compatible, base URL `https://api.fireworks.ai/inference/v1`, env key `FIREWORKS_API_KEY`. Usage in `.rho.exs`: `model: "fireworks_ai:accounts/fireworks/models/deepseek-v3p1"`.

## Supervision Tree

```
# apps/rho (Rho.Application)
Rho.Supervisor (one_for_one)
├── Registry (Rho.AgentRegistry)
├── Task.Supervisor (Rho.TaskSupervisor)
├── Rho.PluginRegistry
├── Rho.TransformerRegistry
├── {Phoenix.PubSub, name: Rho.PubSub}
├── Rho.LLM.Admission
├── [Tape children]
├── Rho.Agent.Supervisor
├── Registry (Rho.EventLogRegistry)
└── DynamicSupervisor (EventLog.Supervisor)

# apps/rho_stdlib (Rho.Stdlib.Application) — also registers built-in plugins/transformers and inits Python
├── Registry (Rho.PythonRegistry)
├── DynamicSupervisor (Python.Supervisor)
├── Registry (Rho.Stdlib.DataTable.Registry)
├── DynamicSupervisor (Rho.Stdlib.DataTable.Supervisor)
├── Rho.Stdlib.DataTable.SessionJanitor
└── Rho.Stdlib.DataTable.ActiveViewListener

# apps/rho_web (RhoWeb.Application)
├── Phoenix.PubSub
└── RhoWeb.Endpoint

# apps/rho_frameworks (RhoFrameworks.Application)
└── RhoFrameworks.Repo
```

## Running Tests

```bash
mix test                                      # full suite
mix test --app rho                            # core only
mix test --app rho_stdlib                     # stdlib only
```

## Plugin Module Map (atom shorthands)

| Shorthand | Module |
|-----------|--------|
| `:bash` | `Rho.Stdlib.Tools.Bash` |
| `:fs_read` | `Rho.Stdlib.Tools.FsRead` |
| `:fs_write` | `Rho.Stdlib.Tools.FsWrite` |
| `:fs_edit` | `Rho.Stdlib.Tools.FsEdit` |
| `:web_fetch` | `Rho.Stdlib.Tools.WebFetch` |
| `:python` | `Rho.Stdlib.Tools.Python` |
| `:skills` | `Rho.Stdlib.Skill.Plugin` |
| `:multi_agent` | `Rho.Stdlib.Plugins.MultiAgent` |
| `:sandbox` | `Rho.Stdlib.Tools.Sandbox` |
| `:step_budget` | `Rho.Stdlib.Plugins.StepBudget` |
| `:live_render` | `Rho.Stdlib.Plugins.LiveRender` |
| `:py_agent` | `Rho.Stdlib.Plugins.PyAgent` |
| `:data_table` | `Rho.Stdlib.Plugins.DataTable` (thin wrapper over `Rho.Stdlib.DataTable` client API — see §Named tables) |
| `:doc_ingest` | `Rho.Stdlib.Plugins.DocIngest` |
| `:tape` / `:journal` | `Rho.Stdlib.Plugins.Tape` |
| `:control` | `Rho.Stdlib.Plugins.Control` |

## Future Directions

`docs/post-refactor-possibilities.md` — what the Plugin/Transformer + BAML
refactor unlocked: cross-cutting policy transformers (rate limiter, cost
ceiling, audit logger, PII redactor), per-agent model A/B, parallel
domain apps, publishable kernel, new TurnStrategy types, replay UI,
non-MultiAgent inter-agent protocols. Reference when planning new
capabilities.
