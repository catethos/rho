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
│   ├── rho_web/           # Phoenix endpoint, LiveViews, observatory
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
- `Rho.Runner` — outer agent loop (step budget, compaction, tape recording)
- `Rho.TurnStrategy` — behaviour for inner turn (LLM call, tool dispatch)
- `Rho.TurnStrategy.Direct` / `Rho.TurnStrategy.Structured` — implementations
- `Rho.Plugin` / `Rho.PluginInstance` / `Rho.PluginRegistry` — plugin system
- `Rho.Transformer` / `Rho.TransformerInstance` / `Rho.TransformerRegistry` — transformer pipeline
- `Rho.Context` — ambient state struct for plugin/transformer callbacks
- `Rho.PromptSection` — structured prompt section struct
- `Rho.Tape.*` — append-only event history
- `Rho.Agent.*` — Worker, Registry, Primary, Supervisor, EventLog
- `Rho.Comms` / `Rho.Comms.SignalBus` — signal bus
- `Rho.Config` — core config (only `tape_module/0`)

### `apps/rho_stdlib/` — Built-in Tools & Plugins

Deps: `rho` (in_umbrella), `floki`, `pythonx`, `erlang_python`, `xlsxir`, `live_render`, `yaml_elixir`.

Module namespaces:
- `Rho.Stdlib` — plugin module map and `resolve_plugin/1`
- `Rho.Stdlib.Tools.*` — Bash, FsRead, FsWrite, FsEdit, WebFetch, Python, Sandbox, PathUtils, Finish, EndTurn, Anchor, SearchHistory, RecallContext, ClearMemory
- `Rho.Stdlib.Plugins.*` — MultiAgent, StepBudget, LiveRender, PyAgent, Spreadsheet, DocIngest, Tape, Control
- `Rho.Stdlib.Skill` / `Rho.Stdlib.Skill.Plugin` / `Rho.Stdlib.Skill.Loader`
- `Rho.Stdlib.Builtin`

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
- `RhoWeb.Observatory` — metrics collector
- `RhoWeb.Application` — starts PubSub, Observatory, Endpoint

### `apps/rho_frameworks/` — Skill Assessment Domain

Deps: `rho`, `rho_stdlib`, `rho_cli` (in_umbrella), `ecto_sqlite3`, `phoenix_ecto`, `bcrypt_elixir`.

- `RhoFrameworks.Repo` — Ecto SQLite repo
- `RhoFrameworks.Accounts` / `.Accounts.User` / `.Accounts.UserToken`
- `RhoFrameworks.Frameworks` / `.Frameworks.Framework` / `.Frameworks.Skill`
- `RhoFrameworks.Plugin` — tool plugin for framework persistence
- `RhoFrameworks.Demos.Hiring.*`

## Plugin & Transformer Architecture

All optional behaviour arrives through **plugins** (`@behaviour Rho.Plugin`) and **transformers** (`@behaviour Rho.Transformer`). A single module may implement both.

### Plugin system

- `Rho.Plugin` — behaviour with three optional callbacks: `tools/2`, `prompt_sections/2`, `bindings/2`
- `Rho.PluginRegistry` — GenServer + ETS for plugin registration and capability collection
- `Rho.PluginInstance` — struct: `module`, `opts`, `scope`, `priority`

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

- **`Rho.Runner`** — outer loop: step budget, compaction, tape recording, transformer dispatch
- **`Rho.TurnStrategy`** — inner turn: LLM call, tool dispatch, response parsing
- `Rho.AgentLoop.Runtime` — immutable run config struct (fields: `model`, `turn_strategy`, `context`, `tape`, etc.)

## Agent System

- `Rho.Agent.Worker` — unified GenServer for all agents
- `Rho.Agent.Registry` — ETS-backed discovery
- `Rho.Agent.Primary` — session namespace helper
- `Rho.Agent.Supervisor` — DynamicSupervisor for all agents
- `Rho.Comms` / `Rho.Comms.SignalBus` — signal bus (sole event delivery path)

## Config System

- `.rho.exs` — per-agent config. Keys: `model`, `system_prompt`, `max_steps`, `max_tokens`, `provider`, `description`, `skills`, `prompt_format`, `avatar`
  - `plugins:` (canonical) / `mounts:` (legacy alias) — list of plugin entries
  - `turn_strategy:` (canonical) / `reasoner:` (legacy alias) — strategy atom or module
- `Rho.CLI.Config` — full config loader, normalizes legacy keys
- `Rho.Config` — core-only config (`tape_module/0`)
- `Rho.Stdlib` — plugin module map and `resolve_plugin/1`

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
└── DynamicSupervisor (Python.Supervisor)

# apps/rho_cli (Rho.CLI.Application)
└── Rho.CLI.Repl

# apps/rho_web (RhoWeb.Application)
├── Phoenix.PubSub
├── RhoWeb.Observatory
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
| `:spreadsheet` | `Rho.Stdlib.Plugins.Spreadsheet` |
| `:doc_ingest` | `Rho.Stdlib.Plugins.DocIngest` |
| `:tape` / `:journal` | `Rho.Stdlib.Plugins.Tape` |
| `:control` | `Rho.Stdlib.Plugins.Control` |
