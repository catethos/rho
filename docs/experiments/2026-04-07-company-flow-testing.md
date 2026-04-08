# Company Flow — Experiment Report

**Date:** 2026-04-07
**Branch:** `skill_framework`
**Feature:** Role-based industry framework browsing (browse-then-load)

---

## What Was Built

Two new tools added to the spreadsheet mount:
- `search_framework_roles` — returns compact role directory (role name, skill count, top 5 skills)
- `load_framework_roles` — loads only selected roles into spreadsheet

Plus supporting SkillStore queries and SKILL.md intent detection updates.

---

## Tested Scenarios

### Scenario 1: Browse template → pick role → create company framework

**Status: PASS**

**Flow observed:**
1. User opened `?company=bank_abc`, asked to browse templates
2. Agent called `list_frameworks(type: "industry")` → found FSF (157 roles, 25k+ rows)
3. User asked for "Data Scientist" → agent called `search_framework_roles(90)`
4. Agent presented relevant roles from the 157 available, recommended "Data Science" (28 skills)
5. User confirmed → agent called `load_framework_roles(90, ["Data Science"])` → loaded 140 rows (not 25k+)
6. User edited: removed DevSecOps and Empathy skills (26 skills remaining)
7. User renamed role "Data Science" → "Data Scientist" via `update_cells`
8. Saved as company framework `data_scientist_2025` (id: 91, 130 rows)

**Issues found:**
- `get_table(filter_field: "DevSecOps")` returned ALL rows because the filter was on skill_name but value wasn't matching properly — agent retried 3x before switching to delete by IDs. Burned ~180k extra tokens. Needs investigation on filter logic.
- Finch pool exhaustion hit twice (after delete_rows and after rename). Root cause: `size: 1` in Finch pool config. **Fixed** by bumping to `size: 5`.
- Structured reasoner format violation once (agent responded in plain text instead of JSON). Auto-recovered via system prompt retry.

**Token cost:** ~$0.02 total (DeepSeek v3.1 via OpenRouter)

---

## Untested Scenarios

### Scenario 2: Browse template → pick MULTIPLE roles → merge → save

**Status: PASS** (with known latency issues)

**Flow observed:**
1. User opened `?company=bank_abc`, browsed templates
2. Agent called `list_frameworks` → found FSF (157 roles) + data_scientist_2025
3. User asked for "Risk Analyst" → agent called `search_framework_roles(90)`
4. Agent recommended Credit Risk (35 skills), Risk Modelling and Validation (34 skills)
5. User confirmed → agent called `load_framework_roles(90, ["Credit Risk", "Risk Modelling and Validation"])` → 345 rows
6. User asked to merge → agent called `merge_roles(mode: "plan")` → found 32 shared, 3 primary-only, 2 secondary-only
7. User approved → agent called `merge_roles(mode: "execute")` → deleted 160 duplicates, renamed 185 rows to "Risk Analyst"
8. User removed 4 irrelevant skills (Product Design, Carbon Markets, Climate Change, Partnership Management) → `delete_rows` 17 rows
9. User removed 2 more (Business Planning, Coaching and Mentoring) → `delete_rows` 13 rows
10. Saved as `risk_analyst_2026` (id: 92, 158 rows)
11. User asked to consolidate overlapping Risk Management + Enterprise Risk Management → agent used `merge_roles(plan)` to analyze, then `delete_rows` + `add_rows` to create unified skill
12. Final save: 153 rows, 31 skills

**Demo script (user messages to replicate):**
1. "search available frameworks?"
2. "i wan to create a skill framework for Risk Analyst. Can u search the closest roles from FsF industry framework?"
3. "i think i prefer Credit Risk + Risk Modelling and Validation"
4. "I think Option 2" (when agent offers merge vs review)
5. "yes please proceed"
6. "can u check which skills are actually not so relevant to Risk Analyst?"
7. "i think lets remove the 4 less critical skills first"
8. "Skills That Might Be Too Strategic/Senior: Business Planning and Needs Analysis, Coaching and Mentoring — i think can remove these two"
9. "i think we can just save this"
10. "can i change the name to risk_analyst_2026?"
11. "Enterprise Risk Management and Risk Management — maybe we can consolidate them into one skill? can u design for me to review first?"
12. "i think u can proceed with this consolidation"
13. "ok, can update the framework being saved with this latest one"

**Key wins vs first attempt (pre-merge_roles tool):**
- `merge_roles` did full dedup in **2 tool calls** (vs 20+ `get_table` calls in first attempt)
- No missed duplicates — deterministic set operations
- No Finch pool crashes — no subagent delegation
- No multi-pass renames — single `update_cells` event

**Issues found:**
- DeepSeek v3.1 timed out 2x at 240s on turns with large context (~46k tokens). Auto-recovered on retry each time.
- Agent still calls `get_table` multiple times for simple skill deletions (needs `delete_by_skill_name` tool).
- `save_framework` tried non-existent id: 1 once before correctly using id: 92.

**Infrastructure changes made during testing:**
- Disconnected `data_extractor` + `proficiency_writer` subagents (dead code / replaced)
- Removed `multi_agent` mount from spreadsheet agent
- Added `generate_proficiency_levels` tool (server-side parallel LLM via gpt-oss-120b)
- Added `merge_roles` tool (deterministic set-operation merge)
- Fixed `get_stream_metadata` RuntimeError (Finch pool exhaustion on metadata fetch)
- Fixed `extract_proficiency_text` for ReqLLM ContentParts
- Bumped `stream_receive_timeout` 120s → 240s

### Scenario 3: Load company framework → edit → versioned save

**Status: PASS** (with minor issues)

**Flow observed:**
1. User opened `?company=bank_abc`, said "Hi"
2. Agent greeted generically (did NOT call `get_company_overview` — welcome intent not triggered)
3. User asked "what frameworks exist?" → agent called `list_frameworks` → showed DS 2025 v1, RA 2026 v1, FSF
4. "Load data scientist framework" → `load_framework(244)` → 140 rows loaded
5. "delete all Growth and Partnerships" → `delete_by_filter(cluster: "Growth and Partnerships")` → **15 rows deleted (3 skills)**
6. "save it" → `save_framework(mode: "plan", year: 2026)` → plan: DS 2026 v1 (new, 25 skills)
7. User confirmed → agent tried execute without decisions (error), retried plan, then executed correctly
8. `Saved 1 role(s): Data Scientist 2026 v1 (125 rows)`
9. "check how many company frameworks?" → `list_frameworks` → DS 2025 v1, DS 2026 v1, RA 2026 v1 — 3 frameworks

**Key wins:**
- `delete_by_filter` worked correctly — deleted exactly 15 rows (3 skills × 5 levels), not the entire table
- `filter_rows` bug fixed — was matching `%{}` against any map, returning all rows
- Versioned save created `data_scientist_2026_v1` alongside existing 2025 v1
- 2025 v1 correctly remains as default

**Issues found:**
- Welcome flow: "Hi" didn't trigger `get_company_overview` — agent used generic greeting. User had to ask "what frameworks exist?" separately.
- Save execute: agent first tried `mode: "execute"` without `decisions` param → error, then retried correctly. DeepSeek needs clearer tool usage guidance.
- Finch timeout hit once (auto-recovered)

**Demo script (user messages to replicate):**
1. "Hi"
2. "what frameworks exist?"
3. "Load data scientist framework"
4. "can we delete all the Growth and Partnerships skill?"
5. "can we save it?"
6. "yes"
7. "can u check how many company frameworks we currently have?"

### Scenario 4: From scratch — create for one role

**Priority: HIGH** — this is the generate-workflow, no template involved.

1. Open `?company=bank_abc` (empty spreadsheet)
2. "Help me create a skill framework for Software Engineer"
3. Agent should follow generate-workflow: intake questions → skeleton → approval → proficiency levels
4. Result: framework with `role="Software Engineer"` on all rows

**What to watch for:**
- Does the agent correctly detect "Generate" intent (no files, describes a role)?
- Does it load the generate-workflow reference?
- Does it use `add_rows` with role field populated?
- Quality of generated skills and proficiency levels

### Scenario 5: From scratch — create for entire company (multi-role)

**Priority: MEDIUM** — complex flow, may need multiple delegation rounds.

1. Open `?company=bank_abc` (empty spreadsheet)
2. "Help me create a skill framework for our entire company, we're a fintech with 5 departments"
3. Agent should: ask about roles/departments → generate multi-role framework
4. Result: framework with multiple roles + company-wide skills (role="")

**What to watch for:**
- Does the agent ask clarifying questions about departments/roles?
- Does it generate company-wide skills (role="") alongside role-specific ones?
- Performance with many rows being added progressively

### Scenario 6: Use template as REFERENCE (not direct load)

**Priority: HIGH** — this is the reference-workflow, different from loading.

1. Open `?company=bank_abc`
2. Upload or describe a reference framework
3. "Use the FSF as reference to build our company's skill framework"
4. Agent should: NOT load FSF directly, but use it as inspiration to create a new tailored framework

**What to watch for:**
- Does the agent correctly detect "Reference" intent vs "Load template" intent?
- Does it avoid dumping the entire FSF into the spreadsheet?
- Does it use `search_framework_roles` to browse relevant roles first?

### Scenario 7: Import from file → enhance with proficiency levels

**Priority: MEDIUM** — file upload + enhance workflow.

1. Open `?company=bank_abc`
2. Upload an Excel/CSV with skill names (no proficiency levels)
3. "Import this and add proficiency levels"
4. Agent should: import → detect missing levels → run enhance-workflow

**What to watch for:**
- File parsing and column mapping
- Correct use of `add_proficiency_levels` tool
- Quality of generated behavioral indicators

### Scenario 8: Load existing company framework → edit → save (update)

**Priority: HIGH** — validates the edit + update-in-place flow.

1. Open `?company=bank_abc`
2. "Load our data_scientist_2025 framework"
3. "Add a new skill: MLOps"
4. "Save" (should update existing, not create new)

**What to watch for:**
- Does `save_framework(framework_id: 91)` update in place?
- Are new rows correctly added alongside existing ones?
- Is the row count accurate after save?

### Scenario 9: Browse roles on framework with NO roles

**Priority: LOW** — edge case.

1. Create a framework where all rows have `role=""`
2. Try `search_framework_roles` on it
3. Agent should get empty list and fall back to `load_framework`

### Scenario 10: Access control — company user can't see other company's frameworks

**Priority: MEDIUM** — security validation.

1. Open `?company=bank_abc`
2. "Show all frameworks"
3. Should see: industry templates + bank_abc's frameworks only
4. Should NOT see other companies' frameworks

### Scenario 11: Admin flow — save as industry template

**Priority: LOW** — admin-only feature.

1. Open `?company=pulsifi_admin`
2. Create or edit a framework
3. "Save as industry template"
4. Agent should allow it (admin check passes)

---

## Bug Backlog

| # | Issue | Severity | Found In |
|---|-------|----------|----------|
| 1 | ~~`get_table` filter returns all rows~~ **FIXED** — `filter_rows(rows, %{})` matched any map, not just empty. Changed to `when filter == %{}` guard. Also affected `delete_by_filter`. | ~~Medium~~ Fixed | Scenario 1, 3 |
| 2 | Structured reasoner format violation (plain text instead of JSON) — auto-recovers but wastes a turn | Low | Scenario 1 |
| 3 | ~~**Finch pool exhaustion crashes agent loop**~~ **FIXED** — `get_stream_metadata` now catches RuntimeError and returns `{:ok, %{}}` as fallback. Subagent delegation removed entirely. | ~~High~~ Fixed | Scenario 1 |
| 4 | DeepSeek v3.1 times out (240s) on large context (~46k+ tokens). Auto-recovers on retry but wastes a turn. Root cause: slow model + accumulated `get_table` JSON responses bloating context. | Medium | Scenario 2 |
| 5 | ~~Agent calls `get_table` multiple times for simple skill deletions~~ **FIXED** — added `delete_by_filter` tool. Agent calls `delete_by_filter(field, value)` instead of `get_table` + `delete_rows`. | ~~Low~~ Fixed | Scenario 2 |
| 6 | `save_framework` tried non-existent id: 1 before correctly using id: 92 — agent hallucinated the ID. | Low | Scenario 2 |
| 7 | Welcome flow: "Hi" doesn't trigger `get_company_overview` — agent uses generic greeting. User has to explicitly ask about frameworks. SKILL.md Welcome intent not reliably detected by DeepSeek. | Medium | Scenario 3 |
| 8 | Agent calls `save_framework(mode: "execute")` without `decisions` param on first attempt — then retries correctly. DeepSeek doesn't always follow two-phase tool pattern on first try. | Low | Scenario 3 |
| 9 | DeepSeek structured output produces garbage tokens (raw IDs with `极` characters) under heavy context load — model breaks out of JSON format. | Medium | Scenario 3 (pre-filter-fix) |

## Infra Fixes Applied

| Fix | Commit |
|-----|--------|
| Tape store timeout: 5s → 30s | `8b9d0bf` |
| Finch pool size: 1 → 5 | `d515652` |
| Stream receive timeout: 120s → 240s | config/config.exs |
| Finch metadata fetch: catch RuntimeError | `4b88830` |
| Disconnect subagents (data_extractor, proficiency_writer) | `35f093f` |
| Add `generate_proficiency_levels` tool (server-side parallel LLM) | `5cde966` |
| Fix ReqLLM ContentParts extraction for gpt-oss-120b | `4b88830` |
| Add `merge_roles` tool (deterministic set-operation merge) | `75577bf` |
| Add versioning columns (role_name, year, version, is_default, description) | `fec7036` |
| Add `save_role_framework`, `get_company_roles_summary`, `set_default_version` | `c82d10f` |
| Rewrite `save_framework` tool with two-phase plan/execute | `6c82ab7` |
| Add `get_company_overview` tool for welcome flow | `ea99530` |
| Add `delete_by_filter` tool (server-side filtered deletion) | `c69361e` |
| Fix `filter_rows` empty map pattern matching bug | `2cddda3` |

---

## Recommended Test Order (Updated)

1. ~~**Scenario 2** (multi-role select + merge) — DONE~~
2. ~~**Scenario 3** (load → edit → versioned save) — DONE~~
3. **Scenario 4** (from scratch, one role) — validates generate-workflow with new `generate_proficiency_levels` tool
4. **Scenario 8** (load → edit → save update in place) — validates overwrite mode of versioned save
5. **Scenario 6** (template as reference) — validates reference-workflow
6. **Scenario 10** (access control) — security check
7. Remaining scenarios as time permits
