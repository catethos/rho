# Skill Framework Editor — Demo Script

**Date:** 2026-04-14
**Duration:** ~20 min (3 sessions)
**Audience:** Leadership, PM, UX/UI, DE, BE, DS
**URL:** `localhost:4001/spreadsheet?company=demo_corp`
**Model:** Haiku 4.5

---

## Story

You are an HR Admin at **demo_corp**. You just registered on the platform. Over the next few days, you use the AI assistant to build your company's competency frameworks from zero — first by leveraging industry standards, then building from scratch, then importing from Excel.

---

## Pre-Demo Checklist

- [ ] FSF industry template is in the DB (backend pre-loads, never deleted)
- [ ] `~/Downloads/test_framework_import.xlsx` ready for upload
- [ ] DB has no `demo_corp` data (fresh company)
- [ ] Server running: `RHO_WEB_ENABLED=true mix run --no-halt`
- [ ] Open `localhost:4001/spreadsheet?company=demo_corp` in browser
- [ ] Spreadsheet panel (left) and chat panel (right) both visible

---

## Session 1: "Day 1 — I just signed up, I have nothing"

> **Theme:** Leverage industry standards. Don't start from zero.

### Flow

| # | You type | What the AI does | Narration notes |
|---|----------|-----------------|-----------------|
| 1 | **"Hey?"** | Calls `get_company_overview` — finds empty company. Greets you, explains capabilities: browse industry templates, create from scratch, import Excel. | "First time experience — the AI guides the user on what's possible." |
| 2 | **"I want to create a skill framework for Risk Analyst, but I don't really know where to start. Can you check the FSF framework to see if there's any closest role I can refer to?"** | Calls `list_frameworks` → finds FSF (157 roles). Calls `search_framework_roles` → shows top matches: Credit Risk (35 skills), Risk Modelling (34 skills), etc. with sample skills. | "157 roles in the industry framework, but we don't dump all 25k rows. The AI browses a directory and shows you what's relevant." |
| 3 | **"I think Credit Risk looks closest. Can you load it into the spreadsheet?"** | `load_framework_roles` → ~170 rows stream into the spreadsheet. Grouped by cluster in role view. | **Wow moment** — rows streaming in live. "Loaded only 1 role out of 157. The relevant skills, not everything." |
| 4 | **"Can we rename the role to Risk Analyst?"** | `update_cells` → all rows renamed to Risk Analyst. | "Customizing the industry template for your company." |
| 5 | **"Hmm, I think Carbon Markets and Climate Change are not relevant for us. Can you remove them?"** | `delete_by_filter` → removes those skills and their proficiency rows. | "Human in the loop — the AI doesn't decide what's relevant, you do." |
| 6 | **"I think this looks good. Can we save it?"** | `save_framework(mode: "plan")` → shows: Risk Analyst 2026 v1, new, will be set as default (first version). Asks for confirmation. | "Two-phase save — shows you the plan before committing. Versioned." |
| 7 | **"Yes"** | `save_framework(mode: "execute")` → saved. | "v1 saved, auto-set as default. Scoped to demo_corp — no other company can see it." |

### Key points for each audience
- **Leadership:** "Minutes instead of weeks. Industry standards as starting point."
- **PM/UX:** "Guided flow — user never feels lost. Browse, pick, customize, save."
- **DE/BE:** "Browse-then-load pattern. Versioned save with company scoping. SQLite persistence."
- **DS:** "The FSF industry framework has 25k+ rows across 157 roles. Smart filtering, not brute force."

---

## Session 2: "Day 2 — I want frameworks for more roles"

> **Theme:** Build from scratch with AI. The system remembers what you've done.

### Setup
- Close the tab or refresh the page (new session, same company)
- Open `localhost:4001/spreadsheet?company=demo_corp`

### Flow

| # | You type | What the AI does | Narration notes |
|---|----------|-----------------|-----------------|
| 1 | **"Hello!"** | `get_company_overview` → shows Risk Analyst 2026 v1 (default) + FSF template available. | "The AI remembers — picks up where you left off." |
| 2 | **"I want to build skill frameworks for Risk Analyst, Data Engineer and Data Scientist"** | Agent notices Risk Analyst v1 already exists. Tells you: "Risk Analyst 2026 v1 already exists. Do you want to include it or just build DE + DS?" | **Key moment** — "The AI doesn't blindly create duplicates. It tells you what you already have." |
| 3 | **"Oh right, then just Data Engineer and Data Scientist"** | Asks intake questions: industry focus, purpose, proficiency levels, specific competencies. | "Guided intake — structures the conversation so nothing is missed." |
| 4 | **"Fintech, career pathing, 5 levels. DE should focus on payments data pipelines, DS on risk modelling and fraud detection"** | Generates skeleton: ~20 skills across both roles via `add_rows`. Shows in spreadsheet grouped by role. | "Skeleton first — review before investing in detail." |
| 5 | **"Looks good, can you generate the proficiency levels?"** | `generate_proficiency_levels` → parallel AI generation, rows stream into spreadsheet in batches. Deletes placeholder rows after. | "Server-side parallel generation — 5 Dreyfus levels per skill. Watch them stream in." |
| 6 | **"Great, can we save all?"** | `save_framework(mode: "plan")` → plan: DE 2026 v1 (new), DS 2026 v1 (new). Both will be auto-default (first version per role). | "Each role saved separately with its own version. All company-scoped." |
| 7 | **"Yes"** | Saved. | "demo_corp now has 3 role frameworks: Risk Analyst, Data Engineer, Data Scientist." |

### Key points for each audience
- **Leadership:** "Scale to entire org — role by role, each with proper versioning."
- **PM:** "AI detects existing frameworks, avoids duplicates, asks before acting."
- **DE/BE:** "Parallel LLM calls via Task.async_stream. Batched writes to spreadsheet via signal bus."
- **DS:** "Dreyfus proficiency model — 5 levels from Novice to Expert. Configurable per generation."

---

## Session 3: "Another day — I have Excel files to import"

> **Theme:** Meet clients where they are. Existing data flows in, AI fills the gaps.

### Setup
- Close the tab or refresh
- Open `localhost:4001/spreadsheet?company=demo_corp`
- Have `~/Downloads/test_framework_import.xlsx` ready to upload

### About the Excel file
- 3 sheets: Product Manager (6 skills), Data Engineer (5 skills), CEO (7 skills)
- Only 3 columns: Skill Name, Category, Description
- **No clusters, no proficiency levels** — AI will need to fill these gaps
- **Data Engineer already exists** in DB from Session 2 — triggers versioning question

### Flow

| # | You type | What the AI does | Narration notes |
|---|----------|-----------------|-----------------|
| 1 | *(Upload test_framework_import.xlsx)* **"Import this"** | Detects import intent. Reads all 3 sheets via `get_uploaded_file`. Shows summary: 18 skills across 3 roles (PM: 6, DE: 5, CEO: 7). Offers options: import as skeleton or with proficiency levels. | "Auto-detects multiple sheets, maps columns. Shows what it found before doing anything." |
| 2 | **"Import as skeleton first"** | `add_rows` → 18 rows with level=0, placeholder descriptions. Sheet name → role mapping. | "Imported as-is. User can review before AI enhancement." |
| 3 | **"Can you generate proficiency levels for all of them?"** | `generate_proficiency_levels` → 90 proficiency level rows generated (18 skills x 5 levels). Streams into spreadsheet. | "One call, all 18 skills, parallel generation. AI fills the gaps you didn't have in Excel." |
| 4 | **"Delete the placeholder rows and save everything"** | Deletes placeholder rows. Then `save_framework(mode: "plan")` → plan shows: PM v1 (new), CEO v1 (new), **DE: "already exists (v1). Create new version or update?"** | **Key moment** — "Versioning in action. DE v1 was built from scratch yesterday — now you're importing a different version from Excel. The AI asks, not assumes." |
| 5 | **"Create new versions for all"** | `save_framework(mode: "execute")` → PM 2026 v1, CEO 2026 v1, DE 2026 **v2** (new version, not default). | "v2 is a draft — the existing default is untouched until you explicitly promote it." |
| 6 | **"Can you list all the frameworks our company has?"** | `get_company_overview` → shows all roles with versions and which is default. | "Full company view — Risk Analyst, Data Engineer (2 versions), Data Scientist, Product Manager, CEO." |

### Key points for each audience
- **Leadership:** "No data left behind — existing Excel frameworks flow in seamlessly."
- **PM/UX:** "Import → enhance → save. Three steps. AI fills what's missing."
- **DE:** "Python-based parsing (openpyxl). Auto column mapping. Multi-sheet support."
- **DS:** "The AI knows when data is complete vs incomplete — adapts its workflow accordingly."

---

## If Things Go Wrong

| Issue | What to do |
|-------|-----------|
| Agent goes silent (Finch timeout) | Just type "hello?" — the loop-level retry should auto-recover now. If not, narrate: "The system auto-recovers from transient errors." |
| Agent responds in raw JSON | This is the structured reasoner format — it auto-recovers on next turn. Just continue. |
| Wrong tool call / error | Let the agent recover — it usually self-corrects. This is a feature, not a bug. |
| Slow response | Haiku 4.5 is fast. If slow, it's OpenRouter routing. Just wait. |

---

## Closing Talking Points

1. **For Leadership:** "What used to take weeks of consultant work + Excel wrangling is now a conversation. The AI doesn't replace the HR expert — it accelerates them."

2. **For PM:** "Every step is human-in-the-loop. Browse before loading, skeleton before generating, plan before saving. The user is always in control."

3. **For Engineering:** "This is built on Rho — our Elixir-based agent framework. Mount architecture for tools, signal bus for real-time UI updates, versioned persistence with company scoping. The same framework powers all our agents."

4. **For DS:** "The proficiency generation uses parallel LLM calls with a separate model (gpt-oss-120b). The main agent (Haiku 4.5) orchestrates, the generation model produces. Separation of concerns."
