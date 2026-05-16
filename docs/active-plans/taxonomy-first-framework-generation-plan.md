# Taxonomy-First Framework Generation Plan

## Goal

Change framework generation from a skill-count-first workflow into a
taxonomy-first workflow:

1. Generate or import a MECE `category -> cluster` structure.
2. Let the user review or tune that structure.
3. Generate skills underneath the approved structure.
4. Generate proficiency levels for the resulting skills.
5. Save the framework as the existing library model.

This keeps the current persisted library shape intact: skills still store
`category`, `cluster`, `skill_name`, `skill_description`, and embedded
`proficiency_levels`. The change is mainly in intake, BAML contracts,
Workbench flow, and review UX.

## Why This Change

The current creation path asks for a target number of skills, then asks the
LLM to produce a flat list of skill rows with category and cluster attributes.
That makes the model invent the framework architecture as a side effect of
skill generation.

The product model is already hierarchical:

```text
category -> cluster -> skill -> proficiency levels
```

Generation should respect that shape. Users should be able to say whether
they want a general, industry-specific, role-specific, transferable, or
non-transferable framework before the skill list exists.

## Current State

### Guided Flow

The scratch path in `RhoFrameworks.Flows.CreateFramework` currently asks for:

- framework name
- description
- domain
- target roles
- skill count
- proficiency levels

Then it runs:

```text
intake_scratch -> research -> generate -> review -> confirm
-> choose_levels -> proficiency -> save
```

`generate` calls `RhoFrameworks.UseCases.GenerateFrameworkSkeletons`, which
passes `skill_count` into `RhoFrameworks.LLM.GenerateSkeleton`.

### BAML Shape

`RhoFrameworks.LLM.GenerateSkeleton` returns:

```elixir
%{
  name: String.t(),
  description: String.t(),
  skills: [
    %{
      category: String.t(),
      cluster: String.t(),
      name: String.t(),
      description: String.t(),
      cited_findings: [integer()]
    }
  ]
}
```

The prompt asks the model to "aim for the requested skill count" and "pick a
small set of categories." Categories and clusters are attributes of each
generated skill rather than first-class planned objects.

### Workbench Plus Menu

The Workbench welcome page `+` menu currently exposes library creation methods:

- `Create from brief`
- `Create from JD`
- `Import spreadsheet`

Related, but not in the `+` menu:

- `Find Roles`
- guided flow `/flows/create-framework`
- smart entry routing

`Create from brief` asks for `skill_count` and sends an agent prompt telling
the spreadsheet assistant to call `generate_framework_skeletons`.

### Proficiency Generation

`RhoFrameworks.UseCases.GenerateProficiency` is already compatible with a
taxonomy-first approach. It reads skill rows from the library table, groups
them by category, and fans out `WriteProficiencyLevels` calls. This can remain
mostly unchanged.

## Target UX

### High-Level Flow

```text
intake
-> taxonomy preferences
-> generate taxonomy
-> review taxonomy
-> generate skills under taxonomy
-> review skills
-> choose proficiency scale
-> generate proficiency
-> save
```

### Plain-Language User Controls

Avoid exposing only technical terms like "transferable" or "MECE." The UI
should use plain labels, with internal values mapped to precise prompt params.

Suggested controls:

| UI Label | Internal Value | Meaning |
| --- | --- | --- |
| Reusable across roles | `transferable` | Broad capabilities that apply across roles or industries |
| Specific to this role/industry | `role_or_industry_specific` | Skills tightly bound to the target role, domain, regulation, or workflow |
| Balanced mix | `mixed` | Default blend of reusable and specific capabilities |
| General | `general` | Avoid industry jargon and niche workflows |
| Industry-specific | `industry_specific` | Include industry vocabulary, workflows, and regulatory context |
| Organization-specific | `organization_specific` | Include internal operating model or company-specific language if supplied |

### Size Controls

Default to a simple size selector:

- `Compact`
- `Balanced`
- `Comprehensive`
- `Custom`

Only show exact count controls when the user chooses `Custom`.

Custom controls:

- category count
- clusters per category
- skills per cluster
- strict counts toggle

Recommended internal params:

```elixir
%{
  taxonomy_size: "balanced",
  category_count: nil | integer,
  clusters_per_category: nil | "2-3" | integer,
  skills_per_cluster: nil | "2-4" | integer,
  strict_counts: false,
  specificity: "general" | "industry_specific" | "organization_specific",
  transferability: "transferable" | "role_specific" | "mixed",
  generation_style: "from_brief" | "from_jd" | "from_import" | "from_roles"
}
```

## Entry Point Impact

### Create From Brief

This is the most affected path.

Current behavior:

```text
brief + skill_count -> flat skills
```

Target behavior:

```text
brief + taxonomy preferences -> category/cluster taxonomy
-> user review -> skills under taxonomy
```

Modal changes:

- Remove or demote `Skill count`.
- Add a compact taxonomy section:
  - Structure: `Compact`, `Balanced`, `Comprehensive`, `Custom`
  - Focus: `Reusable across roles`, `Specific to this role/industry`,
    `Balanced mix`
  - Style: `General`, `Industry-specific`, optional `Organization-specific`
- Keep custom counts hidden unless selected.
- Keep "Open Guided Flow" as the path for advanced tuning.

Recommended modal fields:

```text
Framework name
Description
Domain
Target roles
Structure size: Balanced
Focus: Balanced mix
Style: General / Industry-specific
```

Advanced fields in guided flow:

```text
Category count
Clusters per category
Skills per cluster
Strict counts
Must-have categories
Categories to avoid
```

### Create From JD

A job description is evidence-rich and often role-specific. It should not ask
for category or cluster counts before extraction.

Current behavior:

```text
JD -> extract role requirements and skills
```

Target behavior:

```text
JD -> extract requirements/evidence
-> infer taxonomy
-> review taxonomy and requirements
-> generate or normalize library rows
```

Default taxonomy preferences:

```elixir
%{
  generation_style: "from_jd",
  specificity: "industry_specific",
  transferability: "mixed",
  taxonomy_size: "inferred",
  strict_counts: false
}
```

Key UX question:

> Do you want a reusable framework inspired by this JD, or a role-specific
> requirement set?

Suggested options:

- `Reusable framework`
- `Role-specific requirements`
- `Both`

If the user chooses role-specific requirements, preserve specific JD language
and avoid over-generalizing. If the user chooses reusable framework, abstract
JD evidence into broader categories and clusters.

### Import Spreadsheet

Import should preserve source structure first. Users importing a spreadsheet
usually expect the file's categories and clusters to remain intact.

Current behavior:

```text
CSV/XLSX -> mapped library rows
```

Target behavior:

```text
CSV/XLSX -> preserve/import source rows
-> optional taxonomy normalization actions
```

Initial import modal should not add taxonomy count controls.

Post-import actions:

- infer missing categories/clusters
- rebalance into MECE taxonomy
- split general vs industry-specific skills
- classify transferable vs role-specific skills
- rename categories/clusters
- merge tiny clusters
- split broad clusters

If the file has no category/cluster columns, show an inferred taxonomy review
after import and before save.

### Find Roles / Similar Role Seeds

This path is related to framework creation even though it is not in the plus
menu's library creation group.

Target choices after role selection:

- `Exact union of selected role skills`
- `Abstract into reusable framework`
- `Industry-specific framework from these examples`

Only the abstract/reusable paths need taxonomy generation. Exact union should
preserve source library categories/clusters where possible.

### Smart Entry

Smart entry should continue routing to `create-framework` or `edit-framework`,
but the classifier and query params should optionally capture taxonomy hints:

- "general framework" -> `specificity=general`
- "fintech-specific" -> `specificity=industry_specific`
- "transferable leadership skills" -> `transferability=transferable`
- "role-specific rubric" -> `transferability=role_specific`
- "small framework" -> `taxonomy_size=compact`
- "5 categories" -> `category_count=5`

## Proposed Architecture

### New Domain Concept: Taxonomy Draft

Introduce a session-level taxonomy draft. This does not need to be persisted as
a new database table in v1.

Shape:

```elixir
%{
  name: String.t(),
  description: String.t(),
  preferences: map(),
  categories: [
    %{
      name: String.t(),
      description: String.t(),
      rationale: String.t(),
      clusters: [
        %{
          name: String.t(),
          description: String.t(),
          rationale: String.t(),
          target_skill_count: integer() | nil,
          transferability: "transferable" | "role_specific" | "mixed"
        }
      ]
    }
  ]
}
```

Store it in one of these forms:

1. `taxonomy:<name>` DataTable, one row per cluster.
2. `flow:state` metadata row.
3. A new Workbench artifact snapshot.

Recommended v1: use a `taxonomy:<name>` DataTable because it gives immediate
review/edit UI without schema migration.

Suggested columns:

```elixir
category
category_description
cluster
cluster_description
target_skill_count
specificity
transferability
rationale
_source
```

Key fields:

```elixir
[:category, :cluster]
```

### New Use Case: GenerateFrameworkTaxonomy

Module:

```text
apps/rho_frameworks/lib/rho_frameworks/use_cases/generate_framework_taxonomy.ex
```

Responsibilities:

- validate intake
- ensure `taxonomy:<name>` and `meta` tables
- build BAML input from intake, research, seeds, and preferences
- stream completed category/cluster rows into the taxonomy table
- reconcile final result idempotently
- return summary with `taxonomy_table_name`

Input:

```elixir
%{
  name: String.t(),
  description: String.t(),
  domain: String.t() | nil,
  target_roles: String.t() | nil,
  research: String.t() | nil,
  seeds: String.t() | nil,
  source_evidence: String.t() | nil,
  taxonomy_size: String.t() | nil,
  category_count: integer() | nil,
  clusters_per_category: String.t() | integer() | nil,
  skills_per_cluster: String.t() | integer() | nil,
  strict_counts: boolean(),
  specificity: String.t(),
  transferability: String.t(),
  generation_style: String.t(),
  agent_id: String.t() | nil
}
```

Return:

```elixir
{:ok,
 %{
   taxonomy_table_name: "taxonomy:<name>",
   library_name: name,
   category_count: integer(),
   cluster_count: integer(),
   preferences: map()
 }}
```

### New BAML Function: GenerateTaxonomy

Module:

```text
apps/rho_frameworks/lib/rho_frameworks/llm/generate_taxonomy.ex
```

Output schema:

```elixir
%{
  name: String.t(),
  description: String.t(),
  categories: [
    %{
      name: String.t(),
      description: String.t(),
      rationale: String.t(),
      clusters: [
        %{
          name: String.t(),
          description: String.t(),
          rationale: String.t(),
          target_skill_count: integer(),
          transferability: String.t()
        }
      ]
    }
  ]
}
```

Prompt requirements:

- Generate the `category -> cluster` structure first. Do not generate skills.
- Categories must be mutually exclusive and collectively exhaustive for the
  requested framework scope.
- Clusters must be mutually exclusive within each category.
- Avoid one category per skill.
- Avoid generic bucket names like "Other" unless explicitly justified.
- Respect user counts when `strict_counts` is true.
- Treat counts as guidance when `strict_counts` is false.
- If `specificity=general`, avoid niche industry vocabulary.
- If `specificity=industry_specific`, include industry workflows,
  regulatory concepts, and domain vocabulary where relevant.
- If `transferability=transferable`, prefer reusable capabilities.
- If `transferability=role_specific`, prefer role-bound capabilities.
- If `transferability=mixed`, label clusters by transferability.
- Use research/source evidence when supplied and cite it at category or
  cluster level if the schema supports citations.

### Replace or Split GenerateSkeleton

Two viable approaches:

#### Option A: Add `GenerateSkillsForTaxonomy`

Add a new BAML function and use case:

```text
RhoFrameworks.LLM.GenerateSkillsForTaxonomy
RhoFrameworks.UseCases.GenerateSkillsForTaxonomy
```

Input includes approved taxonomy rows. Output remains flat skills, which write
to `library:<name>`.

Pros:

- clean mental model
- old and new paths can coexist
- prompts are shorter and more precise

Cons:

- more tools/use cases to expose
- more migration work in chat skill docs

#### Option B: Evolve `GenerateFrameworkSkeletons`

Keep the existing use case and tool name, but add taxonomy input. Internally it
does:

1. if taxonomy rows are supplied, generate skills under them
2. if taxonomy rows are absent, use old flat generation as compatibility path

Pros:

- lower disruption to existing agents and tests
- Workbench prompts can move gradually

Cons:

- one module owns two concepts
- old `skill_count` path may linger longer

Recommendation: implement Option A internally, then keep
`generate_framework_skeletons` as a compatibility wrapper for chat agents until
the tool skill docs are updated.

### GenerateSkillsForTaxonomy Contract

Input:

```elixir
%{
  name: String.t(),
  description: String.t(),
  target_roles: String.t(),
  research: String.t(),
  seeds: String.t(),
  taxonomy: String.t(),
  existing_skills: String.t(),
  gaps: String.t(),
  skills_per_cluster: String.t(),
  strict_counts: boolean()
}
```

Output:

```elixir
%{
  skills: [
    %{
      category: String.t(),
      cluster: String.t(),
      name: String.t(),
      description: String.t(),
      cited_findings: [integer()]
    }
  ]
}
```

Prompt requirements:

- Use only categories and clusters from the approved taxonomy.
- Generate skills under every cluster unless it is explicitly marked optional.
- Do not invent new categories or clusters.
- Do not collapse clusters.
- Make skill names concise, 2 to 4 words.
- Make descriptions observable and domain-appropriate.
- Avoid duplicates and near duplicates across clusters.
- If exact counts are not required, prefer coverage quality over count.

## Flow Changes

### CreateFramework Guided Flow

Current scratch path:

```text
intake_scratch -> research -> generate -> review -> confirm
-> choose_levels -> proficiency -> save
```

Target scratch path:

```text
intake_scratch
-> taxonomy_preferences
-> research
-> generate_taxonomy
-> review_taxonomy
-> generate_skills
-> review
-> confirm
-> choose_levels
-> proficiency
-> save
```

Notes:

- `research` can remain before taxonomy generation.
- `review_taxonomy` should be a new table review or custom tree review step.
- `generate_skills` writes into the current `library:<name>` table.
- Existing `review` remains the skill table review.

### Extend Existing Framework

Current extend path:

```text
pick_existing_library -> load_existing_library -> identify_gaps
-> generate -> review -> confirm -> choose_levels -> proficiency -> save
```

Target path:

```text
pick_existing_library
-> load_existing_library
-> analyze_existing_taxonomy
-> identify_taxonomy_gaps
-> review_taxonomy_changes
-> generate_skills_for_gaps
-> review
-> confirm
-> choose_levels
-> proficiency
-> save
```

MVP shortcut:

- Update `IdentifyGaps` to output `category` and `cluster`.
- Feed gaps to `GenerateSkillsForTaxonomy` using the existing library's
  category/cluster map as taxonomy.

### Template / Similar Roles

For role-profile seeded generation:

```text
similar_roles
-> pick_template
-> extract_seed_taxonomy
-> review_taxonomy
-> generate_skills
-> review
-> proficiency
-> save
```

If the user wants exact union, bypass LLM taxonomy generation and preserve
source categories/clusters.

### Merge / Import Paths

Merge and import should not require taxonomy generation up front. They already
have source rows.

Optional post-load actions:

- normalize taxonomy
- rebalance taxonomy
- infer missing clusters
- classify transferability

## Workbench UI Changes

### Plus Menu Labels

Current labels can stay:

- `Create from brief`
- `Create from JD`
- `Import spreadsheet`

Potential future label refinement:

- `Design from brief`
- `Extract from JD`
- `Import spreadsheet`

### Create From Brief Modal

Replace:

```text
Skill count
```

With:

```text
Structure size
Focus
Style
```

Only reveal exact category/cluster/skill counts for custom size.

### Create From JD Modal

Keep:

```text
Upload or paste JD
Role name
Library name
```

Add optional:

```text
Output type:
- Reusable framework
- Role-specific requirements
- Both
```

Do not ask for taxonomy counts at the first step.

### Import Spreadsheet Modal

Keep current fields. Add no taxonomy controls initially.

After import, if categories/clusters are missing or sparse, show an action:

```text
Infer category/cluster structure
```

If categories/clusters exist, show:

```text
Normalize taxonomy
```

### Taxonomy Review Surface

MVP can use a DataTable:

```text
category | category_description | cluster | cluster_description
target_skill_count | transferability | rationale
```

Better UX should be a compact tree:

```text
Technical Foundation
  Architecture & Design
  Engineering Practices
  Systems Operations

Domain Execution
  Regulatory Context
  Industry Workflows
```

Expected actions:

- rename category
- rename cluster
- add category
- add cluster
- remove category
- remove cluster
- split cluster
- merge clusters
- regenerate one category
- rebalance taxonomy
- continue to skill generation

## Chat Agent Changes

### Tool Surface

Add tools:

- `generate_framework_taxonomy`
- `generate_skills_for_taxonomy`

Keep existing:

- `generate_framework_skeletons` as compatibility wrapper
- `generate_proficiency`
- `save_framework`

### Spreadsheet Agent Prompt

Update `.rho.exs` spreadsheet prompt and `create-framework` skill:

- Stop treating skill count as primary intake.
- Ask for taxonomy style when needed:
  - broad reusable framework
  - industry-specific framework
  - role-specific rubric
  - mixed
- Infer defaults from user language:
  - "leadership framework" -> general + transferable
  - "fintech compliance analyst" -> industry-specific + mixed
  - "backend engineer hiring rubric" -> role-specific + mixed
- Generate taxonomy before generating skills unless the user explicitly asks
  for a quick flat draft.

### Workbench Modal Prompt

Update `RhoWeb.WorkbenchActionRunner.build_prompt(:create_framework, ...)`.

Current prompt tells the agent:

```text
Call generate_framework_skeletons with skill_count.
```

Target prompt:

```text
Create a new skill framework in the Workbench.

First call generate_framework_taxonomy with:
- name
- description
- domain
- target_roles
- taxonomy_size
- specificity
- transferability
- optional custom counts

After taxonomy review or if the user requested quick mode, call
generate_skills_for_taxonomy to populate the library table.
```

For a one-click modal, the agent may generate taxonomy and skills in sequence
using default preferences, but it should still expose the taxonomy structure in
the Workbench so the user can revise it.

## BAML Prompt Updates

### GenerateTaxonomy

New prompt. See "New BAML Function: GenerateTaxonomy."

### GenerateSkillsForTaxonomy

New prompt. See "GenerateSkillsForTaxonomy Contract."

### GenerateSkeleton

Keep temporarily for compatibility. Update prompt to say it is legacy quick
generation and should still produce coherent categories/clusters.

Remove or reduce emphasis on:

```text
Aim for the requested skill count.
```

Replace with:

```text
If no taxonomy is supplied, infer a compact category/cluster map first, then
emit skills under that inferred map.
```

### IdentifyGaps

Current output lacks `cluster`. Add it.

New gap shape:

```elixir
%{
  category: String.t(),
  cluster: String.t(),
  skill_name: String.t(),
  rationale: String.t()
}
```

Prompt additions:

- Use existing categories and clusters when possible.
- If a new cluster is needed, explain why.
- Do not only identify missing skills; identify whether the missing concept
  belongs in an existing cluster or requires taxonomy expansion.

### SuggestSkills

Current prompt takes `n` and suggests flat skills. Update to:

- accept taxonomy/context
- prefer suggesting skills inside existing clusters
- if no cluster fits, return a proposed cluster addition separately

Potential output:

```elixir
%{
  skills: [...],
  proposed_clusters: [...]
}
```

For MVP, keep output flat but pass a rendered taxonomy and require existing
cluster reuse unless impossible.

## Data Model and Persistence

No database migration is required for the initial version.

Existing persisted `Skill` already has:

- `category`
- `cluster`
- `name`
- `description`
- `proficiency_levels`

New taxonomy draft is session-scoped and can be discarded after skills are
generated and saved.

Future optional persistence:

- save taxonomy preferences in library metadata
- store taxonomy review decisions
- store cluster descriptions separately
- preserve taxonomy draft as a versioned artifact

Do not create placeholder skill rows for categories or clusters. That would
pollute save/proficiency behavior.

## Implementation Phases

### Phase 1: Contracts and Schemas

- Add taxonomy DataTable schema.
- Add taxonomy preference parsing helpers.
- Add `GenerateTaxonomy` BAML function.
- Add `GenerateFrameworkTaxonomy` use case.
- Add tests for parsing, streaming, final reconciliation, and table writes.

Acceptance criteria:

- Given intake and preferences, taxonomy rows stream into `taxonomy:<name>`.
- Final result reconciliation is idempotent.
- Generated taxonomy rows include category and cluster names.
- No skill rows are created in this phase.

### Phase 2: Skill Generation Under Taxonomy

- Add `GenerateSkillsForTaxonomy` BAML function.
- Add `GenerateSkillsForTaxonomy` use case.
- Render taxonomy rows into prompt input.
- Write generated skills into `library:<name>` using existing Workbench APIs.
- Keep `GenerateFrameworkSkeletons` compatibility path.

Acceptance criteria:

- Generated skills use only approved taxonomy categories/clusters.
- Skills stream into the existing library table.
- Existing proficiency generation works unchanged afterward.

### Phase 3: Guided Flow

- Add `taxonomy_preferences` form step.
- Add `generate_taxonomy` action step.
- Add `review_taxonomy` table review step.
- Add `generate_skills` action step.
- Update flow summaries and table-name resolution.
- Update smart defaults for JD/template/extend paths.

Acceptance criteria:

- Scratch guided flow runs taxonomy first.
- User can edit taxonomy rows before skill generation.
- Skill review and proficiency steps still work.
- Save persists the same library shape as before.

### Phase 4: Workbench Plus Menu

- Update `WorkbenchActions` fields for `create_framework`.
- Update `WorkbenchActionComponent` modal controls.
- Update `WorkbenchActionRunner.build_prompt/2`.
- Preserve simple defaults for quick creation.
- Keep advanced count controls behind `Custom`.

Acceptance criteria:

- `Create from brief` no longer asks for blunt skill count by default.
- Modal can still generate a framework with one submit.
- Guided Flow remains available for advanced tuning.

### Phase 5: JD and Import Integration

- Update JD extraction path to infer taxonomy preferences from source.
- Add reusable-framework vs role-specific-requirements choice.
- Add post-import taxonomy actions for missing/sparse categories.
- Avoid changing import defaults for files that already contain categories and
  clusters.

Acceptance criteria:

- JD path can produce role-specific or reusable structure.
- Spreadsheet import preserves source taxonomy unless user asks to normalize.
- Missing taxonomy can be inferred after import.

### Phase 6: Agent Skill and Prompt Updates

- Update `.rho.exs` spreadsheet prompt.
- Update `.agents/skills/create-framework/SKILL.md`.
- Update tutorial text that mentions skill count and current flow order.
- Add chat tool wrappers for new use cases.
- Mark old skill-count-first guidance as compatibility-only.

Acceptance criteria:

- Agent asks about taxonomy style rather than skill count when context is
  missing.
- Agent infers sane defaults when context is clear.
- Agent generates taxonomy before skills in normal create-framework paths.

### Phase 7: Polish and Better Review UX

- Replace taxonomy DataTable review with a tree-oriented review component.
- Add actions for split/merge/rename/regenerate taxonomy nodes.
- Add visual progress for category/cluster generation and per-cluster skill
  generation.
- Add optional taxonomy metadata to saved library summaries.

Acceptance criteria:

- Taxonomy review feels like editing a framework map, not a spreadsheet chore.
- Users can regenerate a single category or cluster without restarting.

## Test Plan

### Unit Tests

- taxonomy preference parsing
- taxonomy table-name derivation
- taxonomy row normalization
- duplicate category/cluster handling
- strict vs non-strict counts
- skill generation rejects unknown category/cluster outputs
- `IdentifyGaps` includes cluster
- `SuggestSkills` reuses existing clusters

### Use Case Tests

- `GenerateFrameworkTaxonomy.run/2`
- `GenerateSkillsForTaxonomy.run/2`
- compatibility behavior for `GenerateFrameworkSkeletons`
- JD path preference inference
- import path taxonomy inference only when missing

### Flow Tests

- guided scratch path:
  - submit intake
  - submit taxonomy preferences
  - generate taxonomy
  - review taxonomy
  - generate skills
  - generate proficiency
  - save
- custom counts path
- compact/balanced/comprehensive defaults
- extend-existing gap generation

### Web Tests

- Workbench `+` menu still exposes the three creation methods.
- Create from brief modal renders new controls.
- Custom count controls appear only when custom is selected.
- Create from JD modal exposes output type.
- Import spreadsheet modal does not show taxonomy count controls.

### Regression Tests

- existing library save still works
- proficiency generation still groups by category
- existing imports still preserve category/cluster data
- existing role profile flows still work
- `mix rho.arch` passes

## Rollout Strategy

1. Build new taxonomy use cases behind unused tools.
2. Add guided flow support while keeping old `generate` path available.
3. Switch Workbench `Create from brief` to taxonomy-first.
4. Update chat skill docs and spreadsheet prompt.
5. Switch JD and import enhancements.
6. Remove or de-emphasize `skill_count` once compatibility usage drops.

## Open Questions

- Should taxonomy review be mandatory, or should quick-create generate taxonomy
  and skills in one run with an optional "review structure" affordance?
- Should skills be generated by category, by cluster, or in one call with the
  full taxonomy?
- Should proficiency generation fan out by category as today, or by cluster for
  better parallelism and smaller prompts?
- Should taxonomy preferences be saved as library metadata?
- Should imported spreadsheets with weak categories be automatically flagged for
  normalization?
- Should "transferability" live only as prompt context, or become a visible
  column/tag on clusters or skills?

## Recommended MVP

Implement the smallest version that changes the product behavior without
touching persistence:

1. Add taxonomy table schema.
2. Add `GenerateTaxonomy`.
3. Add `GenerateSkillsForTaxonomy`.
4. Add guided flow taxonomy preference and review steps.
5. Update `Create from brief` modal to collect size/focus/style.
6. Keep proficiency and save unchanged.

This gives users control over category/cluster structure and generation style,
while preserving the current library table, proficiency generation, and save
pipeline.
