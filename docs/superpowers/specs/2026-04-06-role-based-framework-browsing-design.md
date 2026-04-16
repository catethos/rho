# Role-Based Industry Framework Browsing

## Problem

When a user wants skills from an industry framework for a specific role (e.g. "Risk Analyst"), the current flow loads the entire framework (potentially 20k+ rows) into the spreadsheet. This:

1. Crashes the tape store — the tool result JSON is too large, causing a GenServer timeout when recording to tape
2. Wastes LLM tokens — massive JSON payloads in the conversation context
3. Overwhelms the user — they see 200 roles when they only care about 1-2

## Solution

Replace the "load entire framework" pattern with a two-step browse-then-load flow:

1. Agent fetches a compact role directory from the framework
2. Agent uses its own reasoning to match the user's request to the top 5 roles
3. User picks which role(s) to load
4. Only the selected roles' rows are loaded into the spreadsheet

## New Tools

### `search_framework_roles`

Lightweight directory of all roles in a framework.

**Input:**
- `framework_id` (integer, required)

**Output:** JSON array of role objects:
```json
[
  {
    "role": "Risk Analyst",
    "skill_count": 9,
    "top_skills": ["Risk Assessment", "Credit Analysis", "Basel Compliance", "Stress Testing", "Regulatory Reporting"]
  },
  ...
]
```

`skill_count` = number of distinct skills (not rows — a skill with 5 proficiency levels is still 1 skill).

**Implementation:**
- Query: `GROUP BY role` on `framework_rows` for the given `framework_id`, counting `DISTINCT skill_name` per role
- For each role, fetch first 5 distinct `skill_name` values ordered by category then skill_name (deterministic, representative)
- Same access control as existing `load_framework` tool (`can_access?/3`)
- Returns compact data — role names + skill counts + sample skill names, no descriptions or levels
- Frameworks with 200+ roles are fine — ~6k tokens for the agent to reason over, well within budget

**Why the agent does the matching, not a dedicated algorithm:**
- The spreadsheet agent is already an LLM — it understands "Risk Analyst in banking" naturally
- No new embedding infra, no semantic search pipeline to maintain
- Matches the approach ds-agents moved toward (LLM matching over embeddings)

### `load_framework_roles`

Filtered load — only specific roles from a framework.

**Input:**
- `framework_id` (integer, required)
- `roles` (array of strings, required) — exact role names as returned by `search_framework_roles`

**Output:** Loads matched rows into the spreadsheet (same mechanism as existing `load_framework`).

**Implementation:**
- Query: `WHERE framework_id = ? AND role IN (?)`
- Send rows to SpreadsheetLive via `{:load_framework_rows, rows, framework}` message (existing pattern)
- Same access control as `load_framework`

## User Flow

```
User: "I need skills for Risk Analyst, we're a bank"

Agent: (calls list_frameworks to find industry frameworks)
Agent: (calls search_framework_roles on the banking framework)
Agent: (reads the role list, picks top 5 matches using its own reasoning)

Agent: "Found 5 closest roles in AICB Banking Framework:
  1. Risk Analyst (9 skills)
     Key skills: Risk Assessment, Credit Analysis, Basel Compliance, ...
  2. Credit Risk Manager (12 skills)
     Key skills: Portfolio Risk, Stress Testing, Loan Evaluation, ...
  3. Compliance Analyst (10 skills)
     Key skills: Regulatory Compliance, AML, Policy Review, ...
  4. Financial Risk Officer (8 skills)
     Key skills: Market Risk, Operational Risk, VaR Analysis, ...
  5. Regulatory Risk Specialist (7 skills)
     Key skills: Basel III, Capital Adequacy, Risk Reporting, ...
  Which role(s) do you want to load?"

User: "1 and 2"

Agent: (calls load_framework_roles with roles: ["Risk Analyst", "Credit Risk Manager"])
       → loads ~83 rows instead of 20k+

User: (edits in spreadsheet, saves as company framework)
```

## What Changes

| Component | Change |
|-----------|--------|
| `Rho.Mounts.Spreadsheet` | Add `search_framework_roles` and `load_framework_roles` tool definitions |
| `Rho.SkillStore` | Add `get_framework_role_directory/1` and `get_framework_rows_for_roles/2` query functions (`get_framework_rows_for_roles(framework_id, role_names)`) |
| Framework-editor SKILL.md | Add intent detection row: user mentions specific role + industry context → `search_framework_roles` then `load_framework_roles` instead of `load_framework`. Update the "Load template" signal to clarify when to use full load vs role-filtered load. |

## What Doesn't Change

- SkillStore schemas (no migrations)
- `load_framework` tool — still useful for loading small company frameworks or when user explicitly wants everything
- Save flow, access control matrix, spreadsheet UI, SpreadsheetLive handlers
- All existing tools remain available

## Access Control

Both new tools follow the same rules as `load_framework`:
- Admins can access any framework
- Everyone can access industry templates
- Company users can only access their own company frameworks

## Edge Cases

- **Framework with no roles** (all rows have `role == ""`): `search_framework_roles` returns empty list. Agent falls back to existing `load_framework` tool.
- **User wants all roles**: Agent can still use `load_framework` for that.
- **Role name mismatch**: `load_framework_roles` uses exact match on role names from `search_framework_roles`, so no mismatch possible if user picks from the presented list.
