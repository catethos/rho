# Rho

An Elixir agent framework with pluggable turn strategies over an append-only tape, a typed transformer pipeline for in-flight policy and mutation, a signal-based multi-agent coordination layer, and parallel peer agents with isolated context windows.

## Architecture at a glance

```
Runner → TurnStrategy → Transformer pipeline → Tape → Bus
```

- **`Rho.Runner`** drives the outer loop: step budget, compaction, tape recording, and transformer dispatch.
- **`Rho.TurnStrategy`** owns the inner turn: LLM call, tool dispatch, response parsing (`:direct` and `:structured` ship built-in).
- **`Rho.Transformer`** runs six typed stages per step (`:prompt_out`, `:response_in`, `:tool_args_out`, `:tool_result_in`, `:post_step`, `:tape_write`) for PII scrub, policy, denial, result replacement, and post-step injection.
- **Tape** is the append-only JSONL event log — the source of truth per agent.
- **Bus** (`Rho.Comms`, backed by `jido_signal`) delivers every event; CLI, LiveViews, and the per-session JSONL `EventLog` all subscribe to `rho.session.<sid>.events.*`.

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

## Tape

Rho's tape is a pluggable, append-only event log. The default projection (`Rho.Tape.Projection.JSONL`) persists to JSONL files under `~/.rho/tapes/`. Tape tools (anchor, search, recall, clear) are contributed automatically by the active projection — they don't need to be listed in your `plugins:` config.

To swap in a custom projection, implement the `Rho.Tape.Projection` behaviour and set it via:

```elixir
# config/config.exs
config :rho, :tape_module, MyApp.Tape.VectorDB
```

### Tape projection (default)

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

The `Rho.Stdlib.Plugins.MultiAgent` plugin lets an agent spawn peer agents that run in parallel, each with their own tape, tools, and Runner. Every agent is a first-class process — they can delegate subtasks, send messages to each other, and be discovered by role.

##### Enabling multi-agent

Add `:multi_agent` to your plugins list in `.rho.exs`:

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet-4.6",
    plugins: [:bash, :fs_read, :fs_write, :fs_edit, :multi_agent],
    max_steps: 50
  ],
  # Role-specific profiles for delegated agents
  researcher: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a research agent. Focus on thorough investigation.",
    plugins: [:bash, :fs_read, :web_fetch],
    max_steps: 30
  ],
  coder: [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a coding agent. Write clean, tested code.",
    plugins: [:bash, :fs_read, :fs_write, :fs_edit],
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

2. **Run** — The delegated agent runs its own Runner loop independently, with full plugin + transformer support, and can itself delegate further (up to max depth). The agent calls `finish` when its task is complete, publishing `rho.task.completed` to the signal bus.

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
- **Persistent event log** — Every session writes a JSONL event log to disk (see [Session Event Log](#session-event-log))

##### Guardrails

| Guardrail | Default | Description |
|-----------|---------|-------------|
| Max agents per session | 10 | Prevents runaway spawning |
| Max depth (nested delegation) | 3 | Limits delegation chains |
| Max steps per delegated agent | 30 | Configurable per role profile |
| Await timeout | 5 minutes | Prevents indefinite blocking |

#### Session Event Log

Every session automatically writes a persistent JSONL event log to disk. The log captures all signal bus events (agent starts/stops, turns, tool calls, inter-agent messages) while filtering out high-frequency streaming events (`text_delta`, `structured_partial`).

**File location**: `{workspace}/_rho/sessions/{session_id}/events.jsonl`

Each line is a JSON object:

```json
{"seq":1,"ts":"2026-03-25T11:06:14.952Z","type":"rho.session.smoke_test_1.events.turn_started","agent_id":"primary_smoke_test_1","session_id":"smoke_test_1","turn_id":"40","data":{"type":"turn_started"}}
```

| Field | Description |
|-------|-------------|
| `seq` | Monotonically increasing sequence number (per session) |
| `ts` | ISO 8601 timestamp |
| `type` | Full signal type (e.g. `rho.turn.started`, `rho.session.*.events.tool_start`) |
| `agent_id` | Which agent produced this event |
| `session_id` | Session namespace |
| `turn_id` | Correlation ID linking events to a specific turn |
| `data` | Event payload (tool args truncated at 2KB, tool results at 4KB) |

##### Programmatic access

```elixir
# Read events with cursor-based pagination
{events, last_seq} = Rho.Agent.EventLog.read(session_id, after: 0, limit: 100)

# Get the file path for direct reading
path = Path.join([workspace, "_rho", "sessions", session_id, "events.jsonl"])
```

##### HTTP API

```bash
# Read event log with cursor pagination
curl "http://localhost:4001/api/sessions/my_session/log?after=0&limit=100"
# => {"events": [...], "cursor": 100, "has_more": true}

# Page through results
curl "http://localhost:4001/api/sessions/my_session/log?after=100&limit=100"
```

##### Message injection

Inject messages into a running session from external tools (e.g. Claude Code observing a simulation):

```elixir
# Inject to the primary agent
Rho.Agent.Primary.inject(session_id, nil, "What's your status?")

# Inject to a specific agent
Rho.Agent.Primary.inject(session_id, "agent_42", "Reconsider your evaluation", from: "external")
```

```bash
# Via HTTP API
curl -X POST http://localhost:4001/api/sessions/my_session/inject \
  -H 'Content-Type: application/json' \
  -d '{"target": "primary", "message": "What is your status?"}'

curl -X POST http://localhost:4001/api/sessions/my_session/inject \
  -H 'Content-Type: application/json' \
  -d '{"target": "agent_42", "message": "Reconsider", "from": "external"}'
```

External messages are formatted differently from inter-agent messages — they don't include instructions to use `send_message` to reply.

##### Session creation via HTTP

```bash
# Create a session (starts EventLog automatically)
curl -X POST http://localhost:4001/api/sessions \
  -H 'Content-Type: application/json' \
  -d '{"session_id": "my_session"}'

# Create with an initial message
curl -X POST http://localhost:4001/api/sessions \
  -H 'Content-Type: application/json' \
  -d '{"session_id": "my_session", "message": "Evaluate these candidates..."}'
```

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
    plugins: [:bash, :fs_read, :fs_write, :fs_edit, :web_fetch, :multi_agent],
    turn_strategy: :direct,
    max_steps: 50
  ]
}
```

### Available plugins (`plugins:` entries)

| Shorthand | Description |
|-----------|-------------|
| `:bash` | Execute shell commands |
| `:fs_read` | Read file contents (requires workspace context) |
| `:fs_write` | Write files (requires workspace context) |
| `:fs_edit` | Edit files with line-based modifications (requires workspace context) |
| `:web_fetch` | Fetch web content via HTTP |
| `:skills` | Load a skill's full prompt content by name (requires workspace) |
| `:multi_agent` | Delegate tasks to peer agents, send messages, discover agents |
| `:sandbox` | Sandboxed file operations via AgentFS overlay |
| `:journal` | Journal/tape introspection tools |
| `:step_budget` | Step budget enforcement |
| `:python` | Execute Python in a persistent REPL |

Tools injected automatically by the tape projection (not listed in `mounts:`):

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

## Multi-Tenant Organizations

The web application (`rho_web` + `rho_frameworks`) supports organization-based multi-tenancy. All framework data is scoped to an organization rather than a user.

### Data Model

```
User ──has_many──→ Memberships ──belongs_to──→ Organization
                       │                          │
                       └─ role (owner/admin/       └─ has_many → Frameworks
                          member/viewer)               has_many → Skills
```

- **Organizations** have a `name` (mutable), `slug` (immutable, used in URLs), and `personal` flag.
- **Memberships** link users to organizations with a role.
- **Frameworks** belong to an organization (not a user).

### Roles

```
owner > admin > member > viewer
```

| Permission | owner | admin | member | viewer |
|------------|-------|-------|--------|--------|
| Delete organization | yes | | | |
| Transfer ownership | yes | | | |
| Rename organization | yes | | | |
| Invite/remove members | yes | yes | | |
| Change member roles | yes | yes | | |
| Create/edit/delete frameworks | yes | yes | yes | |
| View frameworks | yes | yes | yes | yes |

### Personal vs Team Organizations

Every user gets a **personal organization** automatically on registration. Personal orgs:
- Cannot have members invited to them (single-user only)
- Cannot be deleted
- Show as "Personal" in the UI

**Team organizations** are created by users for collaboration. They support multiple members with role-based access.

### User Flows

#### Registration

1. User submits registration form (`/users/register`)
2. `Accounts.register_user/1` creates the user **and** a personal org + owner membership in a single `Ecto.Multi` transaction
3. After login, user is redirected to `/orgs/:slug/spreadsheet`

#### Login

1. User authenticates at `/users/log_in`
2. `UserAuth.log_in_user/3` looks up the user's default (personal) org
3. Redirects to `/orgs/:slug/spreadsheet`

#### Creating a Team Organization

1. Navigate to `/` (org picker)
2. Click "+ New Organization"
3. Enter a name — slug is auto-generated from the name
4. `Accounts.create_organization/2` creates the org + owner membership in a transaction
5. User is redirected to the new org's spreadsheet

#### Adding Members

1. Navigate to `/orgs/:slug/members` (admin+ required)
2. Enter a user's email and select a role
3. `Accounts.add_member/3` looks up the user by email and creates a membership
4. The new member can now access the org at `/orgs/:slug/...`

#### Transferring Ownership

1. Navigate to `/orgs/:slug/members` (owner only)
2. Click "Make Owner" on a member
3. `Accounts.transfer_ownership/2` atomically demotes the old owner to admin and promotes the new owner — wrapped in `Ecto.Multi`

#### Switching Organizations

- The nav bar shows an org switcher dropdown listing all organizations the user belongs to
- Click any org to navigate to its spreadsheet
- Click "All organizations" to return to the picker at `/`

### URL Structure

All org-scoped routes live under `/orgs/:org_slug/`:

| Route | Page |
|-------|------|
| `/` | Org picker (auto-redirects if only 1 org) |
| `/orgs/:slug/spreadsheet` | Skill framework editor |
| `/orgs/:slug/frameworks` | Framework list |
| `/orgs/:slug/frameworks/:id` | Framework detail |
| `/orgs/:slug/settings` | Org settings (rename, delete, org ID) |
| `/orgs/:slug/members` | Member management |
| `/orgs/:slug/observatory` | Agent observatory |

The `LoadOrganization` plug and `ensure_org_member` LiveView on_mount hook resolve the org from the URL slug and verify the user's membership before granting access.

### Key Modules

| Module | Purpose |
|--------|---------|
| `RhoFrameworks.Accounts.Organization` | Org schema (name, slug, personal flag) |
| `RhoFrameworks.Accounts.Membership` | User↔Org join with role |
| `RhoFrameworks.Accounts.Authorization` | Centralized `can?/2` permission checks |
| `RhoFrameworks.Accounts` | Context: org CRUD, membership management, ownership transfer |
| `RhoFrameworks.Frameworks` | All queries scoped by `organization_id` |
| `RhoWeb.Plugs.LoadOrganization` | Plug: resolve org from `:org_slug`, verify membership |
| `RhoWeb.Plugs.RequireRole` | Plug: gate routes by minimum role |
| `RhoWeb.UserAuth` | `on_mount(:ensure_org_member, ...)` for LiveViews |
| `RhoWeb.OrgPickerLive` | Org selector / create-team-org flow |
| `RhoWeb.OrgSettingsLive` | Rename, delete, display org ID |
| `RhoWeb.OrgMembersLive` | Member list, invite, role change, remove, ownership transfer |

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

## Plugins & Transformers

Rho splits the old "mount" concept into two behaviours:

- **`Rho.Plugin`** — the contribution role. A plugin contributes *affordances*: tools, prompt sections, and bindings. Callbacks: `tools/2`, `prompt_sections/2`, `bindings/2`, all taking `(plugin_opts, context)`.
- **`Rho.Transformer`** — the pipeline role. A transformer participates in one or more of six typed stages that fire at fixed points in the agent loop (`:prompt_out`, `:response_in`, `:tool_args_out`, `:tool_result_in`, `:post_step`, `:tape_write`). Single callback: `transform(stage, data, context)`.

A single module may implement both behaviours. Both register through `Rho.PluginRegistry`. A built-in plugin (`Rho.Builtin`) is registered at startup with the lowest priority — any user plugin registered after it takes precedence.

### Writing a Plugin

```elixir
defmodule MyPlugin do
  @behaviour Rho.Plugin
  @behaviour Rho.Transformer

  # --- Rho.Plugin: affordances ---

  @impl Rho.Plugin
  def tools(_opts, %{workspace: workspace}) do
    [jira_tool(workspace)]
  end

  @impl Rho.Plugin
  def prompt_sections(_opts, _context) do
    ["Always check Jira before starting work."]
  end

  # --- Rho.Transformer: in-flight mutation ---

  # Redact secrets from bash results before they reach the LLM.
  @impl Rho.Transformer
  def transform(:tool_result_in, %{tool_name: "bash", result: result} = data, _ctx) do
    case result do
      {:ok, output} when is_binary(output) ->
        if String.contains?(output, "SECRET") do
          {:cont, %{data | result: {:ok, "[redacted]"}}}
        else
          {:cont, data}
        end

      _ ->
        {:cont, data}
    end
  end

  def transform(_stage, data, _ctx), do: {:cont, data}

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

### Transformer example — denying a tool call

A transformer can refuse a tool call at the `:tool_args_out` stage. Unlike `:halt`, a `:deny` skips the call, records a synthetic denial entry on the tape, and lets the turn continue.

```elixir
defmodule BlockRmPolicy do
  @behaviour Rho.Transformer

  @impl true
  def transform(:tool_args_out, %{tool_name: "bash", args: %{"cmd" => cmd}} = data, _ctx) do
    if cmd =~ ~r/\brm\s+-rf\b/ do
      {:deny, "refusing to run `rm -rf` via bash"}
    else
      {:cont, data}
    end
  end

  def transform(_stage, data, _ctx), do: {:cont, data}
end

# Register globally
Rho.PluginRegistry.register(BlockRmPolicy)
```

### Registering plugins

#### Per-agent via `.rho.exs`

Scope plugins to a specific agent profile via the `plugins:` key in `.rho.exs`. Accepts atom shorthand, `{atom, opts}` tuple, or raw module. Plugins listed here activate only when that agent profile is running:

```elixir
%{
  default: [
    model: "openrouter:anthropic/claude-sonnet",
    plugins: [:bash, :fs_read, :fs_write, MyPlugin],
    max_steps: 50
  ],
  coder: [
    model: "openrouter:anthropic/claude-sonnet-4",
    plugins: [:bash, :fs_read, :fs_write, :fs_edit, MyLintPlugin],
    max_steps: 30
  ]
}
```

#### Global plugins (programmatic)

For plugins or transformers that should apply to all agents (e.g. a PII scrubber, a deny policy, an audit logger), register them at runtime:

```elixir
Rho.PluginRegistry.register(MyGlobalPlugin)
```

#### Explicit scope control

```elixir
# Global (default) — fires for all agents
Rho.PluginRegistry.register(MyPlugin)

# Scoped to a specific agent — only fires when agent_name matches
Rho.PluginRegistry.register(MyPlugin, scope: {:agent, :coder})

# With per-instance opts
Rho.PluginRegistry.register(MyPlugin, scope: {:agent, :coder}, opts: [some: :opt])
```

Later registrations have higher priority. Affordances from all matching plugins are merged — tools, prompt sections, and bindings are concatenated.

### Plugin scope semantics

| Context has `agent_name`? | Global plugin | Scoped `{:agent, :coder}` plugin |
|---|---|---|
| `agent_name: :coder` | fires | fires |
| `agent_name: :default` | fires | skipped |
| no `agent_name` (system-level) | fires | skipped |

### Plugin callbacks

`Rho.Plugin` defines three optional capability callbacks — a plugin implements only the ones it provides.

| Callback | Signature | Purpose |
|----------|-----------|---------|
| `tools/2` | `(plugin_opts, context)` | Return tool definitions (`[%{tool: ReqLLM.Tool.t(), execute: fn}]`) |
| `prompt_sections/2` | `(plugin_opts, context)` | Return strings or `%Rho.PromptSection{}` structs appended to the system prompt |
| `bindings/2` | `(plugin_opts, context)` | Return bindings for large resources exposed by reference |

### Transformer stages

`Rho.Transformer` defines a single callback `transform(stage, data, context)` that pattern-matches on the stage atom:

| Stage | Data | Allowed returns |
|-------|------|-----------------|
| `:prompt_out` | `%{messages: [...], system: ...}` | `{:cont, data}` / `{:halt, reason}` |
| `:response_in` | `%{text, tool_calls, usage}` | `{:cont, data}` / `{:halt, reason}` |
| `:tool_args_out` | `%{tool_name, args}` | `{:cont, data}` / `{:deny, reason}` / `{:halt, reason}` |
| `:tool_result_in` | `%{tool_name, result}` | `{:cont, data}` / `{:halt, reason}` |
| `:post_step` | `%{step, entries_appended}` | `{:cont, nil}` / `{:inject, [msg]}` / `{:halt, reason}` |
| `:tape_write` | `entry :: map` | `{:cont, entry}` (halt disallowed) |

Subagents bypass all transformer stages automatically.

### Context struct

All plugin/transformer callbacks receive a `%Rho.Context{}` struct:

```elixir
%Rho.Context{
  tape_name:     "tape_abc123",            # nil when no persistence
  tape_module:   Rho.Tape.Projection.JSONL,
  workspace:     "/my/project",
  agent_name:    :default,
  depth:         0,
  subagent:      false,
  agent_id:      "primary_cli:default",
  session_id:    "cli:default",
  prompt_format: :markdown,
  user_id:       nil
}
```

Implements the `Access` behaviour, so both `context.field` and `context[:field]` work.

### Introspection

```elixir
# Collect merged tools for a context
Rho.PluginRegistry.collect_tools(%{agent_name: :default, workspace: "."})

# Collect prompt sections (raw strings + %PromptSection{})
Rho.PluginRegistry.collect_prompt_sections(%{agent_name: :default, workspace: "."})
```

## Architecture

Rho separates concerns into three planes:

```
┌─────────────────────────────────────────────────────┐
│                   EDGE PLANE                        │
│  CLI, LiveViews, EventLog, HTTP API                 │
│  Bus-only subscribers to session events             │
└──────────────────────┬──────────────────────────────┘
                       │ events
┌──────────────────────▼──────────────────────────────┐
│               COORDINATION PLANE                    │
│  Signal Bus (jido_signal via Rho.Comms)             │
│  Agent Registry (role/capability discovery)         │
│  MultiAgent Plugin (delegation, messaging)          │
│  Session (agent group namespace)                    │
└──────────────────────┬──────────────────────────────┘
                       │ function calls
┌──────────────────────▼──────────────────────────────┐
│                EXECUTION PLANE                      │
│  Runner (outer loop, budget, compaction)            │
│  TurnStrategy (Direct, Structured, extensible)      │
│  Transformer pipeline (6 typed stages)              │
│  Tape (per-agent, append-only JSONL)                │
│  Plugins (tools, prompt sections, bindings)         │
└─────────────────────────────────────────────────────┘
```

### Supervision Tree

```
Rho.Supervisor (one_for_one)
├── Registry (Rho.AgentRegistry)        # agent_id → pid lookup
├── Registry (Rho.PythonRegistry)       # Python interpreter tracking
├── Task.Supervisor (Rho.TaskSupervisor)
├── DynamicSupervisor (Python.Supervisor)
├── Rho.PluginRegistry                  # plugin + transformer registration + ETS dispatch
├── Rho.Comms.SignalBus                 # jido_signal bus (:rho_bus)
├── [Tape children]                     # from tape_module.children/1
├── Rho.Agent.Supervisor (DynamicSupervisor)
│   ├── Rho.Agent.Worker (primary_cli:default)    # primary agent
│   ├── Rho.Agent.Worker (agent_42)               # delegated researcher
│   ├── Rho.Agent.Worker (agent_43)               # delegated coder
│   └── ...
├── Registry (Rho.EventLogRegistry)     # session_id → EventLog pid
├── DynamicSupervisor (EventLog.Supervisor)
│   ├── Rho.Agent.EventLog (session_1)  # JSONL writer for session
│   └── ...
├── Rho.CLI                             # CLI adapter
└── [Web children]                      # conditional: RateLimiter, Endpoint
```

One flat `Agent.Supervisor` for all agents. Session scoping is logical (via `session_id`), not structural.

### File Structure

```
apps/rho/lib/rho/
  application.ex       # OTP supervision tree
  config.ex            # Core configuration accessors
  run_spec.ex          # Explicit agent configuration struct
  session.ex           # Programmatic session API (single entry point)
  sandbox.ex           # AgentFS overlay filesystem lifecycle

  # --- Execution plane ---
  runner.ex            # Outer loop + inlined Runtime/TapeConfig structs
  recorder.ex          # Tape writes during the agent loop
  tool_executor.ex     # Shared tool dispatch with transformer pipeline
  turn_strategy.ex     # TurnStrategy behaviour
  turn_strategy/
    direct.ex          # Standard tool-use loop
    typed_structured.ex # Schema-aligned-parsing strategy
  plugin.ex            # Plugin behaviour (tools/sections/bindings)
  transformer.ex       # Transformer behaviour (6 typed stages)
  context.ex           # Rho.Context struct
  prompt_section.ex    # Prompt section struct
  plugin_instance.ex   # Configured plugin struct
  plugin_registry.ex   # Registration + ETS dispatch
  transformer_instance.ex
  transformer_registry.ex
  tape/
    entry.ex           # Immutable fact record
    store.ex           # GenServer + ETS + JSONL persistence
    service.ex         # High-level tape API + handoff
    view.ex            # Context window assembly
    compact.ex         # Context compaction
    fork.ex            # Fork/merge for parallel exploration
    projection.ex      # Tape projection behaviour
    projection/
      jsonl.ex         # Default JSONL projection

  # --- Coordination plane ---
  comms.ex             # Signal bus behaviour
  comms/
    signal_bus.ex      # jido_signal implementation
  agent/
    worker.ex          # Unified agent process (primary + delegated)
    registry.ex        # ETS-based agent discovery
    supervisor.ex      # DynamicSupervisor for all agents
    event_log.ex       # Per-session JSONL event log (bus subscriber)

apps/rho_stdlib/lib/rho/stdlib/
  tools/
    bash.ex            # Shell commands
    fs.ex              # FsRead + FsWrite + FsEdit (consolidated)
    web_fetch.ex       # HTTP fetch
    python.ex          # Python REPL
    sandbox.ex         # Sandbox tools
    tape_tools.ex      # Anchor + SearchHistory + RecallContext + ClearMemory
    finish.ex          # Delegated agent completion signal
    end_turn.ex        # Terminal end-of-turn signal
    path_utils.ex      # Workspace boundary enforcement
  plugins/
    multi_agent.ex     # delegate_task, await_task, send_message, list_agents
    step_budget.ex     # Step-budget warning (Plugin + Transformer :post_step)
    live_render.ex     # present_ui plugin (UI rendering)
    data_table.ex      # Data table plugin
    doc_ingest.ex      # Document ingestion
    py_agent.ex        # Python-agent bridge
    tape.ex            # Tape/journal introspection
    control.ex         # Control tools

apps/rho_cli/lib/rho/cli/
  config.ex            # .rho.exs loader
  repl.ex              # CLI REPL adapter
  command_parser.ex    # ,tool key=value syntax

apps/rho_cli/lib/mix/tasks/
  rho.chat.ex          # Interactive REPL
  rho.run.ex           # One-shot query
  rho.trace.ex         # Offline tape trace analyzer
```
