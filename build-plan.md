# Rho — Incremental Build Plan (Prototype-First)

## Context

Rho is the Elixir port of Bub (Python). The full architecture is in `elixir-port-architecture.md`. This plan builds **vertically** — each step produces a working thing you can run and interact with.

The rule: at every step you should be able to type something and see something happen.

Steps 1-5 are **done** (marked with checkmarks below).

---

## Step 1-5: Foundation (DONE)

- [x] Mix project with deps (`req_llm ~> 1.6`, `jason ~> 1.4`, `dotenvy ~> 1.1`)
- [x] `Rho.Config` — reads `RHO_MODEL`, `RHO_API_KEY`, `RHO_MAX_STEPS` from env
- [x] `.env` loading via Dotenvy in `application.ex`
- [x] `Rho.Tools.Bash` — tool definition + execution
- [x] `Rho.AgentLoop` — recursive tool-calling loop using ReqLLM
- [x] `mix rho.run "message"` — one-shot LLM query
- [x] `mix rho.chat` — interactive REPL with bash tool

**Try it**: Create a `.env` with your API key, then `mix rho.chat`

---

## Step 6: Add file tools (fs_read, fs_write, fs_edit)

**Goal**: Ask the LLM to read, write, or edit files and it does.

1. Create `lib/rho/tools/fs_read.ex`, `fs_write.ex`, `fs_edit.ex`
2. Add workspace path resolution + boundary checking (`Rho.Tools.PathUtils`)
3. Register all tools in a simple list, pass to agent loop

**Feedback**: Ask "read mix.exs and tell me what deps I have" — it actually reads and answers.

---

## Step 7: Add the Tape — persistent conversation memory

**Goal**: Close `mix rho.chat`, reopen it, and the conversation continues.

1. Create `lib/rho/tape/entry.ex` — the Entry struct with `normalize_keys/1`
2. Create `lib/rho/tape/store.ex` — GenServer with ETS + JSONL persistence
3. Create `lib/rho/tape/service.ex` — high-level API (`session_tape/2`, `append/4`, `messages_for_llm/1`)
4. Start `Rho.Tape.Store` in the supervision tree
5. Modify the REPL to use tape instead of in-memory message list
6. Derive tape name from workspace path

**Feedback**: Have a conversation, quit, restart, and the LLM remembers everything.

---

## Step 8: Command mode — `,bash ls` direct tool execution

**Goal**: Type `,bash cmd=ls` and get instant tool output without going through the LLM.

1. Create `lib/rho/command_parser.ex` — parse `,tool key=value` syntax
2. Create `lib/rho/tools/registry.ex` — maps names to tool modules
3. In the REPL, detect `,` prefix and route to direct execution instead of LLM

**Feedback**: `,bash cmd="echo hello"` prints `hello` instantly.

---

## Step 9: Wrap in OTP — GenServer agent + Channel architecture

**Goal**: Replace the mix task REPL with proper OTP processes. Still works the same from the user's perspective.

1. Create `lib/rho/channel/message.ex` — the Message struct
2. Create `lib/rho/channel/cli.ex` — GenServer wrapping the REPL loop
3. Create `lib/rho/session_router.ex` — routes messages to agent processes
4. Move agent loop into a proper process (can be a simple GenServer or Task for now — defer Jido integration)
5. Create `lib/rho/channel/manager.ex` — routes inbound/outbound messages
6. Wire into supervision tree

**Feedback**: `mix rho.chat` still works, but now it's proper OTP. You can inspect processes in Observer (`:observer.start()`).

---

## Step 10: Add Jido (optional — only if APIs are stable)

**Goal**: Replace the hand-rolled agent GenServer with Jido's AgentServer.

1. Add `jido` and `jido_ai` deps
2. Create `lib/rho/rho_agent.ex` using `use Jido.AI.Agent`
3. Convert tool modules to `use Jido.Action` format
4. Create `lib/rho/jido.ex` — the Jido instance
5. Update `SessionRouter` to use `Rho.Jido.start_agent` / `Rho.Jido.whereis`

**Feedback**: Everything works the same, but you get Jido's supervision, schema validation, and crash isolation for free.

**Alternative**: If Jido's API is too unstable, keep the hand-rolled GenServer from Step 9. The architecture doc itself notes this risk.

---

## Step 11: Hook system — make it pluggable

**Goal**: Behaviour-based hooks so plugins can customize behavior.

1. Create `lib/rho/hook_spec.ex` — the behaviour with all callbacks
2. Create `lib/rho/hook_runtime.ex` — GenServer for registration + ETS for dispatch
3. Create `lib/rho/builtin.ex` — default implementations (system_prompt, etc.)
4. Wire hooks into the agent loop: `system_prompt`, `load_state`, `save_state`, `render_outbound`

**Feedback**: Write a tiny plugin module that changes the system prompt. See the behavior change in chat.

---

## Step 12: Skills system

**Goal**: Drop a `SKILL.md` file in `.agents/skills/my-skill/` and the LLM knows about it.

1. Create `lib/rho/skill.ex` — discovery, YAML parsing, prompt rendering
2. Integrate into system prompt building

**Feedback**: Create a skill file, start chat, and see it mentioned in the LLM's awareness.

---

## Step 13: Telegram channel

**Goal**: Message your bot on Telegram and get responses.

1. Create `lib/rho/channel/telegram.ex` — polling-based GenServer
2. Create `lib/rho/channel/debounce.ex` — per-session message batching
3. Add Telegram config to `Rho.Config`
4. Register via hook system or direct in supervisor

**Feedback**: Send a Telegram message to your bot, get an LLM response back.

---

## Step 14: Polyglot plugins (optional, later)

**Goal**: Python/JS plugins can implement hooks.

1. Add `pythonx` dep, create `Rho.Plugin.PythonRunner`
2. Add `mquickjs_ex` dep, create `Rho.Plugin.JsRunner` + `JsContext`
3. Plugin manifest parser, bridge module generator

**Feedback**: Write a Python plugin that logs every message, see it work.

---

## File structure after Step 9 (the "complete but simple" milestone)

```
lib/
  rho/
    application.ex
    config.ex
    agent_loop.ex
    command_parser.ex
    session_router.ex
    tools/
      registry.ex
      path_utils.ex
      bash.ex
      fs_read.ex
      fs_write.ex
      fs_edit.ex
    tape/
      entry.ex
      store.ex
      service.ex
    channel/
      message.ex
      manager.ex
      cli.ex
  mix/
    tasks/
      rho.run.ex
      rho.chat.ex
mix.exs
.env
```

---

## Verification at each step

Every step has a "Feedback" section. The rule: **if you can't interact with it, it's not done**. No building infrastructure without a way to poke it.

- Steps 1-5: `mix rho.run` / `mix rho.chat` (DONE)
- Steps 6-8: `mix rho.chat` with progressively more features
- Steps 9+: `mix rho.chat` backed by OTP, then add channels

---

## Key deps (minimal set to start)

```elixir
# Steps 1-5 (current)
{:req_llm, "~> 1.6"},
{:jason, "~> 1.4"},
{:dotenvy, "~> 1.1"}

# Step 7 (tape)
# No new deps — just ETS + File

# Step 10 (Jido — optional)
{:jido, "~> 2.0"},
{:jido_ai, "~> 0.5"}

# Step 12 (skills)
{:yaml_elixir, "~> 2.0"}

# Step 14 (polyglot — optional)
{:pythonx, "~> 0.3"},
{:mquickjs_ex, "~> 0.1"}
```

---

## ReqLLM API Quick Reference

| Function | Usage |
|----------|-------|
| `ReqLLM.generate_text(model, messages, opts)` | Blocking text generation |
| `ReqLLM.stream_text(model, messages, opts)` | Streaming text generation |
| `ReqLLM.Context.system(text)` | Build system message |
| `ReqLLM.Context.user(text)` | Build user message |
| `ReqLLM.Context.assistant(text)` | Build assistant message |
| `ReqLLM.Context.assistant(text, tool_calls: calls)` | Assistant message with tool calls |
| `ReqLLM.Context.tool_result(id, result)` | Build tool result message |
| `ReqLLM.tool(name:, description:, parameter_schema:, callback:)` | Define a tool |
| `ReqLLM.Response.text(response)` | Extract text from response |
| `ReqLLM.Response.tool_calls(response)` | Extract tool calls from response |
| `ReqLLM.ToolCall.name(tc)` | Get tool name from call |
| `ReqLLM.ToolCall.args_map(tc)` | Get tool args as map |
