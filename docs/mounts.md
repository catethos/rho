# Writing Custom Mounts

Mounts are the sole extension mechanism in Rho. Everything that contributes optional behavior to an agent — tools, prompt text, bindings, lifecycle hooks — is a mount implementing the `Rho.Mount` behaviour.

## The Two Planes

Mount callbacks are organized into two planes:

| Plane | Callbacks | Visible to LLM? | Purpose |
|-------|-----------|-----------------|---------|
| **Affordances** | `tools/2`, `prompt_sections/2`, `bindings/2` | Yes | Provide capabilities the LLM can see and use |
| **Hooks** | `before_llm/3`, `before_tool/3`, `after_tool/4`, `after_step/4` | No | Policy, guardrails, projection shaping |

All callbacks are optional — implement only what you need.

## Tools-Only Mount (Simplest Case)

The simplest mount provides tools. Here's the pattern used by `Rho.Tools.Bash`:

```elixir
defmodule MyTools.Jira do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{workspace: workspace}) do
    [
      %{
        tool: ReqLLM.tool(
          name: "jira_search",
          description: "Search Jira tickets by query",
          parameter_schema: [
            query: [type: :string, required: true, doc: "JQL or text search query"]
          ],
          callback: fn _args -> :ok end
        ),
        execute: fn %{"query" => query} ->
          case search_jira(query, workspace) do
            {:ok, results} -> {:ok, results}
            {:error, reason} -> {:error, reason}
          end
        end
      }
    ]
  end

  defp search_jira(query, _workspace) do
    {:ok, "Found 3 tickets matching: #{query}"}
  end
end
```

**Key points:**
- `tools/2` returns a list of `%{tool: ReqLLM.Tool.t(), execute: fn}`
- The `execute` function receives a map of string-keyed arguments
- Return `{:ok, string}` or `{:error, term}` from execute
- The `callback: fn _args -> :ok end` in the tool schema is required by ReqLLM but unused by Rho

## Adding Prompt Sections

Prompt sections append text to the system prompt. Useful for injecting instructions or context:

```elixir
defmodule MyMount.Conventions do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def prompt_sections(_mount_opts, %{workspace: workspace}) do
    case File.read(Path.join(workspace, "CONVENTIONS.md")) do
      {:ok, content} -> [content]
      {:error, _} -> []
    end
  end
end
```

Sections from all active mounts are concatenated and appended to the system prompt.

## Adding Bindings

Bindings expose large resources by reference rather than inlining them in the prompt. The engine renders a one-line metadata summary; the LLM accesses the actual content via the specified access method.

```elixir
defmodule MyMount.Database do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def bindings(_mount_opts, _context) do
    [
      %{
        name: "schema",
        kind: :structured_data,
        size: 4200,
        access: :tool,
        persistence: :session,
        summary: "PostgreSQL schema with 12 tables"
      }
    ]
  end
end
```

The binding type fields:
- `kind` — `:text_corpus`, `:structured_data`, `:filesystem`, or `:session_state`
- `access` — `:python_var`, `:tool`, or `:resolver`
- `persistence` — `:turn`, `:session`, or `:derived`

See `Rho.Mounts.JournalTools` for a real example combining tools and bindings.

## Lifecycle Hooks

Hooks run invisibly to the LLM. They're used for policy enforcement, guardrails, and injection.

### `after_tool/4` — Intercept Tool Results

Runs after each tool execution. Return `{:ok, result}` to pass through, or `{:replace, new_result}` to substitute:

```elixir
defmodule MyMount.Redactor do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def after_tool(%{name: "bash"}, result, _mount_opts, _context) do
    if String.contains?(result, "SECRET_KEY") do
      {:replace, "[redacted — contains secrets]"}
    else
      {:ok, result}
    end
  end

  def after_tool(_call, result, _mount_opts, _context), do: {:ok, result}
end
```

### `after_step/4` — Inject Messages Between Steps

Runs after each agent loop step. Return `:ok` to continue, or `{:inject, message}` to insert a user-role message before the next LLM call:

```elixir
defmodule MyMount.Reminder do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def after_step(step, max_steps, _mount_opts, _context) when step > max_steps - 3 do
    {:inject, "[System] #{max_steps - step} steps remaining. Wrap up soon."}
  end

  def after_step(_step, _max_steps, _mount_opts, _context), do: :ok
end
```

See `Rho.Plugins.StepBudget` for a real example using both `tools/2` and `after_step/4`.

### `before_llm/3` — Transform the Projection

Runs before each LLM call with the assembled projection. Return `{:ok, projection}` to pass through, or `{:replace, projection}` to substitute:

```elixir
@impl Rho.Mount
def before_llm(projection, _mount_opts, _context) do
  # Add a system note to the messages
  note = %{"role" => "system", "content" => "Remember: always respond in Spanish."}
  {:replace, %{projection | messages: projection.messages ++ [note]}}
end
```

### `before_tool/3` — Gate Tool Execution

Runs before a tool is executed. Return `:ok` to allow, or `{:deny, reason}` to block:

```elixir
@impl Rho.Mount
def before_tool(%{name: "bash", arguments: %{"cmd" => cmd}}, _mount_opts, _context) do
  if String.contains?(cmd, "rm -rf") do
    {:deny, "Destructive commands are not allowed"}
  else
    :ok
  end
end

def before_tool(_call, _mount_opts, _context), do: :ok
```

## Registration

### Via `.rho.exs` (per-agent)

Use shorthand atoms for built-in mounts or module names for custom ones:

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet",
    mounts: [:bash, :fs_read, :fs_write, MyMount.Jira],
    max_steps: 50
  ]
}
```

Built-in shorthand atoms: `:bash`, `:fs_read`, `:fs_write`, `:fs_edit`, `:web_fetch`, `:python`, `:skills`, `:subagent`, `:sandbox`, `:journal`, `:step_budget`.

Pass options to a mount with a tuple:

```elixir
mounts: [:bash, {:python, max_iterations: 20}, MyMount.Jira]
```

### Programmatic (global)

Register mounts at runtime via `MountRegistry`:

```elixir
Rho.MountRegistry.register(MyMount.ErrorReporter)
```

With explicit scope and options:

```elixir
# Only active for the :coder agent
Rho.MountRegistry.register(MyMount.Linter, scope: {:agent, :coder})

# With mount opts
Rho.MountRegistry.register(MyMount.Jira, opts: [project: "INGEST"])
```

Later registrations have higher priority. A built-in mount (`Rho.Builtin`) is registered at startup with the lowest priority.

## Scoping

| Context `agent_name` | Global mount | `{:agent, :coder}` mount |
|-----------------------|-------------|--------------------------|
| `:coder` | fires | fires |
| `:default` | fires | skipped |
| no `agent_name` | fires | skipped |

Mounts registered via `.rho.exs` are scoped to their agent automatically.

## The Context Map

All callbacks receive a context map:

```elixir
%{
  tape_name: "session_abc123_def456",  # memory reference
  workspace: "/path/to/project",       # working directory
  agent_name: :default,                # :default, :coder, etc.
  depth: 0,                            # 0 = top-level, +1 per subagent
  sandbox: nil                         # or %Rho.Sandbox{} when active
}
```

Use context fields to conditionally provide tools or change behavior. For example, `Rho.Plugins.StepBudget` checks `depth` to skip subagents, and `Rho.Mounts.JournalTools` guards on `tape_name` presence.

## Mount Opts Passthrough

Options specified in `.rho.exs` or at registration time are passed as the first argument to every callback:

```elixir
# .rho.exs
mounts: [{:python, max_iterations: 20}]

# In your mount
def tools(mount_opts, _context) do
  max = Keyword.get(mount_opts, :max_iterations, 10)
  # ... use max
end
```

## Complete Example: A Rate-Limiting Mount

This mount combines tools, hooks, and opts to provide a rate-limited API tool:

```elixir
defmodule MyMount.RateLimitedAPI do
  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(mount_opts, _context) do
    base_url = Keyword.get(mount_opts, :base_url, "https://api.example.com")

    [
      %{
        tool: ReqLLM.tool(
          name: "api_query",
          description: "Query the external API",
          parameter_schema: [
            endpoint: [type: :string, required: true, doc: "API endpoint path"],
            method: [type: :string, required: false, doc: "HTTP method (default: GET)"]
          ],
          callback: fn _args -> :ok end
        ),
        execute: fn %{"endpoint" => endpoint} = args ->
          method = Map.get(args, "method", "GET")
          call_api(base_url, endpoint, method)
        end
      }
    ]
  end

  @impl Rho.Mount
  def prompt_sections(mount_opts, _context) do
    base_url = Keyword.get(mount_opts, :base_url, "https://api.example.com")
    max = Keyword.get(mount_opts, :max_calls, 10)

    ["You have access to an external API at #{base_url}. " <>
     "Limit yourself to #{max} calls per session to avoid rate limiting."]
  end

  @impl Rho.Mount
  def before_tool(%{name: "api_query"}, mount_opts, _context) do
    max_calls = Keyword.get(mount_opts, :max_calls, 10)
    current = Process.get(:api_call_count, 0)

    if current >= max_calls do
      {:deny, "Rate limit reached (#{max_calls} calls). No more API queries allowed."}
    else
      Process.put(:api_call_count, current + 1)
      :ok
    end
  end

  def before_tool(_call, _mount_opts, _context), do: :ok

  defp call_api(base_url, endpoint, method) do
    {:ok, "#{method} #{base_url}/#{endpoint} => 200 OK"}
  end
end
```

Register it:

```elixir
# In .rho.exs
mounts: [:bash, :fs_read, {MyMount.RateLimitedAPI, base_url: "https://api.internal", max_calls: 5}]
```

## Reference: Existing Mounts

| Mount | File | Pattern |
|-------|------|---------|
| `Rho.Tools.Bash` | `lib/rho/tools/bash.ex` | Tools only — simplest example |
| `Rho.Tools.Python` | `lib/rho/tools/python.ex` | Tools + bindings |
| `Rho.Mounts.JournalTools` | `lib/rho/mounts/journal_tools.ex` | Tools + bindings with context guards |
| `Rho.Skills` | `lib/rho/skills.ex` | Tools + prompt sections |
| `Rho.Plugins.StepBudget` | `lib/rho/plugins/step_budget.ex` | Tools + `after_step` hook |
| `Rho.Plugins.Subagent` | `lib/rho/plugins/subagent.ex` | Tools + `after_tool` hook |
