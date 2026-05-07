---
name: create-framework
description: Workflow for creating a NEW skill framework — from scratch with intake, seeded by similar role profiles, or inspired by an existing library
uses: [manage_role, load_similar_roles, generate_framework_skeletons, generate_proficiency, save_framework, browse_library, manage_library]
---

## Create Skill Framework Workflow

This skill builds a NEW framework from nothing or with inspiration. For
LOADING and customizing an existing template (sfia_v8, etc.), use
`import-framework`. For editing an already-saved library, use
`manage-frameworks`.

## Phase 1 — Pick the path FIRST

Before any intake interrogation, classify the user's intent into one of three
paths from their first message. The path determines whether intake comes
first or comes after the user has seen candidate options.

- **Path A — From scratch** (no existing inspiration). Signals: user names
  a role/domain but not any inspiration source ("build a framework for
  Risk Analyst", "create a PM framework").
- **Path B — Seeded by similar role profiles**. Signals: user names a
  role/domain AND points at existing role profiles, an org library, ESCO,
  O*NET, or "similar roles in our org" ("Risk Analyst using ESCO",
  "framework for PM using our existing libraries").
- **Path C — Inspired by an existing library**. Signals: user names a
  specific library as REFERENCE only ("based on SFIA", "like our Backend
  Engineering framework but for PMs", "inspired by AICB").

Multi-framework variant (user names multiple roles like "Risk Analyst,
Data Scientist, Data Engineer"): each role becomes its OWN library.
Process them sequentially — one role at a time, start to finish — not
in parallel.

1. **Detect existing first** — call `manage_library(action: "list")`. If
   any requested role already exists as a saved library, ask: "<X>
   already exists — extend it, create alongside as a new framework, or
   skip it?"
2. **Process one role at a time.** For each role: run the chosen path
   (A/B/C) end-to-end (search → pick → view → overlap → skeleton →
   proficiency → save). Announce progress between roles ("Saved Risk
   Analyst draft. Moving to Data Scientist...") so the user sees the
   sequence.
3. **Do NOT bundle all roles into a single `generate_framework_skeletons`
   call.** That produces one cross-cutting library, not three. The
   `target_roles` param is for ONE library targeted at multiple roles
   (e.g. "Senior Risk Analyst, Lead Risk Analyst" — variants of one
   role), not for separate frameworks.

The typed_structured strategy is one-action-per-turn, so sequential
processing is the only option anyway.

## Phase 2 — Path-specific intake

The intake depth depends on the path. NEVER make the user answer five
intake questions before they've seen any tool output — that's a wall of
interrogation.

### For Path A (from scratch)

Path A has no inspiration to anchor the framework, so intake IS
mandatory before any tool call. Ask only what you can't reasonably
infer:

- **Industry / domain** — e.g. fintech, healthcare, government
- **Role(s)** — single or multi-role
- **Purpose** — hiring, L&D, performance review, career pathing
- **Proficiency levels** — default 5 (Dreyfus); user can override
- **Must-have competencies** — anything guaranteed
- **Existing frameworks to align with** — names of libraries, if any

End with a 2–3 line summary and wait for the user to confirm. If the
user volunteered most of this in their first message, skip what you
have and confirm only the inferred values.

### For Path B (seeded by role profiles)

Do NOT interrogate the user before calling `load_similar_roles`. The
picked roles ARE the framework's anchor — let the user pick first, then
clarify only what's missing.

**Critical: one action per turn.** The typed_structured strategy emits
ONE action per turn. Do NOT respond first and then call the tool — pick
the tool action directly. If you emit a `respond` action with the tool
call as a follow-up, the tool call is silently dropped and the agent
stalls. The user will see the tool call in the chat UI as progress;
your verbal confirmation comes naturally in the next turn after the
tool result returns.

1. **Call `load_similar_roles` directly** as the first action — pass
   the role name as `name` and `target_roles`. Use `domain` if the user
   gave one. Skip any other intake fields. NO `respond` action first.
2. **Continue at Path B step 1 (User picks)** below.

After the user picks roles and you've shown them the overlap analysis,
ask any minimal clarifications that aren't inferable from the picks:
purpose (only if it changes scope — hiring vs career pathing), seniority
range (only if picks span multiple levels). Skip the rest.

### For Path C (inspired by an existing library)

Same principle as Path B — let the user see the reference first.

**Critical: one action per turn.** Same rule as Path B — do NOT respond
first and then call the tool. Pick the tool action directly.

1. **Call `browse_library` directly** as the first action — see Path C
   step 1 below. NO `respond` action first.
2. Ask any minimal clarifications AFTER you've shown the user the
   reference patterns and they've agreed with your approach.

## Phase 3 — Execute the path

The step-by-step for each path. For Path B and C, you've already
called `load_similar_roles` / `browse_library` in Phase 2 — pick up
where Phase 2 left off.

### Path A — From scratch

1. **Generate skeleton** — `generate_framework_skeletons(name, description, [domain], [target_roles], [skill_count])`. Skeleton rows stream into the `library:<name>` workspace table.
2. **Present for approval** — once streaming completes, summarize the categories/clusters/skills (≤ 3 sentences). Ask: "Ready to generate proficiency levels?"
3. **Generate proficiency** — ONLY after explicit approval, call `generate_proficiency(table_name: "library:<name>", levels: <intake-N>)`. This blocks ~30–60s and returns a single summary. Do not call `await_all`.
4. **Save** — offer `save_framework(table: "library:<name>")` to persist. This creates a new DB library record (or updates an existing draft of the same name). It is always a draft — to lock it as a published version, the user explicitly asks to publish (see `manage-frameworks` skill).

### Path B — Seeded by similar role profiles

Phase 2 already called `load_similar_roles` and the user has the
candidate list with UUIDs. Continue from there:

1. **User picks** — present the candidates from Phase 2's tool result and ask which to use as seed (1 or more). The tool output includes the UUID for each — keep those handy.
2. **View each pick's skills** — for each picked role profile, call `manage_role(action: "view", role_profile_id: "<uuid>")` using the UUID from the load_similar_roles output. NEVER pass the role's NAME as `role_profile_id` — names fail UUID validation. The view tool reads but does NOT load anything into the workspace.
3. **Reason about overlap in chat** — read the skill lists from step 2, identify which skills appear in multiple picks (shared) and which are unique to each. Present to the user as plain text:
   ```
   Both have: Risk Modeling, Credit Analysis, Regulatory Compliance (3 shared)
   Risk Analyst only: Stress Testing, Capital Adequacy
   Credit Risk only: Collateral Valuation, Loan Origination
   ```
   Ask: "Keep all 7? Drop any?"
4. **Ask any minimal clarifications** — if not already known, ask only what's needed to scope the framework: purpose (hiring vs L&D vs career pathing), seniority range. Do NOT re-ask things the picks already answer.
5. **User curates** — collect the user's final pick list and clarification answers.
6. **Generate skeleton with seed** — `generate_framework_skeletons(name, description, target_roles, similar_role_skills: <formatted block listing the curated picks>)`. The `similar_role_skills` field accepts a free-text seed context; pass the list of skill names + brief descriptions for each pick.
7. Continue with steps 2–4 of Path A (review → generate proficiency → save).

NEVER load the picked role profiles into a workspace table. NEVER save
them as separate libraries. The agent reads them in chat and curates;
nothing is persisted until step 7's save.

### Path C — Inspired by an existing library

Phase 2 already gave a brief confirmation. Continue from there:

1. **Browse the reference** — `browse_library(library_name: "<name>")` to read its skills/categories/clusters. Do NOT call `load_library` — that would load the whole thing into the workspace, which is `import-framework`'s flow, not this one.
2. **Extract patterns** — read the response and note: category structure, naming conventions, cluster style, level model. Summarize for the user: "SFIA uses 6 categories, 7-level proficiency, focuses on Skills + Knowledge. I'll adapt the structure to a 5-level Dreyfus model for your PM context."
3. **Ask any minimal clarifications** — only what's needed to scope (purpose, seniority). Skip what the reference patterns already imply.
4. **Confirm approach** — wait for user approval.
5. **Generate skeleton with seed** — `generate_framework_skeletons(name, description, similar_role_skills: <formatted block summarizing the reference patterns and any specific skill names you want carried over>)`.
6. Continue with steps 2–4 of Path A (review → generate proficiency → save).

## Rules

- 8–12 skills per framework, 3–6 MECE categories, 1–3 clusters each.
- Skill descriptions: 1 sentence defining the competency boundary.
- NEVER call `generate_proficiency` without presenting the full skeleton and receiving explicit approval.
- After `generate_proficiency` returns, offer `save_framework`. Do NOT verify with data-table tools — the user sees the table.

## Anti-patterns (do NOT do these)

- ❌ For Path A only: skipping intake. Calling `generate_framework_skeletons` from cold (no inspiration) without first gathering domain/role/purpose produces generic output. For Path B and C, intake is deferred — call the tool first.
- ❌ For Path B: interrogating the user with five intake questions before calling `load_similar_roles`. The user said "build for X using ESCO" — that's enough. Run the search, let them pick, ask any missing scope questions AFTER the picks.
- ❌ For Path B: passing a role NAME (e.g. `"financial risk manager"`) as `role_profile_id` to `manage_role(view)`. The tool requires a UUID. Use the UUID from the `load_similar_roles` output (formatted as `- <name> (<UUID>) — ...`).
- ❌ Emitting a `respond` action with verbal confirmation when you intend to call a tool next. The typed_structured strategy emits ONE action per turn — your tool call gets silently dropped. Just emit the tool action directly; the verbal acknowledgement comes naturally in the next turn after the tool result.
- ❌ `load_library` after `generate_framework_skeletons` — the skeleton rows are already in the `library:<name>` table. `load_library` reads from the DB, where the library does not exist yet, and will fail with "Library not found".
- ❌ `load_library` for Path B or C — role profiles and reference libraries are read via `manage_role(view)` / `browse_library`, NOT loaded into the workspace.
- ❌ `manage_library(action: "create")` before `save_framework` — `save_framework` looks up or creates the library by name automatically. Pre-creating produces an empty DB record and a duplicate-name conflict on save.
- ❌ Calling `generate_framework_skeletons` more than once for the same framework — re-running appends to the existing table; re-do only if the user explicitly asks to regenerate.
- ❌ `await_all` after `generate_proficiency` — the chat-side `generate_proficiency` already blocks until every category writer completes. Calling `await_all` afterward sends an empty `agent_ids` list and errors.
- ❌ Using `query_table` / `describe_table` to "verify" what was just generated — the user sees the table directly. Trust the tool's row-count response.
- ❌ For Path B: saving each picked role profile as its own library before comparing. Role profiles are READ via `manage_role(view)` and curated in chat; the comparison is the agent's reasoning, not a tool call.
