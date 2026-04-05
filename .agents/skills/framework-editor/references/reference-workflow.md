# Use File as Reference for New Framework

The uploaded file is NOT imported directly — it's used as context to inform a new framework.

## Step 1: Read the Reference

Call `get_uploaded_file(filename)` to read the full content.

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
