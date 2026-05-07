# Backlog — designed but not yet built

Plans that have been thought through and written down, but aren't on
the active roadmap. Each entry links to its plan doc and notes the
trigger that should bring it back.

When you're staring at one of the listed problems and thinking "we
should solve this" — check here first. The work might already be
half-done in design.

---

## Self-promoting deferred tools

**Plan**: [agent-deferred-tool-promotion.md](agent-deferred-tool-promotion.md)

**One-line summary**: Let the agent itself promote a deferred tool
into its action union via an `enable_tool` meta-action, instead of
needing a human to edit `.rho.exs`.

**Bring this back when**:

- An agent's plugin set grows past ~20 tools and prompt-cache hit
  rate starts dropping turn-over-turn.
- Token cost per turn is dominated by tool-schema definitions (run
  the math: schema bytes / total prompt bytes).
- We hit a third "agent guessed at a deferred tool name and BAML
  coercion failed" incident. (We've already had one — the
  `query_table` regression.)

**Foundation it enables**: dynamic skill loading (below) cannot be
built without this.

---

## Dynamic skill loading — one agent, many shapes

**Plan**: [dynamic-skill-loading.md](dynamic-skill-loading.md)

**One-line summary**: Collapse `:spreadsheet` / `:coder` /
`:researcher` / `:data_extractor` into a single default agent that
shape-shifts mid-conversation by calling `load_skill(name: ...)`.
Multi-agent stays only for genuine policy isolation (hiring
committee).

**Bring this back when**:

- Adding a new specialist agent feels like more typing than it
  should. (`.rho.exs` has 8+ specialists; new one needs full
  plugin/skill/prompt declaration even though it's mostly
  composition of existing pieces.)
- A user complains about "context loss" when delegating between
  agents — they want the same thread to do multiple kinds of work.
- We have at least a week of production data with the deferred-tool
  plan above so the load-on-demand mechanism is exercised.

**Depends on**: deferred-tool promotion (above) must land first.

**First experiment**: convert `:data_extractor` (smallest, most
contained specialist) to a skill. If `default + load_skill("data-extraction")`
matches its current behavior, scale to `:spreadsheet`.

---

## Skill description optimization

**Plan**: [skill-description-optimization.md](skill-description-optimization.md)

**One-line summary**: Rewrite the 5 existing `SKILL.md` descriptions
following the agentskills.io optimization guide, and build
`mix rho.eval_skill` that exploits Rho's explicit `skill()` tool
call for cheap deterministic trigger detection.

**Bring this back when**:

- A user reports "the agent didn't reach for the right skill" or
  the wrong skill activates on an obvious-in-hindsight prompt.
- The skill catalog grows past ~6 entries and the existing
  "Workflow for ..." descriptions start colliding (`combine-libraries`
  vs `consolidate-framework` is the most likely first conflict).
- We're about to start phase 0 of `dynamic-skill-loading.md` —
  that plan calls out skill description quality as an explicit
  confirmation item before committing.

**Foundation it enables**: dynamic skill loading depends on the
agent picking the right skill from descriptions alone; without
this, that plan amplifies the existing miss rate rather than
fixing it.

---

## Adding new entries

When you write a plan that doesn't get built immediately, append it
here with three things:

1. The one-line summary (so future-you can scan)
2. The trigger conditions (so you know when to revisit)
3. Any dependencies on other backlog items (so you know the order)

Don't put implementation details here — those live in the plan doc.
This file is the index, not the substance.
