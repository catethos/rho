# Progressive Tool Loading: Unifying Skills and Tools

## The Problem

Every LLM call includes the full JSON schema of every registered tool, whether or not the tool will be used in that turn. With 10 tools this is manageable. With 30+ tools (bash, fs_read, fs_write, fs_edit, web_fetch, subagent, anchor, search_history, recall_context, clear_memory, skill, plus domain-specific MCP tools, custom extensions...) the cost becomes significant — both in tokens and in LLM attention dilution.

Skills already solved this problem. The `<available_skills>` summary costs a few lines, and full skill content is loaded on-demand via the `skill` tool. But tools have no equivalent — they're all eager, all the time.

## What Are Skills and Tools, Really?

### The surface distinction

| | **Tool** | **Skill** |
|---|---|---|
| Format | Elixir module with `components/1` | SKILL.md with YAML frontmatter |
| What it provides | Executable function (schema + execute fn) | Prompt text (instructions/guidelines) |
| How LLM uses it | Calls it via tools API | Reads it from message context |
| Loading | Eager — schema in every LLM call | Lazy — summary in prompt, body on demand |

### The deeper truth

Both are **capabilities the agent can access**. The only meaningful differences are:

1. **Where the loaded content goes** — tools go into the `tools` API parameter (structured, parameterized). Skills go into the message stream (unstructured, instructional).

2. **Whether they have side effects** — tools DO things (run commands, write files). Skills TEACH things (inject guidelines, instructions).

3. **The loading strategy** — and this is the key insight: this is currently coupled to the kind, but it doesn't have to be.

A tool that's rarely used (say `web_fetch`) wastes tokens on every turn. A skill that's always relevant (say a project's coding conventions) might benefit from being eager. The loading strategy should be independent of the capability kind.

### Why skills are "tools that return text"

The current `skill` tool is a function that takes a name and returns a string. That's it. The string happens to be instructional text rather than, say, file contents — but mechanically it's identical to `fs_read`. Skills are already tools under the hood. They just have a different discovery/loading strategy layered on top.

## Design: One Catalog, Two Kinds

### The unified model

```
Capability
  ├── name: string                       # identifier
  ├── description: string                # for catalog display
  ├── loading: :eager | :deferred        # when to make available
  └── kind:
      ├── :tool → parameter schema + execute fn
      ├── :prompt → body text
      └── :composite → tools + prompt sections
```

This maps directly onto the existing `Extension` behaviour. `components/1` already returns both `tools` and `prompt_sections`. The addition is a `loading` annotation that controls whether a capability's tools are resolved at session start or deferred to the catalog.

### What stays the same

- **SKILL.md files** — still the authoring format for prompt-type capabilities. Users writing prose instructions shouldn't need to write Elixir.
- **Tool modules** — still the authoring format for executable capabilities. `@behaviour Rho.Extension` with `components/1` returning tool defs.
- **Extension behaviour** — unchanged. It already supports the composite case (returning both tools and prompt_sections).

### What changes

- **Loading strategy becomes configurable** — any capability can be eager or deferred.
- **One meta-tool replaces the `skill` tool** — handles discovery and loading for both tools and skills.
- **`tool_defs` in AgentLoop becomes mutable** — new tools can be added mid-conversation when the meta-tool loads them.
- **One catalog in the system prompt** — replaces `<available_skills>` with `<available_capabilities>` listing all deferred items.

## Why Not Full Consolidation?

I considered collapsing skills and tools into a single concept. Here's why that's wrong:

### 1. Different authoring audiences

A SKILL.md author is writing prose. A tool author is writing Elixir code with parameter schemas, execute functions, error handling. Forcing these into one format serves neither audience.

### 2. Different LLM interaction modes

When the LLM loads a tool, it gains a new callable function. When it loads a skill, it gains context/instructions. These are fundamentally different cognitive modes for the LLM — one adds to its action space, the other adds to its knowledge. A single "load" action that sometimes adds tools and sometimes adds knowledge creates ambiguity.

### 3. The composite case is the exception, not the rule

Most capabilities are purely one kind. A "deploy" skill that also provides deploy tools is interesting but rare. Designing the entire system around the composite case over-engineers the common case.

### 4. The right analogy: library catalog, not library book

Books and DVDs are different media. They're shelved differently, consumed differently. But you find them through the same catalog. The unification should be at the **discovery layer**, not at the **content layer**.

## Implementation Plan

### Phase 1: Capability Registry

Add a registry that tracks all available capabilities — both eager and deferred — with their metadata.

**New file: `lib/rho/capability.ex`**

```elixir
defmodule Rho.Capability do
  @moduledoc """
  A registered capability: something the agent can use, either eagerly loaded
  or available for on-demand discovery.
  """

  defstruct [
    :name,           # "bash", "web_fetch", "code-review"
    :description,    # one-line description for catalog
    :module,         # extension module (or nil for SKILL.md-based)
    :source,         # :config | :extension | :skill
    :loading,        # :eager | :deferred
    :kind            # :tool | :prompt | :composite
  ]
end
```

**New file: `lib/rho/capability/registry.ex`**

The registry is built at session start from three sources:
1. `.rho.exs` tool list — annotated with `:eager` or `:deferred`
2. Extension modules — via `components/1` metadata
3. SKILL.md files — always `:prompt` kind, default `:deferred`

```elixir
defmodule Rho.Capability.Registry do
  @moduledoc """
  Builds and queries the capability catalog for a session.
  """

  def build(config, context) do
    eager_tools = resolve_eager(config.tools, context)
    deferred_tools = resolve_deferred(config.deferred || [], context)
    skills = discover_skills(context[:workspace])

    %{
      eager: eager_tools,
      deferred: deferred_tools ++ skills,
      catalog: build_catalog(deferred_tools ++ skills)
    }
  end

  def search(registry, query) do
    # Simple substring/fuzzy match on name + description
    registry.deferred
    |> Enum.filter(fn cap ->
      String.contains?(String.downcase(cap.name), String.downcase(query)) or
      String.contains?(String.downcase(cap.description), String.downcase(query))
    end)
  end

  def resolve(registry, name, context) do
    # Find the deferred capability, resolve it to tool_defs or prompt text
    case Enum.find(registry.deferred, &(&1.name == name)) do
      %{kind: :tool, module: mod} ->
        tool_defs = mod.components(context).tools
        {:tools, tool_defs}

      %{kind: :prompt, module: nil, source: :skill} = cap ->
        body = Rho.Skill.load_body(cap.name, context[:workspace])
        {:prompt, body}

      %{kind: :composite, module: mod} ->
        comps = mod.components(context)
        {:composite, comps.tools, comps.prompt_sections}

      nil ->
        {:error, "Unknown capability: #{name}"}
    end
  end

  defp build_catalog(deferred) do
    Enum.map_join(deferred, "\n", fn cap ->
      kind_tag = case cap.kind do
        :tool -> "[tool]"
        :prompt -> "[skill]"
        :composite -> "[tool+skill]"
      end
      "- #{cap.name} #{kind_tag}: #{cap.description}"
    end)
  end
end
```

### Phase 2: Config Changes

Extend `.rho.exs` to support deferred capabilities:

```elixir
# .rho.exs
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet",
    tools: [:bash, :fs_read, :fs_write, :fs_edit],       # eager — always in schema
    deferred: [:web_fetch, :subagent],                    # lazy — in catalog only
    max_steps: 50
  ]
}
```

**Changes to `lib/rho/config.ex`:**

```elixir
def agent(name \\ :default) do
  # ...existing code...
  %{
    model: config[:model],
    system_prompt: config[:system_prompt],
    tools: config[:tools],
    deferred: config[:deferred] || [],    # NEW
    extensions: config[:extensions] || [],
    max_steps: config[:max_steps],
    max_tokens: config[:max_tokens],
    provider: config[:provider]
  }
end
```

Skills discovered from SKILL.md are implicitly deferred (as they are today). No config change needed for them.

### Phase 3: The Meta-Tool

Replace the `skill` tool with a unified `discover` tool that handles both tool and skill loading.

**New file: `lib/rho/tools/discover.ex`**

```elixir
defmodule Rho.Tools.Discover do
  @behaviour Rho.Extension

  @impl true
  def components(%{workspace: workspace} = context) do
    registry = Rho.Capability.Registry.build(
      Rho.Config.agent(context[:agent_name]),
      context
    )

    catalog = registry.catalog

    %Rho.Extension.Components{
      tools: [
        search_tool(registry, context),
        load_tool(registry, context)
      ],
      prompt_sections: [
        "<available_capabilities>\n#{catalog}\n</available_capabilities>"
      ]
    }
  end

  def components(_), do: %Rho.Extension.Components{}

  defp search_tool(registry, _context) do
    %{
      tool: ReqLLM.tool(
        name: "discover",
        description: """
        Search available capabilities by keyword. Returns matching tools and skills
        that can be loaded with the `load` tool. Use this when you need a capability
        not currently available.
        """,
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search keyword"]
        ],
        callback: fn _ -> :ok end
      ),
      execute: fn args ->
        results = Rho.Capability.Registry.search(registry, args["query"])
        if results == [] do
          {:ok, "No capabilities found matching \"#{args["query"]}\"."}
        else
          formatted = Enum.map_join(results, "\n", fn cap ->
            kind = case cap.kind do
              :tool -> "[tool]"
              :prompt -> "[skill]"
              :composite -> "[tool+skill]"
            end
            "- #{cap.name} #{kind}: #{cap.description}"
          end)
          {:ok, "Found capabilities:\n#{formatted}\n\nUse load(name: \"...\") to activate."}
        end
      end
    }
  end

  defp load_tool(registry, context) do
    %{
      tool: ReqLLM.tool(
        name: "load",
        description: """
        Load a capability by name. For tools, this makes them available for calling
        in subsequent turns. For skills, this returns the full instructional content.
        """,
        parameter_schema: [
          name: [type: :string, required: true, doc: "Capability name to load"]
        ],
        callback: fn _ -> :ok end
      ),
      execute: fn args ->
        case Rho.Capability.Registry.resolve(registry, args["name"], context) do
          {:tools, tool_defs} ->
            # Signal to AgentLoop to merge these tools
            {:ok, "Loaded tool: #{args["name"]}. It is now available for use.",
              add_tools: tool_defs}

          {:prompt, body} ->
            {:ok, body}

          {:composite, tool_defs, prompt_sections} ->
            text = Enum.join(prompt_sections, "\n\n")
            {:ok, text, add_tools: tool_defs}

          {:error, msg} ->
            {:ok, msg}
        end
      end
    }
  end
end
```

### Phase 4: Mutable Tool Set in AgentLoop

This is the core architectural change. `tool_defs` must be able to grow across loop iterations.

**Changes to `lib/rho/agent_loop.ex`:**

The key change is in tool execution result handling. Currently:

```elixir
case tool_def.execute.(args) do
  {:ok, output} -> ...
  {:error, reason} -> ...
end
```

Add a third return shape:

```elixir
case tool_def.execute.(args) do
  {:ok, output} -> {output, nil}
  {:ok, output, add_tools: new_tools} -> {output, new_tools}
  {:error, reason} -> {error_str, nil}
end
```

When `new_tools` is non-nil, merge them into `tool_defs` and rebuild `req_tools` before the next iteration:

```elixir
# After collecting all tool results in a step:
{new_tool_defs, new_req_tools} =
  if pending_tools != [] do
    merged = tool_defs ++ pending_tools
    {merged, Enum.map(merged, & &1.tool)}
  else
    {tool_defs, req_tools}
  end

# Pass updated tool_defs into next iteration
do_loop(model, updated_context, new_req_tools, new_tool_defs, gen_opts, loop_opts,
  step: step + 1, max_steps: max)
```

The tool results that triggered the load still appear in the conversation as text ("Loaded tool: web_fetch"), so the LLM knows the tool is now available. On the next turn, the tool's schema appears in the tools API parameter.

### Phase 5: Migrate Existing Skills

The existing `Rho.Skills` extension becomes a thin adapter. Instead of its own discovery and tool, it feeds into the capability registry.

**Changes to `lib/rho/skills.ex`:**

The `Rho.Skill` struct and `discover/1` function remain — they're the filesystem scanner for SKILL.md files. But instead of providing its own `skill` tool and `<available_skills>` prompt section, it contributes capability entries to the registry.

```elixir
# Rho.Skill entries become Rho.Capability entries:
def to_capability(%Rho.Skill{} = skill) do
  %Rho.Capability{
    name: skill.name,
    description: skill.description,
    module: nil,
    source: :skill,
    loading: :deferred,
    kind: :prompt
  }
end
```

The `Rho.Skills` extension module can be simplified or removed entirely — its two responsibilities (prompt section + skill tool) are now handled by `Rho.Tools.Discover`.

### Phase 6: Backward Compatibility

For users with existing `.rho.exs` using `tools: [:bash, :fs_read, ...]`:

- All tools listed in `tools:` remain eager. No behavior change.
- `deferred:` is a new optional key. If absent, everything is eager (current behavior).
- Skills are automatically deferred (current behavior, just through a different mechanism).
- The `skill` tool name can be kept as an alias for `load` to avoid breaking existing prompt references.

## Considered Alternatives

### Alternative A: Skills become tool modules

Make every SKILL.md compile into an Elixir module at discovery time, with a `components/1` that returns a zero-parameter tool whose execute function returns the body text.

**Rejected because:** Over-engineering. SKILL.md is a good authoring format for prose. Turning it into a module adds build complexity and confuses the authoring model. The registry adapter (`Skill.to_capability/1`) achieves the same result more simply.

### Alternative B: Tools become SKILL.md files

Define tool schemas in markdown with YAML frontmatter, generate Elixir at compile time.

**Rejected because:** Tool implementations need Elixir code. You can't write an `execute` function in markdown. This would require a DSL or code generation step that adds complexity without clear benefit.

### Alternative C: Full consolidation into one type

No distinction between tool and skill. Everything is a "capability" with optional parameters and optional body text.

**Rejected because:** Creates authoring confusion (am I writing a function or prose?), LLM confusion (does loading this give me a callable tool or knowledge?), and implementation complexity (every capability needs both a schema path and a text path). The catalog unification achieves the practical benefits without the conceptual costs.

### Alternative D: No meta-tool, just lazy schema injection

Instead of a `load` tool, inject tool schemas into the prompt lazily based on conversation context (e.g., if the user mentions "fetch a URL", auto-inject web_fetch).

**Rejected because:** Unreliable heuristics. The LLM should decide what tools it needs, not a regex/keyword matcher. The meta-tool approach gives the LLM agency over its own capability set, which is more robust and transparent.

## Open Questions

1. **Should loaded tools persist across tape compaction?** When the tape compacts, the `load` tool call and its result get summarized. But the LLM needs to know the tool is still available. Options: (a) always re-inject loaded tools after compaction, (b) include loaded tool names in the compaction summary, (c) track loaded tools in session state outside the tape.

2. **Should the LLM be able to unload tools?** If the tool set grows too large mid-conversation, an `unload` tool could remove schemas. This adds complexity but could be useful for very long sessions. Probably not worth building initially.

3. **How should deferred tools interact with subagents?** A subagent inherits the parent's tool set. Should it also inherit loaded deferred tools? Probably yes — the parent loaded them for a reason, and the subagent is working on a subtask.

4. **Should eager/deferred be per-agent or global?** Currently `.rho.exs` is per-agent. A tool that's deferred for one agent might be eager for another. The config already supports this naturally since `tools:` and `deferred:` are per-agent keys.

## Migration Path

1. **Phase 1-2** can ship independently — the registry and config changes are backward compatible.
2. **Phase 3-4** are the breaking changes — they replace the `skill` tool and modify AgentLoop's tool execution contract.
3. **Phase 5-6** are cleanup — migrating existing code to the new patterns.

Each phase is independently testable. The system works at every intermediate state.
