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

**Status: PASS**

**Flow observed:**
1. User opened `?company=bank_abc`, said "hello"
2. Agent called `get_company_overview` → showed 3 company frameworks (DS 2025, DS 2026, RA 2026) + FSF template
3. User asked to create Software Engineer framework
4. Agent detected Generate intent → called `read_resource("generate-workflow")` → loaded workflow
5. Agent asked intake questions (industry, purpose, proficiency levels)
6. User confirmed → agent called `add_rows` with 26 skeleton skills (level=0, role="Software Engineer")
7. Agent called `switch_view(mode: "role")` → paused for review
8. User removed Innovation cluster (2 skills) via `delete_by_filter`
9. User removed Junior Developer Mentoring (1 skill) via `delete_by_filter`
10. User moved Technical Leadership to different cluster via `update_cells`
11. Finch timeout hit once (auto-recovered)
12. Agent called `get_table` → collected 23 skills → called `generate_proficiency_levels`
13. **Generated 115 proficiency levels for 23 skills** (server-side parallel LLM)
14. Agent called `delete_rows` to remove 23 placeholder rows
15. Agent reported completion → user said "save this"
16. Finch timeout hit 4x before save (auto-recovered each time)
17. `save_framework(mode: "plan")` → Software Engineer 2026 v1 (new, first role = default)
18. User confirmed → `save_framework(mode: "execute")` → **Saved: Software Engineer 2026 v1 (115 rows)**

**Key wins:**
- Generate workflow end-to-end: intake → skeleton → review → proficiency generation → save
- `generate_proficiency_levels` produced 115 levels for 23 skills in one server-side call
- Versioned save correctly created v1 with `is_default=true` (first version of this role)
- User could edit skeleton before generating (remove/move skills)

**Demo script (user messages to replicate):**
1. "hello"
2. "Data Scientist got how many version?"
3. "Help me create a skill framework for Software Engineer from scratch?"
4. "Industry: Technology; Purpose: career pathing; Proficiency level: use standard; Specific Competencies: JavaScript, AWS"
5. "yes, u may"
6. "I think can remove the entire Innovation skill?"
7. "Remove Junior Developer Mentoring"
8. "Move Technical Leadership to Stakeholder Communication category haha"
9. "I think great, can proceed with generating detailed proficiency levels"
10. "ya, i think can save this framework" (may need to retry 2-3x due to Finch timeouts)
11. "yes" (confirm save plan)

**Issues found:**
- Finch pool exhaustion hit 5x total (Bug #4) — auto-recovers but burns turns and adds latency. User had to retry "save this" 4 times before agent recovered.
- DeepSeek structured output format violation 2x — auto-recovered via system prompt retry
- DeepSeek occasionally slow (~30s per turn on large context)

### Scenario 5: From scratch — create for entire company (multi-role)

**Status: PASS** (with save bug found and fixed)

**Flow observed:**
1. User opened `?company=fintech_xyz` (had existing Data Engineer 2026 v1 from Scenario 10)
2. User asked to create frameworks for 3 roles: Product Manager, Data Engineer, Data Scientist
3. Agent asked intake questions (purpose, proficiency levels, must-haves) → user chose career pathing, 5 levels, fintech focus
4. Agent proposed 5 competency categories with fintech focus → user approved
5. Agent generated **30 skeleton skills** (10 per role) via single `add_rows` call → switched to Role view
6. User approved skeleton → asked to generate proficiency levels per role
7. Agent generated levels role by role: Data Engineer (50 rows) → Data Scientist (50 rows) → Product Manager (50 rows)
8. Agent auto-deleted placeholder rows after each generation
9. **Total: 30 skills, 150 rows across 3 roles**
10. User said "save all" → `save_framework(mode: "plan")` → plan showed:
    - Data Engineer: `status: "exists"` (v1 already in DB)
    - Data Scientist: `status: "new"`
    - Product Manager: `status: "new"`
11. **BUG: Agent auto-chose `action: "update"` for Data Engineer without asking user** → overwrote the existing v1 framework
12. User noticed: "erm, u overwrite my previous Data Engineer version?" → agent admitted the mistake

**Key wins:**
- Multi-role skeleton generation in single add_rows call — clean
- Per-role proficiency generation worked well
- Save plan correctly detected the existing Data Engineer framework
- Haiku handled the complex multi-role flow cleanly

**Bug found and fixed:**
- **Save auto-update bug** — agent chose `action: "update"` without asking the user. Should have asked "Data Engineer already exists. Update or create v2?" Fixed in commit `32ad3a3`: SKILL.md and persistence-workflow now explicitly require presenting the plan, waiting for approval, and defaulting to `action: "create"` for existing roles.

**Issues found:**
- Finch timeout hit twice — agent unresponsive, user had to prompt "hello"
- Agent still tried `get_uploaded_file` on FSF template in reference flow (not relevant here, but pattern persists)

**Demo script (user messages to replicate):**
1. "hello"
2. "Help me create a skill framework for our entire company. We're a fintech with 3 roles: Product Manager, Data Engineer, and Data Scientist"
3. "1. Career pathing & progression 2.Yes, 5 levels 3.infer based on typical fintech role 4.start fresh"
4. "ok" (approve proposed structure)
5. "yes" (approve skeleton)
6. "u can generate proficiency levels per role, can do for Data Engineer first"
7. "hello" (nudge after Finch timeout)
8. "now Data Scientist"
9. "great, i think can save all"
10. (verify save plan before confirming — check for update vs create on existing roles)

### Scenario 6: Use template as REFERENCE (not direct load)

**Status: PASS** (with issues)

**Flow observed:**
1. User opened `?company=bank_abc`, said "hello" → `get_company_overview` showed 4 company frameworks
2. User asked "I want to build a skill framework for Compliance Officer, using the FSF as reference"
3. Agent loaded `reference-workflow.md` → called `list_frameworks` → `search_framework_roles(243)` → presented top compliance roles
4. Agent also tried `get_uploaded_file("FSF...")` — failed gracefully (FSF is a DB template, not a file upload)
5. User picked "Regulatory Compliance" as the reference
6. Agent generated **8 NEW skills** across 4 categories (Regulatory Knowledge, Compliance Operations, Risk & Governance, Professional Development) — NOT copied from FSF's 32 skills
7. Agent called `generate_proficiency_levels` → **40 proficiency levels** for 8 skills
8. User then asked to load Regulatory Compliance for comparison → `load_framework_roles(243, ["Regulatory Compliance"], append: true)` → 160 rows appended
9. User asked to move Power Skills from RC to Compliance Officer → agent used `update_cells` to change role field on 74 rows, then `delete_by_filter(role: "Regulatory Compliance")` to remove remaining RC rows
10. `save_framework(mode: "plan")` → Compliance Officer 2026 v1 (new, 26 skills)
11. `save_framework(mode: "execute")` → **Saved: Compliance Officer 2026 v1 (114 rows)**
12. Agent confirmed it was auto-set as default (first version)

**Key wins:**
- Reference intent correctly detected — agent generated NEW skills, not loaded FSF
- `search_framework_roles` used to browse template (not `load_framework`)
- Append mode worked perfectly for side-by-side comparison
- Move skills between roles via `update_cells` + `delete_by_filter` worked
- Versioned save with auto-default for new role

**Issues found:**
- Agent tried `get_uploaded_file` on FSF (DB template, not uploaded file) — fell back gracefully but wasted a turn. Reference-workflow needs stronger disambiguation for DB templates.
- Agent skipped skeleton review phase — went straight from intake to `generate_proficiency_levels` without showing skeleton for approval first. generate-workflow says MANDATORY but agent bypassed it.
- Finch timeouts caused agent to be unresponsive 4+ times — user had to retry messages repeatedly
- Agent didn't use the new `field2/value2` on `delete_by_filter` for scoped deletion — used update_cells + single filter instead (worked but less elegant)

**Demo script (user messages to replicate):**
1. "hello?"
2. "I want to build a skill framework for Compliance Officer, using the FSF as reference"
3. "I think u may just referencing Regulatory Compliance to draft the framework"
4. "yes cool"
5. "Can we load the Regulatory Compliance into the spreadsheet too?"
6. "Can we move the Power Skills from Regulatory Compliance to the Compliance Officer? then, only delete the entire Regulatory Compliance from the spreadsheet?" (may need to retry due to Finch timeouts)
7. "Can we move the Power Skills from Regulatory Compliance to the Compliance Officer?" (simpler prompt worked better)
8. "save this framework" (may need to retry)
9. "yup, this as default version"

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

**Status: PASS**

**Flow observed:**
1. User opened `?company=bank_abc`, said "hello"
2. Agent called `get_company_overview` → showed DS 2025 (default), DS 2026, RA 2026, SE 2026
3. User asked about Data Scientist versions → agent explained 2025 v1 (default, 28 skills) + 2026 v1 (draft, 25 skills)
4. User asked to load 2026 version → `load_framework(246)` → 125 rows loaded
5. User asked to add MLOps skill → agent called `get_table_summary` to check categories, then `add_rows` with skeleton row
6. Agent auto-called `generate_proficiency_levels` for MLOps → generated 5 proficiency levels
7. User asked to fix level names to match existing style (PL 1-5) and delete placeholder row
8. Agent called `get_table` to check existing style, then `update_cells` (renamed levels) + `delete_rows` (removed placeholder)
9. User said "save this" → `save_framework(mode: "plan", year: 2026)` → plan: update DS 2026 v1 (26 skills, 130 rows)
10. User confirmed → `save_framework(mode: "execute", decisions: [{action: "update", existing_id: 246}])` → **Saved: updated DS 2026 v1 (130 rows)**
11. User asked to set 2026 as default → agent said **"I don't have a direct tool to set the default version"** (Bug — tool was missing)

**Key wins:**
- Update-in-place worked correctly — same framework ID, same version, just updated rows
- Agent auto-generated proficiency levels for the new skill without being asked
- Agent checked existing level naming style before adding (good context awareness)
- Save plan correctly identified "update existing" vs "create new"

**Issues found:**
- `set_default_version` tool was missing from mount — **FIXED** in commit `526218a`
- Finch timeout hit once during conversation (auto-recovered)
- Agent tried `read_resource("check-versions-workflow.md")` which doesn't exist — fell back gracefully

**Demo script (user messages to replicate):**
1. "hello"
2. "Is there latest version for Data Scientist?"
3. "Can u load the 2026 version?"
4. "I am thinking to add a new skill: MLOps"
5. "I think the Level name for MLOps should be follow the existing framework style. and delete the one with pending proficiency description"
6. (retry same message if agent doesn't get it first time)
7. "Save this"
8. "yes"
9. "can u set this version to be default for Data Scientist?" (requires `set_default_version` tool fix)

**Set Default Version — follow-up test (after tool fix):**

Tested in a clean session after adding `set_default_version` tool:
1. User asked "hey, can u check what company frameworks we have?" → `get_company_overview` showed DS 2025 v1 as default
2. User asked "can we set the 2026 version for Data Scientist to default?" → agent called `set_default_version(framework_id: 246)` → **Set Data Scientist 2026 v1 as default**
3. DB confirmed: DS 2025 `is_default=0`, DS 2026 `is_default=1`

Two tool calls, clean execution. No issues.

### Scenario 9: Browse roles on framework with NO roles

**Priority: LOW** — edge case.

1. Create a framework where all rows have `role=""`
2. Try `search_framework_roles` on it
3. Agent should get empty list and fall back to `load_framework`

### Scenario 10: Access control — company user can't see other company's frameworks

**Status: PASS**

**Setup:** Switched model from DeepSeek v3.1 to **Haiku 4.5** (`openrouter:anthropic/claude-haiku-4.5`) for this test onwards.

**Flow observed:**
1. Opened `?company=fintech_xyz` → agent showed "No role frameworks yet" + FSF template
2. Built a Data Engineer framework from scratch (10 fintech-focused skills, 50 proficiency levels)
3. Saved as **Data Engineer 2026 v1** for fintech_xyz (ID: 249)
4. Opened `?company=bank_abc` in new tab → asked "what company frameworks available?"
5. `get_company_overview` returned: Compliance Officer, Data Scientist, Risk Analyst, Software Engineer — **all bank_abc's**
6. User asked "could u access Data Engineer 2026 v1?" → Agent: **"I don't see a Data Engineer framework in your company's available frameworks"**

**Key wins:**
- Access control works — fintech_xyz's Data Engineer not visible to bank_abc
- `get_company_overview` and `list_frameworks` correctly scoped by company_id
- Industry templates (FSF) visible to both companies

**Haiku 4.5 vs DeepSeek v3.1 improvements:**
- Zero JSON format violations (DeepSeek had 2-3 per session)
- Better instruction following — cleaner intake, proper confirmations
- More conversational responses with good formatting
- Still hits Finch timeouts but recovers more gracefully
- Slightly higher cost (~$0.10 vs ~$0.02 per session) but much better quality

**Demo script (fintech_xyz session):**
1. "hey?"
2. "I wanna build a Data Engineer framework, can u check the FsF template to see if there is any closest role for us to use as reference?"
3. "i think load as reference ba"
4. "any suggestion? i dont want to categories them as Power Skills or Prime Skills"
5. "i think is 1. and i want the skills to be more relevant to Fintech"
6. "1. from junior to principal. 2.more in Payments & Settlement. 3.AI. 4.career progression"
7. "yes"
8. "proceed"
9. (wait for proficiency generation to complete, may need to prompt "hello?" due to Finch timeout)
10. "great, then i think u can remove the Data Engineering that we reference from the spreadsheet?"
11. "i think can save it"
12. "should be 2026 version"
13. (confirm save — may need "hello?" to nudge)
14. "yup, set as default"

**Demo script (bank_abc access control check):**
1. "hey, can u check what are the company frameworks available?"
2. "could u access Data Engineer 2026 v1 framework?"

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
3. ~~**Scenario 4** (from scratch, one role) — DONE~~
4. ~~**Scenario 8** (load → edit → save update in place) — DONE~~
5. ~~**Scenario 6** (template as reference) — DONE~~
6. ~~**Scenario 10** (access control) — DONE~~
7. ~~**Scenario 5** (multi-role from scratch) — DONE~~
8. Remaining scenarios as time permits
