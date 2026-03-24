# Rho

An Elixir agent framework with pluggable memory backends, a signal-based multi-agent coordination layer, and parallel peer agents with isolated context windows. The default memory backend is an append-only tape system with JSONL persistence.

## Quick Start

```bash
# One-shot query
mix rho.run "What is 2 + 2?"

# Interactive chat (continuous per directory)
mix rho.chat

# Interactive chat with a named session
mix rho.chat --session my-project
```

## CLI Options

### `mix rho.run`

Send a one-shot message to the LLM. No tape persistence.

```
mix rho.run [OPTIONS] "your message"
```

| Flag | Description |
|------|-------------|
| `--agent NAME` | Agent profile from `.rho.exs` (default: `default`) |
| `--model MODEL` | Override model (e.g. `openrouter:anthropic/claude-sonnet`) |
| `--system PROMPT` | Override system prompt |
| `--max-steps N` | Max tool-calling iterations |

### `mix rho.chat`

Start an interactive multi-turn chat session with tape-backed memory.

By default, sessions are continuous per workspace directory — running `mix rho.chat` in the same directory always resumes the same conversation. The session ID resolves to `"cli:default"`, which is hashed together with the workspace path to produce a deterministic tape name. This means different directories get independent conversations automatically.

Use `--session` to create or resume a named session, useful for maintaining separate conversations within the same directory (e.g., one for a refactor, another for debugging).

```
mix rho.chat [OPTIONS]
```

| Flag | Description |
|------|-------------|
| `--session ID` | Named session. Without this, defaults to a per-directory continuous session. |
| `--agent NAME` | Agent profile from `.rho.exs` (default: `default`) |
| `--model MODEL` | Override model |
| `--system PROMPT` | Override system prompt |
| `--max-steps N` | Max tool-calling iterations |

## Trace Analysis

Every agent loop step is recorded to the tape with structured metadata: token counts (input, output, reasoning, cached, cache creation), cost breakdown (input, output, reasoning, total), model identifier, tool execution latency, and error classification. This data powers offline analysis via `mix rho.trace`.

### `mix rho.trace`

Analyze tape traces without booting the agent runtime — reads JSONL files directly.

```
mix rho.trace <command> [tape_name...] [OPTIONS]
```

| Command | Description |
|---------|-------------|
| `summary` | Session overview: turns, steps, tools, token counts, cache hit rate, cost |
| `tools` | Per-tool breakdown: call count, error count/rate, average latency, error types |
| `costs` | Cost reporting per session with input/output/reasoning breakdown and totals |
| `failures` | Tool errors with classification, max-steps hits, retry patterns |

| Flag | Description |
|------|-------------|
| `--all`, `-a` | Analyze all tapes |
| `--recent N`, `-n N` | Show N most recent tapes (default: 10) |

```bash
# Quick overview of recent sessions
mix rho.trace summary --recent 5

# Which tools fail most?
mix rho.trace tools --all

# How much did a session cost?
mix rho.trace costs session_abc123_def456

# Find failure patterns
mix rho.trace failures --recent 20
```

#### Enriched Tape Entries

Each `:llm_usage` event entry contains:

| Field | Description |
|-------|-------------|
| `model` | Model identifier used for the call |
| `step` | Loop step number |
| `input_tokens` | Tokens sent to the LLM |
| `output_tokens` | Tokens generated |
| `reasoning_tokens` | Reasoning/thinking tokens |
| `cached_tokens` | Cache read hits (reduced cost) |
| `cache_creation_tokens` | Cache write tokens |
| `total_cost` | Total cost in USD |
| `input_cost`, `output_cost`, `reasoning_cost` | Cost breakdown |

Each `:tool_result` entry includes:

| Field | Description |
|-------|-------------|
| `latency_ms` | Wall-clock execution time |
| `error_type` | Classification: `timeout`, `permission_denied`, `not_found`, `invalid_args`, `runtime_error`, `unknown_tool` |

## Memory System

Rho uses a pluggable memory backend defined by the `Rho.Memory` behaviour. The default implementation (`Rho.Memory.Tape`) is an append-only event log backed by JSONL files under `~/.rho/tapes/`. Memory tools (anchor, search, recall, clear) are provided automatically by the active backend — they don't need to be listed in your `tools:` config.

To swap in a custom backend, implement `Rho.Memory` and set it in `config/config.exs`:

```elixir
config :rho, :memory_module, MyApp.Memory.VectorDB
```

### Tape Backend (Default)

The tape is an append-only event log. Every message, tool call, and tool result is recorded as an immutable **Entry**.

#### How It Works

1. **Entries** are immutable facts with monotonic IDs, written to tape automatically via hooks in the agent loop.
2. **Anchors** are special entries that mark phase transitions (e.g., discovery -> implementation). They carry a summary of what happened before and suggested next steps. The LLM creates anchors via the `create_anchor` tool.
3. **Views** assemble context on demand from the tape. The default view includes the latest anchor's summary plus all entries after it. This keeps the LLM's context window bounded.

```
Tape (complete, on disk):
  [e1, e2, e3, e4, anchor, e5, e6, e7, e8]

What the LLM sees (View):
  [system_prompt, anchor.summary, e5, e6, e7, e8]
```

#### Session Resumability

The tape name is derived deterministically from the session ID and workspace path (`session_<hash(session_id)>_<hash(workspace)>`). On restart, the Store loads the existing JSONL file into ETS and the View reconstructs context from where you left off.

By default (no `--session` flag), the session ID resolves to `"cli:default"`, giving you automatic continuity within each directory. With `--session`, you get a separate tape for each named session.

```bash
# Default: continuous per directory — always resumes
mix rho.chat
# ... have a conversation, quit, come back later
mix rho.chat
# picks up where you left off

# Named session: separate conversation in the same directory
mix rho.chat --session refactor
# ... work on refactor, quit
mix rho.chat --session refactor
# resumes the refactor session

# Different directory = different tape, even without --session
cd ~/other-project && mix rho.chat
# independent conversation
```

#### How These Features Help in Chat

During `mix rho.chat`, three mechanisms keep conversations manageable:

| Feature | Who triggers it | What it solves |
|---------|----------------|----------------|
| **Handoff** | LLM (via `create_anchor` tool) | Long conversations with distinct phases. The LLM decides "discovery is done, time to implement" and creates an anchor. The next turn only sees the summary + new entries, not 30 turns of file reading. |
| **Compaction** | System (automatic in agent loop) | Any conversation that gets too long. If the LLM never creates an anchor and the context grows past ~100k tokens, the system auto-summarizes and shifts the view forward. The user never notices. |
| **Fork/Merge** | Code / Multi-agent mount | Multi-agent parallel exploration. Used by the multi-agent mount when `inherit_context: true` to give a delegated agent the parent's conversation history. By default, delegated agents get a fresh tape. |

Example chat session showing handoff in action:

```
You: Find the bug in our auth system
Assistant: [reads files, runs tests across 25 tool calls]
           → calls create_anchor("implement", "Bug found in login.ex:42 —
             session token not refreshed after password change")

You: Ok fix it
Assistant: [sees only: anchor summary + "Ok fix it" — clean context window]
           [fixes the bug in 5 tool calls]
           → calls create_anchor("verify", "Fixed token refresh in login.ex.
             Added guard clause for expired sessions.")

You: Run the tests
Assistant: [sees only: latest summary + "Run the tests"]
```

Without these features, by turn 40 the LLM drags around every message from the start — costs balloon, attention dilutes, and eventually the context window overflows.

#### Handoff

A handoff writes a new anchor and shifts the execution origin. Use it when transitioning between phases — the default view moves forward, but all history stays on tape.

```elixir
# Agent-initiated: the LLM calls create_anchor tool during chat
# Programmatic: call Service.handoff directly
alias Rho.Tape.Service

Service.ensure_bootstrap_anchor("my_tape")
Service.append("my_tape", :message, %{"role" => "user", "content" => "Find the auth bug"})
Service.append("my_tape", :message, %{"role" => "assistant", "content" => "Found it in login.ex"})

# Transition to implementation phase
{:ok, anchor} = Service.handoff("my_tape", "implement", "Discovery complete. Bug in login.ex line 42.",
  next_steps: ["Fix login.ex", "Add regression test"],
  owner: "agent"       # or "human", "system"
)

# The default view now starts after this anchor.
# Entries before it are preserved but excluded from the LLM's context.
view = Rho.Tape.View.default("my_tape")
# view.entries contains only entries appended after the handoff
```

Options for `handoff/4`:
- `:next_steps` — list of suggested actions for the next phase
- `:source_ids` — entry IDs that informed this anchor (default: auto-collected from last 20 non-anchor entries)
- `:owner` — `"agent"`, `"human"`, or `"system"` (default: `"agent"`)

#### Compaction

Compaction is a system-initiated handoff triggered when context approaches the window limit. It asks the LLM to summarize the current context, then writes that as an anchor.

```elixir
alias Rho.Tape.Compact

# Check if compaction is needed (default threshold: 100k estimated tokens)
Compact.needed?("my_tape")                        # => false
Compact.needed?("my_tape", threshold: 50_000)     # => true (custom threshold)

# Estimate current view's token count (1 token ≈ 4 chars)
Compact.estimate_tokens("my_tape")                # => 12500

# Run compaction manually (requires an LLM model for summarization)
{:ok, anchor} = Compact.run("my_tape", model: "openrouter:anthropic/claude-sonnet")

# Or compact only when needed — no-op if under threshold
{:ok, :not_needed} = Compact.run_if_needed("my_tape",
  model: "openrouter:anthropic/claude-sonnet",
  threshold: 100_000
)
```

The agent loop auto-compacts when `tape_name` is set — no manual intervention needed. It checks `Compact.run_if_needed/2` at the start of each iteration.

#### Fork / Merge

Fork creates an isolated tape for parallel exploration. Merge appends only the delta back to the main tape — the main tape is never rewritten.

```elixir
alias Rho.Tape.Fork

# Fork from the main tape (defaults to latest entry)
{:ok, fork_name} = Fork.fork("main_tape")

# Fork from a specific entry ID
{:ok, fork_name} = Fork.fork("main_tape", at: 120)

# Fork with a custom name
{:ok, "my_branch"} = Fork.fork("main_tape", name: "my_branch")

# Work on the fork independently
Rho.Tape.Service.append(fork_name, :message, %{"role" => "user", "content" => "Try approach A"})
Rho.Tape.Service.append(fork_name, :message, %{"role" => "assistant", "content" => "Approach A works"})

# Merge the fork's new entries back into the main tape
{:ok, count} = Fork.merge(fork_name, "main_tape")
# count => 2 (only delta entries, not the fork_origin anchor)
# Merged entries carry %{"from_fork" => fork_name} in their metadata

# Inspect fork metadata
Fork.fork_info(fork_name)
# => %{source_tape: "main_tape", at_id: 120, entries_since_fork: 3}

Fork.fork_info("main_tape")
# => nil (not a fork)
```

```
Main Tape              Fork Tape
  [120] ──fork(at 120)──→
                          [121] append
                          [122] append
       ←──merge──────────
  [121, 122]  (delta only, from_fork metadata attached)
```

#### Multi-Agent Delegation

The `Rho.Mounts.MultiAgent` mount lets an agent spawn peer agents that run in parallel, each with their own tape, tools, and agent loop. Every agent is a first-class process — they can delegate subtasks, send messages to each other, and be discovered by role.

##### Enabling multi-agent

Add `:multi_agent` to your mounts list in `.rho.exs`:

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet-4.6",
    mounts: [:bash, :fs_read, :fs_write, :fs_edit, :multi_agent],
    max_steps: 50
  ],
  # Role-specific profiles for delegated agents
  researcher: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a research agent. Focus on thorough investigation.",
    mounts: [:bash, :fs_read, :web_fetch],
    max_steps: 30
  ],
  coder: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a coding agent. Write clean, tested code.",
    mounts: [:bash, :fs_read, :fs_write, :fs_edit],
    max_steps: 40
  ]
}
```

When `delegate_task(role: "researcher")` is called, the worker spawns with the `:researcher` agent profile from `.rho.exs`. If no matching profile exists, `:default` is used.

##### Tools provided

| Tool | Description |
|------|-------------|
| `delegate_task` | Spawn a new agent with a task. Returns `agent_id` immediately. |
| `await_task` | Block until a delegated agent finishes and return its result. |
| `send_message` | Send a direct message to another agent by ID or role. |
| `list_agents` | Discover active agents in this session with their roles and status. |

##### Lifecycle

1. **Delegate** — The primary LLM calls `delegate_task(task: "...", role: "researcher")`. A new `Agent.Worker` process starts under the `Agent.Supervisor` with its own tape, tools resolved from the role profile, and a system prompt incorporating the task. A `rho.task.requested` signal is published to the bus.

2. **Run** — The delegated agent runs its own agent loop independently. It has full mount/lifecycle support and can itself delegate further (up to max depth). The agent calls `finish` when its task is complete, publishing `rho.task.completed` to the signal bus.

3. **Await** — The parent calls `await_task(agent_id: "agent_123")`. This blocks until the delegated agent's loop returns. The result text is returned to the parent.

4. **Message** — Agents can exchange messages via `send_message`. Messages are delivered to the target agent's mailbox and processed as turns when the agent is idle.

5. **Discovery** — `list_agents` queries the agent registry to show all active agents in the session with their role, status, and depth.

```
Session "cli:default"
├── primary_cli:default (role: primary, depth 0) ← human talks to this one
│   ├─ delegate_task(task: "Research X", role: "researcher")
│   │   └── agent_42 (role: researcher, depth 1) → runs independently
│   ├─ delegate_task(task: "Implement Y", role: "coder")
│   │   └── agent_43 (role: coder, depth 1) → runs independently
│   ├─ await_task(agent_id: "agent_42") → blocks until research done
│   └─ await_task(agent_id: "agent_43") → blocks until code done
```

##### Signal-based coordination

All agent events are published to a `jido_signal` bus (`Rho.Comms`). This provides:

- **Event routing** — Signals like `rho.task.completed`, `rho.turn.started`, and `rho.agent.started` flow through a shared bus
- **Agent discovery** — The `Rho.Agent.Registry` (ETS-backed) tracks running agents by session, role, and capabilities
- **Causality tracking** — Every signal carries `correlation_id` and `causation_id` for debugging agent interactions

##### Guardrails

| Guardrail | Default | Description |
|-----------|---------|-------------|
| Max agents per session | 10 | Prevents runaway spawning |
| Max depth (nested delegation) | 3 | Limits delegation chains |
| Max steps per delegated agent | 30 | Configurable per role profile |
| Await timeout | 5 minutes | Prevents indefinite blocking |

##### Legacy subagent support

The older `Rho.Plugins.Subagent` mount (`:subagent`) is still available for backward compatibility. It provides `spawn_subagent` and `collect_subagent` tools with a simpler fire-and-forget model. New projects should use `:multi_agent` instead.

#### Storage

- Tapes are stored as JSONL files in `~/.rho/tapes/`
- Base64 data URIs are redacted to `[media]` in the JSONL to prevent file bloat
- Entries are cached in ETS for fast reads

## Configuration

Create a `.rho.exs` file in your project root:

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a helpful assistant.",
    mounts: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch, :multi_agent],
    max_steps: 50
  ]
}
```

### Available Mounts

| Mount | Description |
|-------|-------------|
| `:bash` | Execute shell commands |
| `:fs_read` | Read file contents (requires workspace context) |
| `:fs_write` | Write files (requires workspace context) |
| `:fs_edit` | Edit files with line-based modifications (requires workspace context) |
| `:web_fetch` | Fetch web content via HTTP |
| `:skills` | Load a skill's full prompt content by name (requires workspace) |
| `:multi_agent` | Delegate tasks to peer agents, send messages, discover agents |
| `:subagent` | Legacy: spawn and collect parallel child agents with isolated context windows |
| `:sandbox` | Sandboxed file operations via AgentFS overlay |
| `:journal` | Journal/tape introspection tools |
| `:step_budget` | Step budget enforcement |
| `:python` | Execute Python in a persistent REPL |

Tools injected automatically by the memory backend (not listed in `mounts:`):

| Tool | Description |
|------|-------------|
| `create_anchor` | Create tape anchors for phase transitions |
| `search_history` | Substring search on conversation history |
| `recall_context` | Recall summaries from previous phases |
| `clear_memory` | Clear all conversation history and start fresh (requires confirmation) |
| `finish` | Signal task completion from within a delegated agent |

### Direct Commands

Use the `,` prefix to invoke tools directly without going through the LLM. Commands bypass the agent loop entirely — no LLM call, no token cost.

```
,bash ls -la
,fs_read path=src/main.ex
,clear_memory confirm=true
```

The syntax is `,tool_name key=value ...` — positional arguments (without `=`) are joined and passed as the `"cmd"` key. Parsed by `Rho.CommandParser`.

#### Tool Reference

| Command | Parameters | Description |
|---------|-----------|-------------|
| `,bash <cmd>` | `cmd` (positional) | Execute a shell command |
| `,fs_read path=<path>` | `path` (required), `offset` (opt), `limit` (opt) | Read a file with optional line slicing |
| `,fs_write path=<path> content=<text>` | `path` (required), `content` (required) | Write or create a file |
| `,fs_edit path=<path> old=<text> new=<text>` | `path` (required), `old` (required), `new` (required), `start` (opt) | Find and replace text in a file |
| `,web_fetch url=<url>` | `url` (required), `timeout` (opt) | HTTP GET a URL and extract text |
| `,python code=<code>` | `code` (required) | Execute Python in a persistent REPL |
| `,skill name=<name>` | `name` (required) | Load a skill's full prompt content |
| `,create_anchor name=<n> summary=<s>` | `name` (required), `summary` (required), `next_steps` (opt) | Create a tape anchor for phase transition |
| `,search_history query=<q>` | `query` (required), `limit` (opt, default 10) | Search past conversation messages |
| `,recall_context` | `phase` (opt) | Recall summaries from previous phases |
| `,clear_memory confirm=true` | `confirm` (required, must be `true`), `archive` (opt, default `true`) | Clear all conversation history |
| `,sandbox_diff` | — | Show file changes in sandbox (sandbox only) |
| `,sandbox_commit` | — | Apply sandbox changes to real workspace (sandbox only) |
| `,delegate_task task=<task>` | `task` (required), `role` (opt), `max_steps` (opt) | Delegate a task to a new agent |
| `,await_task agent_id=<id>` | `agent_id` (required), `timeout` (opt) | Wait for and collect agent result |
| `,send_message target=<id> message=<msg>` | `target` (required), `message` (required) | Send a message to another agent |
| `,list_agents` | — | List active agents in this session |

Available tools depend on your session context — sandbox tools only appear when `RHO_SANDBOX=true`, multi-agent tools only when depth < max. If you reference an unknown tool, the error message lists all currently available tools.

### Skills

Skills are reusable prompt templates discovered from `SKILL.md` files. They inject domain-specific instructions into the agent's system prompt, so the LLM knows what specialized tasks are available without you repeating yourself every session.

#### Creating a skill

Create a directory with a `SKILL.md` file containing YAML frontmatter and a markdown body:

```bash
mkdir -p .agents/skills/code-review
cat > .agents/skills/code-review/SKILL.md << 'EOF'
---
name: code-review
description: Review code for bugs and style issues
---
Review the provided code. Check for:
- Logic errors and edge cases
- Security vulnerabilities (injection, XSS, etc.)
- Style consistency with the project conventions
- Missing error handling

Output a summary with severity levels: critical, warning, info.
EOF
```

#### Discovery locations

Skills are discovered from three locations (first match wins for duplicate names):

```
<workspace>/.agents/skills/<name>/SKILL.md   # project-local (highest priority)
~/.agents/skills/<name>/SKILL.md             # global (shared across projects)
priv/skills/<name>/SKILL.md                  # builtin (shipped with rho)
```

#### How skills reach the LLM

Skills are injected via the `Rho.Skills` mount. When a session starts, the mount's `prompt_sections/2` callback discovers all skills and appends an `<available_skills>` summary to the system prompt:

```xml
<available_skills>
- code-review: Review code for bugs and style issues
- test-writer: Generate test cases for Elixir modules
</available_skills>
```

The LLM sees the list and can request a skill's full content using the `skill` tool.

#### Auto-expansion with `$skill-name`

Reference a skill in your message with `$skill-name` to auto-expand its full body inline:

```
You: $code-review this file: lib/rho/config.ex
```

The system prompt will include the full `code-review` skill body automatically, so the LLM has the detailed instructions without needing a tool call.

#### Programmatic usage

```elixir
# Discover all skills in a workspace
skills = Rho.Skill.discover("/path/to/project")
# => [%Rho.Skill{name: "code-review", description: "...", ...}, ...]

# Render the prompt section
Rho.Skill.render_prompt(skills)
# => "<available_skills>\n- code-review: Review code for...\n</available_skills>"

# Render with specific skills expanded
expanded = MapSet.new(["code-review"])
Rho.Skill.render_prompt(skills, expanded)
# => includes full body for code-review

# Detect $skill-name references in text
Rho.Skill.expanded_hints("Please $code-review my changes", skills)
# => MapSet<["code-review"]>
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `RHO_MODEL` | Override model (only when no `.rho.exs` exists) |
| `RHO_MAX_STEPS` | Override max steps |
| `RHO_MAX_TOKENS` | Override max tokens |
| `RHO_SANDBOX` | Set to `true` to enable sandboxed file operations via AgentFS |

## Sandbox

When `RHO_SANDBOX=true`, Rho creates an overlay filesystem for each session using [AgentFS](https://github.com/anthropics/agentfs). All file writes from the agent are captured in a SQLite database while the real workspace remains read-only. This prevents the agent from making unreviewed changes to your actual files.

### How It Works

1. **Init** — On session start, `Rho.Sandbox` initializes an AgentFS database at `~/.rho/sandboxes/<session_id>/.agentfs/<agent_id>.db`. The database is reused across restarts of the same session.
2. **Mount** — An NFS (macOS) or FUSE (Linux) overlay is mounted at a temp path. The agent's file tools operate on this mount instead of the real workspace.
3. **Review** — Use the `sandbox_diff` tool to see what the agent changed.
4. **Commit** — Use `sandbox_commit` to sync approved changes back to the real workspace via rsync.
5. **Cleanup** — On graceful shutdown, the mount is unmounted and the agentfs process is terminated.

### Shutdown and Recovery

The agent worker traps exits and the application's `prep_stop/1` callback explicitly stops all active agents, ensuring the agentfs mount process is cleaned up on normal shutdown (including Ctrl-C → abort).

If the BEAM is killed abruptly (e.g., double Ctrl-C or SIGKILL), the agentfs process may be left running. On the next startup, `Rho.Sandbox` automatically:

- Unmounts stale mounts at the expected mount path
- Removes non-directory artifacts left by dead mounts
- Skips `agentfs init` if the database already exists, reusing prior session state

```bash
# Start a sandboxed chat session
RHO_SANDBOX=true mix rho.chat

# The agent writes to the overlay — your real files are untouched
# Use sandbox_diff / sandbox_commit tools inside the chat to review and apply changes
```

### AgentFS CLI

The `agentfs` binary includes CLI tools for inspecting and managing sandbox databases directly, useful for debugging or recovery.

```bash
# List active agentfs mount/run sessions
agentfs ps

# List files in a sandbox database (by agent ID — must run from the db directory)
cd ~/.rho/sandboxes/cli:default && agentfs fs rho_cli_default ls

# List files by database path (from anywhere)
agentfs fs ~/.rho/sandboxes/cli:default/.agentfs/rho_cli_default.db ls

# Read a file from the sandbox
agentfs fs ~/.rho/sandboxes/cli:default/.agentfs/rho_cli_default.db cat short_story.txt

# Show diff between sandbox overlay and base workspace
agentfs diff rho_cli_default  # (from the db directory)

# View the agent action timeline
agentfs timeline rho_cli_default
```

### Cleanup

```bash
# Kill an orphaned agentfs process
lsof ~/.rho/sandboxes/cli:default/.agentfs/rho_cli_default.db
kill <PID>

# Remove a sandbox entirely
rm -rf ~/.rho/sandboxes/cli:default

# Prune unused agentfs resources
agentfs prune
```

### Requirements

The `agentfs` binary must be installed and available on `PATH`. Install it via:

```bash
cargo install agentfs
```

## Mount System

Rho uses a unified mount system based on the `Rho.Mount` behaviour. Mounts contribute **affordances** (tools, prompt sections, bindings) and handle **lifecycle hooks** (before/after LLM calls, tool calls, and steps). All optional behavior arrives through mounts.

A built-in mount (`Rho.Builtin`) is registered at startup with the lowest priority — any user mount registered after it takes precedence.

### Writing a Mount

```elixir
defmodule MyMount do
  @behaviour Rho.Mount

  # Provide tools
  @impl true
  def tools(_mount_opts, %{workspace: workspace}) do
    [jira_tool(workspace)]
  end

  # Provide prompt sections
  @impl true
  def prompt_sections(_mount_opts, _context) do
    ["Always check Jira before starting work."]
  end

  # Intercept tool results
  @impl true
  def after_tool(%{name: "bash"} = _call, result, _mount_opts, _context) do
    case result do
      {:ok, output} when is_binary(output) ->
        if String.contains?(output, "SECRET"),
          do: {:override, "[redacted]"},
          else: :ok
      _ -> :ok
    end
  end

  def after_tool(_call, _result, _mount_opts, _context), do: :ok

  defp jira_tool(_workspace) do
    %{
      tool: ReqLLM.tool(
        name: "jira_search",
        description: "Search Jira tickets",
        parameter_schema: [query: [type: :string, required: true, doc: "Search query"]],
        callback: fn _args -> :ok end
      ),
      execute: fn %{"query" => q} ->
        {:ok, "Results for: #{q}"}
      end
    }
  end
end
```

### Registering Mounts

#### Per-agent mounts via `.rho.exs`

Register scoped mounts using the `mounts:` key — they only activate when that agent is running:

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet",
    mounts: [:bash, :fs_read, :fs_write, MyJiraMount],
    max_steps: 50
  ],
  coder: [
    model: "openrouter:anthropic/claude-sonnet-4",
    mounts: [:bash, :fs_read, :fs_write, :fs_edit, MyLintMount],
    max_steps: 30
  ]
}
```

#### Global mounts (programmatic)

For mounts that should apply to all agents (e.g., error reporting), register them at runtime:

```elixir
Rho.MountRegistry.register(MyGlobalMount)
```

#### Explicit scope control

```elixir
# Global (default) — fires for all agents
Rho.MountRegistry.register(MyMount)

# Scoped to a specific agent — only fires when agent_name matches
Rho.MountRegistry.register(MyMount, scope: {:agent, :coder})

# With options
Rho.MountRegistry.register(MyMount, scope: {:agent, :coder}, opts: [some: :opt])
```

Later registrations have higher priority. Affordances from all matching mounts are merged — tools, prompt sections, and bindings are concatenated.

### Mount Scope Semantics

| Context has `agent_name`? | Global mount | Scoped `{:agent, :coder}` mount |
|---|---|---|
| `agent_name: :coder` | fires | fires |
| `agent_name: :default` | fires | skipped |
| no `agent_name` (system-level) | fires | skipped |

### Mount Callbacks

The `Rho.Mount` behaviour defines these optional callbacks:

**Affordances:**

| Callback | Signature | Purpose |
|----------|-----------|---------|
| `tools/2` | `(mount_opts, context)` | Return tool definitions (`[%{tool: ReqLLM.Tool.t(), execute: fn}]`) |
| `prompt_sections/2` | `(mount_opts, context)` | Return extra text appended to the system prompt |
| `bindings/2` | `(mount_opts, context)` | Return key-value bindings for prompt metadata |

**Lifecycle Hooks:**

| Callback | Signature | Purpose |
|----------|-----------|---------|
| `before_llm/3` | `(messages, mount_opts, context)` | Intercept/transform messages before LLM call |
| `before_tool/3` | `(tool_call, mount_opts, context)` | Intercept before tool execution |
| `after_tool/4` | `(tool_call, result, mount_opts, context)` | Intercept after tool execution. Return `:ok` or `{:override, string}` |
| `after_step/4` | `(step, max_steps, mount_opts, context)` | Intercept after each step. Return `:ok` or `{:inject, string}` |

**Lifecycle:**

| Callback | Signature | Purpose |
|----------|-----------|---------|
| `children/2` | `(mount_opts, context)` | Return child specs for supervised processes |

### Mount Context

All mount callbacks receive a context map:

```elixir
%{
  tape_name: "tape_abc123",
  workspace: "/my/project",
  agent_name: :default,
  agent_id: "primary_cli:default",
  session_id: "cli:default",
  depth: 0,
  sandbox: nil
}
```

### Introspection

```elixir
# Collect merged tools for a context
Rho.MountRegistry.collect_tools(%{agent_name: :default, workspace: "."})

# Collect prompt sections
Rho.MountRegistry.collect_prompt_sections(%{agent_name: :default, workspace: "."})
```

## Architecture

Rho separates concerns into three planes:

```
┌─────────────────────────────────────────────────────┐
│                   EDGE PLANE                        │
│  CLI adapter, Web/WS adapter                        │
│  Subscribe to session events (direct + bus)         │
└──────────────────────┬──────────────────────────────┘
                       │ events
┌──────────────────────▼──────────────────────────────┐
│               COORDINATION PLANE                    │
│  Signal Bus (jido_signal via Rho.Comms)             │
│  Agent Registry (role/capability discovery)         │
│  Multi-Agent Mount (delegation, messaging)          │
│  Session (agent group namespace)                    │
└──────────────────────┬──────────────────────────────┘
                       │ function calls
┌──────────────────────▼──────────────────────────────┐
│                EXECUTION PLANE                      │
│  AgentLoop (recursive LLM tool-calling)             │
│  Reasoner (Direct, extensible)                      │
│  Tape Memory (per-agent, append-only JSONL)         │
│  Mount System (tools, prompt sections, hooks)       │
└─────────────────────────────────────────────────────┘
```

### Supervision Tree

```
Rho.Supervisor (one_for_one)
├── Registry (Rho.AgentRegistry)        # agent_id → pid lookup
├── Registry (Rho.PythonRegistry)       # Python interpreter tracking
├── Task.Supervisor (Rho.TaskSupervisor)
├── DynamicSupervisor (Python.Supervisor)
├── Rho.MountRegistry                   # mount registration + ETS dispatch
├── Rho.Comms.SignalBus                 # jido_signal bus (:rho_bus)
├── [Memory children]                   # from memory_mod.children/1
├── Rho.Agent.Supervisor (DynamicSupervisor)
│   ├── Rho.Agent.Worker (primary_cli:default)    # primary agent
│   ├── Rho.Agent.Worker (agent_42)               # delegated researcher
│   ├── Rho.Agent.Worker (agent_43)               # delegated coder
│   └── ...
├── Rho.CLI                             # CLI adapter
└── [Web children]                      # conditional: RateLimiter, Endpoint
```

One flat `Agent.Supervisor` for all agents. Session scoping is logical (via `session_id`), not structural.

### File Structure

```
lib/rho/
  application.ex       # OTP supervision tree
  config.ex            # Configuration (.rho.exs + env vars)
  sandbox.ex           # AgentFS overlay filesystem lifecycle

  # --- Execution plane ---
  agent_loop.ex        # Recursive LLM tool-calling loop
  agent_loop/
    recorder.ex        # Tape writes during loop
    runtime.ex         # Immutable config per invocation
    tape.ex            # Tape management
  reasoner.ex          # Reasoner behaviour
  reasoner/
    direct.ex          # Default tool-use loop
  lifecycle.ex         # Mount hook closures
  mount.ex             # Mount behaviour
  mount/
    context.ex         # Context struct (agent_id, session_id, depth, ...)
  mount_instance.ex    # Configured mount struct
  mount_registry.ex    # Registration + ETS dispatch
  memory.ex            # Pluggable memory behaviour
  memory/
    tape.ex            # Default tape backend
  tape/
    entry.ex           # Immutable fact record
    store.ex           # GenServer + ETS + JSONL persistence
    service.ex         # High-level tape API + handoff
    view.ex            # Context window assembly
    compact.ex         # Context compaction
    fork.ex            # Fork/merge for parallel exploration
  tools/
    bash.ex            # Shell commands
    fs_read.ex         # Read files
    fs_write.ex        # Write files
    fs_edit.ex         # Edit files
    web_fetch.ex       # HTTP fetch
    python.ex          # Python REPL
    sandbox.ex         # Sandbox tools
    finish.ex          # Delegated agent completion signal
    anchor.ex          # Tape anchor creation
    search_history.ex  # Tape search
    recall_context.ex  # Context recall
    clear_memory.ex    # Memory reset
    path_utils.ex      # Workspace boundary enforcement

  # --- Coordination plane ---
  comms.ex             # Signal bus behaviour
  comms/
    signal_bus.ex      # jido_signal implementation
  agent/
    worker.ex          # Unified agent process (primary + delegated)
    registry.ex        # ETS-based agent discovery
    supervisor.ex      # DynamicSupervisor for all agents
  session.ex           # Session = namespace for agent group
  mounts/
    multi_agent.ex     # delegate_task, await_task, send_message, list_agents
    journal_tools.ex   # Journal introspection tools

  # --- Edge plane ---
  cli.ex               # CLI REPL adapter
  web/
    socket.ex          # WebSocket handler
    endpoint.ex        # Bandit web endpoint
    router.ex          # HTTP routing
    api_router.ex      # API routes
    auth.ex            # Authentication
    rate_limit_plug.ex # Rate limiting

  # --- Legacy (backward compat) ---
  plugins/
    subagent.ex        # Legacy subagent mount (use :multi_agent instead)
    subagent/
      worker.ex        # Legacy subagent worker
      supervisor.ex    # Legacy subagent supervisor
      ui.ex            # CLI progress display

  # --- Utilities ---
  builtin.ex           # Default infrastructure mount
  command_parser.ex    # ,tool key=value syntax
  debounce.ex          # Per-session message buffering
  skill.ex             # Skill struct + discovery
  skills.ex            # Skills mount

lib/mix/tasks/
  rho.chat.ex          # Interactive REPL
  rho.run.ex           # One-shot query
  rho.trace.ex         # Offline tape trace analyzer
```
