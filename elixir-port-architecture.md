# Rho Elixir Port — Architecture Plan

This document describes the full architecture for porting Rho from Python to Elixir/OTP, leveraging **Jido** (agent framework) and **ReqLLM** (LLM client) to eliminate custom plumbing, while preserving the ability to write plugins in Python (via Pythonx) and JavaScript (via MquickjsEx/QuickJS).

> **Library stability note**: Pin `jido`, `jido_ai`, and `req_llm` to exact versions. Design against the documented API subset only. If an API is not documented upstream, don't depend on it — wrap it in a local function you can swap later.

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Supervision Tree](#2-supervision-tree)
3. [Agent Core (Jido)](#3-agent-core-jido)
4. [LLM Integration (ReqLLM)](#4-llm-integration-reqllm)
5. [Actions (Tools)](#5-actions-tools)
6. [Hook System](#6-hook-system)
7. [Polyglot Plugin Runtime](#7-polyglot-plugin-runtime)
8. [Tape and Storage](#8-tape-and-storage)
9. [Skills System](#9-skills-system)
10. [Channels](#10-channels)
11. [Configuration](#11-configuration)
12. [CLI](#12-cli)
13. [Observability](#13-observability)
14. [Operational Concerns](#14-operational-concerns)
15. [Testing Strategy](#15-testing-strategy)
16. [Module Inventory](#16-module-inventory)
17. [Migration Strategy](#17-migration-strategy)

---

## 1. Design Principles

### What stays the same

- **Hook-first, plugin-driven** — all behaviour provided by plugins implementing hook contracts.
- **Envelope-agnostic messages** — channels wrap messages into structured envelopes.
- **Append-only tape** — conversation memory as an event log with fork/commit isolation.
- **Progressive skill disclosure** — summary always in prompt, full body on demand.
- **Command mode** (`,tool args`) alongside agent mode.

### What changes

| Python pattern | Elixir replacement | Why |
|---|---|---|
| `asyncio.create_task` per message | Jido `AgentServer` per session | Supervised, schema-validated, crash-isolated |
| `ContextVar` for tape fork isolation | Immutable agent state via `cmd/2` | Pure functions, no shared mutable state |
| `pluggy` hook dispatch | `Behaviour` callbacks + ETS-backed dispatch | Native pattern, no GenServer bottleneck |
| `republic` LLM orchestration | Explicit ReqLLM loop + Jido Actions | Full control, provider-agnostic |
| `threading.Lock` in TapeFile | Single GenServer serializes access | No locks ever needed |
| `asyncio.Event` + `call_later` debounce | `Process.send_after` + GenServer state | First-class timer support |
| `try/finally` for state cleanup | Process `terminate/2` + monitors | Guaranteed cleanup on crash |
| Manual error isolation in `notify_error` | Supervisor `one_for_one` strategy | Crashes don't cascade |
| `asyncio.Queue` shared bus | Process mailboxes | Zero-cost message passing |
| Custom `Tool` registry + `@tool` decorator | `Jido.Action` modules | Schema validation, auto LLM conversion |
| Custom `LLM` HTTP client | ReqLLM | 16 providers, streaming, cost tracking |

### New capabilities from BEAM + Jido

- **Hot code reloading** — update plugins without restarting the system.
- **Distribution** — run channels on separate nodes if needed.
- **Per-process garbage collection** — a crashed turn's memory is instantly reclaimed.
- **Preemptive scheduling** — a slow tool can't starve other turns.
- **Agent hierarchy** — Jido supports parent-child agent spawning for future multi-agent workflows.
- **Built-in telemetry** — ReqLLM publishes `[:req_llm, :token_usage]` events with cost tracking.

### What Jido and ReqLLM replace

| Former custom module | Replaced by | Lines saved |
|---|---|---|
| `Rho.Framework` (GenServer orchestrator) | `Jido.AgentServer` | ~30 |
| `Rho.Turn` (temporary process) | Signal processing in AgentServer | ~50 |
| `Rho.Agent` (agent loop) | `Jido.AI.Agent` + explicit ReqLLM loop | ~80 |
| `Rho.LLM` (HTTP client) | `ReqLLM.generate_text/3` | ~30 |
| `Rho.Tool` + `Rho.Tool.Registry` + `Rho.Tool.Executor` | `Jido.Action` modules | ~100 |
| `Rho.Agent.CommandParser` | Keep (simple, app-specific) | — |

### What stays custom

| Module | Why |
|---|---|
| `Rho.Tape.*` | Append-only event log is Rho's core innovation; Jido has no equivalent |
| `Rho.Channel.*` | Transport layer (Telegram, CLI) is app-specific |
| `Rho.Skill` | Rho's markdown-based progressive disclosure differs from Jido's concept |
| `Rho.HookRuntime` | Simplified multi-plugin hook dispatch for `load_state`/`save_state` patterns |
| `Rho.Plugin.PythonRunner/JsRunner` | Polyglot runtime is Rho-specific |
| `Rho.Config` | App-specific configuration |

---

## 2. Supervision Tree

```
Rho.Application
├── {Registry, keys: :unique, name: Rho.Registry}  # Process registry (debounce, plugins)
│
├── Rho.TaskSupervisor                    # Task.Supervisor — fire-and-forget async work
│
├── Rho.Jido                              # Jido instance — agent registry + supervision
│   └── (per-session Jido.AgentServer)    # Managed agent processes
│
├── Rho.HookRuntime                       # GenServer — plugin registration + ETS table
│
├── Rho.TapeStoreSupervisor               # Supervisor
│   ├── Rho.Tape.Store                    # GenServer — serialized JSONL writes + ETS reads
│   └── Rho.Tape.Service                  # (stateless module — calls Store directly)
│
├── Rho.PluginSupervisor                  # DynamicSupervisor — foreign plugin runtimes
│   ├── Rho.Plugin.PythonRunner           # GenServer — Pythonx eval, serialized via GIL
│   └── Rho.Plugin.JsRunner              # DynamicSupervisor — per-plugin QuickJS contexts
│       ├── Rho.Plugin.JsContext (plugin_a)
│       └── Rho.Plugin.JsContext (plugin_b)
│
├── Rho.ChannelSupervisor                 # Supervisor (one_for_one)
│   ├── Rho.Channel.Cli                   # GenServer — REPL process
│   ├── Rho.Channel.Telegram              # GenServer — polling + webhook
│   └── Rho.Channel.Debounce.Supervisor   # DynamicSupervisor
│       ├── Rho.Channel.Debounce (session_1)
│       └── Rho.Channel.Debounce (session_2)
│
└── Rho.Channel.Manager                   # GenServer — routes messages to/from agents
```

Key differences from Python:

- `Rho.Framework`, `Rho.TurnSupervisor`, `Rho.Turn` are eliminated. Jido provides process registry, agent supervision, and turn lifecycle internally.
- `Rho.Registry` is an Elixir `Registry` for looking up debounce handlers and JS plugin contexts by name.
- `Rho.TaskSupervisor` is a `Task.Supervisor` for fire-and-forget async work (channel message routing, etc.).
- `Rho.Tape.Service` is a stateless module (not a GenServer) — it calls `Rho.Tape.Store` directly.

### Supervision strategies

| Supervisor | Strategy | Rationale |
|---|---|---|
| `Application` | `one_for_one` | Independent top-level components |
| `Rho.Jido` | Jido-managed | Per-session agents with registry |
| `TapeStoreSupervisor` | `one_for_one` | Store is self-contained |
| `PluginSupervisor` | `one_for_one` | Python and JS runtimes independent |
| `ChannelSupervisor` | `one_for_one` | Channel crash shouldn't affect others |
| `JsRunner` | `DynamicSupervisor` | Per-plugin contexts, independent |

---

## 3. Agent Core (Jido)

### Jido instance

```elixir
defmodule Rho.Jido do
  use Jido, otp_app: :rho
end
```

```elixir
# config/config.exs
config :rho, Rho.Jido,
  max_tasks: 1000
```

### `Rho.RhoAgent` — the core agent

Replaces `Rho.Framework`, `Rho.Turn`, and `Rho.Agent` with a single Jido agent definition.

```elixir
defmodule Rho.RhoAgent do
  use Jido.AI.Agent,
    name: "rho",
    description: "Rho AI agent",
    schema: [
      session_id: [type: :string, required: true],
      workspace: [type: :string, required: true],
      tape_name: [type: :string],
      channel: [type: :string, default: "cli"],
      chat_id: [type: :string, default: "default"]
    ],
    tools: [
      Rho.Actions.Bash,
      Rho.Actions.FsRead,
      Rho.Actions.FsWrite,
      Rho.Actions.FsEdit,
      Rho.Actions.WebFetch,
      Rho.Actions.TapeInfo,
      Rho.Actions.TapeSearch,
      Rho.Actions.TapeReset,
      Rho.Actions.TapeHandoff,
      Rho.Actions.TapeAnchors,
      Rho.Actions.SkillExpand,
      Rho.Actions.Help
    ],
    signal_routes: [
      {"rho.message.inbound", Rho.Actions.HandleInbound},
      {"rho.command.inbound", Rho.Actions.HandleCommand}
    ]

  # NOTE: No on_before_cmd — tape bootstrapping happens in HandleInbound.run/2.
  # Jido's on_before_cmd is intended for pure transformations, not side effects.
end
```

### Session-to-agent mapping

Each unique session gets a supervised agent process. The channel manager resolves the session and routes messages as Jido signals.

```elixir
defmodule Rho.SessionRouter do
  @doc "Resolves session ID and routes message to the correct agent process."

  def route_message(%Rho.Channel.Message{} = message) do
    session_id = resolve_session(message)
    agent_id = "rho:#{session_id}"
    pid = find_or_start_agent(agent_id, message, session_id)

    signal_type = if String.starts_with?(message.content, ","),
      do: "rho.command.inbound",
      else: "rho.message.inbound"

    signal = Jido.Signal.new!(signal_type, %{
      content: message.content,
      channel: message.channel,
      chat_id: message.chat_id,
      context: message.context
    }, source: "/channel/#{message.channel}")

    Jido.AgentServer.call(pid, signal)
  end

  defp find_or_start_agent(agent_id, message, session_id) do
    case Rho.Jido.whereis(agent_id) do
      nil ->
        workspace = message.context[:workspace] || File.cwd!()
        case Rho.Jido.start_agent(Rho.RhoAgent,
          id: agent_id,
          session_id: session_id,
          workspace: workspace,
          channel: message.channel,
          chat_id: message.chat_id
        ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
      pid -> pid
    end
  end

  defp resolve_session(message) do
    case Rho.HookRuntime.call_first(:resolve_session, %{message: message}) do
      nil -> "#{message.channel}:#{message.chat_id}"
      session_id -> session_id
    end
  end
end
```

### Inbound message handling (replaces Turn lifecycle)

```elixir
defmodule Rho.Actions.HandleInbound do
  use Jido.Action,
    name: "handle_inbound",
    description: "Process an inbound message through the full turn lifecycle",
    schema: [
      content: [type: :string, required: true],
      channel: [type: :string, required: true],
      chat_id: [type: :string, default: "default"],
      context: [type: :map, default: %{}]
    ]

  def run(params, context) do
    agent = context.agent
    session_id = agent.state.session_id
    workspace = agent.state.workspace

    # 0. Ensure tape is initialized (moved from on_before_cmd)
    tape_name = Rho.Tape.Service.session_tape(session_id, workspace)
    Rho.Tape.Service.ensure_bootstrap_anchor(tape_name)

    # 1. Load state from hooks
    hook_states = Rho.HookRuntime.call_many(:load_state, %{
      message: params, session_id: session_id
    })
    merged_state = merge_states(hook_states, agent.state)

    # 2. Build prompt
    prompt = Rho.HookRuntime.call_first(:build_prompt, %{
      message: params, session_id: session_id, state: merged_state
    })
    prompt = prompt || params.content

    # 3. Record user message to tape (string keys for persistence consistency)
    Rho.Tape.Service.append(tape_name, :message, %{
      "role" => "user", "content" => params.content
    })

    # 4. Build system prompt
    system_prompt = build_system_prompt(prompt, merged_state)

    # 5. Run agent loop via ReqLLM
    model = Rho.Config.agent().model
    messages = Rho.Tape.Service.messages_for_llm(tape_name)
    tools = Rho.RhoAgent.__agent_config__().tools

    result =
      try do
        {:ok, response} = run_agent_loop(model, messages, system_prompt, tools,
          tape_name: tape_name, state: merged_state)

        # 6. Record assistant response
        Rho.Tape.Service.append(tape_name, :message, %{
          "role" => "assistant", "content" => response
        })

        # 7. Render + dispatch outbound
        outbounds = Rho.HookRuntime.call_many(:render_outbound, %{
          message: params, session_id: session_id,
          state: merged_state, model_output: response
        })
        outbounds = if outbounds == [], do: [default_outbound(params, response)], else: outbounds
        Enum.each(outbounds, &Rho.Channel.Manager.dispatch/1)

        {:ok, %{response: response}}
      rescue
        e ->
          Rho.HookRuntime.notify_error("handle_inbound", e, params)
          {:error, Exception.message(e)}
      after
        # 8. Save state (always — even on error)
        Rho.HookRuntime.call_many(:save_state, %{
          session_id: session_id, state: merged_state,
          message: params, model_output: ""
        })
      end

    result
  end

  @doc "Explicit ReqLLM tool loop. Used by both single-agent and room modes."
  def run_agent_loop(model, messages, system_prompt, tools, opts) do
    tape_name = opts[:tape_name]
    state = opts[:state] || %{}
    max_steps = state[:max_steps] || Rho.Config.agent().max_steps

    context = [ReqLLM.Context.system(system_prompt)] ++ messages

    # Convert Jido actions to ReqLLM tool definitions
    req_tools = Enum.map(tools, fn action_mod ->
      schema = action_mod.__action_schema__()
      ReqLLM.tool(
        name: to_string(action_mod.__action_name__()),
        description: action_mod.__action_description__(),
        parameter_schema: schema
      )
    end)

    do_loop(model, context, req_tools, tools, tape_name, state, step: 1, max_steps: max_steps)
  end

  defp do_loop(_model, _context, _req_tools, _tools, _tape, _state,
               step: step, max_steps: max) when step > max do
    {:error, "max steps exceeded (#{max})"}
  end

  defp do_loop(model, context, req_tools, tools, tape_name, state,
               step: step, max_steps: max) do
    Rho.Tape.Service.append_event(tape_name, "loop.step.start", %{"step" => step})

    case ReqLLM.generate_text(model, context, tools: req_tools) do
      {:ok, response} ->
        case ReqLLM.Response.tool_calls(response) do
          [] ->
            {:ok, ReqLLM.Response.text(response)}

          tool_calls ->
            # Record tool calls on tape
            Rho.Tape.Service.append(tape_name, :tool_call, %{
              "tool_calls" => Enum.map(tool_calls, &Map.from_struct/1)
            })

            # Execute tools and collect results
            results = Enum.map(tool_calls, fn tc ->
              execute_tool(tc, tools, tape_name, state)
            end)

            # Record tool results on tape
            Rho.Tape.Service.append(tape_name, :tool_result, %{
              "results" => Enum.map(results, fn {_status, result} -> inspect(result) end)
            })

            # Build updated context explicitly (no undocumented helpers)
            assistant_msg = %{"role" => "assistant", "tool_calls" => Enum.map(tool_calls, &Map.from_struct/1)}
            tool_msgs = Enum.zip(tool_calls, results) |> Enum.map(fn {tc, {_status, result}} ->
              %{"role" => "tool", "tool_call_id" => tc.id, "name" => tc.function.name, "content" => inspect(result)}
            end)

            updated_context = context ++ [assistant_msg] ++ tool_msgs
            do_loop(model, updated_context, req_tools, tools, tape_name, state,
              step: step + 1, max_steps: max)
        end

      {:error, reason} ->
        Rho.Tape.Service.append_event(tape_name, "loop.error", %{
          "error" => inspect(reason)
        })
        {:error, reason}
    end
  end

  defp execute_tool(tool_call, action_modules, tape_name, state) do
    action_mod = Enum.find(action_modules, fn mod ->
      to_string(mod.__action_name__()) == tool_call.function.name
    end)

    if action_mod do
      tool_context = %{state: state, tape: tape_name}
      case action_mod.run(tool_call.function.arguments, tool_context) do
        {:ok, result} -> {:ok, result}
        {:error, reason} ->
          Rho.Tape.Service.append_event(tape_name, "tool.error", %{
            "tool" => tool_call.function.name,
            "error" => inspect(reason)
          })
          {:error, reason}
      end
    else
      {:error, "unknown tool: #{tool_call.function.name}"}
    end
  end

  defp build_system_prompt(prompt, state) do
    base = Rho.HookRuntime.call_first(:system_prompt, %{prompt: prompt, state: state})
    base = base || Rho.Defaults.system_prompt()

    skills = Rho.Skill.discover(state[:workspace])
    skill_section = Rho.Skill.render_prompt(skills, Rho.Skill.expanded_hints(prompt, skills))

    "#{base}\n\n#{skill_section}"
  end

  defp merge_states(hook_states, agent_state) do
    # agent.state is already a map — no Map.from_struct needed
    Enum.reduce(hook_states, agent_state, fn state, acc ->
      if is_map(state), do: Map.merge(acc, state), else: acc
    end)
  end

  defp default_outbound(params, response) do
    %Rho.Channel.Message{
      channel: params.channel,
      chat_id: params.chat_id,
      content: response,
      kind: :normal
    }
  end
end
```

### Command mode handling

```elixir
defmodule Rho.Actions.HandleCommand do
  use Jido.Action,
    name: "handle_command",
    description: "Execute a direct tool command (,tool args syntax)",
    schema: [
      content: [type: :string, required: true],
      channel: [type: :string, required: true],
      chat_id: [type: :string, default: "default"]
    ]

  def run(params, context) do
    agent = context.agent
    tape_name = agent.state.tape_name ||
      Rho.Tape.Service.session_tape(agent.state.session_id, agent.state.workspace)

    "," <> line = params.content

    {tool_name, args} = Rho.CommandParser.parse(line)

    action_mod = Rho.Actions.Registry.lookup(tool_name) ||
                 Rho.Actions.Bash

    tool_context = %{state: agent.state, tape: tape_name}
    result = case action_mod.run(args, tool_context) do
      {:ok, output} -> output
      {:error, reason} -> "Error: #{reason}"
    end

    Rho.Tape.Service.append_event(tape_name, "command", %{
      "tool" => tool_name, "result" => inspect(result)
    })

    Rho.Channel.Manager.dispatch(%Rho.Channel.Message{
      channel: params.channel,
      chat_id: params.chat_id,
      content: inspect(result),
      kind: :command
    })

    {:ok, %{result: result}}
  end
end
```

### Command parsing

```elixir
defmodule Rho.CommandParser do
  @doc "Parses `,tool_name key=value` syntax"

  def parse(line) do
    tokens = OptionParser.split(line)

    case tokens do
      [] -> {"bash", %{"cmd" => ""}}
      [name | rest] ->
        args = parse_args(rest)
        {name, args}
    end
  end

  defp parse_args(tokens) do
    {kv_tokens, positional} = Enum.split_with(tokens, &String.contains?(&1, "="))

    kwargs = Map.new(kv_tokens, fn token ->
      [k, v] = String.split(token, "=", parts: 2)
      {k, v}
    end)

    if positional != [] do
      Map.put(kwargs, "_positional", positional)
    else
      kwargs
    end
  end
end
```

### `Rho.Envelope`

```elixir
defmodule Rho.Envelope do
  @type t :: map()

  def field(envelope, key, default \\ nil)
  def field(%{} = envelope, key, default), do: Map.get(envelope, key, default)

  def content(envelope), do: field(envelope, :content, "")

  def normalize(envelope) when is_map(envelope), do: envelope
end
```

---

## 4. LLM Integration (ReqLLM)

ReqLLM replaces the custom `Rho.LLM` module entirely. No custom HTTP client needed.

### Provider configuration

```elixir
# Model string format: "provider:model_name"
# Examples:
#   "openrouter:anthropic/claude-sonnet"
#   "openai:gpt-4"
#   "anthropic:claude-sonnet-4-5-20250929"

# API keys via environment or config
config :req_llm, :openrouter_api_key, System.get_env("RHO_API_KEY")
```

### Usage in agent loop

The agent loop (in `HandleInbound`) uses ReqLLM's **documented primitives only**:

1. Build a context list (system + messages)
2. Call `ReqLLM.generate_text/3`
3. Inspect `ReqLLM.Response.tool_calls/1` and `ReqLLM.Response.text/1`
4. Execute tools with our own executor
5. Build updated context explicitly (system + messages + assistant + tool results)
6. Loop until no tool calls or step limit

We do NOT rely on:
- `ReqLLM.Response.to_context/1` (undocumented / version-sensitive)
- `ReqLLM.Context.execute_and_append_tools/3` (if behavior is unclear)
- Automatic tool callback execution via `ReqLLM.tool(..., callback: ...)` — we execute tools ourselves for tape integration

```elixir
# Simple text generation
{:ok, response} = ReqLLM.generate_text(
  "openrouter:anthropic/claude-sonnet",
  context,
  tools: tools,
  temperature: 0.7,
  max_tokens: 1024
)

# Access response
text = ReqLLM.Response.text(response)
tool_calls = ReqLLM.Response.tool_calls(response)
usage = response.usage  # %{input_tokens: 8, output_tokens: 12, total_cost: 0.0006}
```

### Streaming (for future CLI enhancement)

```elixir
{:ok, stream} = ReqLLM.stream_text(model, context)

ReqLLM.StreamResponse.tokens(stream)
|> Stream.each(&IO.write/1)
|> Stream.run()
```

### What ReqLLM provides that we no longer build

| Feature | Details |
|---|---|
| 16 providers | Anthropic, OpenAI, OpenRouter, Google, Groq, xAI, etc. |
| Tool calling | Native support with round-tripping |
| Structured output | `generate_object/4` with schema validation |
| Streaming | First-class SSE via Finch |
| Cost tracking | Automatic per-request token + cost calculation |
| Telemetry | `[:req_llm, :token_usage]` events |
| Multi-source auth | Per-request, in-memory, config, env vars, .env |
| Req middleware | Retry, rate limiting, logging via Req ecosystem |

---

## 5. Actions (Tools)

Jido Actions replace `Rho.Tool`, `Rho.Tool.Registry`, `Rho.Tool.Executor`, and `Rho.Builtin.Tools`.

Each tool is a validated `Jido.Action` module with schema, description, and a `run/2` function. Jido automatically converts actions to LLM-compatible tool definitions.

### Action registry

```elixir
defmodule Rho.Actions.Registry do
  @doc "Maps tool names to action modules for command-mode lookup."

  @tools %{
    "bash" => Rho.Actions.Bash,
    "fs.read" => Rho.Actions.FsRead,
    "fs.write" => Rho.Actions.FsWrite,
    "fs.edit" => Rho.Actions.FsEdit,
    "web.fetch" => Rho.Actions.WebFetch,
    "tape.info" => Rho.Actions.TapeInfo,
    "tape.search" => Rho.Actions.TapeSearch,
    "tape.reset" => Rho.Actions.TapeReset,
    "tape.handoff" => Rho.Actions.TapeHandoff,
    "tape.anchors" => Rho.Actions.TapeAnchors,
    "skill" => Rho.Actions.SkillExpand,
    "help" => Rho.Actions.Help
  }

  def lookup(name) do
    Map.get(@tools, name) ||
      Map.get(@tools, String.replace(name, "_", "."))
  end

  def all, do: @tools

  def render_prompt do
    lines = @tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, mod} -> "- #{name}: #{mod.__action_description__()}" end)

    "<available_tools>\n#{Enum.join(lines, "\n")}\n</available_tools>"
  end
end
```

### Workspace boundary enforcement

All filesystem actions share a common path resolver that prevents escaping the workspace:

```elixir
defmodule Rho.Actions.PathUtils do
  @doc "Resolves a path relative to workspace, preventing escape."
  def resolve_path(context, raw_path) do
    workspace = context.state[:workspace] || raise "No workspace for path resolution"
    expanded_workspace = Path.expand(workspace)

    full = if Path.type(raw_path) == :absolute do
      Path.expand(raw_path)
    else
      Path.join(expanded_workspace, raw_path) |> Path.expand()
    end

    unless String.starts_with?(full, expanded_workspace) do
      raise "Path escapes workspace: #{raw_path}"
    end

    full
  end
end
```

### Builtin actions

```elixir
defmodule Rho.Actions.Bash do
  use Jido.Action,
    name: "bash",
    description: "Execute a shell command",
    schema: [
      cmd: [type: :string, required: true],
      cwd: [type: :string],
      timeout_seconds: [type: :integer, default: 30]
    ]

  def run(%{cmd: cmd} = params, context) do
    cwd = params[:cwd] || context.state[:workspace] || "."
    timeout = (params[:timeout_seconds] || 30) * 1000

    case System.cmd("sh", ["-c", cmd],
           cd: cwd, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} -> {:ok, %{output: output || "(no output)"}}
      {output, code} -> {:error, "exit code #{code}: #{output}"}
    end
  end
end

defmodule Rho.Actions.FsRead do
  use Jido.Action,
    name: "fs_read",
    description: "Read a text file",
    schema: [
      path: [type: :string, required: true],
      offset: [type: :integer, default: 0],
      limit: [type: :integer]
    ]

  def run(%{path: path} = params, context) do
    full_path = Rho.Actions.PathUtils.resolve_path(context, path)

    case File.read(full_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        slice = if params[:limit],
          do: Enum.slice(lines, params.offset, params.limit),
          else: Enum.drop(lines, params.offset)
        {:ok, %{content: Enum.join(slice, "\n")}}
      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  end
end

defmodule Rho.Actions.FsWrite do
  use Jido.Action,
    name: "fs_write",
    description: "Write or create a text file",
    schema: [
      path: [type: :string, required: true],
      content: [type: :string, required: true]
    ]

  def run(%{path: path, content: content}, context) do
    full_path = Rho.Actions.PathUtils.resolve_path(context, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    {:ok, %{written: full_path}}
  end
end

defmodule Rho.Actions.FsEdit do
  use Jido.Action,
    name: "fs_edit",
    description: "Find and replace text in a file",
    schema: [
      path: [type: :string, required: true],
      old: [type: :string, required: true],
      new: [type: :string, required: true],
      start: [type: :integer, default: 0]
    ]

  def run(%{path: path, old: old, new: new} = params, context) do
    full_path = Rho.Actions.PathUtils.resolve_path(context, path)
    content = File.read!(full_path)
    lines = String.split(content, "\n")
    {before, after_lines} = Enum.split(lines, params[:start] || 0)
    section = Enum.join(after_lines, "\n")

    unless String.contains?(section, old) do
      raise "Text not found in #{path} after line #{params[:start] || 0}"
    end

    new_section = String.replace(section, old, new, global: false)
    new_content = Enum.join(before, "\n") <> "\n" <> new_section
    File.write!(full_path, new_content)
    {:ok, %{edited: full_path}}
  end
end

defmodule Rho.Actions.WebFetch do
  use Jido.Action,
    name: "web_fetch",
    description: "HTTP GET a URL",
    schema: [
      url: [type: :string, required: true],
      timeout: [type: :integer, default: 10]
    ]

  def run(%{url: url} = params, _context) do
    timeout = (params[:timeout] || 10) * 1000

    case Req.get(url,
           headers: [{"accept", "text/markdown"}],
           receive_timeout: timeout) do
      {:ok, %{body: body}} -> {:ok, %{body: body}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
```

### Tape actions

```elixir
defmodule Rho.Actions.TapeInfo do
  use Jido.Action,
    name: "tape_info",
    description: "Show tape metadata (entries, anchors, last anchor)",
    schema: []

  def run(_params, context) do
    {:ok, Rho.Tape.Service.info(context.tape)}
  end
end

defmodule Rho.Actions.TapeSearch do
  use Jido.Action,
    name: "tape_search",
    description: "Search conversation tape for matching entries",
    schema: [
      query: [type: :string, required: true],
      limit: [type: :integer, default: 20]
    ]

  def run(%{query: query} = params, context) do
    results = Rho.Tape.Service.search(context.tape, query, params[:limit] || 20)
    {:ok, %{results: results}}
  end
end

defmodule Rho.Actions.TapeReset do
  use Jido.Action,
    name: "tape_reset",
    description: "Clear the tape and start fresh",
    schema: [archive: [type: :boolean, default: false]]

  def run(params, context) do
    Rho.Tape.Service.reset(context.tape, params[:archive] || false)
    {:ok, %{status: "tape reset"}}
  end
end

defmodule Rho.Actions.TapeHandoff do
  use Jido.Action,
    name: "tape_handoff",
    description: "Create a handoff anchor checkpoint",
    schema: [
      name: [type: :string, default: "handoff"],
      summary: [type: :string, default: ""]
    ]

  def run(params, context) do
    Rho.Tape.Service.handoff(context.tape, params[:name] || "handoff", params[:summary] || "")
    {:ok, %{status: "handoff created"}}
  end
end

defmodule Rho.Actions.TapeAnchors do
  use Jido.Action,
    name: "tape_anchors",
    description: "List all anchors in the tape",
    schema: []

  def run(_params, context) do
    entries = Rho.Tape.Store.read(context.tape)
    anchors = Enum.filter(entries, &(&1.kind == :anchor))
    {:ok, %{anchors: anchors}}
  end
end
```

### Meta actions

```elixir
defmodule Rho.Actions.SkillExpand do
  use Jido.Action,
    name: "skill",
    description: "Load a skill's full content by name",
    schema: [name: [type: :string, required: true]]

  def run(%{name: name}, context) do
    skills = Rho.Skill.discover(context.state[:workspace])
    case Enum.find(skills, &(String.downcase(&1.name) == String.downcase(name))) do
      nil -> {:ok, %{result: "(no such skill: #{name})"}}
      skill -> {:ok, %{location: skill.location, body: skill.body}}
    end
  end
end

defmodule Rho.Actions.Help do
  use Jido.Action,
    name: "help",
    description: "Show help and available commands",
    schema: []

  def run(_params, _context) do
    help_text = """
    Rho commands:
      ,bash cmd="..."      — Execute shell command
      ,fs.read path=...    — Read a file
      ,fs.write path=...   — Write a file
      ,fs.edit path=... old="..." new="..."  — Edit a file
      ,web.fetch url=...   — Fetch a URL
      ,tape.info           — Show tape status
      ,tape.search query=... — Search tape
      ,tape.reset          — Clear tape
      ,tape.handoff        — Create checkpoint
      ,skill name=...      — Load a skill

    Or just type naturally to chat with the agent.
    """
    {:ok, %{help: help_text}}
  end
end
```

---

## 6. Hook System

The hook system is simplified compared to the previous plan. Most orchestration that hooks handled (resolve_session, build_prompt, run_model) is now internal to the agent. Hooks remain for **multi-plugin extension points**: state management, outbound rendering, and error handling.

### Hook contracts as behaviours

All callbacks take a **single context map** argument. This avoids the mismatch between multi-arg behaviour declarations and single-map dispatch that plagued the previous design.

```elixir
defmodule Rho.HookSpec do
  @doc "All hook callbacks are optional. Each takes a single context map."

  # --- First-result hooks (stop at first non-nil return) ---

  @callback resolve_session(context :: map()) :: {:ok, String.t()} | :skip
  @callback build_prompt(context :: map()) :: {:ok, String.t()} | :skip
  @callback provide_tape_store(context :: map()) :: {:ok, module()} | :skip
  @callback system_prompt(context :: map()) :: String.t() | nil

  # --- Broadcast hooks (all results collected) ---

  @callback load_state(context :: map()) :: map()
  @callback save_state(context :: map()) :: :ok
  @callback render_outbound(context :: map()) :: [map()]
  @callback dispatch_outbound(context :: map()) :: :ok | :skip
  @callback provide_channels(context :: map()) :: [module()]
  @callback on_error(context :: map()) :: :ok
  @callback register_cli_commands(context :: map()) :: :ok

  @optional_callbacks [
    resolve_session: 1, build_prompt: 1, provide_tape_store: 1, system_prompt: 1,
    load_state: 1, save_state: 1, render_outbound: 1, dispatch_outbound: 1,
    provide_channels: 1, on_error: 1, register_cli_commands: 1
  ]
end
```

### `Rho.HookRuntime` (GenServer for registration, ETS for dispatch)

The GenServer only manages plugin registration. **Hook dispatch runs in the caller's process** by reading the plugin list from ETS. This eliminates the GenServer as a serialization bottleneck — slow plugins block only their own caller, not all hook dispatch system-wide.

```elixir
defmodule Rho.HookRuntime do
  use GenServer

  @table :rho_hook_plugins

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :protected, read_concurrency: true])
    {:ok, %{next_priority: 0}}
  end

  # --- Registration (goes through GenServer for write serialization) ---

  def register(plugin_module, _opts \\ []) do
    GenServer.call(__MODULE__, {:register, plugin_module})
  end

  @impl true
  def handle_call({:register, plugin_module}, _from, %{next_priority: p} = state) do
    :ets.insert(@table, {p, plugin_module})
    {:reply, :ok, %{state | next_priority: p + 1}}
  end

  # --- Dispatch (runs in caller process — no GenServer bottleneck) ---

  def plugins do
    :ets.tab2list(@table)
    |> Enum.sort_by(&elem(&1, 0), :desc)  # higher priority first
    |> Enum.map(&elem(&1, 1))
  end

  def call_first(hook_name, context) when is_map(context) do
    plugins()
    |> Enum.filter(&function_exported?(&1, hook_name, 1))
    |> Enum.reduce_while(nil, fn plugin, _acc ->
      case safe_apply(plugin, hook_name, [context]) do
        :skip -> {:cont, nil}
        {:ok, value} -> {:halt, value}
        value when value != nil -> {:halt, value}
        _ -> {:cont, nil}
      end
    end)
  end

  def call_many(hook_name, context) when is_map(context) do
    plugins()
    |> Enum.filter(&function_exported?(&1, hook_name, 1))
    |> Enum.map(&safe_apply(&1, hook_name, [context]))
    |> Enum.reject(&(&1 == nil or &1 == :skip))
  end

  def notify_error(stage, error, message) do
    for plugin <- plugins(),
        function_exported?(plugin, :on_error, 1) do
      safe_apply(plugin, :on_error, [%{stage: stage, error: error, message: message}])
    end
    :ok
  end

  def hook_report do
    all_hooks = Rho.HookSpec.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0))
    Map.new(all_hooks, fn hook ->
      impls = plugins() |> Enum.filter(&function_exported?(&1, hook, 1))
      {hook, impls}
    end)
  end

  defp safe_apply(plugin, hook_name, args) do
    apply(plugin, hook_name, args)
  rescue
    e ->
      require Logger
      Logger.warning("Hook #{hook_name} in #{inspect(plugin)} failed: #{inspect(e)}")
      nil
  end
end
```

### Plugin example

Plugins pattern-match what they need from the context map:

```elixir
defmodule MyPlugin do
  @behaviour Rho.HookSpec

  def resolve_session(%{message: %{channel: channel, chat_id: chat_id}}) do
    {:ok, "#{channel}:#{chat_id}"}
  end
end
```

### Hook dispatch for foreign plugins

Python and JavaScript plugins are dispatched through bridge modules that delegate to their respective runtimes. See [Section 7](#7-polyglot-plugin-runtime).

### Priority ordering

Plugins registered later have higher priority (same as Python). `Rho.Builtin` is always registered first.

---

## 7. Polyglot Plugin Runtime

> **v1 scope**: For v1, use Pythonx/QuickJS **only for trusted, internal plugins**. Untrusted or community plugins should run via Port-based workers (out-of-process isolation). The embedded runtimes described here are a convenience for local development, not a security boundary.

### Architecture overview

```
Rho.PluginSupervisor (DynamicSupervisor)
│
├── Rho.Plugin.PythonRunner (GenServer, singleton)
│   └── Pythonx embedded interpreter
│   └── Routes: call(plugin_name, hook_name, args) → result
│
└── Rho.Plugin.JsRunner (DynamicSupervisor)
    ├── Rho.Plugin.JsContext (GenServer, per-plugin)
    │   └── MquickjsEx context with registered Elixir callbacks
    └── ...
```

### Plugin manifest format

Foreign plugins declare their hooks via a `plugin.yaml` manifest:

```yaml
# my_python_plugin/plugin.yaml
name: my-python-plugin
language: python
description: Custom session resolver
hooks:
  - resolve_session
  - load_state
entry: my_plugin.py
dependencies:
  - requests>=2.28
```

```yaml
# my_js_plugin/plugin.yaml
name: my-js-plugin
language: javascript
description: Custom output renderer
hooks:
  - render_outbound
entry: plugin.js
```

### Plugin discovery

```
<workspace>/.rho/plugins/     # Project-local (highest priority)
~/.rho/plugins/               # Global user
```

Each subdirectory with a `plugin.yaml` is a plugin candidate. The framework reads the manifest, validates it, and generates a bridge module.

### Bridge module generation

For each foreign plugin, the framework dynamically generates an Elixir module that implements `Rho.HookSpec` and delegates to the appropriate runtime:

```elixir
# Auto-generated at startup for a Python plugin
defmodule Rho.Plugin.Bridge.MyPythonPlugin do
  @behaviour Rho.HookSpec

  def resolve_session(context) do
    Rho.Plugin.PythonRunner.call("my-python-plugin", "resolve_session", context)
  end

  def load_state(context) do
    Rho.Plugin.PythonRunner.call("my-python-plugin", "load_state", context)
  end
end
```

```elixir
# Auto-generated for a JavaScript plugin
defmodule Rho.Plugin.Bridge.MyJsPlugin do
  @behaviour Rho.HookSpec

  def render_outbound(context) do
    Rho.Plugin.JsRunner.call("my-js-plugin", "render_outbound", context)
  end
end
```

### Python runtime: `Rho.Plugin.PythonRunner`

```elixir
defmodule Rho.Plugin.PythonRunner do
  use GenServer

  @doc """
  Singleton GenServer that serializes all Python calls through Pythonx.
  The GIL means concurrent calls would serialize anyway — making it
  explicit avoids surprises and provides backpressure.

  WARNING: Use only for trusted plugins. String interpolation into Python
  source is inherently unsafe. For untrusted plugins, use Port-based
  workers instead.
  """

  defstruct [:initialized, plugins: %{}]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Pythonx.uv_init("""
    [project]
    name = "rho-plugins"
    version = "0.1.0"
    requires-python = ">=3.11"
    dependencies = []
    """)
    {:ok, %__MODULE__{initialized: true}}
  end

  def call(plugin_name, hook_name, context) do
    GenServer.call(__MODULE__, {:call, plugin_name, hook_name, context}, :timer.seconds(30))
  end

  @impl true
  def handle_call({:call, plugin_name, hook_name, context}, _from, state) do
    result = do_python_call(plugin_name, hook_name, context, state)
    {:reply, result, state}
  end

  defp do_python_call(plugin_name, hook_name, context, _state) do
    # Serialize context as JSON to avoid string interpolation attacks
    context_json = Jason.encode!(context)
    {result, _} = Pythonx.eval("""
    import json
    _ctx = json.loads(#{inspect(context_json)})
    plugin = __rho_plugins__[#{inspect(plugin_name)}]
    result = getattr(plugin, #{inspect(hook_name)})(_ctx)
    result
    """)
    Pythonx.decode(result)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def load_plugin(plugin_name, entry_path, _dependencies) do
    GenServer.call(__MODULE__, {:load_plugin, plugin_name, entry_path})
  end

  @impl true
  def handle_call({:load_plugin, plugin_name, entry_path}, _from, state) do
    {_, _} = Pythonx.eval("""
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location(#{inspect(plugin_name)}, #{inspect(entry_path)})
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if "__rho_plugins__" not in dir():
        __rho_plugins__ = {}
    __rho_plugins__[#{inspect(plugin_name)}] = mod
    """)
    {:reply, :ok, %{state | plugins: Map.put(state.plugins, plugin_name, entry_path)}}
  end
end
```

**GIL considerations:**

- All Python plugin calls are serialized through a single GenServer — this makes the GIL constraint explicit rather than surprising.
- I/O-bound Python code (HTTP requests, file reads) releases the GIL, so other BEAM processes aren't blocked during those operations.
- For CPU-heavy or untrusted Python plugins, use a Port-based worker instead of Pythonx. This gives full OS-process isolation at the cost of serialization overhead.

**Security note:** Pythonx runs Python inside the BEAM process. A NIF crash in Python code will take down the entire VM. Use Pythonx only for trusted, vetted plugins.

### JavaScript runtime: `Rho.Plugin.JsRunner`

```elixir
defmodule Rho.Plugin.JsRunner do
  @doc """
  DynamicSupervisor managing per-plugin QuickJS contexts.
  Each JS plugin gets its own isolated context (separate memory, globals).
  No GIL equivalent — contexts are independent.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def load_plugin(plugin_name, entry_path) do
    DynamicSupervisor.start_child(__MODULE__, {Rho.Plugin.JsContext, {plugin_name, entry_path}})
  end

  def call(plugin_name, hook_name, context) do
    [{pid, _}] = Registry.lookup(Rho.Registry, {:js_plugin, plugin_name})
    GenServer.call(pid, {:call, hook_name, context})
  end
end

defmodule Rho.Plugin.JsContext do
  use GenServer

  defstruct [:plugin_name, :ctx]

  def start_link({plugin_name, entry_path}) do
    GenServer.start_link(__MODULE__, {plugin_name, entry_path},
      name: {:via, Registry, {Rho.Registry, {:js_plugin, plugin_name}}}
    )
  end

  @impl true
  def init({plugin_name, entry_path}) do
    {:ok, ctx} = MquickjsEx.new(memory_limit: 1_048_576)  # 1MB per plugin

    ctx = MquickjsEx.set!(ctx, :log, fn [msg] -> Logger.info("[js:#{plugin_name}] #{msg}") end)
    # NOTE: Do not expose fs/network callbacks to untrusted plugins.
    # Only expose carefully audited host APIs.

    source = File.read!(entry_path)
    {_, ctx} = MquickjsEx.eval!(ctx, source)

    {:ok, %__MODULE__{plugin_name: plugin_name, ctx: ctx}}
  end

  @impl true
  def handle_call({:call, hook_name, context}, _from, %{ctx: ctx} = state) do
    context_json = Jason.encode!(context)
    case MquickjsEx.eval(ctx, "plugin.#{hook_name}(#{context_json})") do
      {:ok, result} -> {:reply, result, state}
      {:error, err} -> {:reply, {:error, err}, state}
    end
  end
end
```

### When to use which runtime

| Use case | Runtime | Reason |
|---|---|---|
| Core plugins (channels, tape, agent) | Elixir (native) | Full OTP integration, best performance |
| Trusted local Python plugin code | Pythonx (in-process) | Low overhead, shared memory |
| CPU-heavy or untrusted Python | Port (out-of-process) | Full isolation, no GIL contention, NIF-crash safe |
| Trusted JS tools/transforms | QuickJS (sandboxed) | Memory-limited, fast startup |
| Untrusted community plugins | Port (out-of-process) | Full isolation from BEAM |

---

## 8. Tape and Storage

The tape system is Rho's core innovation and stays fully custom. Jido has no equivalent concept.

### Key design decisions

- **String keys everywhere**: All tape payloads use string keys for consistency between in-memory and JSON-serialized forms. Atom keys in append calls are automatically converted.
- **Per-entry ETS storage**: Entries are stored individually in ETS, not as a single list blob. This makes appends O(1) instead of O(n).
- **Single GenServer for writes**: Serializes all writes to prevent corruption. Reads go directly to ETS (`read_concurrency: true`).

### `Rho.Tape.Entry`

```elixir
defmodule Rho.Tape.Entry do
  @enforce_keys [:id, :kind, :payload]
  defstruct [:id, :kind, :payload, meta: %{}, date: nil]

  @type kind :: :message | :tool_call | :tool_result | :anchor | :event

  def new(kind, payload, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || 0,
      kind: kind,
      payload: normalize_keys(payload),
      meta: normalize_keys(opts[:meta] || %{}),
      date: opts[:date] || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Recursively convert atom keys to string keys for persistence consistency."
  def normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_keys(v)} end)
  end
  def normalize_keys(list) when is_list(list), do: Enum.map(list, &normalize_keys/1)
  def normalize_keys(other), do: other
end
```

### `Rho.Tape.Store` (GenServer)

Persistent JSONL storage. Single process serializes all writes — no locks needed. ETS stores entries individually for O(1) appends.

```elixir
defmodule Rho.Tape.Store do
  use GenServer

  @doc """
  JSONL-based tape storage under ~/.rho/tapes/.
  ETS stores entries individually: {{tape_name, seq_id}, entry}
  Metadata stored as: {{tape_name, :meta}, %{next_id: n}}
  """

  @table :tape_store

  defstruct [:base_dir]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    base_dir = opts[:base_dir] || Path.expand("~/.rho/tapes")
    File.mkdir_p!(base_dir)
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    load_existing(base_dir)
    {:ok, %__MODULE__{base_dir: base_dir}}
  end

  # --- Public API ---

  def append(tape_name, %Rho.Tape.Entry{} = entry) do
    GenServer.call(__MODULE__, {:append, tape_name, entry})
  end

  def read(tape_name) do
    # Read all entries for this tape, ordered by sequence id
    match_spec = [{{{tape_name, :"$1"}, :"$2"}, [{:is_integer, :"$1"}], [{{:"$1", :"$2"}}]}]
    :ets.select(@table, match_spec)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  def base_dir do
    GenServer.call(__MODULE__, :base_dir)
  end

  def clear(tape_name) do
    GenServer.call(__MODULE__, {:clear, tape_name})
  end

  # --- Implementation ---

  @impl true
  def handle_call({:append, tape_name, entry}, _from, state) do
    next_id = get_next_id(tape_name)
    entry = %{entry | id: next_id}

    redacted = redact_payload(entry)

    # Write to JSONL file
    path = tape_path(state.base_dir, tape_name)
    line = Jason.encode!(Map.from_struct(redacted)) <> "\n"
    File.write!(path, line, [:append])

    # Insert individual entry into ETS
    :ets.insert(@table, {{tape_name, next_id}, entry})
    :ets.insert(@table, {{tape_name, :meta}, %{next_id: next_id + 1}})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:base_dir, _from, state) do
    {:reply, state.base_dir, state}
  end

  @impl true
  def handle_call({:clear, tape_name}, _from, state) do
    # Delete all entries for this tape
    entries = read(tape_name)
    Enum.each(entries, fn entry ->
      :ets.delete(@table, {tape_name, entry.id})
    end)
    :ets.delete(@table, {tape_name, :meta})

    # Delete the file
    path = tape_path(state.base_dir, tape_name)
    File.rm(path)

    {:reply, :ok, state}
  end

  defp get_next_id(tape_name) do
    case :ets.lookup(@table, {tape_name, :meta}) do
      [{{^tape_name, :meta}, %{next_id: n}}] -> n
      [] -> 0
    end
  end

  defp tape_path(base_dir, tape_name), do: Path.join(base_dir, "#{tape_name}.jsonl")

  defp redact_payload(%{payload: payload} = entry) do
    redacted = deep_redact_base64(payload)
    %{entry | payload: redacted}
  end

  defp deep_redact_base64(value) when is_binary(value) do
    Regex.replace(~r/data:[^;]+;base64,[A-Za-z0-9+\/=]+/, value, "[media]")
  end
  defp deep_redact_base64(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, deep_redact_base64(v)} end)
  end
  defp deep_redact_base64(value) when is_list(value) do
    Enum.map(value, &deep_redact_base64/1)
  end
  defp deep_redact_base64(value), do: value

  defp load_existing(base_dir) do
    base_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
    |> Enum.each(fn filename ->
      tape_name = String.trim_trailing(filename, ".jsonl")
      entries = parse_jsonl(Path.join(base_dir, filename))
      Enum.each(entries, fn entry ->
        :ets.insert(@table, {{tape_name, entry.id}, entry})
      end)
      if entries != [] do
        max_id = entries |> Enum.map(& &1.id) |> Enum.max()
        :ets.insert(@table, {{tape_name, :meta}, %{next_id: max_id + 1}})
      end
    end)
  end

  defp parse_jsonl(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(line) do
        {:ok, data} -> [entry_from_map(data) | acc]
        {:error, reason} ->
          require Logger
          Logger.warning("Malformed JSONL line in #{path}: #{inspect(reason)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp entry_from_map(data) do
    %Rho.Tape.Entry{
      id: data["id"] || 0,
      kind: String.to_existing_atom(data["kind"]),
      payload: data["payload"] || %{},
      meta: data["meta"] || %{},
      date: data["date"]
    }
  end
end
```

### `Rho.Tape.Service` (stateless module)

High-level tape API, equivalent to Python's `TapeService`. This is a plain module, not a GenServer — it calls `Rho.Tape.Store` for persistence and reads directly from ETS.

```elixir
defmodule Rho.Tape.Service do
  @doc "Derives a tape name from session ID and workspace."
  def session_tape(session_id, workspace) do
    ws_hash = :crypto.hash(:md5, workspace) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    sid_hash = :crypto.hash(:md5, session_id) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "#{ws_hash}__#{sid_hash}"
  end

  def ensure_bootstrap_anchor(tape_name) do
    entries = Rho.Tape.Store.read(tape_name)
    has_anchor = Enum.any?(entries, &(&1.kind == :anchor))
    unless has_anchor do
      append(tape_name, :anchor, %{"name" => "session/start", "state" => %{"owner" => "human"}})
    end
  end

  def append(tape_name, kind, payload, meta \\ %{}) do
    entry = Rho.Tape.Entry.new(kind, payload, meta: meta)
    Rho.Tape.Store.append(tape_name, entry)
  end

  def append_event(tape_name, name, payload) do
    append(tape_name, :event, Map.put(payload, "name", name))
  end

  def info(tape_name) do
    entries = Rho.Tape.Store.read(tape_name)
    anchors = Enum.filter(entries, &(&1.kind == :anchor))
    last_anchor = List.last(anchors)

    entries_since = if last_anchor do
      entries
      |> Enum.reverse()
      |> Enum.take_while(&(&1.id != last_anchor.id))
      |> length()
    else
      length(entries)
    end

    %{
      name: tape_name,
      entries: length(entries),
      anchors: length(anchors),
      last_anchor: last_anchor && last_anchor.payload["name"],
      entries_since_last_anchor: entries_since
    }
  end

  def handoff(tape_name, name, summary \\ "") do
    append(tape_name, :anchor, %{"name" => name, "state" => %{"summary" => summary}})
  end

  def search(tape_name, query, limit \\ 20) do
    entries = Rho.Tape.Store.read(tape_name)
    query_lower = String.downcase(query)

    entries
    |> Enum.filter(&(&1.kind == :message))
    |> Enum.filter(fn entry ->
      content = entry.payload["content"] || ""
      String.contains?(String.downcase(content), query_lower) ||
        fuzzy_match?(content, query)
    end)
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  def reset(tape_name, archive \\ false) do
    if archive do
      entries = Rho.Tape.Store.read(tape_name)
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:\.]/, "")
      backup_path = Path.join(Rho.Tape.Store.base_dir(), "#{tape_name}.jsonl.#{timestamp}.bak")
      content = Enum.map_join(entries, "\n", &Jason.encode!(Map.from_struct(&1)))
      File.write!(backup_path, content)
    end

    Rho.Tape.Store.clear(tape_name)
    ensure_bootstrap_anchor(tape_name)
  end

  def messages_for_llm(tape_name) do
    Rho.Tape.Store.read(tape_name)
    |> Enum.filter(&(&1.kind in [:message, :tool_call, :tool_result]))
    |> convert_to_llm_messages()
  end

  # --- Private ---

  defp fuzzy_match?(_content, query) when byte_size(query) < 3, do: false
  defp fuzzy_match?(content, query) do
    case TheFuzz.Similarity.JaroWinkler.compare(
           String.downcase(content),
           String.downcase(query)
         ) do
      score when score > 0.8 -> true
      _ -> false
    end
  end

  defp convert_to_llm_messages(entries) do
    Enum.reduce(entries, {[], []}, fn entry, {messages, pending_calls} ->
      case entry.kind do
        :message ->
          # name field is present for room messages, absent for single-agent
          {messages ++ [entry.payload], pending_calls}

        :tool_call ->
          msg = %{"role" => "assistant", "tool_calls" => entry.payload["tool_calls"]}
          new_pending = entry.payload["tool_calls"]
          {messages ++ [msg], pending_calls ++ new_pending}

        :tool_result ->
          results = entry.payload["results"] || []
          tool_messages = Enum.zip(pending_calls, results) |> Enum.map(fn {call, result} ->
            %{"role" => "tool", "tool_call_id" => call["id"], "name" => call["function"]["name"], "content" => result}
          end)
          {messages ++ tool_messages, []}
      end
    end)
    |> elem(0)
  end
end
```

### Tape isolation via agent immutability

The Python `ForkTapeStore` with `ContextVar` is replaced by Jido's immutable agent state model. Each agent process owns its tape entries. However note that tape writes happen during execution (user message, tool calls, tool results, loop events), not only on completion. The tape is an event log, not a transactional store — partial entries from a crashed turn remain on tape, which is acceptable for debugging and recovery.

---

## 9. Skills System

### `Rho.Skill`

```elixir
defmodule Rho.Skill do
  defstruct [:name, :description, :location, :source, :metadata, :body]

  @name_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  def discover(workspace_path) do
    roots = [
      {Path.join(workspace_path, ".agents/skills"), "project"},
      {Path.expand("~/.agents/skills"), "global"},
      {Application.app_dir(:rho, "priv/skills"), "builtin"}
    ]

    roots
    |> Enum.flat_map(fn {root, source} ->
      if File.dir?(root) do
        root
        |> File.ls!()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&read_skill(&1, source))
      else
        []
      end
    end)
    |> Enum.uniq_by(&String.downcase(&1.name))
    |> Enum.sort_by(& &1.name)
  end

  defp read_skill(dir, source) do
    skill_md = Path.join(dir, "SKILL.md")

    if File.exists?(skill_md) do
      case parse_skill_md(skill_md, source) do
        {:ok, skill} -> [skill]
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp parse_skill_md(path, source) do
    content = File.read!(path)

    case Regex.run(~r/\A---\n(.*?)\n---\n(.*)/s, content) do
      [_, frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            name = meta["name"]
            desc = meta["description"]

            if name && desc && Regex.match?(@name_pattern, name) do
              {:ok, %__MODULE__{
                name: name,
                description: desc,
                location: path,
                source: source,
                metadata: meta["metadata"] || %{},
                body: String.trim(body)
              }}
            else
              {:error, :invalid_frontmatter}
            end

          _ -> {:error, :yaml_parse_error}
        end

      _ -> {:error, :no_frontmatter}
    end
  end

  def render_prompt(skills, expanded \\ MapSet.new()) do
    summary =
      skills
      |> Enum.map(fn s -> "- #{s.name}: #{s.description}" end)
      |> Enum.join("\n")

    expanded_bodies =
      skills
      |> Enum.filter(&MapSet.member?(expanded, &1.name))
      |> Enum.map(fn s -> "\n## Skill: #{s.name}\n\n#{s.body}" end)
      |> Enum.join("\n")

    "<available_skills>\n#{summary}\n</available_skills>#{expanded_bodies}"
  end

  def expanded_hints(prompt, skills) do
    skills
    |> Enum.filter(fn s -> String.contains?(prompt, "$#{s.name}") end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end
end
```

---

## 10. Channels

### `Rho.Channel` behaviour

```elixir
defmodule Rho.Channel do
  @callback name() :: String.t()
  @callback start(stop_event :: pid()) :: :ok
  @callback stop() :: :ok
  @callback needs_debounce?() :: boolean()
  @callback send_message(message :: map()) :: :ok | {:error, term()}

  @optional_callbacks [send_message: 1]
end
```

### `Rho.Channel.Message`

```elixir
defmodule Rho.Channel.Message do
  defstruct [
    :session_id,
    :channel,
    :content,
    chat_id: "default",
    is_active: false,
    kind: :normal,
    context: %{},
    output_channel: ""
  ]

  def context_str(%__MODULE__{context: ctx}) do
    ctx
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.join(" | ")
  end

  def from_batch(messages) do
    last = List.last(messages)
    content = messages |> Enum.map(& &1.content) |> Enum.join("\n")
    %{last | content: content}
  end
end
```

### `Rho.Channel.Manager` (GenServer)

Routes messages to agents via `Rho.SessionRouter`. **Message routing is non-blocking** — the manager spawns a supervised task for each inbound message instead of calling `route_message` synchronously.

```elixir
defmodule Rho.Channel.Manager do
  use GenServer

  defstruct [:channels, :debounce_handlers, :stop_ref]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    channels = Rho.HookRuntime.call_many(:provide_channels, %{}) |> List.flatten()
    enabled = filter_enabled(channels, opts[:enabled_channels] || "all")

    {:ok, %__MODULE__{
      channels: Map.new(enabled, &{&1.name(), &1}),
      debounce_handlers: %{},
      stop_ref: make_ref()
    }}
  end

  def on_receive(%Rho.Channel.Message{} = message) do
    GenServer.cast(__MODULE__, {:receive, message})
  end

  def dispatch(%Rho.Channel.Message{} = message) do
    GenServer.cast(__MODULE__, {:dispatch, message})
  end

  @impl true
  def handle_cast({:receive, message}, state) do
    channel = Map.get(state.channels, message.channel)

    if channel && channel.needs_debounce?() do
      # Debounce by {channel, chat_id} to avoid cross-chat mixing
      debounce_key = {message.channel, message.chat_id}
      handler = get_or_create_debounce(debounce_key, state)
      Rho.Channel.Debounce.buffer(handler, message)
    else
      # Route via TaskSupervisor — non-blocking
      Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
        Rho.SessionRouter.route_message(message)
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:dispatch, message}, state) do
    output = message.output_channel || message.channel
    case Map.get(state.channels, output) do
      nil ->
        require Logger
        Logger.warning("No channel #{output} for dispatch")
      channel -> channel.send_message(message)
    end
    {:noreply, state}
  end

  def listen_and_run(opts \\ []) do
    GenServer.call(__MODULE__, {:listen_and_run, opts}, :infinity)
  end

  defp filter_enabled(channels, "all"), do: channels
  defp filter_enabled(channels, list) when is_list(list) do
    Enum.filter(channels, &(&1.name() in list))
  end

  defp get_or_create_debounce(debounce_key, _state) do
    case Registry.lookup(Rho.Registry, {:debounce, debounce_key}) do
      [{pid, _}] -> pid
      [] ->
        {:ok, pid} = DynamicSupervisor.start_child(
          Rho.Channel.Debounce.Supervisor,
          {Rho.Channel.Debounce, debounce_key: debounce_key}
        )
        pid
    end
  end
end
```

### `Rho.Channel.Debounce` (GenServer per session)

```elixir
defmodule Rho.Channel.Debounce do
  use GenServer, restart: :transient

  defstruct [
    :debounce_key,
    :debounce_ms,
    :max_wait_ms,
    :active_window_ms,
    :last_active_at,
    buffer: [],
    timer_ref: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Rho.Registry, {:debounce, opts[:debounce_key]}}}
    )
  end

  def buffer(pid, message) do
    GenServer.cast(pid, {:buffer, message})
  end

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{
      debounce_key: opts[:debounce_key],
      debounce_ms: opts[:debounce_ms] || 1_000,
      max_wait_ms: opts[:max_wait_ms] || 10_000,
      active_window_ms: opts[:active_window_ms] || 60_000
    }}
  end

  @impl true
  def handle_cast({:buffer, message}, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      # Commands bypass buffering
      String.starts_with?(message.content, ",") ->
        Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
          Rho.SessionRouter.route_message(message)
        end)
        {:noreply, state}

      # Active message — debounce
      message.is_active ->
        state = cancel_timer(state)
        timer_ref = Process.send_after(self(), :flush, state.debounce_ms)
        {:noreply, %{state |
          buffer: state.buffer ++ [message],
          timer_ref: timer_ref,
          last_active_at: now
        }}

      # Inactive within active window — use max_wait
      state.last_active_at && (now - state.last_active_at) < state.active_window_ms ->
        state = if state.timer_ref == nil do
          timer_ref = Process.send_after(self(), :flush, state.max_wait_ms)
          %{state | timer_ref: timer_ref}
        else
          state
        end
        {:noreply, %{state | buffer: state.buffer ++ [message]}}

      # Inactive outside active window — drop
      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    unless Enum.empty?(state.buffer) do
      merged = Rho.Channel.Message.from_batch(state.buffer)
      Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
        Rho.SessionRouter.route_message(merged)
      end)
    end
    {:noreply, %{state | buffer: [], timer_ref: nil}}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state
  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
```

### `Rho.Channel.Telegram` (GenServer)

```elixir
defmodule Rho.Channel.Telegram do
  use GenServer
  @behaviour Rho.Channel

  defstruct [:token, :bot, :typing_tasks, :allow_users, :allow_chats]

  def name, do: "telegram"
  def needs_debounce?, do: true

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Rho.Config.telegram()
    send(self(), :poll)
    {:ok, %__MODULE__{
      token: config.token,
      typing_tasks: %{},
      allow_users: config.allow_users,
      allow_chats: config.allow_chats
    }}
  end

  @impl true
  def handle_info(:poll, state) do
    updates = fetch_updates(state.token)

    for update <- updates do
      case parse_update(update) do
        {:ok, message} ->
          if allowed?(message, state) do
            Rho.Channel.Manager.on_receive(message)
          end
        :skip -> :ok
      end
    end

    Process.send_after(self(), :poll, 100)
    {:noreply, state}
  end

  def send_message(message) do
    GenServer.cast(__MODULE__, {:send, message})
  end

  @impl true
  def handle_cast({:send, message}, state) do
    send_telegram_message(state.token, message.chat_id, message.content)
    {:noreply, state}
  end

  defp start_typing(chat_id, state) do
    task = Task.start(fn ->
      Stream.interval(4_000)
      |> Enum.each(fn _ -> send_chat_action(state.token, chat_id, "typing") end)
    end)
    %{state | typing_tasks: Map.put(state.typing_tasks, chat_id, task)}
  end

  defp stop_typing(chat_id, state) do
    case Map.pop(state.typing_tasks, chat_id) do
      {nil, _} -> state
      {task, tasks} ->
        Process.exit(task, :normal)
        %{state | typing_tasks: tasks}
    end
  end
end
```

### `Rho.Channel.Cli` (GenServer)

```elixir
defmodule Rho.Channel.Cli do
  use GenServer
  @behaviour Rho.Channel

  def name, do: "cli"
  def needs_debounce?, do: false

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Task.start_link(fn -> repl_loop(opts) end)
    {:ok, %{mode: :agent}}
  end

  defp repl_loop(opts) do
    IO.puts(welcome_banner(opts))

    Stream.repeatedly(fn ->
      prompt = if opts[:mode] == :shell, do: "rho> ,", else: "rho> "
      IO.gets(prompt)
    end)
    |> Stream.reject(&(&1 == :eof))
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.each(fn input ->
      if input in [",quit", ",exit"] do
        System.halt(0)
      end

      message = %Rho.Channel.Message{
        channel: "cli",
        content: input,
        is_active: true,
        kind: if(String.starts_with?(input, ","), do: :command, else: :normal)
      }

      # Route through Channel.Manager, which dispatches asynchronously.
      # Responses arrive via Channel.Manager.dispatch → Cli.send_message.
      Rho.Channel.Manager.on_receive(message)
    end)
  end

  def send_message(message) do
    render_output(message.content, message.kind)
  end

  defp render_output(content, _kind) do
    IO.puts(content)
  end
end
```

### `Rho.Channel.Web` (Bandit WebSocket + REST, session mode)

The web channel exposes Rho as an HTTP API and WebSocket endpoint with a built-in chat UI. It uses `Bandit` + `WebSock` (no Phoenix dependency) and operates in **session mode** — the server owns conversation history via the tape system, and clients send only new messages. The bundled frontend is a zero-dependency single-page app served directly by Bandit.

#### Architecture

```
Browser / API client
    │
    ├── POST /api/messages          → REST (one-shot, request/response)
    │       → Channel.Manager.on_receive → SessionRouter → Worker → AgentLoop
    │       ← JSON response
    │
    └── WS /ws/chat                 → WebSocket (streaming, multi-turn)
            → Channel.Manager.on_receive → SessionRouter → Worker → AgentLoop
            ← Streamed text frames + tool events as JSON
```

#### `Rho.Channel.Web` — Channel behaviour implementation

```elixir
defmodule Rho.Channel.Web do
  @moduledoc """
  Web channel: bridges HTTP/WebSocket clients into the Rho channel system.
  Manages connected WebSocket clients via a Registry for outbound dispatch.
  """
  @behaviour Rho.Channel

  def name, do: "web"
  def needs_debounce?, do: false

  def start(_stop_event), do: :ok
  def stop, do: :ok

  def send_message(%Rho.Channel.Message{chat_id: chat_id} = message) do
    # Dispatch to all WebSocket processes registered for this chat_id
    Registry.dispatch(Rho.Web.ClientRegistry, chat_id, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:rho_response, message})
      end
    end)
  end
end
```

#### `Rho.Web.Router` — HTTP endpoints

```elixir
defmodule Rho.Web.Router do
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # POST /api/messages — one-shot message, synchronous response
  post "/api/messages" do
    %{"content" => content} = conn.body_params
    session_id = conn.body_params["session_id"] || "web:#{generate_id()}"
    workspace = conn.body_params["workspace"] || File.cwd!()

    message = %Rho.Channel.Message{
      channel: "web",
      content: content,
      chat_id: session_id,
      session_id: session_id,
      is_active: true,
      kind: if(String.starts_with?(content, ","), do: :command, else: :normal)
    }

    result = Rho.SessionRouter.route_message(message, workspace: workspace)

    case result do
      {:ok, response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{response: response, session_id: session_id}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: to_string(reason)}))
    end
  end

  # GET /api/sessions/:id — session info
  get "/api/sessions/:id" do
    case Rho.SessionRouter.whereis(id) do
      nil ->
        send_resp(conn, 404, Jason.encode!(%{error: "session not found"}))

      pid ->
        info = Rho.Agent.Worker.info(pid)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(info))
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
```

#### `Rho.Web.Socket` — WebSocket handler

```elixir
defmodule Rho.Web.Socket do
  @moduledoc """
  WebSocket handler for streaming chat sessions.

  Protocol (JSON frames):
    Inbound:  {"type": "message", "content": "...", "session_id": "..."}
    Outbound: {"type": "text", "content": "..."}
              {"type": "tool_start", "name": "...", "args": {...}}
              {"type": "tool_result", "name": "...", "status": "ok", "output": "..."}
              {"type": "done", "content": "..."}
              {"type": "error", "reason": "..."}
  """
  @behaviour WebSock

  @impl true
  def init(opts) do
    session_id = opts[:session_id] || "web:#{generate_id()}"
    workspace = opts[:workspace] || File.cwd!()

    # Register this socket for outbound dispatch
    Registry.register(Rho.Web.ClientRegistry, session_id, %{})

    {:ok, %{session_id: session_id, workspace: workspace}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "message", "content" => content}} ->
        # Run agent loop in a task so the socket stays responsive
        self_pid = self()
        workspace = state.workspace

        Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
          on_event = fn event -> send(self_pid, {:agent_event, event}); :ok end
          on_text = fn chunk -> send(self_pid, {:agent_text, chunk}); :ok end

          message = %Rho.Channel.Message{
            channel: "web",
            content: content,
            chat_id: state.session_id,
            session_id: state.session_id,
            is_active: true
          }

          result = Rho.SessionRouter.route_message(message,
            workspace: workspace,
            on_event: on_event,
            on_text: on_text
          )

          send(self_pid, {:agent_done, result})
        end)

        {:ok, state}

      _ ->
        frame = Jason.encode!(%{type: "error", reason: "invalid message format"})
        {:push, {:text, frame}, state}
    end
  end

  @impl true
  def handle_info({:agent_text, chunk}, state) do
    frame = Jason.encode!(%{type: "text", content: chunk})
    {:push, {:text, frame}, state}
  end

  def handle_info({:agent_event, event}, state) do
    frame = Jason.encode!(event_to_json(event))
    {:push, {:text, frame}, state}
  end

  def handle_info({:agent_done, result}, state) do
    frame = case result do
      {:ok, text} -> Jason.encode!(%{type: "done", content: text})
      {:error, reason} -> Jason.encode!(%{type: "error", reason: to_string(reason)})
    end
    {:push, {:text, frame}, state}
  end

  def handle_info({:rho_response, message}, state) do
    frame = Jason.encode!(%{type: "text", content: message.content})
    {:push, {:text, frame}, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp event_to_json(%{type: :tool_start} = e) do
    %{type: "tool_start", name: e.name, args: e.args}
  end

  defp event_to_json(%{type: :tool_result} = e) do
    %{type: "tool_result", name: e.name, status: to_string(e.status), output: e.output}
  end

  defp event_to_json(%{type: type} = e) do
    %{type: to_string(type)} |> Map.merge(Map.drop(e, [:type]))
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
```

#### `Rho.Web.Endpoint` — Bandit server

```elixir
defmodule Rho.Web.Endpoint do
  @moduledoc "Starts the Bandit HTTP server with WebSocket upgrade support."

  def child_spec(opts) do
    port = opts[:port] || 4000

    {Bandit,
     plug: Rho.Web.Router,
     port: port,
     scheme: :http,
     websocket_options: [
       upgrade: {Rho.Web.Socket, []}
     ]}
  end
end
```

#### Configuration

```elixir
# In Rho.Config
def web do
  %{
    enabled: env("RHO_WEB_ENABLED", "false") == "true",
    port: env_int("RHO_WEB_PORT", 4000),
    cors_origins: env_list("RHO_WEB_CORS_ORIGINS")
  }
end
```

#### Environment variables

| Variable | Description |
|---|---|
| `RHO_WEB_ENABLED` | Set to `"true"` to start the web server (default: `"false"`) |
| `RHO_WEB_PORT` | HTTP port (default: `4000`) |
| `RHO_WEB_CORS_ORIGINS` | Comma-separated allowed CORS origins |

#### Dependencies

| Package | Purpose |
|---|---|
| `bandit` | HTTP/WebSocket server (pure Elixir, no Cowboy) |
| `websock` | WebSocket behaviour contract |
| `plug` | HTTP routing (already a transitive dep via `req`) |
| `cors_plug` | CORS middleware (optional) |

#### Supervision

When `RHO_WEB_ENABLED=true`, the web endpoint is added to the supervision tree:

```elixir
# In Rho.Application.start/2
children = [
  # ... existing children ...
] ++ web_children()

defp web_children do
  config = Rho.Config.web()

  if config.enabled do
    [
      {Registry, keys: :duplicate, name: Rho.Web.ClientRegistry},
      {Rho.Web.Endpoint, port: config.port}
    ]
  else
    []
  end
end
```

#### Why Bandit over Phoenix

- **No Phoenix dependency** — Rho is an agent framework, not a web app. Bandit + Plug + WebSock gives HTTP + WebSocket with minimal overhead.
- **Same WebSock behaviour** — if you later want Phoenix, the `Rho.Web.Socket` module works unchanged with Phoenix.Socket.
- **Lighter supervision** — no PubSub, no Endpoint config, no channel layer. Rho already has its own channel system.

#### Multi-user concerns

The web channel is inherently multi-user — multiple clients connect to the same server. The existing session model (one `Session.Worker` per `session_id`) provides process-level isolation, but additional layers are needed for production safety.

##### Authentication

All web endpoints require authentication via API key or JWT. Unauthenticated requests are rejected before reaching the channel system.

```elixir
defmodule Rho.Web.Auth do
  @moduledoc "Plug for authenticating web requests."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_auth_token(conn) do
      {:ok, user_id} ->
        assign(conn, :user_id, user_id)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp get_auth_token(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- verify_token(token) do
      {:ok, user_id}
    else
      _ -> :error
    end
  end

  defp verify_token(token) do
    # Strategy 1: Static API keys (simple, single-tenant)
    configured_keys = Rho.Config.web().api_keys

    case Enum.find(configured_keys, fn {_id, key} -> key == token end) do
      {user_id, _key} -> {:ok, user_id}
      nil -> :error
    end

    # Strategy 2: JWT verification (multi-tenant)
    # Decode and verify JWT, extract user_id from claims.
    # Requires a signing secret in config.
  end
end
```

For WebSocket connections, the token is passed as a query parameter during the upgrade handshake:

```
WS /ws/chat?token=<api_key_or_jwt>
```

The `Rho.Web.Socket.init/1` callback verifies the token before accepting the connection:

```elixir
def init(opts) do
  case Rho.Web.Auth.verify_ws_token(opts[:token]) do
    {:ok, user_id} ->
      # ... proceed with connection
      {:ok, %{user_id: user_id, session_id: session_id, workspace: workspace}}

    :error ->
      {:stop, :normal, {1008, "unauthorized"}}
  end
end
```

##### Session ownership

Sessions are bound to the authenticated user. A user can only access sessions they created.

```elixir
# Session IDs are prefixed with user_id to prevent cross-user access
session_id = "#{user_id}:#{client_provided_id}"

# In the Router, session lookups are scoped:
defp scoped_session_id(conn, client_id) do
  "#{conn.assigns.user_id}:#{client_id}"
end
```

The `GET /api/sessions` endpoint only lists sessions owned by the authenticated user:

```elixir
get "/api/sessions" do
  user_id = conn.assigns.user_id
  sessions = Rho.SessionRouter.list_sessions(prefix: "#{user_id}:")
  # ...
end
```

##### Workspace isolation

Multiple users sharing the same filesystem tools (`:bash`, `:fs_read`, `:fs_write`) is dangerous. The web channel enforces workspace boundaries per user:

**Option A: Per-user workspace directories (recommended for multi-tenant)**

```elixir
# Each user gets an isolated workspace directory
defp user_workspace(user_id) do
  base = Rho.Config.web().workspace_base || Path.expand("~/.rho/workspaces")
  path = Path.join(base, user_id)
  File.mkdir_p!(path)
  path
end
```

**Option B: Shared workspace, restricted tools**

```elixir
# Web channel uses a limited tool set — no bash, no fs_write
def web_tools do
  [:fs_read, :web_fetch, :anchor, :search_history, :skill_expand]
end
```

**Option C: Read-only mode**

```elixir
# Web sessions get read-only filesystem access
agent_config = %{
  tools: [:fs_read, :web_fetch, :anchor, :search_history],
  system_prompt: base_prompt <> "\nYou have read-only access to the workspace."
}
```

The default is **Option A** when `RHO_WEB_WORKSPACE_BASE` is set, and **Option B** otherwise. This is configured via `Rho.Config.web/0`:

```elixir
def web do
  %{
    enabled: env("RHO_WEB_ENABLED", "false") == "true",
    port: env_int("RHO_WEB_PORT", 4000),
    cors_origins: env_list("RHO_WEB_CORS_ORIGINS"),
    api_keys: parse_api_keys(env("RHO_WEB_API_KEYS", "")),
    workspace_base: env("RHO_WEB_WORKSPACE_BASE"),
    workspace_mode: env("RHO_WEB_WORKSPACE_MODE", "isolated"),  # "isolated" | "shared" | "readonly"
    tools: env_list("RHO_WEB_TOOLS") || nil,   # nil = use agent default
    max_sessions_per_user: env_int("RHO_WEB_MAX_SESSIONS_PER_USER", 10),
    max_connections: env_int("RHO_WEB_MAX_CONNECTIONS", 100)
  }
end

defp parse_api_keys(""), do: []
defp parse_api_keys(str) do
  # Format: "user1:key1,user2:key2"
  str
  |> String.split(",")
  |> Enum.map(fn pair ->
    [user_id, key] = String.split(String.trim(pair), ":", parts: 2)
    {user_id, key}
  end)
end
```

##### Rate limiting

Rate limiting prevents any single user from exhausting LLM quota or overwhelming the system.

```elixir
defmodule Rho.Web.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter per user, stored in ETS.
  Enforced as a Plug in the Router pipeline.
  """
  use GenServer

  @default_rate 10        # requests per window
  @default_window 60_000  # 1 minute in ms

  def init(_), do: {:ok, :ets.new(__MODULE__, [:named_table, :public, :set])}

  def allow?(user_id, opts \\ []) do
    rate = opts[:rate] || @default_rate
    window = opts[:window] || @default_window
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, user_id}

    case :ets.lookup(__MODULE__, key) do
      [{^key, count, window_start}] when now - window_start < window ->
        if count < rate do
          :ets.update_counter(__MODULE__, key, {2, 1})
          true
        else
          false
        end

      _ ->
        :ets.insert(__MODULE__, {key, 1, now})
        true
    end
  end
end
```

Used as a Plug in the Router:

```elixir
defmodule Rho.Web.RateLimitPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = conn.assigns[:user_id] || "anonymous"

    if Rho.Web.RateLimiter.allow?(user_id) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate limit exceeded"}))
      |> halt()
    end
  end
end
```

For WebSocket connections, rate limiting applies per-message:

```elixir
# In Rho.Web.Socket.handle_in/2
def handle_in({text, [opcode: :text]}, state) do
  if Rho.Web.RateLimiter.allow?(state.user_id) do
    # ... process message
  else
    frame = Jason.encode!(%{type: "error", reason: "rate limit exceeded"})
    {:push, {:text, frame}, state}
  end
end
```

##### Connection limits

Cap total WebSocket connections and per-user connections to prevent resource exhaustion:

```elixir
# In Rho.Web.Socket.init/1
def init(opts) do
  config = Rho.Config.web()
  user_id = opts[:user_id]

  total = Registry.count(Rho.Web.ClientRegistry)
  user_count = Registry.count_match(Rho.Web.ClientRegistry, user_id, :_)

  cond do
    total >= config.max_connections ->
      {:stop, :normal, {1013, "server at capacity"}}

    user_count >= config.max_sessions_per_user ->
      {:stop, :normal, {1008, "too many connections"}}

    true ->
      # ... proceed with connection
  end
end
```

##### Session limits

Bound the number of active sessions per user to prevent unbounded memory growth:

```elixir
# In SessionRouter, before starting a new worker
defp check_session_limit(user_id) do
  max = Rho.Config.web().max_sessions_per_user
  current = count_user_sessions(user_id)

  if current >= max do
    {:error, "session limit reached (#{max})"}
  else
    :ok
  end
end
```

##### Environment variables (complete list)

| Variable | Description | Default |
|---|---|---|
| `RHO_WEB_ENABLED` | Start the web server | `"false"` |
| `RHO_WEB_PORT` | HTTP port | `4000` |
| `RHO_WEB_CORS_ORIGINS` | Comma-separated CORS origins | none |
| `RHO_WEB_API_KEYS` | Auth keys, format `user1:key1,user2:key2` | none |
| `RHO_WEB_WORKSPACE_BASE` | Base dir for per-user workspaces | none (uses cwd) |
| `RHO_WEB_WORKSPACE_MODE` | `"isolated"`, `"shared"`, or `"readonly"` | `"isolated"` |
| `RHO_WEB_TOOLS` | Comma-separated tool list for web sessions | agent default |
| `RHO_WEB_MAX_SESSIONS_PER_USER` | Max concurrent sessions per user | `10` |
| `RHO_WEB_MAX_CONNECTIONS` | Max total WebSocket connections | `100` |

##### Summary: what happens on a web request

```
1. Client connects (REST or WebSocket)
2. Auth middleware verifies API key / JWT → extracts user_id
3. Rate limiter checks user's request budget
4. Connection limiter checks capacity (WebSocket only)
5. Session ID is scoped: "user_id:client_session_id"
6. Workspace is resolved based on workspace_mode:
   - isolated: ~/.rho/workspaces/<user_id>/
   - shared: server's cwd (tools may be restricted)
   - readonly: server's cwd (write tools disabled)
7. Message routes through Channel.Manager → SessionRouter → Worker
8. Response dispatched back to the client's connection
```

#### Session mode (primary interaction model)

The web channel operates in **session mode** — the server manages conversation history via the tape system. Clients send only new messages (not full history), and the server reconstructs context from the tape before each LLM call. This leverages tape features like anchors, compaction, and fork/merge that would be impossible if the client owned the history.

**Why session mode over stateless:**
- Tape features (anchors, compaction, search) require server-side history ownership
- Clients stay lightweight — no need to track or replay full conversation state
- Session resumption works across page reloads, device switches, and reconnections
- Tool results and streaming events are persisted server-side automatically

**WebSocket protocol (session mode):**

```
Client → Server (JSON text frames):

  // Send a new message (server appends to tape, runs AgentLoop with full context)
  {"type": "message", "content": "...", "session_id": "..."}

  // Create a new session
  {"type": "session.create", "workspace": "/path/to/project"}

  // Resume an existing session (server replays tape state to client)
  {"type": "session.resume", "session_id": "..."}

  // Drop an anchor at current position
  {"type": "anchor", "label": "checkpoint-1"}

  // Request session list
  {"type": "session.list"}

  // Cancel in-progress generation
  {"type": "cancel"}

Server → Client (JSON text frames):

  // Streamed text chunk (partial assistant response)
  {"type": "text", "content": "partial..."}

  // Tool execution started
  {"type": "tool_start", "name": "bash", "args": {"command": "ls"}}

  // Tool execution finished
  {"type": "tool_result", "name": "bash", "status": "ok", "output": "..."}

  // Agent turn complete (full final text)
  {"type": "done", "content": "full response text"}

  // Session created/resumed — includes history for UI hydration
  {"type": "session.ready", "session_id": "...", "history": [...]}

  // Anchor notification
  {"type": "anchor", "label": "...", "index": 42}

  // Session list
  {"type": "session.list", "sessions": [{"id": "...", "created_at": "...", "last_message": "..."}]}

  // Error
  {"type": "error", "reason": "..."}
```

**History hydration on session.resume:**

When a client sends `session.resume`, the server reads the tape and sends a `session.ready` frame containing the conversation history. This lets the frontend render the full conversation without storing it locally:

```elixir
def handle_resume(session_id, state) do
  tape_name = Rho.Tape.Service.session_tape(session_id, state.workspace)
  events = Rho.Tape.Service.read_all(tape_name)

  history = events
    |> Enum.filter(&(&1["type"] in ["user", "assistant", "tool_result", "anchor"]))
    |> Enum.map(&tape_event_to_history_entry/1)

  frame = Jason.encode!(%{
    type: "session.ready",
    session_id: session_id,
    history: history
  })

  {:push, {:text, frame}, %{state | session_id: session_id}}
end
```

**REST endpoints (session mode):**

```
POST   /api/sessions                 → Create a new session
GET    /api/sessions                 → List sessions for authenticated user
GET    /api/sessions/:id             → Session info + metadata
GET    /api/sessions/:id/history     → Full conversation history from tape
DELETE /api/sessions/:id             → End session, optionally archive tape
POST   /api/sessions/:id/messages    → Send a message (returns streamed SSE or JSON)
POST   /api/sessions/:id/anchor      → Drop an anchor
```

#### Custom frontend

Rho ships a built-in chat UI served directly by Bandit at the root path (`/`). It is a single-page application — one HTML file with inlined CSS/JS — that communicates exclusively via the WebSocket session-mode protocol.

##### Design goals

- **Zero build step** — the frontend is a single `index.html` file in `priv/static/`, served as-is. No npm, no bundler, no node.
- **Session-first** — the UI manages sessions, not message history. Creating, resuming, and switching sessions is a first-class operation.
- **Tape-aware** — anchors are visible in the conversation timeline. Session resumption hydrates the full history from the server.
- **Tool transparency** — tool calls and results are rendered inline (collapsible), so the user sees what the agent is doing.
- **Mobile-friendly** — responsive layout that works on phones and tablets.

##### UI structure

```
┌──────────────────────────────────────┐
│  Rho  │  Session: project-setup  ▼   │  ← header + session selector
├───────┴──────────────────────────────┤
│                                      │
│  ⚓ anchor: initial-setup            │  ← anchor marker
│                                      │
│  👤 Set up the project structure     │  ← user message
│                                      │
│  🤖 I'll create the directory...     │  ← assistant message (streaming)
│  ┌─ bash: mkdir -p src/lib ────────┐ │
│  │ (ok)                            │ │  ← tool call (collapsible)
│  └─────────────────────────────────┘ │
│  🤖 Done! I created src/lib and...   │  ← assistant continuation
│                                      │
│  ⚓ anchor: structure-ready          │  ← anchor marker
│                                      │
├──────────────────────────────────────┤
│  [Type a message...]        [Send]   │  ← input area
│  [,command mode] [⚓ Anchor] [Cancel] │  ← action buttons
└──────────────────────────────────────┘
```

##### Key features

| Feature | Implementation |
|---|---|
| **Session management** | Dropdown lists sessions from `session.list`. "New session" creates one. Selecting a session sends `session.resume` and hydrates history. |
| **Streaming responses** | `type: "text"` frames are appended to the current assistant bubble in real-time. `type: "done"` finalizes. |
| **Tool call rendering** | `tool_start` creates a collapsible block with the tool name + args. `tool_result` fills in the output. Collapsed by default after completion. |
| **Anchor display** | `anchor` events render as labeled dividers in the timeline. Clicking scrolls to that position. |
| **Command mode** | Typing `,` as the first character switches to command mode (different input style, sends as command instead of message). |
| **Cancel** | The cancel button sends `{"type": "cancel"}` to abort in-progress generation. |
| **Reconnection** | On WebSocket disconnect, the UI auto-reconnects and sends `session.resume` to restore state. No local history needed. |
| **Markdown rendering** | Assistant responses are rendered as markdown (using a lightweight inline parser — no heavy dependencies). Code blocks get syntax highlighting via `<pre><code>`. |
| **Auth** | On first load, prompts for API key, stored in `localStorage`. Passed as `?token=` on WebSocket connect. |

##### File location and serving

```elixir
# In Rho.Web.Router
get "/" do
  conn
  |> put_resp_content_type("text/html")
  |> send_file(200, Application.app_dir(:rho, "priv/static/index.html"))
end

get "/assets/:file" do
  path = Application.app_dir(:rho, "priv/static/assets/#{file}")
  if File.exists?(path) do
    conn |> send_file(200, path)
  else
    send_resp(conn, 404, "not found")
  end
end
```

The frontend is a single `priv/static/index.html` file (~500 lines). Vanilla JS, no framework. CSS uses custom properties for theming (light/dark mode). The entire UI is self-contained and works offline once loaded — only the WebSocket connection is needed.

##### Frontend ↔ Server interaction flow

```
1. Page loads → reads API key from localStorage (or prompts)
2. Opens WebSocket: ws://host:port/ws/chat?token=<key>
3. Server authenticates, sends: {"type": "session.list", "sessions": [...]}
4. User selects session → client sends: {"type": "session.resume", "session_id": "..."}
   OR creates new → client sends: {"type": "session.create"}
5. Server sends: {"type": "session.ready", "session_id": "...", "history": [...]}
6. Frontend renders history from session.ready payload
7. User types message → client sends: {"type": "message", "content": "...", "session_id": "..."}
8. Server streams: text → text → tool_start → tool_result → text → done
9. Frontend renders each frame incrementally
10. On disconnect: auto-reconnect → session.resume → re-render from server state
```

##### Updated `Rho.Web.Socket` for session mode

```elixir
defmodule Rho.Web.Socket do
  @moduledoc """
  WebSocket handler for session-mode chat.
  Client sends only new messages; server manages full history via tape.
  """
  @behaviour WebSock

  @impl true
  def init(opts) do
    case Rho.Web.Auth.verify_ws_token(opts[:token]) do
      {:ok, user_id} ->
        # Send session list on connect
        sessions = Rho.SessionRouter.list_sessions(prefix: "#{user_id}:")
        frame = Jason.encode!(%{type: "session.list", sessions: format_sessions(sessions)})
        {:push, {:text, frame}, %{user_id: user_id, session_id: nil, workspace: nil}}

      :error ->
        {:stop, :normal, {1008, "unauthorized"}}
    end
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "session.create"} = msg} ->
        handle_session_create(msg, state)

      {:ok, %{"type" => "session.resume", "session_id" => sid}} ->
        handle_session_resume(sid, state)

      {:ok, %{"type" => "message", "content" => content}} when state.session_id != nil ->
        handle_message(content, state)

      {:ok, %{"type" => "cancel"}} when state.session_id != nil ->
        handle_cancel(state)

      {:ok, %{"type" => "anchor", "label" => label}} when state.session_id != nil ->
        handle_anchor(label, state)

      {:ok, %{"type" => "session.list"}} ->
        handle_session_list(state)

      _ ->
        frame = Jason.encode!(%{type: "error", reason: "invalid message or no active session"})
        {:push, {:text, frame}, state}
    end
  end

  defp handle_session_create(msg, state) do
    workspace = resolve_workspace(state.user_id, msg["workspace"])
    session_id = "#{state.user_id}:#{generate_id()}"

    # Ensure session worker exists
    Rho.SessionRouter.ensure_session(session_id, workspace: workspace)

    frame = Jason.encode!(%{
      type: "session.ready",
      session_id: session_id,
      history: []
    })

    {:push, {:text, frame}, %{state | session_id: session_id, workspace: workspace}}
  end

  defp handle_session_resume(client_sid, state) do
    session_id = "#{state.user_id}:#{client_sid}"
    # ... read tape, hydrate history, send session.ready
  end

  defp handle_message(content, state) do
    self_pid = self()

    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      on_event = fn event -> send(self_pid, {:agent_event, event}) end
      on_text = fn chunk -> send(self_pid, {:agent_text, chunk}) end

      result = Rho.SessionRouter.send_message(state.session_id, content,
        workspace: state.workspace,
        on_event: on_event,
        on_text: on_text
      )

      send(self_pid, {:agent_done, result})
    end)

    {:ok, state}
  end

  # ... handle_info callbacks for streaming (same as before)
end
```

---

## 11. Configuration

### `Rho.Config`

Uses Elixir's `Application` config + runtime env vars with `RHO_` prefix + `.env` file support (via `Dotenvy`).

```elixir
defmodule Rho.Config do
  def agent do
    %{
      home: env("RHO_HOME", "~/.rho") |> Path.expand(),
      model: env("RHO_MODEL", "openrouter:qwen/qwen3-coder-next"),
      api_key: env("RHO_API_KEY"),
      api_base: env("RHO_API_BASE"),
      max_steps: env_int("RHO_MAX_STEPS", 50),
      max_tokens: env_int("RHO_MAX_TOKENS", 1024),
      model_timeout_seconds: env_int("RHO_MODEL_TIMEOUT_SECONDS")
    }
  end

  def channels do
    %{
      enabled_channels: env("RHO_ENABLED_CHANNELS", "all"),
      debounce_seconds: env_float("RHO_DEBOUNCE_SECONDS", 1.0),
      max_wait_seconds: env_float("RHO_MAX_WAIT_SECONDS", 10.0),
      active_time_window: env_float("RHO_ACTIVE_TIME_WINDOW", 60.0)
    }
  end

  def telegram do
    %{
      token: env("RHO_TELEGRAM_TOKEN", ""),
      allow_users: env_list("RHO_TELEGRAM_ALLOW_USERS"),
      allow_chats: env_list("RHO_TELEGRAM_ALLOW_CHATS"),
      proxy: env("RHO_TELEGRAM_PROXY")
    }
  end

  def web do
    %{
      enabled: env("RHO_WEB_ENABLED", "false") == "true",
      port: env_int("RHO_WEB_PORT", 4000),
      cors_origins: env_list("RHO_WEB_CORS_ORIGINS")
    }
  end

  defp env(key, default \\ nil), do: System.get_env(key) || default
  defp env_int(key, default \\ nil) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_integer(val)
    end
  end
  defp env_float(key, default \\ nil) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_float(val)
    end
  end
  defp env_list(key) do
    case System.get_env(key) do
      nil -> nil
      val -> String.split(val, ",") |> Enum.map(&String.trim/1)
    end
  end
end
```

### `.env` loading

```elixir
# In application.ex start/2
Dotenvy.source([".env", System.get_env("DOTENV_FILE")])
```

---

## 12. CLI

### Mix tasks or escript

```elixir
# mix.exs
def project do
  [
    app: :rho,
    escript: [main_module: Rho.CLI]
  ]
end
```

```elixir
defmodule Rho.CLI do
  def main(args) do
    {opts, args, _} = OptionParser.parse(args,
      switches: [workspace: :string, channel: :string, chat_id: :string],
      aliases: [w: :workspace]
    )

    workspace = opts[:workspace] || File.cwd!()

    case args do
      ["run" | message_parts] ->
        run(Enum.join(message_parts, " "), opts)

      ["chat"] ->
        chat(workspace, opts)

      ["gateway" | _] ->
        gateway(workspace, opts)

      ["hooks"] ->
        hooks()

      _ ->
        IO.puts("Usage: rho <run|chat|gateway|hooks> [options]")
    end
  end

  defp run(message, opts) do
    Application.ensure_all_started(:rho)
    msg = %Rho.Channel.Message{content: message, channel: opts[:channel] || "cli"}
    {:ok, result} = Rho.SessionRouter.route_message(msg)
    IO.puts(result.response)
  end

  defp chat(_workspace, _opts) do
    Application.ensure_all_started(:rho)
    Rho.Channel.Manager.listen_and_run(enabled: ["cli"])
  end

  defp gateway(_workspace, opts) do
    Application.ensure_all_started(:rho)
    enabled = if opts[:channel], do: [opts[:channel]], else: "all"
    Rho.Channel.Manager.listen_and_run(enabled: enabled)
  end

  defp hooks do
    Application.ensure_all_started(:rho)
    report = Rho.HookRuntime.hook_report()
    for {hook, plugins} <- report do
      IO.puts("#{hook}: #{Enum.join(Enum.map(plugins, &inspect/1), ", ")}")
    end
  end
end
```

---

## 13. Observability

### Telemetry events

Rho emits telemetry events via `:telemetry.execute/3` for operational visibility:

| Event | Measurements | Metadata |
|---|---|---|
| `[:rho, :turn, :start]` | — | `session_id`, `channel` |
| `[:rho, :turn, :stop]` | `duration` (native) | `session_id`, `channel`, `steps` |
| `[:rho, :turn, :error]` | `duration` (native) | `session_id`, `error` |
| `[:rho, :tool, :execute]` | `duration` (native) | `tool`, `tape_name`, `status` |
| `[:rho, :tape, :append]` | — | `tape_name`, `kind` |
| `[:rho, :hook, :call]` | `duration` (native) | `hook_name`, `plugin`, `status` |

### ReqLLM cost tracking

ReqLLM publishes `[:req_llm, :token_usage]` events with token counts and cost. Attach a handler in `Application.start/2`:

```elixir
:telemetry.attach("rho-llm-cost", [:req_llm, :token_usage], fn _event, measurements, metadata, _config ->
  Logger.info("LLM cost",
    model: metadata.model,
    input_tokens: measurements.input_tokens,
    output_tokens: measurements.output_tokens,
    cost: measurements.total_cost
  )
end, nil)
```

### Logger metadata

All log messages include structured metadata via `Logger.metadata/1`:

```elixir
Logger.metadata(session_id: session_id, channel: channel, tape: tape_name)
```

---

## 14. Operational Concerns

### Graceful shutdown

On `Application.stop/1` or SIGTERM:

1. **Flush debounce buffers**: Each `Rho.Channel.Debounce` process sends `:flush` to itself in `terminate/2`.
2. **Drain in-flight tasks**: `Rho.TaskSupervisor` is shut down with a timeout, allowing running turns to complete.
3. **Stop typing indicators**: `Rho.Channel.Telegram` cancels all typing tasks in `terminate/2`.
4. **Tape writes are synchronous**: Since `Rho.Tape.Store` uses `GenServer.call`, all pending writes complete before the process stops.

### Backpressure and limits

| Limit | Default | Config |
|---|---|---|
| Max tool steps per turn | 50 | `RHO_MAX_STEPS` |
| Max LLM tokens per request | 1024 | `RHO_MAX_TOKENS` |
| Debounce buffer (max messages before flush) | 100 | — |
| Agent process timeout | 120s | — |
| Python plugin call timeout | 30s | — |
| Web: max total connections | 100 | `RHO_WEB_MAX_CONNECTIONS` |
| Web: max sessions per user | 10 | `RHO_WEB_MAX_SESSIONS_PER_USER` |
| Web: requests per minute per user | 10 | `Rho.Web.RateLimiter` |

### Deployment

- **NIF packaging**: Pythonx and MquickjsEx include NIFs. Use `mix release` with the correct target architecture. For Docker, build on the same arch as the target.
- **Persistent volumes**: Mount `~/.rho/tapes` as a persistent volume in containers.
- **Home directory**: Set `RHO_HOME` explicitly in containers (e.g., `/data/rho`).
- **Secrets**: Use environment variables (`RHO_API_KEY`, `RHO_TELEGRAM_TOKEN`). Never commit `.env` files.
- **Health checks**: Expose a simple HTTP endpoint or use `mix release` health checks to verify the supervision tree is running.

---

## 15. Testing Strategy

### Unit tests

- **Actions**: Test each `Rho.Actions.*` module with mock context. Verify input validation, output shape, and error cases.
- **Tape transforms**: Test `Rho.Tape.Entry.normalize_keys/1`, `convert_to_llm_messages/1`, search, and handoff logic.
- **Command parser**: Property test `Rho.CommandParser.parse/1` with arbitrary inputs.
- **Skills**: Test discovery, YAML parsing, prompt rendering.

### Integration tests

- **Fake LLM provider**: A stub module that returns canned responses and tool calls. Used in `HandleInbound` tests without hitting real APIs.
- **JSONL round-trip**: Property tests that serialize entries to JSONL and parse them back, verifying no data loss or key mutation.
- **Session routing**: Test concurrent `route_message` calls to verify no duplicate agent starts.

### Concurrency tests

- **Tape Store**: Multiple processes appending concurrently — verify ordering and no data corruption.
- **Channel Manager**: Verify non-blocking behavior — manager doesn't freeze during slow turns.
- **Debounce**: Test timer behavior, buffer flushing, and command bypass under concurrent messages.

---

## 16. Module Inventory

### Core

| Module | Python equivalent | Role | Notes |
|---|---|---|---|
| `Rho.Application` | `__main__.py` | OTP application, supervision tree | |
| `Rho.Jido` | — | Jido instance, agent supervision | **New**: replaces Framework + Turn |
| `Rho.RhoAgent` | `framework.py` + `agent.py` | Agent definition with schema + tools | **New**: single agent definition |
| `Rho.SessionRouter` | `process_inbound` routing | Session-to-agent mapping | **New**: race-safe start-or-find |
| `Rho.HookSpec` | `hookspecs.py` | Hook contract definitions | Single-map callbacks |
| `Rho.HookRuntime` | `hook_runtime.py` | Plugin registry + ETS dispatch | No GenServer bottleneck |
| `Rho.Envelope` | `envelope.py` | Envelope utilities | |
| `Rho.Config` | `settings.py` | Configuration | |
| `Rho.CLI` | `cli.py` | CLI commands | |
| `Rho.TaskSupervisor` | — | Task.Supervisor for async work | **New** |

### Agent + LLM

| Module | Python equivalent | Role | Notes |
|---|---|---|---|
| `Rho.Actions.HandleInbound` | `agent._agent_loop` | Turn lifecycle as Jido Action | Explicit ReqLLM loop |
| `Rho.Actions.HandleCommand` | `agent._run_command` | Command mode as Jido Action | |
| `Rho.CommandParser` | (part of agent.py) | `,tool args` parsing | |
| `Rho.Actions.PathUtils` | — | Workspace boundary enforcement | **New** |

### Actions (Tools)

| Module | Python equivalent | Role | Notes |
|---|---|---|---|
| `Rho.Actions.Registry` | `REGISTRY` dict | Tool name → module mapping | Compile-time map |
| `Rho.Actions.Bash` | `bash` tool | Shell execution | Jido Action |
| `Rho.Actions.FsRead` | `fs.read` tool | File reading | Workspace-bounded |
| `Rho.Actions.FsWrite` | `fs.write` tool | File writing | Workspace-bounded |
| `Rho.Actions.FsEdit` | `fs.edit` tool | File editing | Workspace-bounded |
| `Rho.Actions.WebFetch` | `web.fetch` tool | HTTP GET | Jido Action |
| `Rho.Actions.TapeInfo` | `tape.info` tool | Tape metadata | Jido Action |
| `Rho.Actions.TapeSearch` | `tape.search` tool | Tape search | Jido Action |
| `Rho.Actions.TapeReset` | `tape.reset` tool | Tape clearing | Jido Action |
| `Rho.Actions.TapeHandoff` | `tape.handoff` tool | Tape checkpoint | Jido Action |
| `Rho.Actions.TapeAnchors` | `tape.anchors` tool | List anchors | Jido Action |
| `Rho.Actions.SkillExpand` | `skill` tool | Load skill content | Jido Action |
| `Rho.Actions.Help` | `help` tool | Help text | Jido Action |

### Tape

| Module | Python equivalent | Role |
|---|---|---|
| `Rho.Tape.Entry` | `TapeEntry` | Tape entry struct (string-key normalized) |
| `Rho.Tape.Store` | `FileTapeStore` + `TapeFile` | JSONL persistence + per-entry ETS |
| `Rho.Tape.Service` | `TapeService` | High-level tape API (stateless module) |

### Channels

| Module | Python equivalent | Role |
|---|---|---|
| `Rho.Channel` | `channels/base.py` | Channel behaviour |
| `Rho.Channel.Message` | `channels/message.py` | Message struct |
| `Rho.Channel.Manager` | `channels/manager.py` | Non-blocking channel orchestration |
| `Rho.Channel.Debounce` | `channels/handler.py` | Per-session debounce |
| `Rho.Channel.Cli` | `channels/cli/` | CLI REPL |
| `Rho.Channel.Telegram` | `channels/telegram.py` | Telegram adapter |
| `Rho.Channel.Web` | — (new) | Web channel behaviour impl |
| `Rho.Web.Router` | — (new) | REST API (Plug) |
| `Rho.Web.Socket` | — (new) | WebSocket handler (WebSock) |
| `Rho.Web.Endpoint` | — (new) | Bandit HTTP server |
| `Rho.Web.Auth` | — (new) | API key / JWT authentication plug |
| `Rho.Web.RateLimiter` | — (new) | Token-bucket rate limiter (ETS) |
| `Rho.Web.RateLimitPlug` | — (new) | Rate limit enforcement plug |

### Plugins

| Module | Python equivalent | Role |
|---|---|---|
| `Rho.Builtin` | `builtin/hook_impl.py` | Default hook implementations |
| `Rho.Plugin.PythonRunner` | — (new) | Pythonx bridge (trusted only) |
| `Rho.Plugin.JsRunner` | — (new) | QuickJS supervisor |
| `Rho.Plugin.JsContext` | — (new) | Per-plugin JS context |
| `Rho.Plugin.Bridge.*` | — (new) | Auto-generated hook delegates |

### Skills

| Module | Python equivalent | Role |
|---|---|---|
| `Rho.Skill` | `skills.py` | Discovery, parsing, prompt rendering |

---

## 17. Migration Strategy

### Phase 1: Foundation (weeks 1-2)

1. `mix new rho --sup` — create project with supervision tree
2. Add `jido`, `jido_ai`, `req_llm` dependencies (pinned versions)
3. Implement `Rho.Jido` instance + `Rho.Config` (env vars, .env loading)
4. Implement `Rho.Registry` (Elixir Registry) + `Rho.TaskSupervisor`
5. Implement `Rho.HookSpec` + `Rho.HookRuntime` (single-map callbacks + ETS dispatch)
6. Implement `Rho.Envelope`, `Rho.Builtin` (default hook implementations)

### Phase 2: Tape + Storage (week 3)

1. Implement `Rho.Tape.Entry` (with `normalize_keys/1`), `Rho.Tape.Store` (per-entry ETS)
2. Implement `Rho.Tape.Service` (stateless module)
3. Write JSONL round-trip property tests
4. Verify JSONL format compatibility with Python version (for data migration)

### Phase 3: Actions + Agent (weeks 3-4)

1. Implement `Rho.Actions.PathUtils` (workspace boundary enforcement)
2. Implement all `Rho.Actions.*` modules as Jido Actions
3. Implement `Rho.Actions.Registry` (compile-time tool map)
4. Implement `Rho.RhoAgent` (Jido AI agent definition — no side effects in hooks)
5. Implement `Rho.SessionRouter` (race-safe session-to-agent mapping)
6. Implement `Rho.Actions.HandleInbound` (explicit ReqLLM loop) + `Rho.Actions.HandleCommand`
7. Implement `Rho.CommandParser`
8. Write integration tests with fake LLM provider
9. Verify ReqLLM integration with OpenRouter, OpenAI, Anthropic

### Phase 4a: Channels — CLI + Telegram (weeks 4-5)

1. Implement `Rho.Channel` behaviour, `Rho.Channel.Message`
2. Implement `Rho.Channel.Cli` (REPL — responses via `send_message` dispatch)
3. Implement `Rho.Channel.Manager` (non-blocking via TaskSupervisor) + `Rho.Channel.Debounce`
4. Implement `Rho.Channel.Telegram`
5. Concurrency tests for channel routing

### Phase 4b: Web Channel — Backend (weeks 5-6)

1. Add `bandit` + `websock` dependencies
2. Implement `Rho.Channel.Web` (Channel behaviour, dispatches to WebSocket clients via Registry)
3. Implement `Rho.Web.Router` (session-mode REST endpoints: sessions CRUD, messages, history, anchors)
4. Implement `Rho.Web.Socket` (WebSocket handler with session-mode JSON protocol — create/resume/message/cancel/anchor)
5. Implement `Rho.Web.Endpoint` (Bandit child spec)
6. Implement `Rho.Config.web/0` (port, CORS, enabled flag, workspace mode, API keys, limits)
7. Conditional supervision: only start web endpoint when `RHO_WEB_ENABLED=true`
8. Implement `Rho.Web.Auth` (API key + JWT verification for REST and WebSocket)
9. Implement session ownership scoping (`user_id:client_session_id`)
10. Implement workspace isolation (`isolated` / `shared` / `readonly` modes via `RHO_WEB_WORKSPACE_MODE`)
11. Implement `Rho.Web.RateLimiter` (token-bucket per user, ETS-backed) + `RateLimitPlug`
12. Implement connection limits (total + per-user caps, enforced in `Socket.init/1`)
13. Implement tape history hydration (`session.resume` → read tape → send `session.ready` with history)
14. WebSocket integration tests (connect, auth, create session, send message, receive streamed response, resume session)
15. Multi-user isolation tests (user A cannot access user B's sessions)
16. Rate limiting tests (verify 429 on REST, error frame on WebSocket)

### Phase 4c: Web Channel — Custom Frontend (week 6)

1. Create `priv/static/index.html` — single-file chat UI (vanilla HTML/CSS/JS, no build step)
2. Implement WebSocket client layer (connect, reconnect, auth token from localStorage)
3. Implement session management UI (create, list, resume, switch sessions via dropdown)
4. Implement message rendering (user bubbles, assistant streaming, markdown with code blocks)
5. Implement tool call rendering (collapsible blocks: tool_start → tool_result)
6. Implement anchor display (labeled dividers in timeline, clickable to scroll)
7. Implement command mode (`,` prefix switches input style, sends as command)
8. Implement cancel button (sends `cancel` frame to abort generation)
9. Implement auto-reconnect (on disconnect, reconnect → session.resume → re-render from server state)
10. Add light/dark theme toggle (CSS custom properties)
11. Responsive layout (works on mobile)
12. Serve static files from `Rho.Web.Router` (root `/` → index.html, `/assets/*`)
13. End-to-end test: start server, open browser, create session, chat, resume session after reconnect

### Phase 5: Skills (week 5)

1. Implement `Rho.Skill` (discovery, parsing, prompt rendering)
2. Port bundled skills (gh, telegram, skill-creator, skill-installer)

### Phase 6: Polyglot Plugins (weeks 6-7)

1. Add `pythonx` dependency, implement `Rho.Plugin.PythonRunner` (trusted plugins only)
2. Add `mquickjs_ex` dependency, implement `Rho.Plugin.JsRunner` + `JsContext`
3. Implement plugin manifest parser (`plugin.yaml`)
4. Implement bridge module generator
5. Write example plugins in Python and JavaScript
6. Document security boundaries and trusted-only constraints

### Phase 7: Observability + Polish (weeks 7-8)

1. Add telemetry events throughout
2. Build escript or Burrito-based binary
3. Rich CLI output (Owl library for terminal UI)
4. Integration tests against the Python test suite
5. Data migration tool (read Python JSONL tapes)
6. Graceful shutdown verification

### Key dependencies (hex packages)

| Package | Version | Purpose |
|---|---|---|
| `jido` | ~> 2.0 (pinned) | Agent framework, supervision, state management |
| `jido_ai` | ~> 0.5 (pinned) | AI agent runtime, tool loop |
| `req_llm` | ~> 1.6 (pinned) | LLM client (16 providers, streaming, cost tracking) |
| `req` | — | HTTP client (web.fetch, pulled in by req_llm) |
| `jason` | — | JSON encoding/decoding |
| `bandit` | ~> 1.0 | HTTP/WebSocket server (web channel) |
| `websock` | ~> 0.5 | WebSocket behaviour contract |
| `cors_plug` | — | CORS middleware (optional, for web channel) |
| `pythonx` | — | Embedded Python interpreter (trusted plugins) |
| `mquickjs_ex` | — | Embedded QuickJS JavaScript |
| `yaml_elixir` | — | YAML parsing (skills, plugin manifests) |
| `dotenvy` | — | .env file loading |
| `owl` | — | Terminal UI (rich output, panels) |
| `the_fuzz` | — | Fuzzy string matching (tape search) |
| `telemetry` | — | Observability events |

### Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Jido API stability (v2.0 recently released) | Breaking changes possible | Pin version, design against documented subset only |
| ReqLLM undocumented APIs | Loop code may break on update | Use only `generate_text`, `Response.text`, `Response.tool_calls`; build context manually |
| Jido AI agent loop vs custom tape integration | Tape entries may not record at right points | Keep explicit ReqLLM loop; don't depend on Jido's built-in loop |
| Pythonx NIF crash | Takes down BEAM VM | Use only for trusted plugins; Port-based workers for untrusted |
| MquickjsEx trampoline limits | JS callbacks must be idempotent | Document constraint; validate in plugin loader |
| Telegram library maturity | Fewer mature Elixir Telegram libraries | Use raw Bot API via Req |
| JSONL format compatibility | Data migration between Python and Elixir | Share the same JSONL schema; property tests for round-trip |
| Atom/string key confusion | Silent bugs in payload access | Normalize to string keys at tape boundary; `Rho.Tape.Entry.normalize_keys/1` |
| Session start race conditions | Duplicate agents or crashes | Handle `{:error, {:already_started, pid}}` in SessionRouter |
| Web channel security | Unauthorized access to agent tools | `Rho.Web.Auth` plug (API key or JWT); session ownership scoping (`user_id:session_id`); CORS whitelist |
| Web workspace isolation | Users executing code in each other's files | Per-user workspace dirs (`RHO_WEB_WORKSPACE_BASE`); `workspace_mode` config; restricted tool sets for `shared`/`readonly` modes |
| WebSocket resource exhaustion | Memory/CPU from too many connections | `max_connections` cap; `max_sessions_per_user` cap; connection rejected with WebSocket close code 1013 |
| Web rate limiting | Single user exhausts LLM quota | `Rho.Web.RateLimiter` (token-bucket per user in ETS); 429 on REST, error frame on WebSocket |
