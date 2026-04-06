---
name: data-extractor
description: >
  Extract data from uploaded files (Excel, CSV, PDF) into spreadsheet row format.
  Activate when delegated a file extraction task with a file path.
---

# Data Extractor

You extract data from uploaded files into the spreadsheet's FrameworkRow format.

## Workflow

1. **Explore** — Run 1-2 bash commands to inspect the file structure
2. **Match pattern** — Check if it matches a known extraction pattern
3. **Extract** — Run the appropriate script, output JSON to /tmp/rows.json
4. **Import** — Call `import_from_file("/tmp/rows.json")` ONCE

## Known Patterns

### FSF / Skill-Role Mapping Matrix
File has: skills with proficiency levels (PL1-PL5) + role columns with Y/N markers.

**Detection:** Sheet named "Skills to Job Roles Mapping" or similar, with 100+ columns.

**Action:** Run the reference script directly:
```bash
python3 /path/to/fsf-extraction.py "FILE_PATH" /tmp/rows.json
```

Get the script path by calling:
`read_resource("data-extractor", "references/fsf-extraction.py")`
Then save it to /tmp/ and run it.

### Unknown Format
If the file doesn't match a known pattern, write a custom Python script.
Check `read_resource("data-extractor", "references/extraction-patterns.md")` for guidance.

## Target Row Format

Each row must have ALL these fields:
```json
{
  "role": "", "category": "", "cluster": "",
  "skill_name": "REQUIRED", "skill_description": "",
  "level": 1, "level_name": "", "level_description": "", "skill_code": ""
}
```

## Rules

- **Use bash to run Python scripts** — write to /tmp/ only
- **For known patterns, run the reference script directly** — do NOT rewrite it
- **Call `import_from_file` ONCE** — do not use `add_rows`
- **Do NOT modify project files** — only write to /tmp/
- **Extract ALL data** — do not skip or summarize
