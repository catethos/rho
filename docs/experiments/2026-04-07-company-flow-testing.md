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

### Scenario 2: Browse template → pick MULTIPLE roles → create company framework

**Priority: HIGH** — validates multi-select which we explicitly designed for.

1. Open `?company=bank_abc`
2. "Browse the FSF template"
3. "I need skills for both Credit Risk and Risk Modelling roles"
4. Agent should call `search_framework_roles` → present matches → user picks 2+
5. Agent calls `load_framework_roles(90, ["Credit Risk", "Risk Modelling and Validation"])`
6. User edits, saves as company framework

**What to watch for:**
- Does the agent correctly pass multiple roles in the JSON array?
- Are both roles' rows loaded and visible in the spreadsheet?
- Does "By Role" view correctly group the two roles?

### Scenario 3: Load entire template (no role filter)

**Priority: MEDIUM** — validates the old `load_framework` still works for small frameworks.

1. Open `?company=bank_abc`
2. "Load our data_scientist_2025 framework" (the company framework saved in Scenario 1)
3. Agent should use `load_framework` (not `load_framework_roles`) since it's a small company framework

**What to watch for:**
- Does the agent correctly choose `load_framework` over `load_framework_roles` for small/company frameworks?
- Does the tape store handle it without timeout?

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
| 1 | `get_table` filter returns all rows when filter_value doesn't match any skill_name — agent retries multiple times wasting tokens | Medium | Scenario 1 |
| 2 | Structured reasoner format violation (plain text instead of JSON) — auto-recovers but wastes a turn | Low | Scenario 1 |

## Infra Fixes Applied

| Fix | Commit |
|-----|--------|
| Tape store timeout: 5s → 30s | `8b9d0bf` |
| Finch pool size: 1 → 5 | uncommitted (config/config.exs) |

---

## Recommended Test Order

1. **Scenario 8** (load → edit → save) — validates the full CRUD loop
2. **Scenario 2** (multi-role select) — validates the key new feature
3. **Scenario 4** (from scratch, one role) — validates generate-workflow still works
4. **Scenario 6** (template as reference) — validates reference-workflow
5. **Scenario 10** (access control) — security check
6. Remaining scenarios as time permits
