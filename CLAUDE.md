# Rho — Developer Context

## Project Overview

Rho is an Elixir-based AI agent framework structured as an **umbrella** with five apps. Agents are configured with plugins (tools, prompt sections, bindings), transformers (in-flight mutation + policy), tapes (append-only event history), skills, sandbox support, and signal-based multi-agent coordination.

## Umbrella Structure

```
rho/
├── apps/
│   ├── rho/              # Core agent runtime kernel (ZERO Phoenix/Ecto deps)
│   ├── rho_stdlib/        # Built-in tools & plugins
│   ├── rho_cli/           # Mix tasks, .rho.exs loader, CLI REPL
│   ├── rho_web/           # Phoenix endpoint, LiveViews
│   └── rho_frameworks/    # Ecto/SQLite skill-assessment domain
├── config/
│   ├── config.exs
│   └── runtime.exs
└── mix.exs               # Umbrella root
```

## Three-Plane Architecture

- **Execution plane** — `Rho.Runner`, `Rho.TurnStrategy`, tapes, plugins, transformers. Core LLM reasoning loop. Lives in `apps/rho/`.
- **Coordination plane** — Signal bus (`Rho.Comms`), agent registry, multi-agent plugin. Lives in `apps/rho/` (bus) and `apps/rho_stdlib/` (multi-agent plugin).
- **Edge plane** — CLI (`apps/rho_cli/`) and web (`apps/rho_web/`) adapters.

## App Boundaries

### `apps/rho/` — Core Runtime Kernel

No Phoenix, Ecto, or external tool deps. Deps: `req_llm`, `jido_signal`, `jason`, `nimble_options`.

Key modules:
- `Rho.Session` — programmatic session API (single entry point for CLI, web, tests)
- `Rho.RunSpec` / `Rho.RunSpec.FromConfig` — explicit agent configuration struct
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
- `Rho.Comms` / `Rho.Comms.SignalBus` — signal bus
- `Rho.Config` — core config (tape_module, agent_config, etc.)

### `apps/rho_stdlib/` — Built-in Tools & Plugins

Deps: `rho` (in_umbrella), `floki`, `pythonx`, `erlang_python`, `xlsxir`, `live_render`, `yaml_elixir`.

Module namespaces:
- `Rho.Stdlib` — plugin module map and `resolve_plugin/1`
- `Rho.Stdlib.Tools.*` — Bash, FsRead/FsWrite/FsEdit (in fs.ex), WebFetch, Python, Sandbox, PathUtils, Finish, EndTurn, Anchor/SearchHistory/RecallContext/ClearMemory (in tape_tools.ex)
- `Rho.Stdlib.Plugins.*` — MultiAgent, StepBudget, LiveRender, PyAgent, Spreadsheet, DocIngest, Tape, Control, DataTable
- `Rho.Stdlib.DataTable` — client API for the per-session data table server (synchronous row ops, named tables). Callers pass `table: "name"` in opts; default is `"main"`. Entry points: `ensure_started/1`, `ensure_table/4`, `add_rows/3`, `get_rows/2`, `update_cells/3`, `replace_all/3`, `delete_rows/3`, `delete_by_filter/3`, `get_table_snapshot/2`, `list_tables/1`, `summarize_table/2`.
- `Rho.Stdlib.DataTable.Server` — per-session `GenServer` that owns table state and publishes coarse invalidation events via `Rho.Comms` (`rho.session.<sid>.events.data_table`). Uses `restart: :temporary` — a crashed server stays down with `{:error, :not_running}` returned to callers rather than silently restarting empty.
- `Rho.Stdlib.DataTable.Schema` / `Rho.Stdlib.DataTable.Schema.Column` / `Rho.Stdlib.DataTable.Table` — pure data structs
- `Rho.Stdlib.DataTable.SessionJanitor` — listens for `rho.agent.stopped` and stops the matching server
- `Rho.Stdlib.Skill` / `Rho.Stdlib.Skill.Plugin` / `Rho.Stdlib.Skill.Loader`
- `Rho.Stdlib.Builtin`

#### Named tables

A single session can have multiple named data tables side-by-side. `"main"` is created eagerly with a permissive (dynamic) schema and accepts arbitrary LLM-generated fields. Domain tools declare strict schemas and opt in to named tables by calling `Rho.Stdlib.DataTable.ensure_table(session_id, "library", library_schema())` before writing rows. Example pattern (see `RhoFrameworks.Tools.LibraryTools.load_library`):

```elixir
:ok = DataTable.ensure_table(ctx.session_id, "library", DataTableSchemas.library_schema())
# return %Rho.Effect.Table{table_name: "library", schema_key: :skill_library, rows: rows}
# — EffectDispatcher writes rows to the "library" table and auto-switches the LV tab.
```

Agent-facing plugin tools (`get_table`, `add_rows`, `update_cells`, …) take an optional `table:` param that defaults to `"main"`. Agents that load a named table must pass `table:` on subsequent ops — there is no auto-tracking of "active" table server-side. The `:spreadsheet` agent's system prompt documents the per-path convention (`table: "library"` after `load_library`, `table: "role_profile"` after `load_role_profile` / `clone_role_skills` / `start_role_profile_draft`).

### `apps/rho_cli/` — CLI Infrastructure

Deps: `rho`, `rho_stdlib` (in_umbrella), `dotenvy`.

- `Rho.CLI.Config` — full `.rho.exs` loader, normalizes legacy keys
- `Rho.CLI.Repl` — GenServer REPL adapter
- `Rho.CLI.CommandParser` — command parsing
- `Rho.CLI.Application` — boots Dotenvy, registers plugins, inits Python
- `Mix.Tasks.Rho.{Chat,Run,Trace}` — mix tasks

### `apps/rho_web/` — Phoenix Web Application

Deps: `rho`, `rho_stdlib`, `rho_cli`, `rho_frameworks` (in_umbrella), `phoenix`, `phoenix_live_view`, `bandit`.

- `RhoWeb.*` — endpoint, router, LiveViews, components
- `RhoWeb.Application` — starts PubSub, Endpoint

### `apps/rho_frameworks/` — Skill Assessment Domain

Deps: `rho`, `rho_stdlib`, `rho_cli` (in_umbrella), `ecto_sqlite3`, `phoenix_ecto`, `bcrypt_elixir`.

- `RhoFrameworks.Repo` — Ecto SQLite repo
- `RhoFrameworks.Accounts` / `.Accounts.User` / `.Accounts.UserToken`
- `RhoFrameworks.Frameworks` / `.Frameworks.Framework` / `.Frameworks.Skill`
- `RhoFrameworks.Plugin` — tool plugin for framework persistence
- `RhoFrameworks.DataTableSchemas` — declared `Rho.Stdlib.DataTable.Schema` values for the `"library"` and `"role_profile"` named tables. Domain tools pass these to `DataTable.ensure_table/4`.
- `RhoFrameworks.Tools.LibraryTools` / `.Tools.RoleTools` — `Rho.Tool` DSL modules. Library/role tools load into their respective named tables; `save_to_library` / `save_role_profile` read from the named tables (not from `"main"`) and return `:not_running`/empty errors actionably. `save_and_generate` persists confirmed skeleton skills to the library table AND spawns proficiency writer lite workers per category in a single tool call; `add_proficiency_levels` (in `SharedTools`) then matches by `skill_name` to update existing skeleton rows with proficiency data.
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
- `Rho.Comms` / `Rho.Comms.SignalBus` — signal bus (sole event delivery path)

## Config System

- `.rho.exs` — per-agent config. Keys: `model`, `system_prompt`, `max_steps`, `max_tokens`, `provider`, `description`, `skills`, `prompt_format`, `avatar`
  - `plugins:` — list of plugin entries (atom shorthand, `{atom, opts}` tuple, or raw module)
  - `turn_strategy:` — strategy atom or module
- `Rho.CLI.Config` — full config loader, normalizes legacy keys
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
├── Rho.Comms.SignalBus
├── [Tape children]
├── Rho.Agent.Supervisor
├── Registry (Rho.EventLogRegistry)
└── DynamicSupervisor (EventLog.Supervisor)

# apps/rho_stdlib (Rho.Stdlib.Application)
├── Registry (Rho.PythonRegistry)
├── DynamicSupervisor (Python.Supervisor)
├── Registry (Rho.Stdlib.DataTable.Registry)
├── DynamicSupervisor (Rho.Stdlib.DataTable.Supervisor)
└── Rho.Stdlib.DataTable.SessionJanitor

# apps/rho_cli (Rho.CLI.Application)
└── Rho.CLI.Repl

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
