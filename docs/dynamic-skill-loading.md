# Dynamic skill loading — one agent, many shapes

> Status: design proposal. Builds on `agent-deferred-tool-promotion.md`.
> Treats deferred tools as the foundation; this doc is the layer above.

## The vision

Today an agent's shape is fixed at boot. `.rho.exs` declares
`:spreadsheet`, `:coder`, `:researcher`, etc., each with its own
system prompt, plugin set, and skill list. To do a different kind of
work the user either picks a different agent or the current one
delegates via `multi_agent`.

The proposal: a single agent boots with a thin essential layer, then
shape-shifts mid-conversation by loading skills on demand. The
agent's identity at any moment is the union of:

- **Essentials** (always-on): respond, think, finish/end_turn,
  enable_tool, load_skill.
- **Meta-skill** (always-on or auto-loaded first turn):
  capability-awareness — what skills exist, how to scope work, how
  to recover when a skill doesn't fit.
- **Loaded skills** (zero or more): each adds a tool bundle, a
  procedure (system-prompt addendum), and possibly a domain
  vocabulary.

`load_skill("create-framework")` makes the agent a framework editor
for the rest of the conversation. `load_skill("code-writer")` later
in the same conversation also makes it a coder, on top. The agent
can do both, with both contexts intact.

## Why this is genuinely different

The current `multi_agent` delegation pattern can simulate this — but
fundamentally it is **fan-out, then merge**. Each delegated agent is
a fresh conversation, with its own context, its own LLM call, its
own decisions. The parent gets a summary back.

Dynamic loading is **shape-shifting in place**. Same conversation,
same memory, same LLM session. The user gets a continuous assistant;
the agent gets accumulated context across capability boundaries.

What this gives, that delegation can't:

- **No re-onboarding.** A delegated researcher doesn't know what the
  framework editor learned three turns ago. A shape-shifted agent
  remembers everything.
- **One thread, one tape.** Easier to review, easier to replay.
- **Token compounding.** Skills loaded earlier in a long session
  benefit from prompt-cache hits as long as nothing displaces them.
- **No coordination overhead.** No `delegate_task` /
  `await_task` round-trips for capability-only work.

What delegation still does better:

- **Policy isolation.** The hiring committee — technical evaluator,
  culture evaluator, comp evaluator — needs *different policies*,
  not different capabilities. Each evaluator should disagree with
  the others; that's the whole point. Loading three policies into
  one agent collapses the disagreement.
- **Concurrency.** Three evaluators running in parallel is a
  parallelism story, not a capability story.
- **Adversarial roles.** Code-writer and code-reviewer disagreeing
  is more useful when they're separate agents.

So: **delegation stays for policy / persona / parallelism;
shape-shifting takes over for capability extension.** Most current
delegation is capability-only ("I need to extract data from this
PDF; let me delegate to data_extractor") — that case becomes
`load_skill("data-extraction")`.

## What a skill becomes

Today a skill is a Markdown file in `.agents/skills/<name>/SKILL.md`,
loaded by the `:skills` plugin into the system prompt at agent
boot. It's static text.

In this model, a skill is a structured bundle:

```elixir
%Skill{
  name: "create-framework",
  description: "Multi-step workflow to create a skill framework from scratch",
  instructions: """
    ... markdown body, what's currently in SKILL.md ...
  """,
  required_tools: [:add_rows, :update_cells, :edit_row, :generate_proficiency, ...],
  required_plugins: [:data_table],
  vocabulary: ["proficiency level", "skill cluster", "framework"]
}
```

`load_skill(name)` does three things:

1. **Promotes the listed tools** (same mechanism as `enable_tool`,
   batched).
2. **Appends the skill's instructions** to the system prompt as a
   new section, marked with the skill's name so it can be tracked.
3. **Marks the skill loaded** in the agent's context.

Subsequent turns:

- The skill's prompt section persists.
- Its tools are available.
- The agent can call `load_skill` again for another skill on top.

## Three layers of agent capability

```
┌─────────────────────────────────────────────┐
│  Loaded skills (0..N)                        │  per-conversation, dynamic
│   - create-framework                         │
│   - code-writer                              │
├─────────────────────────────────────────────┤
│  Meta-skill: capability-awareness            │  always-on (or first-turn auto-load)
│   - what skills exist                        │
│   - how to scope work to a skill             │
│   - how to recover when no skill fits        │
├─────────────────────────────────────────────┤
│  Essentials                                  │  always-on, framework-level
│   - respond, think, finish/end_turn          │
│   - enable_tool, load_skill                  │
│   - (typed_structured action union scaffolding) │
└─────────────────────────────────────────────┘
```

The essentials layer is small enough to fit in any prompt cache
window; everything above it is dynamic and explicitly opted into.

## What `.rho.exs` looks like

Today:

```elixir
%{
  default: [...],
  spreadsheet: [model: ..., plugins: [...], skills: [...]],
  coder: [...],
  researcher: [...],
  data_extractor: [...],
  ...
}
```

After:

```elixir
%{
  default: [
    model: "...",
    system_prompt: "You are an assistant. Load skills as needed.",
    plugins: [
      :load_skill,        # the new always-on plugin
      :essentials,        # respond/think/finish (already implicit)
      {:all_domain_plugins, deferred: :all}
    ],
    skills: ["capability-awareness"],
    ...
  ],

  # Specialist agents survive only for policy isolation:
  technical_evaluator: [...],
  culture_evaluator: [...],
  compensation_evaluator: [...]
}
```

`:spreadsheet`, `:coder`, `:researcher`, `:data_extractor`
disappear. Their work is now `default + load_skill(...)`.

## Skill discovery

The agent learns what's available the same way it learns about
deferred tools — via a prompt section emitted by the
capability-awareness layer:

```
## Available skills

  - create-framework — multi-step workflow to create a skill framework
  - import-framework — parse a PDF/Excel and turn it into a framework
  - data-extraction — extract structured data from documents
  - code-writer — write Elixir code, idiomatic, with tests
  - web-research — find and cite sources from the web
  - hiring — evaluate candidates against role profiles

  (loaded: create-framework)

Call load_skill(name: "...", reason: "...") to load one. Skills
remain loaded for the rest of the conversation. Each adds ~200–800
prompt tokens per turn.
```

Same pattern as the deferred-tool listing: name + first-line
description, with a status marker. The agent picks deliberately,
not by guessing.

## Token economics

Approximate, for a hypothetical 8-skill 30-tool repo:

| Mode             | Per-turn tokens | Notes                    |
|------------------|-----------------|--------------------------|
| Pre-shaped agent | ~2500           | All tools + all skills loaded |
| Shape-shift cold | ~600            | Just essentials + meta   |
| Shape-shift +1 skill | ~1200       | Essentials + one skill   |
| Shape-shift +3 skills | ~2400      | About even with pre-shaped |

The win is in **the long tail of conversations that only need 1–2
skills.** A user asking "what's the weather" hits the cold-start
cost only and never grows. A user creating a framework + asking
follow-up questions stays at +1. Only the rare power-user session
that touches everything pays the full cost — and they pay it
incrementally rather than from turn 1.

Combined with prompt caching: each `load_skill` invalidates the
cache after that point, but the essentials layer stays warm
forever.

## Where this gets hard

Honest list of things that aren't free:

### Skill conflicts

Two loaded skills declare overlapping or contradictory rules ("be
terse" vs "be thorough"). The agent's prompt now contains both.
LLM behavior in conflicts is unpredictable. Mitigations:

- Strong skill description discipline — skills should declare a
  domain, not a personality.
- A `last-loaded-wins` rule for explicit conflicts, with a
  conflict warning in the prompt.
- Don't try to detect conflicts statically; treat them as a runtime
  cost the user occasionally pays.

### Skill bloat over time

A long conversation accumulates skills. Each adds tokens. Without
auto-unload, conversations get heavier as they progress.

- v1: skip auto-unload. Most conversations don't load >3 skills.
- v2: unload-on-idle ("skill X hasn't been used in 10 turns"). Or
  explicit `unload_skill`.
- The user can always start a new conversation if they want to
  reset.

### Replay determinism

The shape of the agent at any point in a tape replay must be
exactly what it was at recording time. Same answer as the
deferred-tool plan: `load_skill` is a normal tool event recorded on
the tape. Replay reproduces the loaded set in order. ✓

### Multi-agent boundaries

If a shape-shifted agent delegates to a child, what does the child
inherit? Probably nothing — child agents start clean. This matches
the deferred-tool plan's answer and the principle of "delegation =
isolation". The parent can pass relevant context as a message.

### "What if the agent loads the wrong skill?"

It loads another one. Skills are additive in v1. If skill A doesn't
help, the agent calls load_skill(B) and proceeds. The cost is some
wasted prompt tokens for A's instructions, paid for the rest of the
conversation. Mitigation: capability-awareness skill teaches "scope
your skill choice carefully; you can't easily undo a load."

### What about plugins that aren't skills?

`:multi_agent`, `:journal`, `:tape`, `:control` — these are
infrastructure, not domain capabilities. They stay as static
plugins on the default agent. The deferred mechanism applies to
their tools individually if any are token-heavy.

## Migration path

Phased; each ships independently and ships value.

### Phase 0 — Land deferred-tool promotion (existing plan)

Foundation. Without this, dynamic loading has nothing to build on.

### Phase 1 — Skill struct + lazy loader

- Define `%Rho.Stdlib.Skill{}` with `required_tools`, `description`,
  `instructions`.
- Migrate existing skills (currently bare Markdown) to declare
  these in their SKILL.md frontmatter or a sibling `skill.exs`.
- `load_skill(name)` runtime action: validates name, batch-enables
  required tools, appends instructions to a new prompt section,
  records to context.
- Skill listing prompt section.

### Phase 2 — Migrate one specialist

Pick `:data_extractor` (smallest, most contained). Convert its
plugin/skill bundle into a `data-extraction` skill. Confirm that
`default` agent + `load_skill("data-extraction")` produces
equivalent behavior. Compare tape outputs.

### Phase 3 — Migrate `:spreadsheet`

Bigger lift; framework creation has multi-step flows. Confirm the
existing `create-framework` skill works when its tools are loaded
via `load_skill` rather than always-on plugin config.

### Phase 4 — Default-agent collapse

Remove `:coder`, `:researcher`, `:spreadsheet` definitions from
`.rho.exs`. The `default` agent does everything. Keep the
hiring-committee evaluators as they are — they're the policy-isolation
case.

### Phase 5 — Refine

- Track which loaded skills are actually being exercised (via tape
  analysis).
- If specific skill combinations show up frequently, consider a
  `load_bundle` shorthand or "starter skills" for the default.
- Decide whether auto-unload is worth building based on observed
  conversation lengths.

## What to confirm before committing

This is a real direction, not a refactor. Before we start migrating:

1. **A working deferred-tool promotion mechanism** — phase 0 of the
   companion plan must land first and be in production for at least
   a few days, so the load-on-demand muscle is exercised at the
   tool layer before scaling to skills.
2. **Token telemetry** — instrument prompt sizes per turn, broken
   down by static / dynamic / cache-hit. Without this we're
   guessing at the win.
3. **Skill description quality** — the agent's skill choice is only
   as good as the descriptions it reads. Audit the existing skills'
   first lines; rewrite where they're vague.
4. **One specialist first** — phase 2's
   `:data_extractor` conversion is the experiment. If it doesn't
   produce equivalent behavior, we re-think before scaling.

## What this is not

- **Not a runtime DSL.** Skills are still authored statically;
  they're just loaded dynamically. No code generation, no LLM
  writing skills.
- **Not infinite shape-shifting.** The skill catalog is fixed at
  agent boot. The agent picks from a known list.
- **Not a replacement for delegation.** Hiring committee, parallel
  evaluators, adversarial review — these stay multi-agent.
- **Not strictly necessary.** Static specialists work fine for
  small repos and simple use cases. This pays off when the catalog
  grows past ~5 specialists with overlapping tool needs.

## Why I think it's worth doing

The current `.rho.exs` is already showing strain — `:spreadsheet`'s
plugin list mixes domain tools with infrastructure
(`:doc_ingest`, `:multi_agent`), and adding a new specialist means
another full agent definition rather than another skill module.
The system is a typology when it should be a composition.

The deferred-tool plan already sets this up: once tools are
load-on-demand, skills as bundles-of-load-on-demand-tools is the
natural next abstraction. Doing both gives us a model that scales
to "the assistant can do anything in the catalog, paid in tokens
only when actually used" without redesigning the agent system later.

The single hard question is **what to do about persona / policy**
— and the answer ("delegation stays for that") is honest and
keeps the multi-agent layer as the thing it should be: a
coordination primitive, not a way to fake capability switching.
