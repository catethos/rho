# Skill Framework — Product Flow Analysis

## Current Product Problems (from SC Feedback)

### Problem 1: Role-Skill Link Lost on Accumulation

**What happens today:**
1. HR gives JD for "Risk Analyst" → AI generates skills → user picks top 6 → saved to company skill framework
2. HR gives JD for "Data Engineer" → AI generates skills → user picks top 6 → ADDED to same company framework
3. After 20 roles → company framework has 100+ skills in a flat bag
4. User goes to Role Creation page for "Risk Analyst" → system re-matches JD against 100+ skills → recommends DIFFERENT skills than the original 6

**Root cause:** The system stores skills in a flat company collection but does NOT store which skills were selected for which role. When the user returns to set up the role, the system re-matches from scratch and gets different results.

**What should happen:** When user picks 6 skills for "Risk Analyst", store BOTH:
- The skills in the company library
- The role-skill link: "Risk Analyst → [these 6 skills] at [these proficiency levels]"

When the user returns to Role Creation, look up the stored link — don't re-match.

**Note:** See Er's proposed fix is correct: "on role creation page, instead of AI recommend and match the skills from the Skill Framework to the same JD, should actually based on same JD, directly give the list of skills from the Skill Framework that the user already pre-selected when AI generating the Skill framework at the first place."

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

## What Actually Gets Stored (ds-agents API)

Before designing the product flow, we need to understand what the backend supports:

### Collections API — The Only Storage Layer

```
POST /collections/{type}/{id}/skills — store skills
GET  /collections/{type}/{id}/skills — retrieve skills
```

Two collection types:
- `"framework"` — industry/shared frameworks (e.g., `framework/AICB`)
- `"organization"` — company-specific libraries (e.g., `organization/pulsifi`)

Each skill stored:
```json
{
  "name": "Risk Management",       // required
  "description": "Ability to...",   // required
  "code": "RISK_001",              // optional, unique within collection
  "category": "Technical",          // optional
  "cluster": "Finance",            // optional
  "metadata": {}                    // optional, free-form JSON
}
```

**What is NOT stored:**
- Proficiency level definitions (can be put in `metadata` JSON, but no first-class support)
- Role-skill mapping (which skills a role needs)
- Required proficiency level per role
- Who selected which skills

### Framework Generation API — Creates Skills + Proficiency Levels

```
POST /framework/generate — AI generates full framework (async 3-phase)
POST /framework/proficiencies — generate proficiency levels for existing skills
GET  /framework/status/:job_id — poll for results
```

This generates skills with proficiency levels, but the proficiency data is returned to the caller — it's NOT automatically stored in a collection. The caller must take the output and POST it to the Collections API separately.

### Match API — Suggests Skills for a JD

```
POST /collections/{type}/{id}/match — match JD to skills in a collection
```

Input: job description text + which collection to search
Output: matched_skills (from collection) + unmatched_skills (in JD but not in collection)

### What Does NOT Exist

- **No Role entity** — no `/roles` endpoint, no role table
- **No role-skill mapping** — no way to store "Risk Analyst needs skills A, B, C"
- **No proficiency storage** — proficiency levels aren't first-class in collections
- **No company scoping** — `collection_id` is free-form, no access control

---

## The Correct Product Flow (Three Phases)

### Phase 1: Skill Library Creation

**Goal:** Build the company's master skill library — a catalogue of all skills the organization cares about, each with proficiency level definitions.

**Who:** HR Admin / L&D Manager / Talent Team

**When:** One-time setup + periodic updates

**How it works today (current product):**
1. User gives a role JD
2. AI generates skills for that role
3. User selects top 6
4. Skills added to company framework (accumulative)
5. Repeat for each role

**The problem with "accumulative":** Skills pile up without role context. The company framework becomes a flat bag of 100+ skills where nobody knows which skills belong to which role.

**How it SHOULD work:**
1. User gives a role JD (or uploads a file, or picks an industry template)
2. AI generates skills
3. User reviews and edits (this is where the spreadsheet editor shines)
4. Skills saved with role context preserved (Phase 2 link)
5. Company library = union of all role frameworks, de-duplicated

### Phase 2: Role-Skill Selection

**Goal:** For a specific role, define which skills are required and at what proficiency level.

**Who:** Hiring Manager / HR Admin

**When:** Per role (when creating/updating a job)

**How it should work:**
1. User selects a role (or gives JD)
2. System shows skills already linked to this role (from Phase 1)
3. User can adjust: add/remove skills, change required levels
4. Mapping stored: `{role, skill_code, required_level}`

**The key insight from SC feedback:** Phase 2 should NOT re-match from scratch. It should return the EXACT skills the user selected during Phase 1.

### Phase 3: Candidate Assessment

**Goal:** Score candidates against role requirements.

**How it works:** Assessment API takes `required_skill[]` (from Phase 2 mapping) + `observation_data[]` (from tests/interviews) → returns probability scores.

---

## De-Duplication: When Same Skill Name Appears Across Roles

This is more nuanced than "just de-duplicate by name." Three distinct cases:

### Case 1: Same skill, same definition, different roles

**Example:** "Communication" appears for both "Data Analyst" and "Project Manager." Both roles define it the same way: "Ability to convey information clearly to stakeholders."

**What should happen:**
- ONE entry in company library
- BOTH roles reference it
- Data Analyst requires Level 2, Project Manager requires Level 4
- The required level is per-role, NOT per-skill

**Why this is fine:** The skill definition is universal. The proficiency levels (Level 1-5 descriptions) are the same. Only the REQUIRED level differs by role.

### Case 2: Same skill name, DIFFERENT definitions, different roles

**Example:** "Python Programming" for Data Analyst vs Data Engineer:
- DA: "Using Python for statistical analysis, pandas, scikit-learn"
- DE: "Building distributed data pipelines, Spark, Airflow"

**What should happen:** The agent asks:
- "Both roles need 'Python Programming' but with different focus areas. Options:"
  - A) Keep one generic definition that covers both contexts
  - B) Create two variants: "Python (Analytics)" and "Python (Engineering)"
  - C) Keep the first definition, adjust the second role's requirements

**Why this matters:** If stored as one skill, the proficiency level descriptions may not fit both contexts. Level 3 for analytics Python is very different from Level 3 for engineering Python.

### Case 3: Same role, same skill, created at different times (user forgot)

**Example:** HR admin created "Data Analyst" framework in January (8 skills). In December, she opens a new session and says "Create a skill framework for Data Analyst."

**What should happen:**
1. Agent checks if data already exists in spreadsheet → if empty, can't detect
2. IF connected to collections API: agent queries `GET /collections/organization/{company}/skills` → finds existing skills → alerts user
3. Agent: "I found an existing Data Analyst framework from January with 8 skills: [list]. Do you want to:"
   - **Update** — modify the existing framework (add skills, edit descriptions)
   - **Start fresh** — generate new, discard old
   - **Compare** — generate new alongside old, let you pick the best from each

**Current limitation:** Without collections API connection, the spreadsheet editor can only detect duplicates within the CURRENT session. Cross-session duplicate detection requires API integration (future feature).

### Case 4: Industry framework import + company customization

**Example:** Company imports FSF (160 skills). Then HR says "For OUR Data Analyst role, I want to modify 3 of these skill descriptions."

**What should happen:**
- Original FSF skills stored as `framework/FSF` (read-only reference)
- Company's customized version stored as `organization/{company}` (editable)
- Modifications tracked: "Risk Management (customized from FSF)"
- Original FSF definitions preserved for benchmarking

---

## How the Spreadsheet Editor Helps Phase 1

The spreadsheet editor handles ALL Phase 1 input scenarios:

### Scenario A: Generate from Scratch for a Single Role

**User says:** "Build me a skill framework for a Data Analyst in fintech"

**Agent flow:**
1. Intent: Generate → loads `generate-workflow.md`
2. Intake: asks domain, role, purpose, proficiency levels
3. Skeleton: generates 8 skills across 5 categories → user reviews
4. Proficiency: delegates to sub-agents → 8 × 5 = 40 rows

**Example output:**
```
Category: Technical Skills
  Cluster: Programming
    Skill: Python Programming
      Level 1 (Novice): Writes basic scripts following tutorials and documentation
      Level 2 (Developing): Builds data pipelines for routine ETL tasks independently
      Level 3 (Proficient): Designs modular Python applications with testing and CI/CD
      Level 4 (Advanced): Architects scalable data platforms, mentors junior analysts
      Level 5 (Expert): Pioneers novel data engineering patterns adopted org-wide
```

**What this produces:** A role-specific skill framework (8 skills with proficiency definitions). When stored, this would go to the company library AND create a role-skill link for "Data Analyst."

### Scenario B: Import Existing Company Framework from Excel

**User says:** "Here's our current framework" [uploads competency_framework_2025.xlsx]

**Agent flow:**
1. Intent: Import → loads `import-workflow.md`
2. Parses Excel: 4 sheets, 200 skills, columns: Competency Area, Skill, Description, Level 1-5
3. Column mapping: "Competency Area" → category, "Skill" → skill_name
4. User confirms → imports 200 skills × 5 levels = 1000 rows
5. User reviews and edits in spreadsheet

**What this produces:** A company-wide skill library (no role associations — the uploaded Excel is a flat library).

### Scenario C: Import Industry Framework (FSF / AICB)

**User says:** "We're in banking, load the FSF framework" [uploads FSF Excel]

**Agent flow:**
1. Parses Excel → 4 sheets (How to Read, Job Roles, Skills Mapping ×2)
2. Agent: "This file has job roles AND skills. Which to import?"
3. User: "Import the skills"
4. Agent extracts 160 unique skills with categories → imports to spreadsheet
5. Agent: "160 skills imported. This file also contains role-to-skill mappings for 166 roles. I can't store role mappings in the spreadsheet, but I can note which roles use each skill in the description."

**What this produces:** An industry template skill library. The role mapping data is visible to the agent (it read the Excel) but the spreadsheet only stores the skills. Role mapping is a Phase 2 concern.

### Scenario D: Upload File as Reference, Generate New

**User says:** "Here's Google's engineering ladder. Build something similar for our startup." [uploads PDF]

**Agent flow:**
1. Parses PDF → text (prose, not tables)
2. Intent: Reference → loads `reference-workflow.md`
3. Extracts patterns: 6 levels, categories, naming style
4. Generates NEW framework adapted to startup context
5. Result: custom framework inspired by but not copied from reference

### Scenario E: Import + Enhance (Add Proficiency Levels)

**User says:** "Here's our skill list, no proficiency levels yet" [uploads CSV]

**Agent flow:**
1. Parses CSV → 30 skills, no level columns
2. Imports with level=0 (placeholder)
3. Agent: "30 skills imported, no proficiency levels. Generate Dreyfus levels?"
4. User: "Yes" → sub-agents generate 30 × 5 = 150 descriptions

### Scenario F: Iterative Role-by-Role Building (Accumulative)

**User says:** "Start with Data Analyst skills"

**Agent flow:**
1. Generates 8 skills for Data Analyst → 40 rows in spreadsheet
2. User: "Now add Data Engineer skills"
3. Agent generates 8 skills for Data Engineer → detects overlap:
   - "Python Programming" already exists but with different description
   - "SQL" already exists with same description
   - 5 skills are new
4. Agent: "Found 2 overlapping skills:
   - 'SQL' — same definition, I'll skip the duplicate
   - 'Python Programming' — different definition. Your existing one focuses on analytics. The new one focuses on distributed systems. Options:
     a) Keep existing definition (analytics focus)
     b) Replace with new definition (engineering focus)
     c) Create two variants: 'Python (Analytics)' and 'Python (Engineering)'
     d) Merge into one broader definition covering both contexts"
5. User decides → agent updates spreadsheet

**This is the realistic flow for building a company-wide library role-by-role.**

---

## What the Spreadsheet Editor Does NOT Handle

Phase 1 concerns (library building) — **handled by spreadsheet editor.**

Phase 2 concerns (role-skill selection) — **NOT handled, different UX needed:**

| Missing Capability | Why It's Phase 2 | What's Needed |
|-------------------|------------------|---------------|
| Role-skill selection | Picking which skills a role needs from the library | Checklist/picker UI, not spreadsheet |
| Required proficiency per role | Setting "this role needs Level 3" | Role configuration interface |
| JD-to-skill matching | Suggesting skills for a JD | Match API integration |
| Multi-role comparison | "Show Data Analyst vs Data Engineer skills" | Side-by-side view |
| Role-skill mapping storage | Persisting the selection | New API endpoint needed |

Phase 3 concerns (assessment) — **handled by existing Assessment API**, once Phase 2 provides `required_skill[]`.

---

## The Real Product Question

The SC feedback reveals that the current product SKIPS Phase 2 by trying to re-derive role-skill selections from the company library at Role Creation time. This is the root cause of all the confusion.

**The fix is NOT better AI matching. The fix is: store the user's selection and return it when asked.**

The spreadsheet editor solves Phase 1 (building the library). Phase 2 (role-skill selection + storage) is a separate product feature that needs:
1. A new API endpoint for role-skill mappings
2. A role configuration UI (not a spreadsheet)
3. Integration between the library (Phase 1) and role setup (Phase 2)

---

## Summary

| Phase | What | Who | Tool | Status |
|-------|------|-----|------|--------|
| 1 | Build skill library | HR Admin / L&D | Spreadsheet Editor | Demo ready |
| 2 | Select skills per role + set required levels | Hiring Manager | Role Config UI (not built) | Gap |
| 3 | Assess candidates | System | Assessment API | Exists |

| API Endpoint | Phase | Status |
|-------------|-------|--------|
| `POST /framework/generate` | 1 | Exists |
| `POST /collections/.../skills` | 1 | Exists |
| `POST /collections/.../match` | 2 | Exists (but misused as Phase 2 substitute) |
| Role-skill mapping CRUD | 2 | Does NOT exist |
| `POST /skill_assessment` | 3 | Exists |
