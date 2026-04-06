# Import Framework from File

## Step 1: Review File Summary

The upload summary in the message tells you: filename, row count, column names, and sample rows. Read this first to understand what was uploaded.

## Step 2: Read Full Data

Call `get_uploaded_file(filename)` to read parsed data. For large files (>200 rows), this returns paginated results — use `offset` and `limit` parameters to read in batches.

For multi-sheet Excel files, the summary lists all sheets. Ask the user which sheet(s) to import if there are multiple.

## Step 3: Column Mapping

Map the uploaded columns to spreadsheet columns. Propose the mapping and confirm with the user.

**Spreadsheet columns:** category, cluster, skill_name, skill_description, level, level_name, level_description

**Common column name aliases:**

| Spreadsheet Column | Common Names (English) | Malay | Chinese |
|-------------------|----------------------|-------|---------|
| category | Competency Area, Domain, Category, Pillar | Kategori, Bidang | 技能类别, 能力领域 |
| cluster | Skill Group, Cluster, Sub-category, Theme | Kelompok, Kumpulan | 技能组, 集群 |
| skill_name | Competency, Capability, Skill, Skill Name | Kemahiran, Kompetensi | 技能名称, 能力名称 |
| skill_description | Description, Definition, Overview | Keterangan, Penerangan | 技能描述, 描述 |
| level | Level, Proficiency Level, Band | Tahap, Aras | 等级, 级别 |
| level_name | Level Name, Band Name, Stage | Nama Tahap | 等级名称 |
| level_description | Behavioral Indicator, Description, Criteria | Penunjuk Tingkah Laku | 行为指标, 等级描述 |

If columns don't map cleanly, explain what you found and ask the user how to proceed.

When importing files:
- Check if the source has role/job information (column named "Role", "Job Role", etc.)
- If yes: set role field per skill based on the mapping
- If no: set role="" (company-wide library)
- For industry frameworks with role-skill mapping matrices (like FSF):
  read the mapping, create one row per skill × role combination

## Step 4: Confirm Before Importing

Present the mapping summary:
"I'll map [Column A] → category, [Column B] → skill_name, [Column C] → skill_description. No proficiency level columns found — I'll leave those empty. Import [N] rows?"

Wait for user confirmation.

## Step 5: Import

Call `add_rows` with mapped data. For large files, batch in groups of 200 rows.

If the spreadsheet already has data, ask: "The spreadsheet already has [N] rows. Do you want me to replace all data, or add these as new rows?"

## Step 6: Report

Report what was imported: row count, categories found, any issues (unmapped columns, empty values, duplicates).

After import is complete, remind user to save:
"Imported [N] rows. Save as [company/industry] framework?"
