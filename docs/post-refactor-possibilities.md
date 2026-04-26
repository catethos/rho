# Post-Refactor Possibilities

**Date:** 2026-04-26 · **Branch:** `refactor` (post Phases 1–13 +
kernel-minimisation Phases 1–7)

After the refactor, several things became cheap that used to be
expensive. Captured here for reference, not as a commitment.

---

## 1. Cross-cutting policies as transformers

The Plugin/Transformer split with six stages (`:prompt_out`,
`:response_in`, `:tool_args_out`, `:tool_result_in`, `:post_step`,
`:tape_write`) plus the kernel-min Phase 2 work (subagent flag → policy
transformer) means transformers now apply uniformly across `Direct`,
`TypedStructured`, and subagents. Pre-refactor the `subagent` flag
short-circuited the pipeline — global policies silently skipped subagent
turns.

Each of the following is roughly a single 30–80 line transformer
module:

- **Rate limiter** — `:prompt_out` halts when caller exceeds a
  per-user/per-org token budget per minute.
- **Cost ceiling** — `:tape_write` accumulates token cost; halts the
  loop when the session crosses a cap.
- **Audit logger** — `:tape_write` mirrors entries to an external sink
  (Honeycomb, S3, Postgres).
- **PII redactor** — `:prompt_out` + `:response_in` masks emails,
  phones, SSNs before they reach the LLM and after they come back.
- **Tool-args validator** — `:tool_args_out` denies tool calls that
  violate org policy (e.g. `bash` outside an allowlist).

Highest immediate-value pick: **cost ceiling**, since multi-agent
fan-out can run away.

## 2. Cheaper / swappable models per agent

`TurnStrategy.TypedStructured` + BAML works against any model — not just
Anthropic and OpenAI. The codebase already runs `proficiency_writer` on
`openrouter:openai/gpt-oss-120b` (Cerebras / Groq / Fireworks fallbacks).

Possibilities:

- A/B different models per agent role in `.rho.exs` without touching
  code.
- Route long context to Sonnet, route fan-out subagents to Haiku or
  oss-120b for a 5-10× cost reduction.
- Custom `ReqLLM` providers (already done for Fireworks AI direct) for
  any OpenAI-compatible endpoint — Together, Replicate, vLLM,
  self-hosted.

## 3. Parallel domain apps

`apps/rho_frameworks/` is now a clean template:

- Domain `Scope` struct (3 fields) for boundary
- Named `DataTable` schemas per domain entity
- Domain tools as `Rho.Tool` modules in a single plugin
- BAML-backed `LLM.*` modules for structured calls

A `rho_research` (research assistant), `rho_coding_agent`, or
`rho_support` (customer support) could sit alongside without touching
the kernel. Each gets its own Ecto repo, its own DataTable schemas, its
own `.rho.exs` agents.

## 4. Publishable kernel

`apps/rho/` has zero Phoenix and Ecto deps. Plugin/Transformer
behaviours are stable contracts. `Rho.Events` is Phoenix.PubSub —
ubiquitous.

If we hold the line on dep purity, `rho` could be released as a
standalone hex package. `rho_baml` is already shaped as a library (no
Application, no `priv/`, no supervision tree).

What this would need:
- Move stdlib tools that depend on the umbrella into a `rho_stdlib`
  hex package that depends on `rho`.
- Decide whether `apps/rho/lib/req_llm/providers/fireworks_ai.ex` (the
  custom provider) belongs in core or stdlib.
- Versioning policy + a CHANGELOG.

## 5. New TurnStrategy implementations

`Rho.TurnStrategy` is a behaviour with a single `run/2` callback. Two
implementations exist (`Direct`, `TypedStructured`). New ones are
~150 lines each:

- **`ReAct`** — observe / think / act trace, useful for tool-heavy
  tasks where the model benefits from explicit observation framing.
- **`ToolOnly`** — no text response classification; the loop continues
  until a tool call returns `{:final, _}`. Cheaper for batch jobs.
- **`Critic`** — every response is run through a second model that
  decides whether to accept, retry with feedback, or escalate. Useful
  for high-stakes domains.
- **`MCTS-lite`** — branch on multiple candidate tool calls, score, pick
  best. Heavier; useful for planning agents.

## 6. Replay & observability UI

Every session writes a `Rho.Tape` (append-only JSONL) and broadcasts to
`Rho.Events`. A "session replay" LiveView is mostly UI work:

- Scrub bar over a tape timeline
- Step-by-step playback with token stream re-rendering
- Diff two sessions side by side
- Filter events by transformer / plugin / tool

## 7. Inter-agent protocols beyond MultiAgent

The kernel-min Phase 3 (`handle_signal/3` plugin callback) means
multi-agent is a plugin concern. Other inter-agent protocols become
plugins:

- **A2A (Agent-to-Agent) bridge** — wire Rho agents to external A2A
  endpoints
- **MCP server** — expose a Rho agent as an MCP-callable tool
- **Swarm coordinator** — broadcast/quorum primitives over the same bus

---

## What would NOT be made cheaper by these changes

- LiveView UX work (still requires hand-written components per surface).
- Tool authoring for new domains (still requires understanding of the
  task; the framework only removes wiring overhead).
- Long-context strategies — context compaction lives in `Rho.Runner`
  but the algorithms (summarization, anchor-based recall) are still
  application-level decisions.

---

## Picking next

If you want one concrete next move, **cost ceiling transformer +
session cost dashboard** is the highest-leverage pair: protects against
runaway fan-out, surfaces actual model spend, and validates the
transformer-as-policy pattern before bigger uses (rate limiter, audit
logger).
