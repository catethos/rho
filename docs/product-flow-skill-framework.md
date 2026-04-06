# Skill Framework — Product Flow Analysis

## Current Product Problems (from SC Feedback)

### Problem 1: Role-Skill Link Lost on Accumulation

**What happens today:**
1. User gives JD for "Risk Analyst" → AI generates skills → user picks top 6 → saved to company skill framework
2. User gives JD for "Data Engineer" → AI generates skills → user picks top 6 → ADDED to same company framework
3. After 20 roles → company framework has 100+ skills in a flat bag
4. User goes to Role Creation page for "Risk Analyst" → system re-matches JD against 100+ skills → recommends DIFFERENT skills than the original 6

**Root cause:** The system stores skills in a flat company collection but does NOT store which skills were selected for which role. When the user returns to set up the role, the system re-matches from scratch and gets different results.

**What should happen:** When user picks 6 skills for "Risk Analyst," store BOTH:
- The skills in the company library (de-duplicated)
- The role-skill link: "Risk Analyst → [these 6 skills] at [these proficiency levels]"

When the user returns to Role Creation, look up the stored link — don't re-match.

### Problem 2: Inconsistent AI Generation

**What happens today:**
- User uploads a framework → AI generates skills → user edits → clicks "refresh" on one skill → gets completely different result
- Reason: the "refresh button" uses a different AI prompt than the original generation

**Root cause:** Two different endpoints with different prompts producing inconsistent results.

**Already solved:** Backend team replicated the AI prompt for the refresh button.

### Problem 3: Manual Upload Not Available

**What happens today:** No way to upload Excel/CSV/PDF of existing framework.

**Status:** Product team is building this. Our spreadsheet editor already solves this.

---

## The Three Phases of Skill Framework Management

### Phase 1: Skill Library Creation (Company-Wide)

**Goal:** Build the company's master skill library — a catalogue of all skills the organization cares about, each with proficiency level definitions.

**Who does it:** HR Admin / L&D Manager / Talent Team (one-time setup, periodic updates)

**Input sources:**
- AI generation from role descriptions
- Import from existing Excel/CSV/PDF frameworks
- Industry templates (FSF, SFIA, O*NET)
- Manual creation

**Output:** A company skill library stored in `organization/{company_id}` collection. Each skill has: name, description, category, cluster, and proficiency level definitions (metadata).

**De-duplication at this level:** By skill name within the company. If "Data Analysis" already exists and a new role also generates "Data Analysis," the library doesn't get a duplicate. BUT — the descriptions and proficiency definitions may differ (see De-duplication section below).

### Phase 2: Role-Skill Selection (Per Role)

**Goal:** For a specific role, select which skills from the company library are required, and at what proficiency level.

**Who does it:** Hiring Manager / HR Admin (per role)

**Input:** Role JD or role name

**Output:** A role-skill mapping:
```
Role: "Risk Analyst"
Required skills:
  - Risk Management (Level 4)
  - Data Analysis (Level 3)
  - Regulatory Compliance (Level 3)
  - Financial Modeling (Level 4)
  - Communication (Level 2)
  - Problem Solving (Level 3)
```

**This is the missing piece in the current product.** The mapping is not stored anywhere.

### Phase 3: Candidate Assessment (Per Candidate)

**Goal:** Score how well a candidate matches a role's skill requirements.

**Who does it:** System (automated) after observations are collected

**Input:** Role's required_skills (from Phase 2) + candidate observation scores

**Output:** Probability score per skill + overall match score

---

## How the Spreadsheet Editor Helps Phase 1

The spreadsheet editor handles ALL Phase 1 scenarios. Here are concrete examples:

### Scenario A: Generate from Scratch for a Single Role

**User says:** "Build me a skill framework for a Data Analyst in fintech"

**Flow:**
1. Agent activates `framework-editor` skill → intent: Generate
2. Agent loads `generate-workflow.md` → asks intake questions
3. User confirms: 5 categories, Dreyfus proficiency model, 5 levels
4. Agent generates skeleton: 8 skills across 5 categories
5. User reviews: "Add Python Programming, remove Excel" → agent adjusts
6. Agent delegates proficiency generation to sub-agents
7. Result: 8 skills × 5 levels = 40 rows in spreadsheet

**Example output:**
```
Category: Technical Skills
  Cluster: Programming
    Skill: Python Programming
      Level 1 (Novice): Writes basic scripts following tutorials...
      Level 2 (Developing): Builds data pipelines for routine ETL tasks...
      Level 3 (Proficient): Designs modular Python applications with testing...
      Level 4 (Advanced): Architects scalable data platforms, mentors juniors...
      Level 5 (Expert): Pioneers novel data engineering patterns adopted org-wide...
```

### Scenario B: Import Existing Company Framework from Excel

**User says:** "Here's our current framework" [uploads competency_framework_2025.xlsx]

**Flow:**
1. Backend parses Excel → 4 sheets, 200 skills, columns: Competency Area, Skill, Description, Level 1-5
2. Agent activates `framework-editor` skill → intent: Import
3. Agent loads `import-workflow.md` → reads file data
4. Agent proposes column mapping: "Competency Area" → category, "Skill" → skill_name, etc.
5. User confirms → agent imports 200 skills × 5 levels = 1000 rows
6. User reviews: "Merge 'Communication' and 'Business Communication' — they're the same"
7. Agent updates spreadsheet

### Scenario C: Import Industry Framework (FSF / AICB)

**User says:** "We're in banking, load the FSF framework" [uploads FSF-Job-Roles-and-Skills_Master-Database.xlsx]

**Flow:**
1. Backend parses Excel → 4 sheets including "Skills to Job Roles Mapping" (160 skills)
2. Agent asks: "This file has 4 sheets. Which ones should I import?"
   - "How to Read" (instructions) — skip
   - "Job Roles" (166 roles) — useful for reference
   - "Skills to Job Roles Mapping" (160 skills × 166 roles) — the skill data
   - "Job Roles to Skills Mapping" (transposed) — same data
3. User: "Import the skills from 'Skills to Job Roles Mapping'"
4. Agent extracts unique skills with categories → imports to spreadsheet
5. Agent: "I found 160 skills across 8 categories. The role mapping data is available but our spreadsheet stores the skill library only. Shall I note the role associations in the skill descriptions?"

**Note:** The role-skill mapping from FSF is Phase 2 data. The spreadsheet editor handles Phase 1 (the skill library). Phase 2 (which of these 160 skills apply to "Risk Analyst" specifically) needs a different interface.

### Scenario D: Upload File as Reference, Generate New Framework

**User says:** "Here's what Google uses for their engineering ladder. Build something similar for our startup." [uploads google_eng_ladder.pdf]

**Flow:**
1. Backend parses PDF → extracted text (prose, no clean tables)
2. Agent activates `framework-editor` skill → intent: Reference
3. Agent loads `reference-workflow.md` → reads PDF content
4. Agent: "I see Google uses 6 levels (L3-L8) with categories: Technical Leadership, System Design, Coding, Communication. I'll adapt this for a startup context — fewer levels (4), more emphasis on versatility."
5. User confirms approach → agent generates new framework inspired by reference
6. Result: Custom framework, not a copy

### Scenario E: Import + Enhance (Add Proficiency Levels to Bare Framework)

**User says:** "Here's our skill list, but we don't have proficiency levels yet" [uploads skills_list.csv]

**Flow:**
1. Backend parses CSV → 30 skills, columns: Category, Skill Name, Description (no levels)
2. Agent activates `framework-editor` skill → intent: Import + Enhance
3. Agent imports 30 skills with level=0 (placeholder)
4. Agent: "Imported 30 skills. None have proficiency levels. Want me to generate Dreyfus-model levels for all?"
5. User: "Yes, 5 levels each"
6. Agent delegates to sub-agents → generates 30 × 5 = 150 proficiency descriptions
7. Result: Complete framework with behavioral indicators

### Scenario F: Iterative Role-by-Role Building

**User says:** "Let's start with Data Analyst skills"

**Flow:**
1. Agent generates 8 skills for Data Analyst → user reviews → added to spreadsheet (40 rows)
2. User: "Now add skills for Data Engineer"
3. Agent generates 8 skills for Data Engineer → some overlap with Data Analyst
4. Agent: "3 of these skills (Python Programming, SQL, Data Pipeline Design) already exist in the spreadsheet. I'll add the 5 new ones and skip the duplicates."
5. User: "Actually, Data Engineer needs a DIFFERENT description for Python Programming — more about distributed systems"
6. Agent: "Should I update the existing Python Programming description, or create a separate entry like 'Python Programming (Data Engineering)'?"
7. User decides → agent updates spreadsheet

**This is the de-duplication question in action.** See below.

---

## De-Duplication: The Three Cases

### Case 1: Same skill, different roles, added at the same time

**Situation:** User builds framework for 3 roles in one session. Both Data Analyst and Data Engineer need "Python Programming."

**Question:** Is this one skill or two?

**Answer: It depends on whether the proficiency definitions differ.**
- If both roles define "Python Programming" the same way (same description, same level definitions) → ONE entry in the library. Each role just references it at a different required level.
- If the roles need DIFFERENT definitions (DA: "statistical scripting", DE: "distributed systems") → TWO entries, disambiguated: "Python Programming (Analytics)" and "Python Programming (Engineering)"

**What the agent should do:**
1. Detect the name collision
2. Compare descriptions
3. If similar → "Python Programming already exists. Both roles can use it. Data Analyst requires Level 3, Data Engineer requires Level 4."
4. If different → "Both roles need 'Python Programming' but with different definitions. Should I create two variants, or merge into one broader definition?"

### Case 2: Same skill, same role, different time (user forgot)

**Situation:** HR admin created Data Analyst framework in January. In December, she starts creating it again.

**Question:** How does the system detect this?

**Answer: The agent should check existing data before generating.**
1. User: "Create a skill framework for Data Analyst"
2. Agent calls `get_table_summary` → sees 40 rows already exist
3. Agent: "I see an existing framework with 8 skills (40 rows with proficiency levels). Categories: Technical Skills, Analytical Skills, Communication. 
   - Want me to **update** it (add/modify skills)?
   - Want me to **start fresh** (replace everything)?
   - Want me to **merge** (generate new, compare with existing, keep the best of both)?"
4. User decides

**If the spreadsheet is empty** (fresh session), the agent can't detect prior frameworks because the data isn't persisted across sessions. This detection only works if:
- The existing framework is loaded into the spreadsheet first (from the collections API)
- Or the agent checks the collections API directly (future feature)

### Case 3: Same skill name, completely different context

**Situation:** "Communication" in a nursing framework vs "Communication" in a software engineering framework.

**Question:** Are these the same skill?

**Answer: No.** The proficiency definitions are completely different:
- Nursing: "Communicates patient status using SBAR protocol"
- Engineering: "Documents technical decisions in ADRs and presents to stakeholders"

**What the agent should do:** These are in different company frameworks, so they don't collide. If they're in the SAME company framework (unlikely but possible for a healthcare + tech company), disambiguate: "Communication (Clinical)" vs "Communication (Technical)".

---

## What the Spreadsheet Editor Does NOT Handle (Phase 2)

The spreadsheet editor is designed for **building the skill library** (Phase 1). It does NOT handle:

1. **Role-skill selection** — picking which skills from the library apply to a specific role
2. **Required proficiency per role** — setting "this role needs Level 3 for Risk Management"
3. **JD-to-skill matching** — suggesting skills for a job description (this is the Match API)
4. **Multi-role view** — "show me Data Analyst skills vs Data Engineer skills side-by-side"

These are Phase 2 concerns that need a different UX (likely a role configuration interface, not a spreadsheet). The spreadsheet is great for bulk editing skill definitions and proficiency levels, but role-skill selection is better served by a checklist/picker interface where the user sees the company library and checks off what applies.

---

## Summary: Where Each Piece Lives

| Capability | Tool | Status |
|-----------|------|--------|
| Generate skill framework from scratch | Spreadsheet Editor (Rho) | Done |
| Import from Excel/CSV/PDF | Spreadsheet Editor (Rho) | Done |
| Import industry template (FSF/AICB) | Spreadsheet Editor (Rho) | Done |
| Use file as reference for generation | Spreadsheet Editor (Rho) | Done |
| Enhance framework (add proficiency levels) | Spreadsheet Editor (Rho) | Done |
| De-duplication on iterative building | Spreadsheet Editor (agent logic) | Partial (agent checks existing data) |
| Store to company collection | Collections API (ds-agents) | Exists, not connected |
| Match JD to stored skills | Match API (ds-agents) | Exists, not connected |
| Role-skill mapping + required levels | Not built | Phase 2 gap |
| Candidate assessment scoring | Assessment API (ds-agents) | Exists |
