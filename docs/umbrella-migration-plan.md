# Rho Umbrella Migration Plan

## Goal

Restructure the Rho monolith into an umbrella app with clean boundaries. Each app has a single responsibility, its own `mix.exs` with only the deps it needs, and no legacy alias shims.

## Current State Summary

The repo is a single Mix app (`rho`) at v0.1.0 that bundles:
- An agent runtime kernel (Runner, TurnStrategy, Tape, Plugin, Transformer, Agent, Comms)
- 14+ tool modules under `lib/rho/tools/`
- A full Phoenix web app under `lib/rho_web/`
- Ecto/SQLite domain models (Accounts, Frameworks)
- A metrics collector (Observatory)
- Demo code (Demos.Hiring)
- CLI infrastructure (mix tasks, REPL, config loader)
- ~10 deprecated alias/delegate modules from a Mount→Plugin rename

All of this compiles as one OTP app with deps on Phoenix, Ecto, bcrypt, pythonx, xlsxir, etc.

---

## Target Umbrella Structure

```
rho/                          # repo root
├── apps/
│   ├── rho/                  # core agent runtime kernel (ZERO Phoenix/Ecto deps)
│   ├── rho_stdlib/           # built-in tools & plugins
│   ├── rho_cli/              # mix tasks, .rho.exs loader, CLI REPL
│   ├── rho_web/              # Phoenix endpoint, LiveViews, auth, observatory
│   └── rho_frameworks/       # Ecto/SQLite skill-assessment domain
├── config/
│   ├── config.exs
│   └── runtime.exs
├── mix.exs                   # umbrella root
└── README.md
```

---

## App Boundaries: What Goes Where

### `apps/rho/` — Core Agent Runtime Kernel

**Purpose:** The reusable framework. Another Elixir project should be able to add `{:rho, path: "apps/rho"}` and get a working agent runtime with zero Phoenix/Ecto/web deps.

**Deps:** `{:req_llm, "~> 1.6"}`, `{:jido_signal, "~> 2.0"}`, `{:jason, "~> 1.4"}`, `{:nimble_options, "~> 1.0"}`

**Modules (current path → new path):**

| Current file | New file | Notes |
|---|---|---|
| `lib/rho.ex` | `apps/rho/lib/rho.ex` | Remove `hello/0` placeholder, add real moduledoc |
| `lib/rho/runner.ex` | `apps/rho/lib/rho/runner.ex` | Rename internal field `reasoner` → `turn_strategy`, `mount_context` → `context` |
| `lib/rho/turn_strategy.ex` | `apps/rho/lib/rho/turn_strategy.ex` | No changes |
| `lib/rho/turn_strategy/direct.ex` | `apps/rho/lib/rho/turn_strategy/direct.ex` | No changes |
| `lib/rho/turn_strategy/structured.ex` | `apps/rho/lib/rho/turn_strategy/structured.ex` | No changes |
| `lib/rho/plugin.ex` | `apps/rho/lib/rho/plugin.ex` | No changes |
| `lib/rho/plugin_instance.ex` | `apps/rho/lib/rho/plugin_instance.ex` | No changes |
| `lib/rho/plugin_registry.ex` | `apps/rho/lib/rho/plugin_registry.ex` | Remove `apply_stage/3` and transformer logic (moves to TransformerRegistry) |
| `lib/rho/transformer.ex` | `apps/rho/lib/rho/transformer.ex` | No changes to behaviour |
| *(new)* | `apps/rho/lib/rho/transformer_registry.ex` | New GenServer+ETS for transformer stage dispatch. Extract `apply_stage/3`, `safe_transform/6`, `do_apply_stage/3` from current PluginRegistry |
| *(new)* | `apps/rho/lib/rho/transformer_instance.ex` | Struct: `module`, `opts`, `scope`, `priority` (same shape as PluginInstance) |
| `lib/rho/context.ex` | `apps/rho/lib/rho/context.ex` | Rename field `memory_mod` → `tape_module` in struct and all references |
| `lib/rho/mount/prompt_section.ex` | `apps/rho/lib/rho/prompt_section.ex` | Move out of `mount/` subdir, module becomes `Rho.PromptSection` |
| `lib/rho/structured_output.ex` | `apps/rho/lib/rho/structured_output.ex` | No changes |
| `lib/rho/parse/lenient.ex` | `apps/rho/lib/rho/parse/lenient.ex` | No changes |
| `lib/rho/tape/entry.ex` | `apps/rho/lib/rho/tape/entry.ex` | No changes |
| `lib/rho/tape/store.ex` | `apps/rho/lib/rho/tape/store.ex` | No changes |
| `lib/rho/tape/service.ex` | `apps/rho/lib/rho/tape/service.ex` | No changes |
| `lib/rho/tape/view.ex` | `apps/rho/lib/rho/tape/view.ex` | No changes |
| `lib/rho/tape/compact.ex` | `apps/rho/lib/rho/tape/compact.ex` | No changes |
| `lib/rho/tape/fork.ex` | `apps/rho/lib/rho/tape/fork.ex` | No changes |
| `lib/rho/tape/context.ex` | `apps/rho/lib/rho/tape/context.ex` | Behaviour — no changes |
| `lib/rho/tape/context/tape.ex` | `apps/rho/lib/rho/tape/context/tape.ex` | Default JSONL implementation |
| `lib/rho/agent/worker.ex` | `apps/rho/lib/rho/agent/worker.ex` | Replace `Rho.MountRegistry` calls with `Rho.PluginRegistry` |
| `lib/rho/agent/primary.ex` | `apps/rho/lib/rho/agent/primary.ex` | No changes |
| `lib/rho/agent/supervisor.ex` | `apps/rho/lib/rho/agent/supervisor.ex` | No changes |
| `lib/rho/agent/registry.ex` | `apps/rho/lib/rho/agent/registry.ex` | No changes |
| `lib/rho/agent/event_log.ex` | `apps/rho/lib/rho/agent/event_log.ex` | No changes |
| `lib/rho/comms.ex` | `apps/rho/lib/rho/comms.ex` | No changes |
| `lib/rho/comms/signal_bus.ex` | `apps/rho/lib/rho/comms/signal_bus.ex` | No changes |
| `lib/rho/agent_loop/runtime.ex` | `apps/rho/lib/rho/agent_loop/runtime.ex` | Rename field `reasoner` → `turn_strategy`, `mount_context` → `context` |
| `lib/rho/agent_loop/recorder.ex` | `apps/rho/lib/rho/agent_loop/recorder.ex` | No changes |
| `lib/rho/agent_loop/tape.ex` | `apps/rho/lib/rho/agent_loop/tape.ex` | Rename field `memory_mod` → `tape_module` |
| `lib/rho/sandbox.ex` | `apps/rho/lib/rho/sandbox.ex` | No changes |
| `lib/rho/debounce.ex` | `apps/rho/lib/rho/debounce.ex` | No changes |

**Application module:** `Rho.Application` — stripped down to only start core children:
```elixir
children = [
  {Registry, keys: :unique, name: Rho.AgentRegistry},
  {Task.Supervisor, name: Rho.TaskSupervisor},
  Rho.PluginRegistry,
  Rho.TransformerRegistry,      # NEW
  Rho.Comms.SignalBus,
  # tape children from tape_module
] ++ tape_children ++ [
  Rho.Agent.Supervisor,
  {Registry, keys: :unique, name: Rho.EventLogRegistry},
  {DynamicSupervisor, name: Rho.Agent.EventLog.Supervisor, strategy: :one_for_one},
]
```

No Repo, no Phoenix, no Python, no Observatory, no CLI.

**Config key renames:**
- Application env: `:memory_module` → `:tape_module`

---

### `apps/rho_stdlib/` — Built-in Tools & Plugins

**Purpose:** The standard library of tools and plugins that ship with Rho. Optional — a user could depend on `rho` without `rho_stdlib`.

**Deps:** `{:rho, in_umbrella: true}`, `{:floki, "~> 0.37"}`, `{:pythonx, "~> 0.4"}`, `{:erlang_python, "~> 2.3"}`, `{:xlsxir, "~> 1.6"}`, `{:live_render, "~> 0.5"}`

**Modules (current path → new path):**

Tools — standalone (substantial external capability):

| Current file | New file | New module name |
|---|---|---|
| `lib/rho/tools/bash.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/bash.ex` | `Rho.Stdlib.Tools.Bash` |
| `lib/rho/tools/fs_read.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/fs_read.ex` | `Rho.Stdlib.Tools.FsRead` |
| `lib/rho/tools/fs_write.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/fs_write.ex` | `Rho.Stdlib.Tools.FsWrite` |
| `lib/rho/tools/fs_edit.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/fs_edit.ex` | `Rho.Stdlib.Tools.FsEdit` |
| `lib/rho/tools/web_fetch.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/web_fetch.ex` | `Rho.Stdlib.Tools.WebFetch` |
| `lib/rho/tools/python.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/python.ex` | `Rho.Stdlib.Tools.Python` |
| `lib/rho/tools/python/interpreter.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/python/interpreter.ex` | `Rho.Stdlib.Tools.Python.Interpreter` |
| `lib/rho/tools/sandbox.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/sandbox.ex` | `Rho.Stdlib.Tools.Sandbox` |
| `lib/rho/tools/path_utils.ex` | `apps/rho_stdlib/lib/rho/stdlib/tools/path_utils.ex` | `Rho.Stdlib.Tools.PathUtils` |

Tools — grouped into plugins (small, tightly related):

| Current files | New file | New module | Provides tools |
|---|---|---|---|
| `tools/anchor.ex`, `tools/search_history.ex`, `tools/recall_context.ex`, `tools/clear_memory.ex`, `tools/tape_tools.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/tape.ex` | `Rho.Stdlib.Plugins.Tape` | `create_anchor`, `search_history`, `recall_context`, `clear_memory` |
| `tools/finish.ex`, `tools/end_turn.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/control.ex` | `Rho.Stdlib.Plugins.Control` | `finish`, `end_turn` |

Plugins & Mounts:

| Current file | New file | New module name |
|---|---|---|
| `lib/rho/mounts/multi_agent.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/multi_agent.ex` | `Rho.Stdlib.Plugins.MultiAgent` |
| `lib/rho/mounts/live_render.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/live_render.ex` | `Rho.Stdlib.Plugins.LiveRender` |
| `lib/rho/mounts/spreadsheet.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/spreadsheet.ex` | `Rho.Stdlib.Plugins.Spreadsheet` |
| `lib/rho/mounts/doc_ingest.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/doc_ingest.ex` | `Rho.Stdlib.Plugins.DocIngest` |
| `lib/rho/mounts/py_agent.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/py_agent.ex` | `Rho.Stdlib.Plugins.PyAgent` |
| `lib/rho/plugins/step_budget.ex` | `apps/rho_stdlib/lib/rho/stdlib/plugins/step_budget.ex` | `Rho.Stdlib.Plugins.StepBudget` |
| `lib/rho/plugins/subagent.ex` | *(DELETE)* | Legacy — superseded by MultiAgent |
| `lib/rho/builtin.ex` | `apps/rho_stdlib/lib/rho/stdlib/builtin.ex` | `Rho.Stdlib.Builtin` |
| `lib/rho/skill.ex` | `apps/rho_stdlib/lib/rho/stdlib/skill.ex` | `Rho.Stdlib.Skill` |
| `lib/rho/skill/plugin.ex` | `apps/rho_stdlib/lib/rho/stdlib/skill/plugin.ex` | `Rho.Stdlib.Skill.Plugin` |
| `lib/rho/skill/loader.ex` | `apps/rho_stdlib/lib/rho/stdlib/skill/loader.ex` | `Rho.Stdlib.Skill.Loader` |

**Application module:** `Rho.Stdlib.Application` — starts Python supervisor, registers nothing (registration is done by the CLI/web app that assembles the system).

**Plugin module map (replaces `@mount_modules` in Config):**
```elixir
@plugin_modules %{
  bash:           Rho.Stdlib.Tools.Bash,
  fs_read:        Rho.Stdlib.Tools.FsRead,
  fs_write:       Rho.Stdlib.Tools.FsWrite,
  fs_edit:        Rho.Stdlib.Tools.FsEdit,
  web_fetch:      Rho.Stdlib.Tools.WebFetch,
  python:         Rho.Stdlib.Tools.Python,
  skills:         Rho.Stdlib.Skill.Plugin,
  multi_agent:    Rho.Stdlib.Plugins.MultiAgent,
  sandbox:        Rho.Stdlib.Tools.Sandbox,
  step_budget:    Rho.Stdlib.Plugins.StepBudget,
  live_render:    Rho.Stdlib.Plugins.LiveRender,
  py_agent:       Rho.Stdlib.Plugins.PyAgent,
  spreadsheet:    Rho.Stdlib.Plugins.Spreadsheet,
  doc_ingest:     Rho.Stdlib.Plugins.DocIngest,
}
```

---

### `apps/rho_cli/` — CLI Infrastructure

**Purpose:** Mix tasks, `.rho.exs` config loader, CLI REPL adapter, command parser.

**Deps:** `{:rho, in_umbrella: true}`, `{:rho_stdlib, in_umbrella: true}`, `{:dotenvy, "~> 1.1"}`

**Modules:**

| Current file | New file | New module name |
|---|---|---|
| `lib/rho/config.ex` | `apps/rho_cli/lib/rho/cli/config.ex` | `Rho.CLI.Config` |
| `lib/rho/cli.ex` | `apps/rho_cli/lib/rho/cli/repl.ex` | `Rho.CLI.Repl` |
| `lib/rho/command_parser.ex` | `apps/rho_cli/lib/rho/cli/command_parser.ex` | `Rho.CLI.CommandParser` |
| `lib/mix/tasks/rho.chat.ex` | `apps/rho_cli/lib/mix/tasks/rho.chat.ex` | `Mix.Tasks.Rho.Chat` |
| `lib/mix/tasks/rho.run.ex` | `apps/rho_cli/lib/mix/tasks/rho.run.ex` | `Mix.Tasks.Rho.Run` |
| `lib/mix/tasks/rho.trace.ex` | `apps/rho_cli/lib/mix/tasks/rho.trace.ex` | `Mix.Tasks.Rho.Trace` |
| `lib/mix/tasks/rho.reasoner_report.ex` | *(DELETE)* | Legacy name |

**Application module:** `Rho.CLI.Application` — starts:
- Dotenvy source loading
- `Rho.CLI.Repl` GenServer
- Plugin registration from `.rho.exs` config
- Python initialization (moved from current `Rho.Application`)

**Config normalization:** `Rho.CLI.Config` accepts both old and new keys but normalizes immediately:
- `mounts:` → `plugins:` (accept both, warn on old)
- `reasoner:` → `turn_strategy:` (accept both, warn on old)
- `memory_module` → `tape_module` (accept both, warn on old)
- The rest of the codebase only sees canonical keys

---

### `apps/rho_web/` — Phoenix Web Application

**Purpose:** Web UI, auth, LiveViews, observatory, API endpoints.

**Deps:** `{:rho, in_umbrella: true}`, `{:rho_stdlib, in_umbrella: true}`, `{:phoenix, "~> 1.7"}`, `{:phoenix_live_view, "~> 1.0"}`, `{:phoenix_html, "~> 4.2"}`, `{:bandit, "~> 1.6"}`, `{:plug, "~> 1.16"}`, `{:bcrypt_elixir, "~> 3.0"}`

**Modules:**

| Current file | New file | Notes |
|---|---|---|
| `lib/rho_web/**/*` | `apps/rho_web/lib/rho_web/**/*` | Move entire directory, module names unchanged |
| `lib/rho/observatory.ex` | `apps/rho_web/lib/rho_web/observatory.ex` | Rename to `RhoWeb.Observatory` |
| `lib/rho_web/observatory_api.ex` | `apps/rho_web/lib/rho_web/observatory_api.ex` | Already correct |

**Application module:** `RhoWeb.Application` — starts:
- `{Phoenix.PubSub, name: Rho.PubSub}`
- `RhoWeb.Observatory` (was `Rho.Observatory`)
- `RhoWeb.Endpoint`

---

### `apps/rho_frameworks/` — Skill Assessment Domain

**Purpose:** Ecto/SQLite CRUD for the "frameworks" skill assessment feature. Completely optional.

**Deps:** `{:rho, in_umbrella: true}`, `{:ecto_sqlite3, "~> 0.17"}`, `{:phoenix_ecto, "~> 4.6"}`

**Modules:**

| Current file | New file | New module name |
|---|---|---|
| `lib/rho/repo.ex` | `apps/rho_frameworks/lib/rho_frameworks/repo.ex` | `RhoFrameworks.Repo` |
| `lib/rho/accounts.ex` | `apps/rho_frameworks/lib/rho_frameworks/accounts.ex` | `RhoFrameworks.Accounts` |
| `lib/rho/accounts/user.ex` | `apps/rho_frameworks/lib/rho_frameworks/accounts/user.ex` | `RhoFrameworks.Accounts.User` |
| `lib/rho/accounts/user_token.ex` | `apps/rho_frameworks/lib/rho_frameworks/accounts/user_token.ex` | `RhoFrameworks.Accounts.UserToken` |
| `lib/rho/frameworks.ex` | `apps/rho_frameworks/lib/rho_frameworks/frameworks.ex` | `RhoFrameworks.Frameworks` |
| `lib/rho/frameworks/framework.ex` | `apps/rho_frameworks/lib/rho_frameworks/frameworks/framework.ex` | `RhoFrameworks.Frameworks.Framework` |
| `lib/rho/frameworks/skill.ex` | `apps/rho_frameworks/lib/rho_frameworks/frameworks/skill.ex` | `RhoFrameworks.Frameworks.Skill` |
| `lib/rho/mounts/framework_persistence.ex` | `apps/rho_frameworks/lib/rho_frameworks/plugin.ex` | `RhoFrameworks.Plugin` |
| `lib/rho/demos/hiring/**` | `apps/rho_frameworks/lib/rho_frameworks/demos/hiring/**` | `RhoFrameworks.Demos.Hiring.*` |
| `priv/repo/migrations/*` | `apps/rho_frameworks/priv/repo/migrations/*` | Move as-is |

**Application module:** `RhoFrameworks.Application` — starts `RhoFrameworks.Repo`.

---

## Modules to DELETE (Legacy Shims)

These exist only as backward-compat delegates from the Mount→Plugin rename. Delete them outright — no migration, no compat package.

| File | Module | Reason |
|---|---|---|
| `lib/rho/mount.ex` | `Rho.Mount` | Identical behaviour to `Rho.Plugin` |
| `lib/rho/mount_registry.ex` | `Rho.MountRegistry` | Full defdelegate to `Rho.PluginRegistry` |
| `lib/rho/mount_instance.ex` | `Rho.MountInstance` | Duplicate struct of `Rho.PluginInstance` |
| `lib/rho/agent_loop.ex` | `Rho.AgentLoop` | Defdelegate to `Rho.Runner` |
| `lib/rho/reasoner.ex` | `Rho.Reasoner` | Behaviour alias for `Rho.TurnStrategy` |
| `lib/rho/reasoner/direct.ex` | `Rho.Reasoner.Direct` | Defdelegate to `Rho.TurnStrategy.Direct` |
| `lib/rho/reasoner/structured.ex` | `Rho.Reasoner.Structured` | Defdelegate to `Rho.TurnStrategy.Structured` |
| `lib/rho/skills.ex` | `Rho.Skills` | Defdelegate to `Rho.Skill.Plugin` |
| `lib/rho/plugins/subagent.ex` | `Rho.Plugins.Subagent` | Legacy — superseded by `MultiAgent` |

---

## Internal Field Renames

These are mechanical find-and-replace operations across the codebase.

| Old name | New name | Where it appears |
|---|---|---|
| `runtime.reasoner` | `runtime.turn_strategy` | `Rho.Runner`, `Rho.AgentLoop.Runtime` struct, `TurnStrategy.Direct`, `TurnStrategy.Structured` |
| `runtime.mount_context` | `runtime.context` | `Rho.Runner`, `TurnStrategy.Direct` |
| `config[:reasoner]` | `config[:turn_strategy]` | `Rho.CLI.Config` (accept both at load, normalize) |
| `config[:mounts]` | `config[:plugins]` | `Rho.CLI.Config` (accept both at load, normalize) |
| `Rho.Config.memory_module/0` | `Rho.Config.tape_module/0` | `Rho.Application`, `Rho.Agent.Worker`, `Rho.Runner` |
| `context.memory_mod` | `context.tape_module` | `Rho.Context` struct, all callers |
| `tape.memory_mod` | `tape.tape_module` | `Rho.AgentLoop.Tape` struct, `Rho.Runner` |
| `state.memory_mod` | `state.tape_module` | `Rho.Agent.Worker` |
| `state.memory_ref` | `state.tape_ref` | `Rho.Agent.Worker` |
| `Rho.Mount.PromptSection` | `Rho.PromptSection` | All files that reference prompt sections |
| `@mount_modules` | `@plugin_modules` | `Rho.CLI.Config` |
| `resolve_mount/1` | `resolve_plugin/1` | `Rho.CLI.Config` |
| `Rho.MountRegistry.*` | `Rho.PluginRegistry.*` | `Rho.Agent.Worker`, `Mix.Tasks.Rho.Run`, all callers |

---

## New Module: `Rho.TransformerRegistry`

Extract from current `Rho.PluginRegistry`:

```elixir
defmodule Rho.TransformerRegistry do
  @moduledoc """
  Transformer registration and stage dispatch.

  Separate from PluginRegistry (which handles capability contribution).
  A module may implement both Rho.Plugin and Rho.Transformer, but
  registers separately for each role.
  """
  use GenServer

  @table :rho_transformer_instances

  def start_link(opts \\ [])
  def register(module, opts \\ [])
  def clear()
  def apply_stage(stage, data, context)

  # Move these private functions from PluginRegistry:
  # - do_apply_stage/3 (all stage variants)
  # - safe_transform/6
  # - subagent_passthrough/2
  # - active_transformers/1 (like active_plugins but reads from @table)
end
```

**Registration call sites** (update in CLI/web application boot):
```elixir
# Where currently a single module is registered as both:
Rho.PluginRegistry.register(Rho.Stdlib.Plugins.StepBudget, scope: {:agent, :default})
Rho.TransformerRegistry.register(Rho.Stdlib.Plugins.StepBudget, scope: {:agent, :default})
```

**Runner update:** Replace `Rho.PluginRegistry.apply_stage(...)` with `Rho.TransformerRegistry.apply_stage(...)` in:
- `Rho.Runner.run_prompt_out/3`
- `Rho.Runner.run_post_step/3`
- `Rho.TurnStrategy.Direct.run/2` (for `:response_in`, `:tool_args_out`, `:tool_result_in`)

---

## Test Migration

| Current test file | New location | Notes |
|---|---|---|
| `test/rho/tape/*_test.exs` (6 files) | `apps/rho/test/rho/tape/*_test.exs` | No changes needed |
| `test/rho/agent/*_test.exs` (6 files) | `apps/rho/test/rho/agent/*_test.exs` | No changes |
| `test/rho/mount/prompt_section_test.exs` | `apps/rho/test/rho/prompt_section_test.exs` | Update module ref |
| `test/rho/parse/*_test.exs` (2 files) | `apps/rho/test/rho/parse/*_test.exs` | No changes |
| `test/rho/structured_output_test.exs` | `apps/rho/test/rho/structured_output_test.exs` | No changes |
| `test/rho/mount_registry_test.exs` | `apps/rho/test/rho/plugin_registry_test.exs` | Update all `MountRegistry` → `PluginRegistry` refs |
| `test/rho/mount_integration_test.exs` | `apps/rho/test/rho/plugin_integration_test.exs` | Update refs |
| `test/rho/agent_loop_test.exs` | `apps/rho/test/rho/runner_test.exs` | Update `AgentLoop` → `Runner` refs |
| `test/rho/reasoner/*_test.exs` (2 files) | `apps/rho/test/rho/turn_strategy/*_test.exs` | Update module refs |
| `test/rho/acceptance_gate_test.exs` | `apps/rho/test/rho/acceptance_gate_test.exs` | No changes |
| `test/rho/tools/*_test.exs` (4 files) | `apps/rho_stdlib/test/rho/stdlib/tools/*_test.exs` | Update module refs |
| `test/rho/skill_test.exs` | `apps/rho_stdlib/test/rho/stdlib/skill_test.exs` | Update refs |
| `test/rho/skill/plugin_test.exs` | `apps/rho_stdlib/test/rho/stdlib/skill/plugin_test.exs` | Update refs |
| `test/rho/command_parser_test.exs` | `apps/rho_cli/test/rho/cli/command_parser_test.exs` | Update refs |
| `test/rho/observatory_test.exs` | `apps/rho_web/test/rho_web/observatory_test.exs` | Update refs |
| `test/rho/mounts/live_render_test.exs` | `apps/rho_stdlib/test/rho/stdlib/plugins/live_render_test.exs` | Update refs |
| `test/rho_web/*_test.exs` (4 files) | `apps/rho_web/test/rho_web/*_test.exs` | No changes |
| `test/support/` | Split per-app | Helpers go to the app that needs them |
| `test/fixtures/` | Split per-app | Fixtures go where used |
| `test/test_helper.exs` | Per-app `test/test_helper.exs` | Each app gets its own |

---

## Config Migration

### Root `config/config.exs`
```elixir
import Config

# ReqLLM connection pool (shared)
config :req_llm,
  stream_receive_timeout: 120_000,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 25, conn_max_idle_time: 30_000]
    }
  ]

config :phoenix, :json_library, Jason

# Import app-specific configs
import_config "../apps/*/config/config.exs"
```

### `apps/rho/config/config.exs`
```elixir
import Config
config :rho, tape_module: Rho.Tape.Context.Tape
```

### `apps/rho_web/config/config.exs`
```elixir
import Config

config :rho_web, RhoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  url: [host: "localhost"],
  check_origin: ["//localhost"],
  server: true,
  secret_key_base: "rho_dev_secret_key_base_at_least_64_bytes_long_for_cookie_signing_purposes!!",
  render_errors: [formats: [html: RhoWeb.ErrorHTML], layout: false],
  pubsub_server: Rho.PubSub,
  live_view: [signing_salt: "rho_lv_salt"]
```

### `apps/rho_frameworks/config/config.exs`
```elixir
import Config

config :rho_frameworks, ecto_repos: [RhoFrameworks.Repo]
config :rho_frameworks, RhoFrameworks.Repo,
  database: Path.expand("../priv/rho.db", __DIR__),
  pool_size: 5
```

---

## Priv Directory Migration

| Current | New |
|---|---|
| `priv/repo/migrations/*` | `apps/rho_frameworks/priv/repo/migrations/*` |
| `priv/py_agents/*` | `apps/rho_stdlib/priv/py_agents/*` |

---

## Execution Order

### Phase 1: Scaffold umbrella + core app (no renames yet)
1. Create umbrella `mix.exs` at root
2. Create `apps/rho/mix.exs` with minimal deps
3. Move core modules to `apps/rho/lib/rho/` (exact same paths/names for now)
4. Create `apps/rho/lib/rho/application.ex` with stripped supervision tree
5. Verify `mix compile` passes for `apps/rho` alone

### Phase 2: Move non-core apps
6. Create `apps/rho_frameworks/` — move Repo, Accounts, Frameworks, migrations
7. Create `apps/rho_web/` — move `lib/rho_web/`, Observatory
8. Create `apps/rho_stdlib/` — move tools, plugins, mounts, skills
9. Create `apps/rho_cli/` — move Config, CLI, mix tasks, CommandParser
10. Verify each app compiles in isolation

### Phase 3: Delete legacy shims
11. Delete all 9 deprecated alias modules listed above
12. Update all call sites to use canonical names
13. Verify full umbrella `mix test` passes

### Phase 4: Rename internals
14. `Rho.Mount.PromptSection` → `Rho.PromptSection` (move file + update all refs)
15. Struct field renames: `reasoner` → `turn_strategy`, `mount_context` → `context`, `memory_mod` → `tape_module`, `memory_ref` → `tape_ref`
16. Config key renames in CLI.Config: `mounts:` → `plugins:`, `reasoner:` → `turn_strategy:`
17. Verify full umbrella `mix test` passes

### Phase 5: Split registries
18. Create `Rho.TransformerRegistry` + `Rho.TransformerInstance`
19. Extract transformer logic from `Rho.PluginRegistry`
20. Update `Rho.Runner` and `Rho.TurnStrategy.Direct` to use `TransformerRegistry`
21. Update registration call sites (CLI boot, web boot)
22. Verify full umbrella `mix test` passes

### Phase 6: Tool consolidation
23. Merge `anchor.ex`, `search_history.ex`, `recall_context.ex`, `clear_memory.ex`, `tape_tools.ex` into `Rho.Stdlib.Plugins.Tape`
24. Merge `finish.ex`, `end_turn.ex` into `Rho.Stdlib.Plugins.Control`
25. Update plugin module map
26. Verify full umbrella `mix test` passes

### Phase 7: Rewrite README
27. Update root `README.md` to describe the umbrella structure
28. Write per-app READMEs
29. Use only canonical names — no `Mount`, `Reasoner`, `AgentLoop` references
30. Remove aspirational file tree; replace with actual tree

### Phase 8: Cleanup
31. Update `AGENTS.md` / `CLAUDE.md` to match new structure
32. Update `.rho.exs` example in docs
33. Delete `erl_crash.dump`, stale `.png` files, `blog.txt`, `short_story.txt`, demo outputs from repo root
34. Remove unused `Rho.hello/0` from `lib/rho.ex`

---

## Cross-Reference: Callers to Update

These are the specific call sites that reference legacy modules and must be updated:

### `Rho.MountRegistry` callers (→ `Rho.PluginRegistry`):
- `lib/rho/agent/worker.ex` lines 893, 950 — `Rho.MountRegistry.collect_tools/1`
- `lib/mix/tasks/rho.run.ex` line 32 — `Rho.MountRegistry.collect_tools/1`
- `lib/rho/application.ex` line 52, 90 — `Rho.MountRegistry` (start_link, register)

### `Rho.AgentLoop` callers (→ `Rho.Runner`):
- `lib/mix/tasks/rho.run.ex` line 45 — `Rho.AgentLoop.run/3`

### `Rho.Mount.PromptSection` callers (→ `Rho.PromptSection`):
- `lib/rho/runner.ex` lines 130, 155–157 — `alias Rho.Mount.PromptSection`
- `lib/rho/plugin_registry.ex` lines 140, 157, 165–166
- `lib/rho/turn_strategy.ex` line 41
- `lib/rho/plugins/step_budget.ex` (implicit via Plugin return)
- All plugins returning `PromptSection` structs

### `config[:reasoner]` callers (→ `config[:turn_strategy]`):
- `lib/rho/config.ex` line 115 — `config[:reasoner]`
- `lib/mix/tasks/rho.run.ex` line 39 — `config.reasoner`
- `lib/rho/runner.ex` line 83 — `opts[:reasoner]`

### `Rho.Config.memory_module/0` callers:
- `lib/rho/application.ex` line 29
- `lib/rho/agent/worker.ex` line 172

---

## Verification Checklist

After each phase, verify:
- [ ] `mix compile --warnings-as-errors` passes for each app
- [ ] `mix test` passes for each app
- [ ] `mix rho.run "test"` works end-to-end
- [ ] `mix rho.chat` works end-to-end
- [ ] No references to deleted modules remain (`grep -r "MountRegistry\|AgentLoop\|Rho\.Mount\b\|Rho\.Reasoner\b" apps/`)
- [ ] Each app's `mix.exs` has only the deps it actually needs
- [ ] `apps/rho` compiles without Phoenix, Ecto, bcrypt, pythonx, xlsxir deps
