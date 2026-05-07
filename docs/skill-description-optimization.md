# Skill description optimization

> Status: design proposal. Prerequisite for `dynamic-skill-loading.md`
> ("Skill description quality" is an explicit confirmation item there).
> Standalone value even if dynamic loading is never built.

## The vision

Today the 5 skills in `.agents/skills/` are activated when the LLM
decides to call `skill(name: ...)`. That decision is made entirely
from the `description` field in each `SKILL.md` frontmatter — the
body is hidden until activation. So the description is a **binary
classifier the LLM runs against every user prompt**.

Two failure modes:

- **False negative** (description too narrow) — the user has the
  problem the skill solves, but their phrasing didn't match. The
  agent muddles through with general knowledge instead.
- **False positive** (description too broad) — the description
  triggers on near-misses that need a different skill (or no skill
  at all). The wrong workflow gets injected.

This plan: rewrite all 5 descriptions following the agentskills.io
optimization guide, then build a deterministic eval harness that
exploits Rho's explicit `skill()` tool call for cheap trigger
detection.

## Why this is genuinely worth doing

The agentskills.io best-practices doc and optimization guide both
make the same point: a skill that doesn't activate is dead weight.
Every byte of body text is worthless if the description fails.
And every false-positive activation pollutes context for the rest
of the conversation.

Three properties of Rho's runtime make the eval loop specifically
*cheaper* here than for most clients:

1. **Activation is an explicit tool call.** Trigger detection =
   inspect tape for `skill(name: "x")`. No log scraping, no
   classifier, no probabilistic match. Boolean.
2. **`Rho.Session` is the single entry point** — we can run the eval
   in-process from a mix task. No subprocess overhead, no Claude Code
   harness in the loop.
3. **Tapes are already the source of truth.** A query → tape mapping
   gives us replay artifacts for free; we can store every eval run
   for later regression checks.

So the eval cost is roughly: 1 LLM call per query × 3 runs × ~20
queries × N skills = ~1200 LLM calls for the full audit. Cheap.

## Audit of the current 5 descriptions

All five start with **"Workflow for..."** — implementation framing,
not the imperative form the guide recommends. Severity rating below
is my read of how badly each one classifies; the eval will replace
this with numbers.

| Skill | Current description | Severity | Issue |
|---|---|---|---|
| `combine-libraries` | "Workflow for merging multiple skill libraries into one (requires explicit user approval before committing)" | Medium | Internal jargon ("skill libraries"); parenthetical is a precondition, not a trigger. |
| `consolidate-framework` | "Workflow for deduplicating and consolidating skills within a library" | **High** | "Consolidating" is vague — could mean cleanup, dedupe, merge, reorganize. Likely both false positives and false negatives. |
| `create-framework` | "Workflow for creating a new skill framework from scratch (analyze → create → approve → generate proficiency levels → save)" | Medium | Parenthetical wastes tokens on implementation steps the body already covers. No trigger phrasings. |
| `import-framework` | "Workflow for importing skill frameworks from standard templates (SFIA) or documents (PDF, Excel, Word)" | Low | Best of the five — actually lists concrete trigger keywords. Could still benefit from indirect-phrasing hooks. |
| `role-profiles` | "Workflow for creating and cloning role profiles (requires an existing library)" | High | "Role profile" is internal jargon. User more likely says "build a job spec" or "competency expectations for a senior X." |

## Description rewrite principles

Direct from the optimization guide, in the order they bind for our
skills:

1. **Imperative + user-intent.** "Use this skill when the user wants
   to X" beats "Workflow for X-ing."
2. **Push on indirect phrasings.** Explicitly list non-jargon
   wordings: "even if the user says 'job spec' instead of 'role
   profile.'"
3. **Boundary against adjacent skills.** Where two skills share
   keywords (e.g., `combine-libraries` vs `consolidate-framework`),
   each description should explicitly say what it is *not* for and
   point at the right skill.
4. **Stay under 1024 chars.** Hard spec limit; descriptions tend
   to grow during optimization.
5. **No body content leakage.** Anti-patterns, step counts, tool
   names belong in the body — they cost tokens at startup
   (description loads for *every* skill at boot) but only buy value
   after activation.

## Proposed rewrites (v1, pre-eval)

These are starting points to test, not final. Numbers are character
counts.

### `create-framework` (96 → ~480)

```yaml
description: >
  Use this skill when the user wants to build a new skill framework,
  competency model, skills matrix, or evaluation rubric from scratch —
  including generating skill categories, defining proficiency levels,
  or starting a fresh library. Trigger even if the user phrases it as
  "build a competency model for X", "make a skills rubric", or "I need
  to define what skills a Y role needs," without explicitly using the
  word "framework."
```

### `consolidate-framework` (76 → ~520)

```yaml
description: >
  Use this skill when the user wants to clean up, deduplicate, or
  consolidate redundant skills within an existing library — finding
  near-duplicate skill names, merging overlapping competencies, or
  reducing skill count without changing scope. Trigger on phrasings
  like "remove duplicates", "this library has too many overlapping
  skills", "merge similar entries", or "tighten up this framework."
  Do NOT use for combining two separate libraries (use combine-libraries
  for that).
```

### `combine-libraries` (TBD)

Needs a boundary against `consolidate-framework`. Draft:

```yaml
description: >
  Use this skill when the user wants to merge two or more separate
  skill libraries into one — combining a backend library with a
  frontend library, or unifying engineering and product competency
  lists. Trigger on phrasings like "combine these libraries",
  "merge our X and Y skill lists", or "unify these into one
  framework." Do NOT use for deduplicating skills inside a single
  library (use consolidate-framework for that).
```

### `role-profiles` (TBD)

Needs to anchor non-jargon phrasings. Draft:

```yaml
description: >
  Use this skill when the user wants to create or clone a role
  profile — a job spec, competency expectations, or required-skills
  list for a specific role. Trigger on phrasings like "build a
  job spec for senior backend engineer", "what skills should a
  product manager have", "clone the engineer profile for senior",
  or "define the requirements for this role." Requires an existing
  skill library to draw from.
```

### `import-framework` (TBD)

Already decent. Add indirect triggers:

```yaml
description: >
  Use this skill when the user wants to import a skill framework
  from a standard template (SFIA) or an external document (PDF,
  Excel, Word, CSV). Trigger on phrasings like "import this SFIA",
  "I have this competency model in a PDF", "use this Excel as the
  starting point", or "load this rubric from the doc," even if
  the user doesn't explicitly say "import."
```

## Eval harness

### Trigger detection

Trivial in Rho:

```elixir
defmodule Mix.Tasks.Rho.EvalSkill do
  use Mix.Task

  def run([skill_name, queries_path]) do
    queries = Jason.decode!(File.read!(queries_path))

    Enum.map(queries, fn %{"query" => q, "should_trigger" => expected} ->
      runs =
        for _ <- 1..3 do
          {:ok, tape} = Rho.Session.run_once(:default, q)
          triggered_skill?(tape, skill_name)
        end

      trigger_rate = Enum.count(runs, & &1) / 3

      %{
        query: q,
        should_trigger: expected,
        trigger_rate: trigger_rate,
        passed: (expected and trigger_rate >= 0.5) or
                (not expected and trigger_rate < 0.5)
      }
    end)
  end

  defp triggered_skill?(tape, name) do
    Enum.any?(tape.entries, fn
      %{type: :tool_call, tool: "skill", args: %{name: ^name}} -> true
      _ -> false
    end)
  end
end
```

### Query files

One JSON per skill, ~20 queries each, 60/40 train/validation split.
Stored at `.agents/skills/<name>/eval_queries.json`. Format:

```json
[
  {"query": "...", "should_trigger": true,  "split": "train"},
  {"query": "...", "should_trigger": false, "split": "validation"}
]
```

Should-not-trigger queries should be **near-misses** that share
keywords with this skill but actually need a different one — these
are the cases where boundary clauses earn their tokens.

### What to track per iteration

Per skill:

- Train pass rate
- Validation pass rate
- Per-query trigger rate (so we can spot the borderline cases)
- Diff of description text vs previous iteration

Pick the iteration with the **best validation pass rate**, not the
last one. Overfitting to train is the explicit failure mode the
guide warns about.

## Migration path

Phased; each phase ships independently.

### Phase 1 — Manual rewrite + sanity check

Apply the v1 rewrites above. Manually try 3-5 prompts per skill
in the LiveView console. If a skill fails to trigger on something
obvious, iterate the description before building any tooling.

This is cheap and catches the worst issues without writing code.

### Phase 2 — Build `mix rho.eval_skill`

Implement the trigger-detection task above. Wire it through
`Rho.Session` so it runs in-process. Confirm it correctly detects
trigger / non-trigger on a hand-picked pair of queries.

### Phase 3 — Author query sets

Per skill, write 20 queries:

- 8-10 should-trigger, varied across phrasing/explicitness/detail/complexity
- 8-10 should-not-trigger, biased toward near-misses

Include realism: file paths, casual language, typos, embedded
context. The guide is firm on this — generic test queries don't
predict real-world behavior.

Most labor-intensive phase. Maybe an hour per skill. Worth doing
once and keeping under version control.

### Phase 4 — Optimization loop

Per skill, run the eval, identify train failures, revise the
description, re-run. 5 iterations max. Stop early if validation
score plateaus.

### Phase 5 — Maintenance loop

Every time the agent picks the wrong skill in a real conversation
(or fails to pick one when it should have), append the user's
phrasing to that skill's `eval_queries.json` as a labeled query.
Re-run the eval before the next release. The query set grows over
time and stays grounded in real usage, not synthesized test cases.

## Where this gets hard

### Near-miss boundaries are hard to label

For `combine-libraries` vs `consolidate-framework` — what about
"clean up these two libraries before combining them"? It's both.
Real prompts often need multiple skills sequenced. Decision:
should-trigger on the *first* skill the user expects to need;
the body's workflow handles the handoff.

### Description and body must stay aligned

If the description says "use for X, Y, Z" but the body only covers
X and Y, activation succeeds but execution fails. Worse than no
skill. Mitigation: the eval set should include queries that exercise
each thing the description claims; if execution fails, that's a
body problem, not a description problem.

### Spec compliance creep

Adding a 1024-char-limit check or "name matches parent dir" check
to `Rho.Stdlib.Skill.parse_skill_md/2` is tempting at this point.
Don't. Description optimization is a behavioral change, not a
schema change. Keep the scope narrow; spec-strictness can be its
own plan if it ever matters.

### LLM nondeterminism

The guide assumes 3 runs per query. With Rho's setup we could go
higher cheaply, but variance above ~3 runs is usually noise, not
signal. Stick with 3 unless we see specific descriptions where
trigger rate hovers right at 0.5 — those need more runs to
disambiguate.

## What this is not

- **Not a description-generation system.** No LLM writing
  descriptions for us. The optimization is human-in-the-loop;
  Claude can suggest revisions but a person commits them.
- **Not body optimization.** The body content is governed by
  the best-practices guide (gotchas, defaults, procedures). That's
  a separate concern — though once activation is reliable, body
  quality becomes the next bottleneck.
- **Not a runtime classifier.** We're not building a separate
  description-vs-prompt scoring layer. The LLM does the
  classification; we just measure how well it does.

## Why I think it's worth doing now

Three reasons it's the right time, not a year from now:

1. **`dynamic-skill-loading.md` requires it.** That plan's
   "What to confirm before committing" section explicitly calls
   out skill description quality as a prerequisite. We can't move
   to load-on-demand if the agent picks the wrong skill 30% of
   the time.
2. **The catalog is the right size.** 5 skills is small enough
   that an audit is a day's work. Past 10 it becomes a project.
3. **The eval infrastructure compounds.** Once `mix rho.eval_skill`
   exists, every new skill comes with its query set; activation
   quality stops being a "we'll get to it" problem and becomes
   part of the skill-authoring workflow. Cheap to build now,
   expensive to retrofit later.

The work itself is not glamorous — it's text editing and JSON
authoring. But the eval harness specifically is the kind of
infrastructure that pays back every time we add or revise a skill,
and we're going to be doing a lot of that as the framework matures.
