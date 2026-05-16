# Skill Framework Generation — Redesign Plan

## Problem

The current spreadsheet agent generates skill frameworks purely from a short prompt section (~30 lines). It produces generic output because:

1. **No intake** — jumps straight to generation without understanding the domain, role family, or organizational context
2. **Flat generation** — generates everything (categories → clusters → skills → proficiency levels) in one monolithic `add_rows` call
3. **No methodology** — doesn't follow established competency modeling standards (SHRM, Dreyfus, OPM)
4. **Weak behavioral indicators** — proficiency descriptions tend to be vague ("shows initiative") rather than observable ("proactively identifies process inefficiencies and proposes improvements without prompting")

## Design Goals

1. **Guided intake** — ask the user contextual questions before generating
2. **Two-phase generation** — skeleton first (categories/clusters/skills), then proficiency levels in parallel via sub-agents
3. **Research-backed quality** — embed Dreyfus model, Bloom's taxonomy verbs, and behavioral indicator best practices into prompts
4. **Progressive rendering** — user sees the skeleton immediately, then proficiency levels fill in as sub-agents complete

---

## Phase 1: Guided Intake (Conversational)

Before generating anything, the agent should gather context. The prompt should instruct the agent to ask these questions (adapting based on what the user volunteers):

| Category | Questions |
|----------|-----------|
| **Domain** | What industry/sector? What department or function? |
| **Role scope** | Single role, job family, or organization-wide? What's the role title? |
| **Purpose** | Hiring assessment? L&D? Performance review? Career pathing? |
| **Existing frameworks** | Any existing competency models to align with? (SFIA, O*NET, internal) |
| **Scale** | How many categories? How many proficiency levels per skill? (default: 4-5) |
| **Level naming** | Preferred naming scheme? (Dreyfus: Novice→Expert, or custom) |
| **Differentiators** | What distinguishes high performers from adequate ones in this role? |
| **Must-include** | Any specific competencies that must appear? |

The agent should NOT require answers to all questions. It should adapt — if the user says "software engineering manager," the agent can infer reasonable defaults and confirm.

**Implementation**: This is purely a prompt change. No code changes needed.

---

## Phase 2: Skeleton Generation (Primary Agent)

After intake, the primary spreadsheet agent generates the **high-level structure only**:

```
Category → Cluster → Skill Name + Skill Description
```

This is written to the spreadsheet immediately via `add_rows`, with **empty proficiency levels** (level=0, level_name="", level_description="Generating...").

**Why skeleton first:**
- User can review and correct the structure before investing in proficiency level generation
- Fast feedback loop — skeleton for a 50-skill framework takes one LLM call
- The agent should pause after skeleton and ask: "Here's the proposed structure. Want me to proceed with generating proficiency levels, or adjust anything first?"

**Row format during skeleton phase:**
```json
{
  "category": "Technical Excellence",
  "cluster": "Software Design",
  "skill_name": "System Architecture",
  "skill_description": "Designs scalable, maintainable system architectures that balance technical constraints with business requirements",
  "level": 0,
  "level_name": "",
  "level_description": "⏳ Pending generation..."
}
```

One row per skill (not per proficiency level) during this phase.

**Implementation**: Prompt change + minor spreadsheet mount change to support a "skeleton" row format.

---

## Phase 3: Parallel Proficiency Level Generation (Sub-Agents)

Once the user approves the skeleton, the primary agent delegates proficiency level generation to sub-agents — one per category (or per cluster, depending on size).

### Architecture

```
Primary Agent (spreadsheet + multi_agent mounts)
  │
  ├─ delegate_task("Generate proficiency levels for Technical Excellence category")
  │   └─ proficiency_writer sub-agent (depth 1)
  │       → Calls add_rows with 4-5 rows per skill in this category
  │
  ├─ delegate_task("Generate proficiency levels for Leadership category")
  │   └─ proficiency_writer sub-agent (depth 1)
  │       → Calls add_rows with 4-5 rows per skill in this category
  │
  └─ delegate_task("Generate proficiency levels for Communication category")
      └─ proficiency_writer sub-agent (depth 1)
          → Calls add_rows with 4-5 rows per skill in this category
```

Sub-agents run **in parallel**. Each has access to the `:spreadsheet` mount so it can:
1. Read the current skeleton via `get_table` (filtered by category)
2. Delete the placeholder row for each skill
3. Add the full proficiency level rows (typically 4-5 per skill)

### Delegation flow

```
Step 1: Primary reads skeleton via get_table_summary
Step 2: For each category, call delegate_task(role: "proficiency_writer", task: "...")
Step 3: Collect all agent_ids
Step 4: await_task for each agent_id
Step 5: Primary confirms completion, reports final stats
```

### Sub-agent prompt design

The `proficiency_writer` role prompt should embed:

1. **Dreyfus model** as the default progression framework:
   - Level 1: **Novice** — Rule-following, no discretion, needs supervision
   - Level 2: **Advanced Beginner** — Recognizes patterns from experience, limited judgment
   - Level 3: **Competent** — Deliberate planning, organized approach, takes responsibility
   - Level 4: **Proficient** — Intuitive diagnosis, sees the big picture, frustrated by rigid rules
   - Level 5: **Expert** — Automatic, creative, teaches others, shapes the field

2. **Bloom's taxonomy verbs** for each level:
   - Level 1: Identify, list, follow, recognize, describe
   - Level 2: Apply, demonstrate, execute, implement
   - Level 3: Analyze, organize, compare, prioritize, troubleshoot
   - Level 4: Evaluate, judge, assess, mentor, optimize
   - Level 5: Create, design, architect, innovate, transform

3. **Behavioral indicator quality rules**:
   - Each description must be **observable** (what you'd *see* someone doing)
   - Use format: **action verb + core activity + context/outcome**
   - Example: "Designs distributed system architectures that handle 10x traffic growth while maintaining sub-100ms p99 latency"
   - Anti-pattern: "Is good at system design"
   - Each level must assume mastery of all prior levels
   - Levels must be **mutually exclusive** — no overlapping behaviors
   - 1-2 sentences per level description (concise but specific)

---

## Config Changes (`.rho.exs`)

### Updated `spreadsheet` profile

```elixir
spreadsheet: [
  model: "openrouter:anthropic/claude-sonnet-4.6",
  description: "Skill framework editor with guided intake and parallel generation",
  skills: [],
  system_prompt: """
  <see Phase 1-3 prompt below>
  """,
  mounts: [
    :spreadsheet,
    {:multi_agent, only: [:delegate_task, :await_task, :list_agents]}
  ],
  reasoner: :structured,
  max_steps: 50
],
```

### New `proficiency_writer` profile

```elixir
proficiency_writer: [
  model: "openrouter:anthropic/claude-haiku-4.5",
  description: "Generates Dreyfus-model proficiency levels for skills in a competency framework",
  skills: ["competency frameworks", "proficiency levels", "behavioral indicators"],
  system_prompt: """
  <see sub-agent prompt below>
  """,
  mounts: [:spreadsheet],
  reasoner: :structured,
  max_steps: 15
],
```

Note: Using `claude-haiku-4.5` for sub-agents to reduce cost — proficiency level writing is a focused, well-constrained task.

---

## Prompt Design

### Primary Agent (Spreadsheet) — Full Prompt

```
You are a skill framework editor assistant that builds enterprise-quality competency
frameworks following established HR/L&D methodology.

## Workflow

You work in three phases:

### Phase 1: Intake
Before generating anything, understand the context. Ask the user:
- What industry/domain is this for?
- What role or job family?
- What's the purpose? (hiring, L&D, performance review, career pathing)
- How many proficiency levels per skill? (default: 5, using Dreyfus model)
- Any specific competencies that must be included?
- Any existing frameworks to align with?

Adapt your questions based on what the user volunteers. If they say "software engineering
manager," infer reasonable defaults and confirm rather than asking 10 questions.

### Phase 2: Skeleton
Generate the high-level structure and add it to the spreadsheet:
- 3-6 categories (broad competency areas)
- 2-5 clusters per category (related skill groupings)
- 2-5 skills per cluster
- Each skill gets one placeholder row (level=0, level_description="⏳ Pending...")

After adding the skeleton, STOP and ask the user:
"Here's the proposed framework structure with [N] skills across [M] categories.
Review the categories and skills — want me to adjust anything before I generate
the proficiency levels?"

### Phase 3: Parallel Proficiency Generation
Once approved, delegate proficiency level generation to sub-agents:
1. Use get_table to read the current skeleton
2. For each category, call delegate_task with role "proficiency_writer"
   Include in the task: category name, list of skills with descriptions,
   number of proficiency levels, and the session_id
3. Await all tasks
4. Delete the placeholder rows
5. Report completion stats

## Quality Standards
- Skill descriptions: 1 sentence defining the competency boundary
- Use enterprise language appropriate to the domain
- Categories should be MECE (mutually exclusive, collectively exhaustive)
- Target 6-10 competencies per role (frameworks >12 lose discriminant validity)
- Cluster names should be intuitive groupings, not jargon

## Tools
- get_table_summary: Check current state before any changes
- get_table: Read rows, optionally filtered
- add_rows: Add new rows (skeleton or proficiency levels)
- update_cells: Edit specific cells
- delete_rows: Remove rows by ID
- replace_all: Full table replacement
- delegate_task: Spawn sub-agent for parallel proficiency generation
- await_task: Collect sub-agent results
```

### Sub-Agent (Proficiency Writer) — Prompt Section in Mount

```
You are a proficiency level writer for competency frameworks. You receive a category
of skills and generate proficiency levels for each one.

## Your Task
For each skill provided, generate proficiency level rows and add them to the spreadsheet
using add_rows. First, delete the placeholder row for each skill using delete_rows.

## Proficiency Level Model (Dreyfus-based)

Level 1 — Novice (Foundational):
  Follows established procedures. Needs supervision for non-routine situations.
  Verbs: identifies, follows, recognizes, describes, lists

Level 2 — Advanced Beginner (Developing):
  Applies learned patterns to real situations. Handles routine tasks independently.
  Verbs: applies, demonstrates, executes, implements, operates

Level 3 — Competent (Proficient):
  Plans deliberately. Organizes work systematically. Takes ownership of outcomes.
  Verbs: analyzes, organizes, prioritizes, troubleshoots, coordinates

Level 4 — Advanced (Senior):
  Exercises judgment in ambiguous situations. Mentors others. Optimizes processes.
  Verbs: evaluates, mentors, optimizes, integrates, influences

Level 5 — Expert (Master):
  Innovates and shapes the field. Operates intuitively. Recognized authority.
  Verbs: architects, transforms, pioneers, establishes, strategizes

## Quality Rules
- Each description MUST be observable: what would you literally SEE this person doing?
- Format: [action verb] + [core activity] + [context or business outcome]
- GOOD: "Designs distributed architectures that maintain sub-100ms p99 latency under 10x traffic spikes"
- BAD: "Is good at system design"
- Each level assumes mastery of all prior levels — don't repeat lower-level behaviors
- Levels must be mutually exclusive — if two levels sound interchangeable, rewrite
- 1-2 sentences per level_description, max

## Output Format
Call add_rows with rows_json containing all proficiency levels for all skills in your
assigned category. Group by skill (all levels for skill A, then all levels for skill B).

Do NOT include an "id" field — IDs are assigned automatically.
```

---

## Code Changes Required

### 1. Spreadsheet Mount — Update `prompt_sections/2`

Replace the current generic prompt with the Phase 1-3 prompt above.

**File:** `lib/rho/mounts/spreadsheet.ex`, lines 53-88

### 2. `.rho.exs` — Update spreadsheet profile

- Add `:multi_agent` to mounts (with `only:` filter)
- Increase `max_steps` from 30 to 50
- Add `proficiency_writer` agent profile

**File:** `.rho.exs`, lines 56-71

### 3. Spreadsheet Mount — Handle placeholder rows

Add visual indicator for pending rows. The current `atomize_keys` and rendering already handle arbitrary field values, so `"⏳ Pending..."` in `level_description` will render fine. No code change needed here.

### 4. SpreadsheetLive — Handle sub-agent signals

Sub-agents publish to the same session's signal bus topic. The LiveView already subscribes to `rho.session.#{session_id}.events.*`, so sub-agent `rows_delta` signals will be received automatically. **No code change needed.**

### 5. (Optional) Proficiency writer prompt section in mount

If we want the proficiency_writer prompt to be part of the mount rather than just in `.rho.exs`, add a conditional prompt section in the Spreadsheet mount based on agent depth or role. But `.rho.exs` system_prompt is simpler for now.

---

## Implementation Order

1. **Update `.rho.exs`** — Add `proficiency_writer` role, update `spreadsheet` mounts/max_steps
2. **Update `prompt_sections/2`** in `Rho.Mounts.Spreadsheet` — Replace with the intake + skeleton + delegation prompt
3. **Test manually** — Run a spreadsheet session, verify:
   - Agent asks intake questions
   - Skeleton generates with placeholder rows
   - Agent pauses for approval
   - Sub-agents generate proficiency levels in parallel
   - Rows stream progressively into the UI
4. **Iterate on prompts** — Tune based on output quality

---

## Cost Estimate

For a framework with 5 categories × 4 clusters × 4 skills = 80 skills:

| Phase | Model | Tokens (est.) | Cost (est.) |
|-------|-------|---------------|-------------|
| Intake | Sonnet 4.6 | ~2K in, ~500 out | ~$0.01 |
| Skeleton | Sonnet 4.6 | ~3K in, ~8K out | ~$0.10 |
| Proficiency (5 sub-agents) | Haiku 4.5 | 5 × (2K in, 6K out) | ~$0.05 |
| **Total** | | | **~$0.16** |

Versus current single-shot: ~$0.15-0.30 for worse quality. Parallel generation should also be faster wall-clock time.

---

## Future Enhancements (Out of Scope)

- **Validation pass**: After generation, run a review sub-agent that checks for overlapping levels, missing Bloom's verbs, and vague descriptors
- **Import existing frameworks**: Parse uploaded CSV/Excel to bootstrap
- **O*NET integration**: Look up standard competencies by occupation code
- **Export formats**: Generate formatted PDF/docx from the spreadsheet data
