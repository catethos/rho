# Enhance Imported Framework

Prerequisites: data already exists in the spreadsheet (from import or previous generation).

## Step 1: Assess Current State

Call `get_table_summary` to understand what's in the spreadsheet. Then `get_table` to examine the data.

Identify gaps:
- Skills with missing proficiency levels (level=0 or no level rows)
- Weak or vague behavioral indicators
- Missing categories or clusters
- Inconsistent naming

Report findings to the user.

## Step 2: Propose Enhancements

Based on the gap analysis, propose what to improve:
- **Add proficiency levels** — generate Dreyfus-model levels for skills that lack them
- **Strengthen indicators** — rewrite vague descriptions using quality-rubric.md standards
- **Fill gaps** — suggest missing competencies based on the domain
- **Standardize** — align naming conventions, merge duplicates

Get user approval before proceeding.

## Step 3: Execute Enhancements

**For proficiency level generation:**
1. Read current data via `get_table`
2. Collect skills needing levels into a JSON array with metadata (skill_name, category, cluster, skill_description, role)
3. Call `generate_proficiency_levels(skills_json: "[...]")` — generates all levels in parallel server-side
4. Clean up placeholder rows (level=0)

**For indicator improvement:**
- Use `update_cells` to rewrite specific level_description values
- Follow the quality rubric: observable verbs, specific context, non-overlapping levels

**For gap filling:**
- Use `add_rows` for new skills
- Propose additions before adding

## Step 4: Report

Summarize what was enhanced: skills updated, levels added, indicators improved.
