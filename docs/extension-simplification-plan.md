# Extension System Simplification Plan

## Problem Statement

Rho currently has **four overlapping extension mechanisms** for what are conceptually similar things — ways to extend the agent's capabilities:

| Mechanism | Registration | Discovery | Behaviour |
|-----------|-------------|-----------|-----------|
| **Hooks/Plugins** | `HookRuntime.register/2` (ETS) | `function_exported?/3` on 13 optional callbacks | `@behaviour HookSpec` |
| **Tools** | `Config.@tool_registry` / `@contextual_tools` (hardcoded maps) | Atom lookup in two maps, arity-0 vs arity-1 split | Implicit `%{tool: ReqLLM.Tool.t(), execute: fn}` |
| **Skills** | Filesystem scan (`SKILL.md` files) | `Skill.discover/1` + `Skills.Plugin` hook adapter + `Tools.SkillExpand` tool | None (struct-based) |
| **Channels** | `provide_channels` hook returning modules | `HookRuntime.call_many/2` | `@behaviour Rho.Channel` (separate from HookSpec) |

This creates confusion:
1. Two parallel paths to provide tools (static registry vs `provide_tools` hook)
2. Skills spread across 3 modules/files for one concept
3. Three separate behaviour contracts
4. HookSpec is a 13-callback kitchen sink mixing unrelated concerns

## Goal

Unify extensions under **one primary mechanism** while keeping all existing features working. The `.rho.exs` config format remains backward-compatible.

---

## Architecture Overview (Current)

### How tools are assembled today

In `Session.Worker.resolve_all_tools/2` (lib/rho/session/worker.ex:258-274):

```elixir
defp resolve_all_tools(state, opts \\ []) do
  config = Rho.Config.agent(state.agent_name)
  tool_context = %{tape_name: state.memory_ref, workspace: state.workspace}
  hook_context = Map.merge(tool_context, %{agent_name: state.agent_name, depth: opts[:depth] || 0})

  base_tools    = Rho.Config.resolve_tools(config.tools, tool_context)       # Path 1: static registry
  memory_tools  = state.memory_mod.provide_tools(state.memory_ref, hook_context)
  plugin_tools  = Rho.HookRuntime.call_many(:provide_tools, hook_context)    # Path 2: hook system
                  |> List.flatten()
  base_tools ++ memory_tools ++ plugin_tools
end
```

Three separate sources merged into one list. The static registry (`Config.resolve_tools`) and the hook system (`provide_tools`) do the same thing.

### How static tools are registered today

In `Config` (lib/rho/config.ex:13-24), two hardcoded maps with different arities:

```elixir
# Arity-0: no context needed
@tool_registry %{
  bash: &Rho.Tools.Bash.tool_def/0,
  web_fetch: &Rho.Tools.WebFetch.tool_def/0
}

# Arity-1: needs workspace or context
@contextual_tools %{
  fs_read: &Rho.Tools.FsRead.tool_def/1,
  fs_write: &Rho.Tools.FsWrite.tool_def/1,
  fs_edit: &Rho.Tools.FsEdit.tool_def/1,
  skill_expand: &Rho.Tools.SkillExpand.tool_def/1
}
```

`resolve_tools/2` dispatches to one map or the other based on which map contains the atom. The `context_for/2` function (line 154) extracts the right context value depending on the tool name.

### How skills work today (3 modules)

1. **`Rho.Skill`** (lib/rho/skill.ex) — Filesystem discovery of `SKILL.md` files from project/global/builtin directories. Parses YAML frontmatter. Renders `<available_skills>` prompt section. Detects `$skill-name` hints for auto-expansion.

2. **`Rho.Skills.Plugin`** (lib/rho/skills/plugin.ex) — A `@behaviour HookSpec` module that implements `build_prompt/1`. Calls `Skill.discover/1` and `Skill.render_prompt/2` to inject the skills list into the system prompt. Registered in `Application.start/2`.

3. **`Rho.Tools.SkillExpand`** (lib/rho/tools/skill_expand.ex) — A static tool in `@contextual_tools` that lets the LLM call `skill(name: "...")` to load a skill's full body at runtime. Also calls `Skill.discover/1`.

### How channels are discovered today

`Channel.Manager.ensure_channels/1` (lib/rho/channel/manager.ex:136-144):

```elixir
defp ensure_channels(state) do
  channels = Rho.HookRuntime.call_many(:provide_channels, %{}) |> List.flatten()
  channel_map = Map.new(channels, fn mod -> {mod.name(), mod} end)
  %{state | channels: channel_map}
end
```

Channels implement `@behaviour Rho.Channel` (a separate 5-callback behaviour in lib/rho/channel.ex), but are *discovered* through the `HookSpec` hook system. `Rho.Builtin.provide_channels/1` returns the module list.

### How plugins are registered at boot

In `Application.start/2` (lib/rho/application.ex:39-46):

```elixir
Rho.HookRuntime.register(Rho.Builtin)          # lowest priority
Rho.HookRuntime.register(Rho.Skills.Plugin)     # next priority

# Per-agent plugins from .rho.exs
for agent_name <- Rho.Config.agent_names() do
  config = Rho.Config.agent(agent_name)
  for plugin <- config.plugins do
    Rho.HookRuntime.register(plugin, scope: {:agent, agent_name})
  end
end
```

### Current HookSpec callbacks (lib/rho/hook_spec.ex)

| Callback | Dispatch | Used by |
|----------|----------|---------|
| `resolve_session/1` | `call_first` | `SessionRouter` |
| `build_prompt/1` | `call_many` | `AgentLoop` |
| `provide_tape_store/1` | `call_first` | (unused?) |
| `system_prompt/1` | `call_first` | `AgentLoop` |
| `after_tool_call/1` | `call_first` | `AgentLoop` |
| `provide_tools/1` | `call_many` | `Session.Worker` |
| `load_state/1` | `call_many` | `AgentLoop` |
| `save_state/1` | `call_many` | `AgentLoop` |
| `render_outbound/1` | `call_many` | (outbound pipeline) |
| `dispatch_outbound/1` | `call_many` | (outbound pipeline) |
| `provide_channels/1` | `call_many` | `Channel.Manager` |
| `on_error/1` | broadcast | `HookRuntime.notify_error` |
| `register_cli_commands/1` | `call_many` | (CLI) |

---

## Plan

### Phase 1 — Add `Rho.Extension` behaviour and `Components` struct

**Effort**: ~1 hour  
**Risk**: None (pure additions, no existing code changes)

#### New files

**`lib/rho/extension.ex`**

```elixir
defmodule Rho.Extension do
  @moduledoc """
  Unified extension behaviour. Replaces HookSpec as the primary
  extension point. Extensions contribute components (tools, prompt
  sections, channels, CLI commands) and handle lifecycle events.
  """

  @callback components(context :: map()) :: Rho.Extension.Components.t()
  @callback resolve_session(context :: map()) :: {:ok, String.t()} | :skip
  @callback load_state(context :: map()) :: term()
  @callback save_state(context :: map()) :: :ok
  @callback handle_event(event :: map()) :: :ok | {:override, String.t()} | :skip

  @optional_callbacks components: 1, resolve_session: 1, load_state: 1, save_state: 1, handle_event: 1
end
```

**`lib/rho/extension/components.ex`**

```elixir
defmodule Rho.Extension.Components do
  @moduledoc """
  Struct grouping all contributions from an extension.
  Each field is a list (or nil for overrides like system_prompt/tape_store).
  """

  defstruct tools: [],
            prompt_sections: [],
            system_prompt: nil,
            channels: [],
            cli_commands: [],
            tape_store: nil

  @type t :: %__MODULE__{
    tools: [map()],
    prompt_sections: [String.t()],
    system_prompt: String.t() | nil,
    channels: [module()],
    cli_commands: [map()],
    tape_store: module() | nil
  }
end
```

**`lib/rho/extension/legacy_adapter.ex`**

Wraps any existing `@behaviour HookSpec` module into the new `Extension` interface so both old and new plugins work through one dispatch path:

```elixir
defmodule Rho.Extension.LegacyAdapter do
  @moduledoc """
  Adapts a HookSpec plugin module into Extension callbacks.
  Used by HookRuntime to treat old plugins and new extensions uniformly.
  """

  def components(plugin_mod, context) do
    %Rho.Extension.Components{
      tools: call_if_exported(plugin_mod, :provide_tools, [context], []) |> List.wrap() |> List.flatten(),
      prompt_sections: build_prompt_section(plugin_mod, context),
      system_prompt: call_if_exported(plugin_mod, :system_prompt, [context], nil),
      channels: call_if_exported(plugin_mod, :provide_channels, [context], []) |> List.wrap() |> List.flatten(),
      cli_commands: [],  # register_cli_commands has side effects, handled separately
      tape_store: call_if_exported(plugin_mod, :provide_tape_store, [context], nil)
    }
  end

  defp build_prompt_section(mod, context) do
    case call_if_exported(mod, :build_prompt, [context], :skip) do
      {:ok, section} -> [section]
      section when is_binary(section) -> [section]
      _ -> []
    end
  end

  defp call_if_exported(mod, fun, args, default) do
    if function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  end
end
```

#### Verification

- All existing tests pass (no code changed)
- New modules compile: `mix compile`

---

### Phase 2 — Unify tool resolution into one path

**Effort**: Half day  
**Risk**: Medium — changes core tool resolution. Test carefully.

#### Goal

Eliminate the dual `@tool_registry` / `@contextual_tools` maps. All tool atoms become aliases to extension modules that implement `components/1`.

#### Changes to `lib/rho/config.ex`

Replace the two maps and `resolve_tools/2`:

```elixir
# BEFORE (two maps, two arities)
@tool_registry %{bash: &Rho.Tools.Bash.tool_def/0, web_fetch: &Rho.Tools.WebFetch.tool_def/0}
@contextual_tools %{fs_read: &Rho.Tools.FsRead.tool_def/1, ...}

# AFTER (one map, all modules implement components/1)
@tool_extensions %{
  bash:         Rho.Tools.Bash,
  web_fetch:    Rho.Tools.WebFetch,
  fs_read:      Rho.Tools.FsRead,
  fs_write:     Rho.Tools.FsWrite,
  fs_edit:      Rho.Tools.FsEdit,
  skill_expand: Rho.Skills   # will be created in Phase 4; alias for now
}
```

New `resolve_tools/2`:

```elixir
def resolve_tools(tool_names, context \\ %{}) do
  Enum.flat_map(tool_names, fn name ->
    case Map.get(@tool_extensions, name) do
      nil -> raise "Unknown tool: #{inspect(name)}"
      mod ->
        Code.ensure_loaded!(mod)
        if function_exported?(mod, :components, 1) do
          mod.components(context).tools
        else
          # Legacy: call tool_def/0 or tool_def/1
          cond do
            function_exported?(mod, :tool_def, 1) -> [mod.tool_def(context_for(name, context))]
            function_exported?(mod, :tool_def, 0) -> [mod.tool_def()]
            true -> raise "Module #{inspect(mod)} has no tool_def or components"
          end
        end
    end
  end)
end
```

This preserves backward compat: existing tool modules still work with `tool_def/0` or `tool_def/1` until they're migrated to `components/1`.

#### Changes to each tool module (optional, can be incremental)

Add `components/1` to each tool module. Example for `Rho.Tools.Bash`:

```elixir
# Add to lib/rho/tools/bash.ex
def components(_context) do
  %Rho.Extension.Components{tools: [tool_def()]}
end
```

For contextual tools like `Rho.Tools.FsRead`:

```elixir
def components(%{workspace: workspace}) do
  %Rho.Extension.Components{tools: [tool_def(workspace)]}
end
```

Keep existing `tool_def/0` and `tool_def/1` for backward compat until Phase 6.

#### Changes to `lib/rho/session/worker.ex`

Simplify `resolve_all_tools/2`. The `provide_tools` hook path still works but goes through the same component resolution:

```elixir
defp resolve_all_tools(state, opts \\ []) do
  config = Rho.Config.agent(state.agent_name)
  context = %{
    tape_name: state.memory_ref,
    workspace: state.workspace,
    agent_name: state.agent_name,
    depth: opts[:depth] || 0
  }

  base_tools    = Rho.Config.resolve_tools(config.tools, context)
  memory_tools  = state.memory_mod.provide_tools(state.memory_ref, context)
  plugin_tools  = Rho.HookRuntime.call_many(:provide_tools, context) |> List.flatten()
  base_tools ++ memory_tools ++ plugin_tools
end
```

No change to worker logic yet — `provide_tools` hook still works for `Subagent` until Phase 3.

#### Verification

- `mix test` — all existing tests pass
- Manual: `mix rho.chat` → verify bash, fs_read, fs_write, fs_edit, skill_expand, web_fetch all work
- Verify subagent still gets tools (it uses `Config.resolve_tools` internally in `do_spawn`)

---

### Phase 3 — Migrate Subagent to Extension

**Effort**: Half day  
**Risk**: Medium — Subagent has subtle behaviors (completion piggyback, depth limits)

#### Goal

`Rho.Plugins.Subagent` stops being a HookSpec plugin that uses two hooks (`provide_tools` + `after_tool_call`). Instead it becomes an extension that returns tools via `components/1` and handles events via `handle_event/1`.

#### Changes to `lib/rho/plugins/subagent.ex`

Add `@behaviour Rho.Extension` alongside existing `@behaviour Rho.HookSpec`:

```elixir
@behaviour Rho.Extension
@behaviour Rho.HookSpec  # keep for backward compat during transition

# New Extension callback
@impl Rho.Extension
def components(%{tape_name: tape_name, workspace: workspace} = ctx) do
  memory_mod = ctx[:memory_mod] || Rho.Memory.Tape
  depth = ctx[:depth] || 0

  tools =
    if depth >= @max_depth, do: [],
    else: [spawn_tool(tape_name, workspace, depth, memory_mod), collect_tool(memory_mod)]

  %Rho.Extension.Components{tools: tools}
end

# New Extension callback (replaces after_tool_call)
@impl Rho.Extension
def handle_event(%{type: :tool_result, tape_name: tape_name, output: output})
    when is_binary(tape_name) do
  case check_completed(tape_name) do
    [] -> :ok
    done ->
      notice = Enum.map_join(done, "\n", fn {id, result} ->
        "[subagent #{id} finished: #{String.slice(to_string(result), 0..300)}]"
      end)
      {:override, output <> "\n\n" <> notice}
  end
end

def handle_event(_), do: :ok
```

Keep the old `provide_tools/1` and `after_tool_call/1` temporarily so both paths work.

#### Changes to `lib/rho/config.ex`

Add `:subagent` to `@tool_extensions`:

```elixir
@tool_extensions %{
  ...,
  subagent: Rho.Plugins.Subagent
}
```

#### Changes to `.rho.exs`

Users can now write either (both work):

```elixir
# New style
tools: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch, :subagent]

# Old style (still works)
tools: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch],
plugins: [Rho.Plugins.Subagent]
```

#### Verification

- Spawn a subagent, verify it runs and returns results
- Verify completion piggyback notifications still appear in tool output
- Verify depth limits still work (max depth = 3)
- Verify concurrent subagent limit still enforced

---

### Phase 4 — Collapse Skills into one module

**Effort**: 3-4 hours  
**Risk**: Low — mostly code consolidation

#### Goal

Merge three modules into one `Rho.Skills` that handles discovery, prompt injection, and the `skill` tool.

#### New file: `lib/rho/skills.ex` (replaces three modules)

```elixir
defmodule Rho.Skills do
  @moduledoc """
  Unified skills extension. Discovers SKILL.md files, injects the skills
  list into the system prompt, and provides the `skill` tool for the LLM
  to load full skill content at runtime.
  """

  @behaviour Rho.Extension

  # --- Extension callback ---

  @impl true
  def components(%{workspace: workspace, messages: messages} = _context) when is_binary(workspace) do
    skills = discover(workspace)

    if skills == [] do
      %Rho.Extension.Components{}
    else
      user_text = extract_user_text(messages || [])
      expanded = expanded_hints(user_text, skills)
      prompt_section = render_prompt(skills, expanded)

      %Rho.Extension.Components{
        tools: [skill_tool(workspace)],
        prompt_sections: [prompt_section]
      }
    end
  end

  def components(%{workspace: workspace}) when is_binary(workspace) do
    skills = discover(workspace)
    if skills == [] do
      %Rho.Extension.Components{}
    else
      %Rho.Extension.Components{
        tools: [skill_tool(workspace)],
        prompt_sections: [render_prompt(skills, MapSet.new())]
      }
    end
  end

  def components(_context), do: %Rho.Extension.Components{}

  # --- All existing Rho.Skill public functions remain here ---
  # discover/1, render_prompt/2, expanded_hints/2, parse_skill_md/2
  # (move them verbatim from lib/rho/skill.ex)

  # --- Tool definition (moved from Tools.SkillExpand) ---

  defp skill_tool(workspace) do
    %{
      tool: ReqLLM.tool(
        name: "skill",
        description: "Load a skill's full prompt content by name.",
        parameter_schema: [
          name: [type: :string, required: true, doc: "The skill name to expand"]
        ],
        callback: fn _args -> :ok end
      ),
      execute: fn args -> execute_skill_expand(args, workspace) end
    }
  end

  defp execute_skill_expand(args, workspace) do
    name = args["name"] || args[:name] || ""
    if String.trim(name) == "" do
      {:error, "name is required"}
    else
      skills = discover(workspace)
      case Enum.find(skills, &(String.downcase(&1.name) == String.downcase(name))) do
        nil ->
          available = Enum.map_join(skills, ", ", & &1.name)
          {:ok, "No skill found: \"#{name}\". Available: #{available}"}
        skill ->
          {:ok, "## Skill: #{skill.name}\n\n#{skill.body}"}
      end
    end
  end

  defp extract_user_text(messages) do
    messages
    |> Enum.filter(&(Map.get(&1, :role) == :user))
    |> Enum.map_join(" ", &to_string(Map.get(&1, :content, "")))
  end
end
```

#### Files to deprecate (keep as thin wrappers)

**`lib/rho/skill.ex`** — delegate all public functions to `Rho.Skills`:

```elixir
defmodule Rho.Skill do
  @moduledoc false
  # Deprecated: use Rho.Skills directly
  defdelegate discover(workspace), to: Rho.Skills
  defdelegate render_prompt(skills, expanded \\ MapSet.new()), to: Rho.Skills
  defdelegate expanded_hints(prompt, skills), to: Rho.Skills
  defdelegate parse_skill_md(path, source), to: Rho.Skills
end
```

**`lib/rho/skills/plugin.ex`** — delegate to `Rho.Skills.components/1`:

```elixir
defmodule Rho.Skills.Plugin do
  @moduledoc false
  # Deprecated: Rho.Skills now handles this via Extension
  @behaviour Rho.HookSpec
  def build_prompt(context) do
    comps = Rho.Skills.components(context)
    case comps.prompt_sections do
      [section | _] -> {:ok, section}
      _ -> :skip
    end
  end
end
```

**`lib/rho/tools/skill_expand.ex`** — keep but delegate:

```elixir
defmodule Rho.Tools.SkillExpand do
  @moduledoc false
  # Deprecated: Rho.Skills now provides this tool via components/1
  def tool_def(workspace) do
    comps = Rho.Skills.components(%{workspace: workspace})
    List.first(comps.tools)
  end
end
```

#### Changes to `lib/rho/config.ex`

Update the tool extension map:

```elixir
@tool_extensions %{
  ...,
  skill_expand: Rho.Skills,   # legacy atom
  skills: Rho.Skills           # preferred atom
}
```

#### Verification

- Skills list appears in system prompt (check via `IO.puts` in agent_loop or test)
- `$skill-name` auto-expansion still works
- LLM can call `skill(name: "...")` tool and get full body
- Builtin skills from `priv/skills/` still discovered

---

### Phase 5 — Channels as components

**Effort**: Half day  
**Risk**: Low-medium — channel startup order matters

#### Goal

Channels are discovered through `components/1` instead of a dedicated `provide_channels` hook, eliminating the need for `Rho.Channel` as a separate discovery behaviour.

#### Changes to `lib/rho/builtin.ex`

Add `@behaviour Rho.Extension` and implement `components/1`:

```elixir
@behaviour Rho.Extension

@impl Rho.Extension
def components(_context) do
  channels = [Rho.Channel.Cli]
  channels = if Rho.Config.web().enabled, do: channels ++ [Rho.Channel.Web], else: channels

  %Rho.Extension.Components{channels: channels}
end
```

Keep the old `provide_channels/1` as a wrapper for now.

#### Changes to `lib/rho/channel/manager.ex`

Update `ensure_channels/1` to use the new grouped API when available, falling back to old hook:

```elixir
defp ensure_channels(%{channels: channels} = state) when is_map(channels), do: state

defp ensure_channels(state) do
  # Gather channels from all extensions via components
  channels =
    Rho.HookRuntime.call_many(:provide_channels, %{})
    |> List.flatten()

  channel_map = Map.new(channels, fn mod -> {mod.name(), mod} end)
  %{state | channels: channel_map}
end
```

(This doesn't change yet — `provide_channels` still works. The real change is that `Builtin.components/1` now *also* returns channels, so when Phase 6 switches `HookRuntime` to use `components/1` internally, channels flow through the same path.)

#### Keep `@behaviour Rho.Channel`

The runtime channel contract (`name/0`, `start/2`, `stop/0`, `send_message/1`, `needs_debounce?/0`) is still useful as a type contract for channel modules. It just stops being a *discovery* mechanism.

#### Verification

- `mix rho.chat` still starts CLI channel
- Web channel still discovered when `RHO_WEB_ENABLED=true`

---

### Phase 6 — Cut over HookRuntime and deprecate HookSpec

**Effort**: Half day  
**Risk**: Medium — final migration of all call sites

#### Goal

Add grouped dispatch APIs to `HookRuntime` that call `components/1` on all registered extensions. Update `AgentLoop` and `SessionRouter` to use them. Deprecate direct `call_first`/`call_many` for the hook names that are now covered by `components/1`.

#### Changes to `lib/rho/hook_runtime.ex`

Add new public functions:

```elixir
@doc "Collect merged components from all registered extensions."
def components(context) do
  plugins_for(context)
  |> Enum.reduce(%Rho.Extension.Components{}, fn mod, acc ->
    Code.ensure_loaded!(mod)
    comps =
      cond do
        function_exported?(mod, :components, 1) ->
          mod.components(context)
        true ->
          # Legacy HookSpec adapter
          Rho.Extension.LegacyAdapter.components(mod, context)
      end

    merge_components(acc, comps)
  end)
end

@doc "Resolve session ID through extensions."
def resolve_session(context) do
  plugins_for(context)
  |> Enum.reduce_while(nil, fn mod, _acc ->
    Code.ensure_loaded!(mod)
    result =
      cond do
        function_exported?(mod, :resolve_session, 1) -> mod.resolve_session(context)
        true -> :skip
      end

    case result do
      {:ok, id} -> {:halt, {:ok, id}}
      id when is_binary(id) -> {:halt, {:ok, id}}
      _ -> {:cont, nil}
    end
  end)
end

@doc "Dispatch an event to all extensions that handle events."
def dispatch_event(event) do
  for {_p, mod, _scope} <- all_entries() do
    Code.ensure_loaded!(mod)
    cond do
      function_exported?(mod, :handle_event, 1) -> mod.handle_event(event)
      true -> :ok
    end
  end
  :ok
end

defp merge_components(acc, comps) do
  %Rho.Extension.Components{
    tools: acc.tools ++ (comps.tools || []),
    prompt_sections: acc.prompt_sections ++ (comps.prompt_sections || []),
    system_prompt: comps.system_prompt || acc.system_prompt,
    channels: acc.channels ++ (comps.channels || []),
    cli_commands: acc.cli_commands ++ (comps.cli_commands || []),
    tape_store: comps.tape_store || acc.tape_store
  }
end
```

#### Changes to `lib/rho/agent_loop.ex`

Replace individual hook calls with grouped component resolution:

```elixir
# BEFORE
system_prompt = Rho.HookRuntime.call_first(:system_prompt, hook_context) || base_system_prompt
prompt_extras = Rho.HookRuntime.call_many(:build_prompt, hook_context)

# AFTER
comps = Rho.HookRuntime.components(hook_context)
system_prompt = comps.system_prompt || base_system_prompt
system_prompt =
  case comps.prompt_sections do
    [] -> system_prompt
    sections -> [system_prompt | sections] |> Enum.join("\n\n")
  end
```

Replace `after_tool_call` hook with `dispatch_event`:

```elixir
# BEFORE
case Rho.HookRuntime.call_first(:after_tool_call, hook_ctx) do ...

# AFTER
case Rho.HookRuntime.dispatch_event(Map.put(hook_ctx, :type, :tool_result)) do ...
```

#### Changes to `lib/rho/session_router.ex`

```elixir
# BEFORE
case Rho.HookRuntime.call_first(:resolve_session, hook_context) do ...

# AFTER
case Rho.HookRuntime.resolve_session(hook_context) do ...
```

#### Changes to `lib/rho/session/worker.ex`

Simplify `resolve_all_tools/2`:

```elixir
defp resolve_all_tools(state, opts \\ []) do
  config = Rho.Config.agent(state.agent_name)
  context = %{
    tape_name: state.memory_ref,
    workspace: state.workspace,
    agent_name: state.agent_name,
    depth: opts[:depth] || 0
  }

  config_tools  = Rho.Config.resolve_tools(config.tools, context)
  memory_tools  = state.memory_mod.provide_tools(state.memory_ref, context)
  hook_tools    = Rho.HookRuntime.components(context).tools
  config_tools ++ memory_tools ++ hook_tools
end
```

#### Deprecation

Mark in `lib/rho/hook_spec.ex`:

```elixir
@moduledoc """
Deprecated: Use `@behaviour Rho.Extension` instead.
...
"""
```

Keep `call_first/2` and `call_many/2` working — they're still useful for custom hooks outside the standard set. Just stop using them for the 13 standard HookSpec callbacks in core code.

#### Verification

- Full integration test: `mix rho.chat` with all features
- Subagent spawn/collect works
- Skills prompt injection works
- Channel discovery works
- Session resolution works
- `after_tool_call` override (subagent completion piggyback) works

---

## Config Migration Guide

### Current `.rho.exs` (still works after all phases)

```elixir
%{
  default: [
    model: "openrouter:minimax/minimax-m2.5",
    system_prompt: "You are a helpful agent.",
    tools: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch],
    plugins: [Rho.Plugins.Subagent],
    max_steps: 50
  ]
}
```

### Preferred `.rho.exs` (after migration)

```elixir
%{
  default: [
    model: "openrouter:minimax/minimax-m2.5",
    system_prompt: "You are a helpful agent.",
    extensions: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch, :subagent],
    max_steps: 50
  ]
}
```

`Config.agent/1` normalizes both forms:
- `tools:` atoms → looked up in `@tool_extensions`
- `plugins:` modules → registered directly in HookRuntime
- `extensions:` → unified key accepting both atoms and modules

---

## Summary of file changes by phase

| Phase | New files | Modified files | Deprecated files |
|-------|-----------|----------------|------------------|
| 1 | `extension.ex`, `extension/components.ex`, `extension/legacy_adapter.ex` | — | — |
| 2 | — | `config.ex`, tool modules (add `components/1`) | — |
| 3 | — | `plugins/subagent.ex`, `config.ex` | — |
| 4 | `skills.ex` | `config.ex` | `skill.ex`, `skills/plugin.ex`, `tools/skill_expand.ex` |
| 5 | — | `builtin.ex`, `channel/manager.ex` | — |
| 6 | — | `hook_runtime.ex`, `agent_loop.ex`, `session_router.ex`, `session/worker.ex` | `hook_spec.ex` |

## End state

- **1 primary behaviour** (`Rho.Extension`) with 5 grouped callbacks
- **1 tool resolution path** (atoms → extension modules → `components/1`)
- **1 Skills module** (`Rho.Skills`) owning discovery + prompt + tool
- **Channels** discovered through the same `components/1` path as tools
- **HookSpec** deprecated but still functional for backward compat
- **`call_first`/`call_many`** still available for custom hooks
