# Use Reference to Build New Framework

The reference is NOT imported directly — it's used as context to inform a NEW framework.

**CRITICAL: Do NOT call `load_framework` or `load_framework_roles`.** The goal is to generate new skills inspired by the reference, not copy them.

## Two Reference Sources

### A. Database template (e.g. "use FSF as reference")

1. Call `search_framework_roles(framework_id)` to browse roles in the template
2. Present the top 5 most relevant roles to the user — let them pick which to reference
3. For the selected roles, note the skill names, categories, and cluster structure
4. Do NOT load them into the spreadsheet — use the search results as context only
5. Proceed to Step 2 below

### B. Uploaded file (e.g. user uploads a PDF/Excel)

1. Call `get_uploaded_file(filename)` to read the full content
2. Proceed to Step 2 below

## Step 2: Extract Patterns

Analyze the reference framework for:
- **Category structure** — how are competencies organized?
- **Naming conventions** — formal vs informal, industry-specific terms
- **Level structure** — how many levels? What model (Dreyfus, custom)?
- **Indicator style** — how are behavioral descriptions written?
- **Domain specifics** — industry-relevant competencies

Summarize what you found: "The reference framework uses [N] categories, [M]-level proficiency model, and focuses on [domain]. Key patterns: [observations]."

## Step 3: Confirm Approach

Ask the user:
"Based on this reference, I'll build a new framework for [their domain/role] using similar structure. I'll adapt the categories and skills to your context while keeping the reference's [specific patterns]. Sound good?"

## Step 4: Generate

Proceed to the generate workflow (`references/generate-workflow.md`), but incorporate the reference patterns:
- Use similar category structure if appropriate
- Match the proficiency level model
- Adapt naming conventions to the user's domain
- Use the reference's indicator style as a quality benchmark

The result should be a NEW framework inspired by — but not copied from — the reference.
