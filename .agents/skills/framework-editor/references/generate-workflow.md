# Generate Framework from Scratch

Follow these phases in order. NEVER skip a phase.

## Phase 1: Guided Intake (MANDATORY — before any tool calls)

Gather context before generating. Do NOT call add_rows, replace_all, or delegate_task until intake is complete.

Ask the user (adapt based on what they volunteer — don't ask what you can infer):
- What industry/domain is this for?
- What role or job family?
- What's the purpose? (hiring, L&D, performance review, career pathing)
- How many proficiency levels per skill? (default: 5, using Dreyfus model)
- Any specific competencies that must be included?
- Any existing frameworks to align with?

If the user gives a specific role like "software engineering manager," infer reasonable defaults and confirm in a brief summary rather than asking many questions.

End intake by summarizing what you'll build and waiting for the user to confirm.

## Phase 2: Skeleton Generation (MANDATORY — before delegating)

Only after the user confirms your intake summary, generate the high-level structure:
- 3-6 categories (broad competency areas)
- 2-5 clusters per category (related skill groupings)
- 2-5 skills per cluster
- Each skill gets ONE placeholder row: `level=0, level_name="", level_description="Pending..."`

IMPORTANT: Do NOT generate proficiency levels yourself. Only generate the skeleton.

When adding skeleton rows, include the role field:
{"role": "[role name or empty]", "category": "...", ...}

If the user specified a role (e.g., "Build skills for Data Analyst"),
set role="Data Analyst" on all generated rows.
If no role specified, set role="" (company-wide).

After generating, switch to Role view if role was specified:
switch_view(mode: "role")

After adding the skeleton via `add_rows`, STOP and ask:
"Here's the proposed framework structure with [N] skills across [M] categories. Review the categories and skills — want me to adjust anything before I generate the proficiency levels?"

Wait for user approval before proceeding to Phase 3.

## Phase 3: Proficiency Level Generation

Once the user approves:
1. Use `get_table` to read the current skeleton
2. Collect all skills into a JSON array with their metadata (skill_name, category, cluster, skill_description, role)
3. Call `generate_proficiency_levels(skills_json: "[...]")` — this generates all levels in parallel server-side
4. After generation completes, use `get_table` to find rows with `level=0`
5. Delete only those placeholder rows by their IDs
6. Report completion stats to user

After generation is complete, remind the user:
"Framework generated with [N] skills. Want to save it? You can say 'save this'
or continue editing first."
