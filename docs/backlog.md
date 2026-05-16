# Backlog — designed but not yet built

Plans that have been thought through and written down, but aren't on
the active roadmap. Each entry links to its plan doc and notes the
trigger that should bring it back.

When you're staring at one of the listed problems and thinking "we
should solve this" — check here first. The work might already be
half-done in design.

---

## Self-promoting deferred tools

**Plan**: [backlog-plans/agent-deferred-tool-promotion.md](backlog-plans/agent-deferred-tool-promotion.md)

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

**Plan**: [backlog-plans/dynamic-skill-loading.md](backlog-plans/dynamic-skill-loading.md)

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

**Plan**: [backlog-plans/skill-description-optimization.md](backlog-plans/skill-description-optimization.md)

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

## AI readiness assessment agent

**Plan**: [backlog-plans/ai-readiness-assessment-plan.md](backlog-plans/ai-readiness-assessment-plan.md)

**One-line summary**: Add an assessor agent and plugin that conducts a
conversational AI-readiness assessment, records observations, and produces a
scored 3x4 readiness report.

**Bring this back when**:

- AI-readiness assessment becomes a product surface rather than a demo idea.
- We want a bounded vertical slice that exercises custom tools, session-scoped
  assessment state, and report generation.
- There is a clear owner for the scoring rubric and report UX.

---

## Research-as-tool Option A

**Plan**: [backlog-plans/research-as-tool-option-a.md](backlog-plans/research-as-tool-option-a.md)

**One-line summary**: Replace `ResearchDomain`'s worker-agent spawn with a
bounded Exa-backed task/tool path that writes directly to the `research_notes`
named table.

**Bring this back when**:

- Research-domain latency, cost, or failure modes from worker agents become a
  recurring issue.
- The wizard and chat agent both need the same deterministic research primitive.
- We want `research_domain` to be callable as a normal workflow tool.

---

## Static asset migration

**Plan**: [future-improvement-velocity-plan.md](future-improvement-velocity-plan.md)

**One-line summary**: Move grouped inline CSS from Elixir modules toward normal
Phoenix static assets after the current split has been visually verified.

**Bring this back when**:

- CSS review or compile churn becomes a bottleneck again.
- The grouped `RhoWeb.InlineCSS.*` modules are stable enough to move
  mechanically.
- We have a reliable browser/visual smoke path for chat, data table, library,
  role, settings, and flow views.

---

## Lite-loop tool execution convergence

**Plan**: [future-improvement-velocity-plan.md](future-improvement-velocity-plan.md)

**One-line summary**: Decide whether `Rho.Runner.LiteLoop` should converge with
`Rho.ToolExecutor` or remain intentionally direct, then document and test the
choice.

**Bring this back when**:

- A tool-execution bug appears in one runner mode but not the other.
- New transformer/tool policy work needs identical behavior across normal and
  lite runs.
- The direct lite path starts gaining duplicated normalization or timeout logic.

---

## Framework library row and research-note extraction

**Plan**: [future-improvement-velocity-plan.md](future-improvement-velocity-plan.md)

**One-line summary**: Continue the `RhoFrameworks.Library` facade split by
extracting row conversion/write normalization and research-note archive helpers
behind stable public APIs.

**Bring this back when**:

- `RhoFrameworks.Library` or `RhoFrameworks.Workbench` changes need row-shape or
  research-note persistence edits.
- We touch save/import/dedup workflows and want clearer ownership.
- Tests around named-table-to-library persistence become hard to localize.

---

## Adding new entries

When you write a plan that doesn't get built immediately, append it
here with three things:

1. The one-line summary (so future-you can scan)
2. The trigger conditions (so you know when to revisit)
3. Any dependencies on other backlog items (so you know the order)

Don't put implementation details here — those live in the plan doc.
This file is the index, not the substance.
