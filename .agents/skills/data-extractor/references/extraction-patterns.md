# Extraction Patterns

Common file structures and how to handle them.

## Pattern 1: Flat Skill List (simple Excel/CSV)

Structure: One row per skill, columns map directly to fields.

```
| Category | Cluster | Skill Name | Description | Level | Level Name | Level Description |
```

Approach: Direct mapping. Read with openpyxl or csv, map columns, output JSON.

## Pattern 2: Skills with Proficiency Levels (vertical)

Structure: Multiple rows per skill, one row per proficiency level.

```
| Category | Cluster | Skill Name | Description | Level | Level Name | Level Description |
| Tech     | Coding  | Python     | ...         | 1     | Novice     | Basic scripts...  |
| Tech     | Coding  | Python     | ...         | 2     | Developing | Builds modules... |
```

Approach: Read as-is, each row becomes one framework row.

## Pattern 3: Skills with Proficiency Levels (horizontal)

Structure: One row per skill, proficiency levels as columns (PL1-PL5).

```
| Category | Cluster | Skill | Definition | PL1 desc | PL2 desc | PL3 desc | PL4 desc | PL5 desc |
```

Approach: Expand each skill row into N rows (one per PL level).
See `references/fsf-extraction.py` for a working example.

## Pattern 4: Skill-Role Mapping Matrix

Structure: Skills in rows, roles in columns, Y/N markers.

```
| Skill    | Role A | Role B | Role C |
| Python   | Y      |        | Y      |
| SQL      | Y      | Y      |        |
```

Approach:
- For each skill × role where marker is Y, create rows with that role
- If proficiency levels exist (Pattern 3 + 4 combined), create one row per level per role
- Total rows = skills × levels × mapped_roles

**Critical:** Y means the role requires ALL proficiency levels of that skill.
So if skill has PL1-PL5 and role has Y → 5 rows for that skill-role combo.

See `references/fsf-extraction.py` for the full Pattern 3+4 implementation.

## Pattern 5: Multi-sheet with Cross-references

Structure: Separate sheets for skills, roles, and mappings.

Approach:
1. Read each sheet into a Python dict/list
2. Cross-reference by skill name or code
3. Build the combined output

## Validation Checklist

Before calling `import_from_file`, always verify:
- [ ] Total row count makes sense (skills × levels × roles)
- [ ] No empty skill_name values
- [ ] Proficiency levels are 1-5 integers (not strings)
- [ ] Role names match across the dataset
- [ ] Sample rows look correct (print 3-5 examples)
- [ ] level_description contains actual content (not empty or placeholder)
