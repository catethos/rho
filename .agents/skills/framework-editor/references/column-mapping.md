# Column Mapping Reference

Common column names found in client skill framework files and their mappings to the spreadsheet schema.

## Spreadsheet Schema

| Column | Type | Description |
|--------|------|-------------|
| category | String | Broad competency area (e.g., "Technical Excellence") |
| cluster | String | Related skill grouping within a category |
| skill_name | String | The specific competency name |
| skill_description | String | 1-sentence definition of the competency |
| level | Integer | Proficiency level number (1-5, or 0 for placeholder) |
| level_name | String | Level label (e.g., "Novice", "Expert") |
| level_description | String | Observable behavioral indicator for this level |

## Common Aliases by Language

### English
| Spreadsheet Column | Common Aliases |
|-------------------|---------------|
| category | Competency Area, Domain, Category, Pillar, Competency Group, Focus Area |
| cluster | Skill Group, Cluster, Sub-category, Theme, Sub-domain, Capability Area |
| skill_name | Competency, Capability, Skill, Skill Name, Core Competency, Attribute |
| skill_description | Description, Definition, Overview, Competency Definition, Skill Description |
| level | Level, Proficiency Level, Band, Tier, Stage, Grade |
| level_name | Level Name, Band Name, Stage Name, Proficiency Label |
| level_description | Behavioral Indicator, Indicator, Description, Criteria, Observable Behavior, Performance Criteria |

### Malay (Bahasa Malaysia)
| Spreadsheet Column | Common Aliases |
|-------------------|---------------|
| category | Kategori, Bidang, Kawasan Kompetensi |
| cluster | Kelompok, Kumpulan, Sub-kategori |
| skill_name | Kemahiran, Kompetensi, Keupayaan |
| skill_description | Keterangan, Penerangan, Definisi |
| level | Tahap, Aras, Peringkat |
| level_name | Nama Tahap, Label Aras |
| level_description | Penunjuk Tingkah Laku, Kriteria, Petunjuk Prestasi |

### Chinese (Simplified)
| Spreadsheet Column | Common Aliases |
|-------------------|---------------|
| category | 技能类别, 能力领域, 类别, 胜任力领域 |
| cluster | 技能组, 集群, 子类别, 能力群 |
| skill_name | 技能名称, 能力名称, 胜任力, 核心能力 |
| skill_description | 技能描述, 描述, 定义, 能力说明 |
| level | 等级, 级别, 层级, 熟练度 |
| level_name | 等级名称, 级别名称 |
| level_description | 行为指标, 等级描述, 绩效标准, 行为表现 |

## Mapping Protocol

1. Read the column headers from the uploaded file
2. Auto-match using the alias tables above (case-insensitive)
3. For unmatched columns, show the user and ask how to map them
4. If no proficiency level columns exist, note this — the user may want to add levels later via the enhance workflow
5. If the file has extra columns not in the schema, ask whether to ignore them or include as metadata

## Common File Structures

**Flat structure** (one row per skill, no levels):
→ Map to category/cluster/skill_name/skill_description. Set level=0.

**Wide structure** (levels as columns: "Level 1", "Level 2", ...):
→ Pivot: create one row per skill × level combination.

**Long structure** (one row per skill × level):
→ Direct mapping, most compatible with our schema.
