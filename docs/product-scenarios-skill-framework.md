# Skill Framework AI Agent — Product Scenarios & Capability Boundaries

**Last updated:** 2026-04-14
**Status:** All scenarios tested and passing
**Model:** Claude Haiku 4.5

---

## Overview

The Skill Framework Editor is an AI-powered assistant that helps HR teams build, manage, and maintain competency frameworks through a conversational interface paired with a live spreadsheet. It supports multi-company access control, versioned saves, industry template browsing, and AI-generated proficiency levels.

---

## Data Model

Every row in the spreadsheet has these columns:

| Column | Description |
|--------|-------------|
| `role` | The job role (e.g. "Risk Analyst") |
| `category` | Broad grouping (e.g. "Power Skills", "Technical Skills") |
| `cluster` | Sub-grouping within category (e.g. "Innovation and Delivery") |
| `skill_name` | The competency name (e.g. "Critical Thinking") |
| `skill_description` | What the skill means |
| `level` | Proficiency level number (1-5) |
| `level_name` | Proficiency level label (e.g. "Novice", "Expert") |
| `level_description` | Behavioral indicators for that level |

Each skill has 5 proficiency levels (Dreyfus model: Novice → Advanced Beginner → Competent → Proficient → Expert), so **1 skill = 5 rows**.

---

## Capability Map

| Capability | What it can do | What it cannot do |
|-----------|---------------|-------------------|
| **Browse industry templates** | Search 157+ roles by keyword, shows skill counts + sample skills. Loads only selected roles, not entire framework. | Cannot search across multiple industry frameworks simultaneously (only one framework at a time). |
| **Load roles** | Load one or multiple roles from a template. Supports replace (default) and append mode (side-by-side). | No partial load within a role — loads all skills for the selected role(s). |
| **Merge roles** | Merge exactly 2 roles at a time. Deduplication is by **exact skill_name match** only. Shows plan before executing. Primary role's proficiency levels are kept for shared skills. | Cannot merge 3+ roles in one operation — must chain (merge A+B, then result+C). Dedup is exact string match — "Risk Management" and "Risk Mgmt" are treated as different skills. No semantic/fuzzy matching. |
| **Create from scratch** | AI-guided intake → skeleton generation → human review → proficiency generation. Supports single role or multiple roles in one session. | Skeleton quality depends on how specific the intake answers are. AI may generate generic skills if context is vague. |
| **Import from Excel** | Auto-detects sheets (1 sheet = 1 role). Maps columns by header name. Handles partial data (missing clusters, missing proficiency levels). | Column headers must be recognizable (e.g. "Skill Name", "Category"). Unusual headers may need manual mapping guidance. Only .xlsx and .csv supported. |
| **AI proficiency generation** | Generates 5 Dreyfus-model levels per skill. Parallel generation (batches of 6, up to 4 concurrent). Streams results into spreadsheet live. | Uses a separate LLM model (GPT-OSS-120B) — quality may vary. No guarantee of consistency across skills unless same batch. Cannot generate non-Dreyfus models (e.g. 3-level or 7-level). |
| **Edit cells** | Change any field value for any row via natural language. AI finds the correct row by skill name, level, or description. Batch rename (e.g. rename all clusters). | AI may struggle to target the exact row if skill names are ambiguous. Filtering by `level_description` text doesn't always match (exact string match required). Targeting by `skill_name` is more reliable. |
| **Delete skills** | Delete by skill name, by filter (category, cluster, role), or by row ID. Supports multi-field filters (field + field2). | Cannot undo deletes. No "soft delete" — rows are permanently removed from the spreadsheet. |
| **Versioned save** | Auto-versions per role (v1, v2...). First version auto-set as default. Two-phase: plan → approve → execute. Each role saved separately. | Cannot save multiple roles as a single "framework bundle". Cannot delete saved frameworks. Cannot rename saved frameworks after saving. Title-case normalization may change casing (e.g. "HR Manager" → "Hr Manager"). |
| **Version management** | Set any version as default. View all versions per role. Create new version or update existing (user chooses). | Cannot diff two versions. Cannot rollback to a previous version (must re-load and re-save). Cannot delete a specific version. |
| **Access control** | Company-scoped queries — companies cannot see each other's frameworks. Industry templates visible to all. | No user-level permissions (anyone with the company URL can edit). No audit log of who changed what. |

---

## Scenarios

### Scenario 1: Start from Industry Template (Single Role)

> **As an** HR admin with no existing frameworks,
> **I want to** find a relevant industry template and customize it for my company,
> **So that** I don't have to build a framework from scratch.

**Flow:**
1. User lands on the page with an empty company
2. Asks the AI to find the closest role from the industry template (e.g. FSF)
3. AI browses 157 roles and shows matching options with skill counts and sample skills
4. User picks one (e.g. "Credit Risk") → AI loads only that role (~170 rows)
5. User renames the role (e.g. "Credit Risk" → "Risk Analyst")
6. User reviews and removes irrelevant skills
7. User saves → versioned save as "Risk Analyst 2026 v1", auto-set as default

**Boundaries:**
- Browse returns role name + skill count + top 5 sample skills (not full content)
- Rename updates all rows for that role in one batch
- Each deleted skill removes 5 rows (1 per proficiency level)

---

### Scenario 2: Merge Two Roles from Template

> **As an** HR admin building a framework for a role that spans multiple domains,
> **I want to** pick and merge skills from two template roles,
> **So that** I get a comprehensive framework without manual deduplication.

**Flow:**
1. User asks AI to find roles for "Risk Analyst"
2. AI finds Credit Risk (35 skills) + Risk Modelling (34 skills) — user picks both
3. AI loads both roles into the spreadsheet (345 rows)
4. User asks to merge → AI shows merge plan: 32 shared, 3 primary-only, 2 secondary-only
5. User approves → AI executes: deletes secondary's duplicate rows, renames all to new role name
6. User removes a few irrelevant skills, saves

**How merge deduplication works:**
- Dedup is **exact `skill_name` string match** — "Risk Management" ≠ "Risk Mgmt"
- User designates a **primary** and **secondary** role
- For **shared skills** (same name in both): keeps primary's proficiency levels, deletes secondary's rows
- For **primary-only skills**: kept as-is
- For **secondary-only skills**: kept and renamed to the new role
- All remaining rows get their `role` field renamed to the new role name

**Tested example:** Credit Risk (35 skills) + Risk Modelling (34 skills) → 32 shared, 3 primary-only, 2 secondary-only → 37 unique skills, 160 duplicate rows deleted

**Boundaries:**
- Merge works on **exactly 2 roles at a time** — cannot merge 3 roles in one call
- To merge 3+ roles, chain sequential merges: merge A+B → result, then merge result+C
- Chaining was tested (Financial Analyst + Finance Analyst → then merged with Risk Analyst) — works but each merge step is independent (no cross-step dedup optimization)
- When chaining: if merged result has skills like "Budget Forecasting" (from role B) and "Budget Development & Forecasting" (from role A), these are NOT detected as duplicates because the names differ
- No semantic/fuzzy matching — skills with similar meanings but different names are treated as distinct
- No preview of proficiency level differences for shared skills — primary's levels are always kept

---

### Scenario 3: Edit Existing Framework (Load → Edit → Save)

> **As an** HR admin returning to update an existing framework,
> **I want to** load a previously saved framework, make changes, and save.

**Flow:**
1. User opens the page — AI shows existing company frameworks with versions
2. User asks to load a specific framework
3. User makes edits: remove a cluster, add a new skill, rename things
4. AI auto-generates proficiency levels for new skills
5. User saves → AI asks: "Update existing v1 or create v2?"

**Boundaries:**
- Loading replaces the current spreadsheet content (unless `append: true`)
- Added skills start as skeleton rows (level=0) until proficiency levels are generated
- Save plan shows all roles in the spreadsheet with their status (new/exists)

---

### Scenario 4: Edit Specific Cell Text

> **As an** HR admin reviewing proficiency descriptions,
> **I want to** edit the text of a specific proficiency level.

**Flow:**
1. User loads an existing framework
2. User asks to change a specific level description (e.g. "Change PL1 for Adaptability to '...'")
3. AI finds the correct row by skill_name, updates the text via `update_cells`

**How cell targeting works:**
- AI searches by `skill_name` (most reliable), then by `level` number
- Filtering by `level_description` text requires exact string match — may return empty results if text doesn't match exactly
- Can update any field: `skill_name`, `skill_description`, `category`, `cluster`, `level_name`, `level_description`, `role`
- Updates one or multiple cells per call

**Tested example:** Changed PL1 level_description for "Adaptability and Resiliency" — AI first tried filtering by description text (failed 2x), then found it by skill_name (succeeded)

**Boundaries:**
- AI targets rows by skill_name first — this is the most reliable identifier
- Exact text filters may fail if the text contains special characters or line breaks
- No bulk find-and-replace across all rows (must target specific rows)
- Changes are immediate in the spreadsheet but not persisted to DB until user saves

---

### Scenario 5: Create from Scratch (Single Role)

> **As an** HR admin with a new role not covered by templates,
> **I want to** build a framework from scratch with AI assistance.

**Flow:**
1. User asks to create a framework for a new role
2. AI asks intake questions: industry, purpose, proficiency levels, specific competencies
3. AI generates skeleton: ~20-25 skills organized by category and cluster
4. User reviews skeleton in spreadsheet, removes/edits skills
5. User approves → AI generates proficiency levels (parallel, ~5 seconds per batch of 6)
6. User saves as v1

**Boundaries:**
- Skeleton quality depends on intake specificity — "Fintech Data Engineer focused on payments" produces better results than "Data Engineer"
- AI generates 5 Dreyfus levels per skill — cannot customize to 3 or 7 levels
- Proficiency generation uses a separate model (GPT-OSS-120B) — level descriptions may vary in style
- Generation is batched (6 skills per batch, 4 concurrent) — 20 skills takes ~15 seconds

---

### Scenario 6: Create from Scratch (Multi-Role / Company-Wide)

> **As an** HR admin building frameworks for multiple roles in one session.

**Flow:**
1. User asks to build for multiple roles (e.g. "Product Manager, Data Engineer, Data Scientist")
2. AI checks existing frameworks — tells user if any role already exists
3. User confirms which to build
4. AI generates skeleton for all roles, generates proficiency levels per role
5. User saves all → each role saved separately with own version

**Boundaries:**
- AI detects existing roles and warns — does NOT silently overwrite
- Each role is saved independently (separate framework ID, separate version number)
- First version of any role is auto-set as default
- When saving roles that already exist, user must choose: update existing or create new version

---

### Scenario 7: Use Template as Reference (Not Direct Load)

> **As an** HR admin who wants inspiration from templates but not a copy.

**Flow:**
1. User asks to build a framework "using FSF as reference"
2. AI browses template, user picks a reference role
3. AI generates NEW skills inspired by the template (not copied)
4. User can load the reference side-by-side (append mode) for comparison
5. User can move skills between roles via `update_cells`, then delete the reference role

**Boundaries:**
- "Reference" means the AI sees the template's structure but generates original skills
- Moving skills between roles = changing the `role` field on selected rows
- Side-by-side requires append mode — both roles share the same spreadsheet
- Deleting the reference role removes all its rows from the spreadsheet (not from the DB template)

---

### Scenario 8: Import from Excel (Partial Data)

> **As an** HR admin with existing skill lists in Excel (no proficiency levels).

**Flow:**
1. User uploads an Excel file with multiple sheets (one per role)
2. AI reads all sheets, auto-maps columns
3. AI imports as skeleton rows, user reviews
4. User asks AI to generate proficiency levels, then saves

**Boundaries:**
- Supported columns: Skill Name (required), Category, Cluster, Description, Level, Level Name, Level Description, Role
- Sheet name is used as role name if no Role column
- If clusters are missing, AI can suggest and batch-assign cluster names
- Maximum file size: 10MB, formats: .xlsx, .csv, .pdf
- Up to 10 files per upload

---

### Scenario 9: Import from Excel (Complete Data)

> **As an** HR admin with a fully structured Excel file.

**Flow:**
1. User uploads Excel with all 8 columns filled
2. AI detects complete data — imports directly via `replace_all`
3. User saves → 100% data fidelity verified

**Boundaries:**
- All 8 columns must be present and recognizable
- Data is imported as-is — no AI modification or generation
- 100% fidelity: tested with 25 rows, every field matched source Excel exactly
- Minor issue: role names get title-case normalized on save (e.g. "HR Manager" → "Hr Manager")

---

### Scenario 10: Access Control (Multi-Company)

> **As a** platform operator serving multiple companies.

**Flow:**
1. Company A builds and saves frameworks at `?company=company_a`
2. Company B opens `?company=company_b` — cannot see Company A's data
3. Industry templates (FSF) visible to all companies

**Boundaries:**
- Scoping is by URL parameter `?company=xxx` — no authentication layer
- All queries (list, load, save, overview) are filtered by company_id
- Industry templates have `company_id = NULL` — visible to everyone
- Admin access via `?company=pulsifi_admin` — can save industry templates
- No user-level permissions within a company

---

### Scenario 11: Set Default Version

> **As an** HR admin promoting a draft version to default.

**Flow:**
1. User asks to set a specific version as default
2. AI calls `set_default_version` — atomically swaps default flag

**Boundaries:**
- Only one default per role per company (transactional swap)
- Non-default versions remain accessible but are "drafts"
- No way to "unset" a default without setting another version as default

---

## Detailed Capability Boundaries

### Merge — Critical Details for Scoping

| Aspect | Current Behavior | Implication |
|--------|-----------------|-------------|
| Roles per merge | Exactly 2 | To merge 3+ roles, must chain: A+B → AB, then AB+C. Each step is a separate plan/execute. |
| Dedup method | Exact `skill_name` string match | "Risk Management" and "Risk Mgmt" are NOT deduplicated. No fuzzy/semantic matching. |
| Conflict resolution | Primary role wins for shared skills | User cannot choose which role's proficiency levels to keep per-skill — it's all-or-nothing from primary. |
| Chained merge dedup | Each merge step is independent | After merging A+B, if result has "Budget Forecasting" (from B) and "Budget Development & Forecasting" (from A), these remain as separate skills. |
| Plan visibility | Shows shared/primary-only/secondary-only skill names | Does not show the proficiency level differences for shared skills. |
| Merge output | All rows renamed to new role name | Original role names are lost in the spreadsheet (but preserved in DB if saved before merge). |

### Save — Critical Details for Scoping

| Aspect | Current Behavior | Implication |
|--------|-----------------|-------------|
| Save granularity | Per-role | Each role in the spreadsheet is saved as a separate framework. Cannot bundle multiple roles into one "framework". |
| Version numbering | Auto-incremented per company+role+year | Same role in different years = separate version sequences. |
| Existing detection | By company_id + role_name | AI asks "update or create new version" — never silently overwrites. |
| Default logic | First version = auto-default. Subsequent = draft. | Users must explicitly promote drafts via `set_default_version`. |
| Year handling | AI may default to wrong year | User sometimes needs to correct (e.g. "should be 2026 not 2025"). |
| Delete | Not supported | No way to delete a saved framework or version. |

### Edit — Critical Details for Scoping

| Aspect | Current Behavior | Implication |
|--------|-----------------|-------------|
| Cell targeting | AI searches by skill_name (reliable) or description text (unreliable) | Exact string filter on level_description may fail. Skill_name filtering is preferred. |
| Batch edits | AI can update multiple cells per call, rename all rows in a role | Efficient for bulk renames. |
| Undo | Not supported | All edits are immediate. No way to revert except re-loading from DB. |
| Persistence | Edits are in-memory until saved | Refreshing the page loses unsaved edits. |

### Import — Critical Details for Scoping

| Aspect | Current Behavior | Implication |
|--------|-----------------|-------------|
| File formats | .xlsx, .csv, .pdf | PDF support uses pdfplumber (best-effort parsing). |
| Sheet handling | Each sheet = one role | Single-sheet files with a "Role" column are also supported. |
| Column mapping | By header name recognition | Must use standard-ish names. Custom headers need user guidance. |
| Missing data | AI fills gaps (clusters, proficiency levels) | Cluster assignment is AI-generated — may not match company taxonomy. |
| Data fidelity | 100% for complete imports | Verified field-by-field with 25-row test file. |

---

## Not Supported (Current Limitations)

| Feature | Status | Notes |
|---------|--------|-------|
| Delete saved framework | Not supported | No delete tool exists |
| Undo/redo edits | Not supported | Must re-load from DB |
| Version diff | Not supported | Cannot compare two versions side-by-side |
| Version rollback | Not supported | Must re-load old version and re-save |
| Semantic merge dedup | Not supported | Only exact skill_name match |
| 3+ role merge in one call | Not supported | Must chain 2-role merges |
| Custom proficiency levels (non-5) | Not supported | Always generates 5 Dreyfus levels |
| User authentication | Not supported | Company access is URL-based only |
| Audit trail | Not supported | No record of who changed what |
| Framework deletion | Not supported | Once saved, cannot be removed |
| Non-English content | Untested | AI may generate English regardless of input language |
| Concurrent editing | Not tested | Multiple users on same company URL not tested |
| Export to Excel | Not supported | Can only import, not export |

---

## Architecture Summary (for Engineering reference)

- **Agent model:** Claude Haiku 4.5 (fast, accurate instruction following)
- **Proficiency generation model:** GPT-OSS-120B (parallel, cost-effective)
- **UI:** Phoenix LiveView — two-panel layout (spreadsheet + chat), resizable divider
- **Persistence:** SQLite with Ecto, versioned per role per company
- **Communication:** Signal bus for real-time spreadsheet updates, sync messages for reads
- **Access control:** Company ID scoping on all queries, passed from URL to agent context
