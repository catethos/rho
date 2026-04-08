# Welcome Flow — Data-Aware Greeting with Capability Summary

**Date:** 2026-04-08
**Branch:** `skill_framework`

---

## Problem

When a user opens the spreadsheet editor, the agent either:
1. Says nothing useful until the user asks "what can you do?" or "search frameworks?"
2. Improvises a generic greeting without checking what the company already has

The user has to discover the agent's capabilities through trial and error, and has no idea what data already exists for their company.

## User Stories

**As a returning HR user (bank_abc):**
> I open the editor and immediately see: "bank_abc has 2 role frameworks: Data Scientist (26 skills), Risk Analyst (31 skills). I can help you create new ones, edit existing, browse industry templates, or import from files. What would you like to do?"
> 
> I don't need to ask "what frameworks do I have" or "what can you do" — it's right there.

**As a new HR user (new_company):**
> I open the editor and see: "Welcome! No skill frameworks yet for new_company. I can help you get started — browse industry templates like the Malaysian Financial Sector framework (157 roles), create a role framework from scratch, or import from Excel/CSV. What would you like to do?"
> 
> I immediately know my options without guessing.

**As any user, after new tools are added:**
> The capabilities section stays accurate because the agent derives it from the SKILL.md intent table, which we update with every feature. No hardcoded list to go stale.

## Solution

Update the SKILL.md Welcome intent to define a structured first-message flow. No new tools, no schema changes, no code.

---

## Design

### Welcome Flow (first message, empty spreadsheet)

When the agent detects a first message with an empty spreadsheet, it should:

1. **Call `list_frameworks`** (no type filter) to get all frameworks visible to this company
2. **Separate results** into:
   - Company frameworks: where `type == "company"` and `company_id` matches
   - Industry templates: where `type == "industry"`
3. **Present a greeting** based on what was found:

#### Case A: Company has frameworks

```
Welcome! Here's what bank_abc has:

**Your role frameworks:**
- Data Scientist (26 skills, 130 proficiency levels)
- Risk Analyst (31 skills, 153 proficiency levels)

**Industry templates available:**
- FSF Malaysian Financial Sector (157 roles)

I can help you:
- Load and edit an existing framework
- Create a new role framework (from scratch or using industry templates)
- Browse industry template roles to find relevant skills
- Import from Excel, CSV, or PDF files
- Generate AI proficiency levels for your skills

What would you like to work on?
```

#### Case B: Company has no frameworks

```
Welcome! No skill frameworks yet for new_company.

**Industry templates available:**
- FSF Malaysian Financial Sector (157 roles)

I can help you get started:
- Browse industry template roles to find relevant skills for your company
- Create a new role framework from scratch
- Import an existing framework from Excel, CSV, or PDF

What would you like to do?
```

#### Case C: "What can you do?" (any time, not just welcome)

The agent should answer by introspecting the intent detection table — this is the current behavior and it works well. No change needed. The SKILL.md intent table IS the source of truth for capabilities.

### What the Welcome intent does NOT do

- Does NOT compute a company skill library (that's a future feature)
- Does NOT auto-load any framework — just presents the summary
- Does NOT show skill-level detail — just role names and counts
- Does NOT change the system prompt in `.rho.exs` — the welcome logic lives entirely in SKILL.md

### Capability list maintenance

The "I can help you:" list in the welcome message is **part of the SKILL.md prompt**, not hardcoded in code. When we add new features (like we added `merge_roles` yesterday), we update the SKILL.md intent table AND the welcome capability list in the same commit. This keeps them in sync.

The capability list should be **user-facing language** (not tool names):
- "Load and edit an existing framework" (not `load_framework`)
- "Generate AI proficiency levels" (not `generate_proficiency_levels`)
- "Browse industry template roles" (not `search_framework_roles`)

---

## Files to Change

| File | Action | What |
|------|--------|------|
| `.agents/skills/framework-editor/SKILL.md` | Modify | Replace Welcome intent row with detailed flow. Add capability summary section. |

That's it. One file change.

---

## PM Review: Flow Validation

| Scenario | User sees | Next likely action | Supported? |
|----------|-----------|-------------------|------------|
| New user, no data | "No frameworks yet. Browse templates, create, or import." | Browse templates | Yes — Browse templates intent |
| Returning user, has data | "You have 2 frameworks: DS, RA. Load, edit, create, or browse." | "Load risk_analyst_2026" | Yes — Load company intent |
| User asks "what can you do?" | Agent introspects tools + intents | Any intent | Yes — current behavior |
| User uploads file immediately | File handling kicks in, welcome is skipped | Import/Reference/Enhance | Yes — file intents take priority |
| User types a role name first message | Generate intent matches | Generate workflow | Yes — "No files, describes role" intent |

### Edge cases

| Case | Behavior |
|------|----------|
| Company has 10+ frameworks | Show first 5, say "and 5 more. Say 'show all' for the full list." |
| No industry templates in DB | Skip the "Industry templates available" section |
| User is admin | Same welcome, but save-as-template capability mentioned |
| User ignores welcome, asks something specific | Normal intent detection takes over — welcome is not blocking |

---

## Engineering Review

**Risk: None.** This is a SKILL.md prompt change only. No code, no schema, no tools. If the welcome message is bad, we just edit the markdown.

**Testing:** Manual — open `?company=bank_abc` (has data) and `?company=new_co` (no data), verify the greeting.

**Rollback:** Revert the SKILL.md change.
