# Rho Artifact Workbench UI/UX Plan

> Updated implementation handoff.
>
> This supersedes the earlier "make the table/chat prettier" framing. The
> simpler model is: Rho is an artifact workbench where HR practitioners and an
> agent collaborate on skill frameworks, role requirements, imports,
> comparisons, and review decisions.

## 1. First Principles

The app should not be understood as:

```text
chat + data table + debug tools
```

The app should be understood as:

```text
workflow -> artifacts -> decisions -> saved HR assets
```

Every major user action creates or changes one or more **artifacts**:

- a reusable skill framework
- a role's required skills
- a candidate-role picker
- a library-combine conflict review
- a duplicate-review queue
- a comparison/diff result
- a gap-analysis or lens result

The user should always be able to answer five questions without reading raw
table names, tool calls, or debug metadata:

1. What am I working on?
2. Why does it exist?
3. What is linked to it?
4. What is incomplete or awaiting my decision?
5. What can I do next?

The agent should receive the same answers as compact deterministic context
before deciding whether deeper table-tool reads are necessary.

## 2. The Key Simplification

Do not implement separate solutions for:

- better table titles
- better assistant prompt context
- better action buttons
- JD upload showing two tables
- combine/dedup decision states
- role/library distinction

Instead, add one thin interpretation layer:

```text
DataTable state + effect metadata + selections
  -> Workbench context
  -> UI header / artifact switcher / assistant suggestions / prompt section
```

This shared layer is the design and engineering center of the redesign.

This also gives Rho the right foundation for **generative UI**, but in a
bounded product sense: the agent should help select or request the right
workbench surface for the user's current artifact and decision, while Phoenix
renders only trusted, prebuilt components. Do not interpret generative UI here
as arbitrary LLM-generated HTML, HEEx, CSS, or client code.

## 3. Existing Architecture To Keep

Keep these parts of the current system:

- `Rho.Stdlib.DataTable.Server` remains the owner of session table state.
- Named tables such as `library:<name>`, `role_profile`, `role_candidates`,
  `combine_preview`, and `dedup_preview` remain valid internal identifiers.
- `RhoWeb.DataTableComponent` remains the main editable artifact surface.
- `RhoWeb.AppLive` remains the session shell that combines workspace and chat.
- `Rho.Stdlib.Plugins.DataTable.prompt_sections/2` remains the right hook for
  giving the agent current editor context.
- `Rho.Effect.Table.metadata` already exists and should be used for workflow
  and artifact linkage metadata.

Important files:

- `apps/rho/lib/rho/effect/table.ex`
- `apps/rho_stdlib/lib/rho/stdlib/data_table.ex`
- `apps/rho_stdlib/lib/rho/stdlib/data_table/table.ex`
- `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex`
- `apps/rho_stdlib/lib/rho/stdlib/effect_dispatcher.ex`
- `apps/rho_web/lib/rho_web/workspaces/data_table.ex`
- `apps/rho_web/lib/rho_web/components/data_table_component.ex`
- `apps/rho_web/lib/rho_web/live/app_live.ex`
- `apps/rho_web/lib/rho_web/live/session_live/data_table_helpers.ex`
- `apps/rho_web/lib/rho_web/data_table/schemas.ex`
- `apps/rho_frameworks/lib/rho_frameworks/data_table_schemas.ex`
- `apps/rho_frameworks/lib/rho_frameworks/tools/workflow_tools.ex`
- `apps/rho_frameworks/lib/rho_frameworks/tools/library_tools.ex`
- `apps/rho_frameworks/lib/rho_frameworks/tools/role_tools.ex`

## 4. Core Concepts

### 4.1 Artifact

An artifact is the user-facing object represented by one table or one analysis
result.

Proposed shape:

```elixir
%Rho.Stdlib.DataTable.ArtifactSummary{
  table_name: "library:CEO",
  kind: :skill_library,
  title: "CEO Skill Framework",
  subtitle: "Reusable skill taxonomy",
  source_label: "Generated from CEO JD",
  workflow: :jd_extraction,
  row_count: 7,
  metrics: %{
    skills: 7,
    categories: 4,
    proficiency_levels: 0,
    missing_levels: 7
  },
  state: [:draft, :needs_levels],
  selected_count: 2,
  selected_preview: [
    %{id: "row_123", label: "Fundraising", detail: "Business, 0 levels"}
  ],
  linked: %{
    role_table: "role_profile",
    source_upload_id: "upl_..."
  },
  actions: [:save_draft, :generate_levels, :publish, :export]
}
```

This does not replace the row data. It is a compact interpretation of it.

### 4.2 Workflow

A workflow explains why the artifact exists and what other artifacts are linked.

Proposed workflow ids:

- `:create_framework`
- `:jd_extraction`
- `:import_upload`
- `:edit_existing`
- `:extend_existing`
- `:combine_libraries`
- `:dedup_library`
- `:seed_from_roles`
- `:role_search`
- `:role_profile_edit`
- `:gap_analysis`
- `:lens_scoring`
- `nil`

Proposed shape:

```elixir
%Rho.Stdlib.DataTable.WorkflowSummary{
  id: :jd_extraction,
  title: "JD Extraction",
  source_label: "CEO Job Description.pdf",
  artifact_tables: ["library:CEO", "role_profile"],
  active_table: "library:CEO",
  summary: "Extracted a skill framework and role requirements from one JD.",
  next_actions: [:review_framework, :review_role_requirements, :generate_levels, :save_both]
}
```

### 4.3 Workbench Context

The workbench context is the full summary for the current data-table workspace.

Proposed shape:

```elixir
%Rho.Stdlib.DataTable.WorkbenchContext{
  active_table: "library:CEO",
  workflow: %WorkflowSummary{},
  artifacts: [%ArtifactSummary{}, ...],
  active_artifact: %ArtifactSummary{},
  debug: %{
    table_order: ["library:CEO", "role_profile"],
    view_key: :skill_library
  }
}
```

This should be derived. It should not become a second canonical state store.

### 4.4 Generative Workbench Surface

A generative workbench surface is a trusted UI surface selected from a small
catalog based on workflow, artifact state, metadata, and user intent.

It is "generative" because the agent or tool result can request the most
appropriate surface for the moment. It is not unbounded generation: the request
is structured data, and `rho_web` decides how to render it with existing
Phoenix components.

Proposed shape:

```elixir
%Rho.Effect.WorkbenchSurface{
  kind: :dedup_review,
  artifact_table: "dedup_preview",
  title: "Duplicate Review",
  props: %{
    unresolved_count: 4,
    decision_modes: [:keep_a, :keep_b, :merge, :keep_both]
  },
  allowed_actions: [:apply_cleanup, :save_cleaned_framework]
}
```

The first implementation can avoid a new effect struct and use
`Rho.Effect.Table.metadata[:ui_intent]`. A dedicated effect is useful later if
surfaces become first-class outputs beyond data tables.

Initial surface catalog:

- `:artifact_summary`
- `:linked_artifacts`
- `:role_candidate_picker`
- `:conflict_review`
- `:dedup_review`
- `:gap_review`
- `:confirmation_panel`

User-facing goal:

```text
the right workspace appears for the thing I am trying to decide
```

Examples:

- JD extraction -> linked framework and role-requirements review
- similar-role search -> candidate picker
- combine libraries -> conflict review queue
- dedup library -> duplicate review queue
- gap analysis -> actionable recommendation review
- save/publish/fork -> confirmation panel with provenance

## 5. Module Placement

The summary layer needs to be used by both web UI and agent prompt context.
Because `rho_stdlib` cannot depend on `rho_web` or `rho_frameworks`, put the
pure generic logic in `rho_stdlib` and keep Phoenix-specific rendering in
`rho_web`.

Recommended modules:

### `Rho.Stdlib.DataTable.WorkbenchContext`

New pure module in:

```text
apps/rho_stdlib/lib/rho/stdlib/data_table/workbench_context.ex
```

Responsibilities:

- infer artifact kind from table name, storage schema name, schema columns, and
  metadata
- derive artifact titles
- compute metrics from bounded table snapshots
- include selected-row previews
- derive workflow summary from metadata and table relationships
- preserve validated surface intent hints for web presenters
- produce prompt-friendly markdown/xml snippets

Inputs should be plain maps/structs from `DataTable.get_session_snapshot/1`,
`DataTable.get_table_snapshot/2`, `DataTable.get_selection/2`, and metadata.

### `RhoWeb.WorkbenchPresenter`

New web-only presenter module in:

```text
apps/rho_web/lib/rho_web/workbench_presenter.ex
```

Responsibilities:

- map artifact summary actions to labels and button variants
- map artifact kind/state to CSS classes
- validate and map `ui_intent` surface requests to known component variants
- decide which action buttons render in the header
- keep HEEx clean

### `RhoWeb.DataTableComponent`

Use the derived context to render:

- artifact switcher
- active artifact header
- metrics and warnings
- action bar
- existing data table body

Do not make this component own a second interpretation of table kind.

### `Rho.Stdlib.Plugins.DataTable`

Use `WorkbenchContext` to inject the same active artifact summary into the
agent prompt section.

## 6. Artifact Kinds

### 6.1 Skill Library

Internal sources:

- table names: `library`, `library:<name>`
- storage schema name: `"library"`
- web schema key: `:skill_library`

User-facing language:

- title: `<Name> Skill Framework`
- noun: `skill`
- plural noun: `skills`
- purpose: reusable skill taxonomy

Primary fields:

- `category`
- `cluster`
- `skill_name`
- `skill_description`
- `proficiency_levels`

Metrics:

- skill count
- category count
- total proficiency level count
- skills missing proficiency levels

States:

- `:draft`
- `:saved`
- `:published`
- `:needs_levels`
- `:ready_to_publish`
- `:generated`
- `:imported`

Actions:

- `:save_draft`
- `:publish`
- `:generate_levels`
- `:suggest_skills`
- `:dedup`
- `:export`
- `:fork`

Example header:

```text
CEO Skill Framework
Draft | 7 skills | 4 categories | 0 levels | 7 need levels

[Save draft] [Generate levels] [Suggest skills] [Publish] [Export]
```

### 6.2 Role Profile / Role Requirements

Internal sources:

- table name: `role_profile`
- storage schema name: `"role_profile"`
- web schema key: `:role_profile`

User-facing language:

- title: `<Role Name> Role Requirements`
- noun: `required skill`
- plural noun: `required skills`
- purpose: demand profile for a role

Primary fields:

- `skill_name`
- `required_level`
- `required`
- `priority`
- `source_quote`
- `verification`

Metrics:

- required skill count
- required vs optional count
- missing required level count
- unverified count
- unmapped count, when mapping metadata exists

States:

- `:draft`
- `:needs_mapping`
- `:needs_review`
- `:ready_to_save`

Actions:

- `:save_role_profile`
- `:map_to_framework`
- `:review_gaps`
- `:clone_role`
- `:export`

Example header:

```text
CEO Role Requirements
Draft | 7 required skills | 3 required | 4 optional | 0 missing levels
Based on CEO Skill Framework

[Save role profile] [Map to framework] [Review gaps] [Export]
```

### 6.3 Role Candidates

Internal sources:

- table name: `role_candidates`
- storage schema name: `"role_candidates"`
- web schema key: `:role_candidates`

User-facing language:

- title: `Candidate Roles`
- purpose: picker for selecting source roles

Metrics:

- candidate count
- query count
- selected candidate count

States:

- `:awaiting_selection`
- `:has_selection`

Actions:

- `:seed_framework_from_selected`
- `:clone_selected_role`
- `:clear_selection`

This should look like a picker, not a spreadsheet.

### 6.4 Combine Preview

Internal sources:

- table name: `combine_preview`
- storage schema name: `"combine_preview"`
- web schema key: `:combine_conflicts`

User-facing language:

- title: `Combine Libraries`
- purpose: review conflicts before creating a merged library

Metrics:

- clean skill count, when metadata provides it
- conflict count
- unresolved conflict count
- resolved count

States:

- `:needs_resolution`
- `:ready_to_merge`

Actions:

- `:resolve_conflicts`
- `:create_merged_library`
- `:cancel`

Example:

```text
Combine Libraries
HR Assistant + People Ops -> People Team Framework
18 clean skills | 4 conflicts unresolved

[Create merged library disabled] [Export review]
```

### 6.5 Dedup Preview

Internal sources:

- table name: `dedup_preview`
- storage schema name: `"dedup_preview"`
- web schema key: `:dedup_preview`

User-facing language:

- title: `Duplicate Review`
- purpose: review likely duplicate skills within one library

Metrics:

- duplicate candidate count
- unresolved count
- resolved count
- theme/cluster count

States:

- `:needs_resolution`
- `:ready_to_apply`
- `:clean`

Actions:

- `:apply_cleanup`
- `:save_cleaned_framework`
- `:export_review`

### 6.6 Generic Table

Keep generic behavior for unknown tables:

- title from schema or table name
- noun: `row`
- actions: export, add row if editable

## 7. Workflow Coverage

### 7.1 Create New Framework

User examples:

- "Build a skill framework for Product Manager."
- "Create a customer success framework."

Current code paths:

- `RhoFrameworks.Flows.CreateFramework`
- `RhoFrameworks.UseCases.LoadSimilarRoles`
- `RhoFrameworks.UseCases.GenerateFrameworkSkeletons`
- `RhoFrameworks.UseCases.GenerateProficiency`
- `RhoFrameworks.UseCases.SaveFramework`
- `RhoFrameworks.Tools.WorkflowTools.generate_framework_skeletons`
- `RhoFrameworks.Tools.WorkflowTools.generate_proficiency`
- `RhoFrameworks.Tools.WorkflowTools.save_framework`

Artifact behavior:

- primary artifact: `skill_library`
- workflow: `:create_framework`
- linked artifacts: optional similar roles or research notes

UI behavior:

- show generation progress
- show missing proficiency levels
- next actions: generate levels, review, save draft, publish

### 7.2 Upload JD

User examples:

- "Upload this JD and create a role profile."
- "Extract the skills from this job description."

Current code paths:

- `RhoFrameworks.UseCases.ExtractFromJD`
- `RhoFrameworks.Tools.WorkflowTools.extract_role_from_jd`

Artifact behavior:

- creates `skill_library`
- creates `role_profile`
- both should share workflow `:jd_extraction`
- both should carry source upload/document metadata when available

UI behavior:

```text
JD Extraction
Source: CEO Job Description.pdf

[CEO Skill Framework] [CEO Role Requirements]

Extracted:
- 7 framework skills, 0 proficiency levels
- 7 role requirements, 3 required, 4 optional

[Review framework] [Review role requirements] [Generate missing levels] [Save both]
```

Do not drop the user into a raw `role_profile` tab and expect them to infer
what happened.

### 7.3 Import Spreadsheet/CSV Library

User examples:

- "Import our skills spreadsheet."
- "Bring this Excel file in as a library."

Current code paths:

- `RhoFrameworks.UseCases.ImportFromUpload`
- `RhoFrameworks.Tools.WorkflowTools.import_library_from_upload`

Artifact behavior:

- one or more `skill_library` artifacts
- workflow: `:import_upload`
- source file metadata

UI behavior:

- show each imported framework as a distinct artifact
- show warnings and partial failures clearly
- next actions: review, generate missing levels, save draft, publish

### 7.4 Extend Or Reference Existing Library

User examples:

- "Use our Engineering framework as a starting point."
- "Reference the Sales library and fill gaps."
- "Load the CEO library."

Current code paths:

- `RhoFrameworks.UseCases.ListExistingLibraries`
- `RhoFrameworks.UseCases.LoadExistingFramework`
- `RhoFrameworks.UseCases.IdentifyFrameworkGaps`
- `RhoFrameworks.Tools.LibraryTools.load_library`
- `RhoFrameworks.Tools.LibraryTools.browse_library`
- `RhoFrameworks.Tools.WorkflowTools.load_similar_roles`

Artifact behavior:

- loaded source library should be distinguished from working draft
- workflow: `:edit_existing` or `:extend_existing`
- metadata should preserve source/reference library id when known

UI behavior:

- show "Based on <library>" or "Referencing <library>"
- make it clear if the user is editing original, fork, or new draft
- show gap findings as proposals, not silent mutations

### 7.5 Combine Libraries

User examples:

- "Combine the HR and People Ops libraries."
- "Merge these two frameworks and let me resolve conflicts."

Current code paths:

- `RhoFrameworks.Tools.LibraryTools.combine_libraries`
- `RhoFrameworks.UseCases.DiffFrameworks`
- `RhoFrameworks.UseCases.MergeFrameworks`
- `RhoFrameworks.UseCases.ResolveConflicts`
- `combine_preview` table

Artifact behavior:

- primary artifact: `combine_preview`
- output artifact after commit: `skill_library`
- workflow: `:combine_libraries`
- metadata should include source library ids/names and target library name

UI behavior:

- show source libraries side by side
- show conflict and clean counts
- unresolved count must be visible
- `Create merged library` disabled until conflicts are resolved

### 7.6 Deduplicate Library

User examples:

- "Find duplicate skills in this library."
- "Clean this framework before publishing."

Current code paths:

- `RhoFrameworks.Tools.LibraryTools.dedup_library`
- `dedup_preview` table
- `save_framework` applies decisions

Artifact behavior:

- primary artifact: `dedup_preview`
- linked artifact: source `skill_library`
- workflow: `:dedup_library`

UI behavior:

- make it a review queue
- actions read as decisions: keep A, keep B, keep both, merge
- next action after resolution: save cleaned framework

### 7.7 Diff Versions Or Compare Against Source

User examples:

- "What changed from the published version?"
- "What did this fork change?"

Current code paths:

- `RhoFrameworks.Tools.LibraryTools.diff_library`
- `Library.diff_versions`
- `Library.diff_against_source`

Artifact behavior:

- output may start as assistant prose/json
- future artifact kind could be `:diff_result`

UI behavior:

- present added/changed/removed skills as comparison
- show compared versions/source names
- support review before publish

### 7.8 Fork A Library

User examples:

- "Make a copy I can edit."
- "Customize this template for my org."

Current code paths:

- `RhoFrameworks.Tools.LibraryTools.fork_library`
- `DataTableHelpers.handle_fork/2`
- `RhoFrameworks.Library.fork_library`

Artifact behavior:

- artifact remains `skill_library`
- workflow: `:edit_existing`
- metadata should include `source_library_id` and `source_library_name`

UI behavior:

- show "Forked from <source>"
- default action: save draft

### 7.9 Find Similar Roles And Seed Framework

User examples:

- "Find roles similar to Risk Analyst."
- "Use selected roles to create a framework."

Current code paths:

- `RhoFrameworks.Tools.RoleTools.analyze_role(action: "find_similar")`
- `role_candidates` table
- row selection
- `RhoFrameworks.Tools.WorkflowTools.seed_framework_from_roles`
- `RhoFrameworks.UseCases.PickTemplate`

Artifact behavior:

- first artifact: `role_candidates`
- resulting artifact: `skill_library`
- workflow: `:seed_from_roles`
- metadata should retain selected source role ids/names

UI behavior:

- candidate table is a picker
- selected count is prominent
- next action: seed framework from selected roles
- resulting framework says "Built from N selected roles"

### 7.10 Clone Or Start Role Profile

User examples:

- "Clone this role."
- "Start a draft role profile from selected candidates."

Current code paths:

- `RhoFrameworks.Tools.RoleTools.manage_role`
- `RhoFrameworks.Tools.RoleTools.analyze_role`
- `role_profile` table
- `role_candidates` table selection

Artifact behavior:

- primary artifact: `role_profile`
- workflow: `:role_profile_edit`

UI behavior:

- make required level and required/optional status central
- do not make it look like a reusable skill framework

### 7.11 Gap Analysis / Lens Scoring

User examples:

- "What skills are missing?"
- "Score this role against the lens."

Current code paths:

- `RhoFrameworks.Tools.RoleTools.analyze_role(action: "gap_analysis")`
- `RhoFrameworks.Tools.LensTools.score_role`
- `RhoFrameworks.Tools.LensTools.lens_dashboard`
- `RhoWeb.Workspaces.LensDashboard`

Artifact behavior:

- future artifact kind: `:analysis_result`
- linked to role profile and/or skill library

UI behavior:

- render findings as reviewable recommendations
- link findings to affected rows when possible
- next actions: add missing skills, adjust required level, dismiss

## 8. Metadata Contract

`Rho.Effect.Table` already has a `metadata` field. Use it.

Recommended metadata keys:

```elixir
%{
  workflow: :jd_extraction,
  artifact_kind: :skill_library,
  title: "CEO Skill Framework",
  source_label: "CEO Job Description.pdf",

  library_id: "...",
  library_name: "CEO",
  role_profile_id: "...",
  role_name: "CEO",

  source_upload_id: "upl_...",
  source_document_name: "CEO Job Description.pdf",

  source_library_ids: ["..."],
  source_library_names: ["HR Assistant", "People Ops"],
  source_role_profile_ids: ["..."],
  source_role_names: ["Risk Analyst", "Compliance Officer"],

  linked_library_table: "library:CEO",
  linked_role_table: "role_profile",
  output_table: "library:People Team",

  clean_count: 18,
  conflict_count: 4,
  unresolved_count: 4,

  ui_intent: %{
    surface: :conflict_review,
    artifact_table: "combine_preview",
    allowed_actions: [:resolve_conflicts, :create_merged_library],
    props: %{
      decision_modes: [:keep_left, :keep_right, :merge, :keep_both]
    }
  },

  persisted?: false,
  published?: false,
  immutable?: false,
  dirty?: true
}
```

Do not require all keys. The summary layer should derive reasonable fallback
values from table name, schema name, and rows.

Where to add metadata first:

- `extract_role_from_jd` effects
- `import_library_from_upload` effects
- `generate_framework_skeletons` effects
- `combine_libraries` preview effect
- `dedup_library` effect
- `seed_framework_from_roles` effect
- `load_library` / `fork_library` effects

`ui_intent` is optional. If absent, `WorkbenchContext` and
`RhoWeb.WorkbenchPresenter` should still choose a conservative default surface
from artifact kind and state. If present, it is a request, not an instruction to
execute arbitrary UI code.

## 9. Workbench Context Derivation

### 9.1 Inputs

Use:

- session snapshot from `DataTable.get_session_snapshot/1`
- active table from `DataTable.get_active_table/1`
- active table snapshot from `DataTable.get_table_snapshot/2`
- selections from `DataTable.get_selection/2`
- `ws_state.metadata` in web
- metadata carried by `:view_change` events

Important current shapes:

`DataTable.get_session_snapshot/1` returns tables with:

```elixir
%{
  name: table.name,
  schema: table.schema,
  row_count: row_count,
  version: version
}
```

`DataTable.get_table_snapshot/2` returns:

```elixir
%{
  name: table.name,
  schema: table.schema,
  rows: rows,
  row_count: row_count,
  version: version
}
```

### 9.2 Kind Inference

Prefer explicit metadata:

```elixir
metadata[:artifact_kind]
```

Fallback rules:

- schema name `"library"` or table starts with `"library:"` -> `:skill_library`
- schema name `"role_profile"` or table `"role_profile"` -> `:role_profile`
- schema name/table `"role_candidates"` -> `:role_candidates`
- schema name/table `"combine_preview"` -> `:combine_preview`
- schema name/table `"dedup_preview"` -> `:dedup_preview`
- otherwise -> `:generic_table`

### 9.3 Metric Derivation

Skill library:

- `skills`: row count
- `categories`: unique non-empty `category`
- `clusters`: unique non-empty `{category, cluster}`
- `proficiency_levels`: sum of `length(proficiency_levels || [])`
- `missing_levels`: rows where `proficiency_levels` is empty

Role profile:

- `required_skills`: row count
- `required`: count where `required == true`
- `optional`: count where `required == false`
- `missing_required_levels`: rows with nil/blank/0 `required_level`
- `unverified`: rows where `verification` is nil, blank, or not accepted

Role candidates:

- `candidates`: row count
- `queries`: unique `query`
- `selected`: selection count

Combine/dedup:

- `pairs`: row count
- `unresolved`: rows where `resolution` is nil, blank, or `"unresolved"`
- `resolved`: row count minus unresolved
- `clusters`: unique `cluster`, if present

### 9.4 Action Derivation

The first version can be deterministic and conservative.

Skill library:

- always: export
- if rows > 0: save draft
- if missing_levels > 0: generate levels
- if rows > 0: suggest skills
- if saved/persisted and rows > 0: publish
- if saved/persisted: fork, dedup

Role profile:

- if rows > 0: save role profile
- if linked library exists: map to framework
- if rows > 0: review gaps, export

Role candidates:

- if selected > 0: seed framework from selected roles
- if selected == 1: clone selected role

Combine/dedup:

- if unresolved > 0: resolve conflicts/duplicates
- if unresolved == 0 and rows > 0: create merged library or apply cleanup

Actions can initially render as buttons that submit existing events or canned
agent prompts. Direct deterministic wiring can come later.

## 10. UI Plan

### 10.1 Workbench Layout

Default workbench mode:

```text
Top app nav

Artifact/workflow strip
  JD Extraction: CEO Job Description.pdf
  [CEO Skill Framework] [CEO Role Requirements]

Main area
  Left: active artifact editor/review table
  Right: assistant panel
```

Chat remains intact, but workbench mode should not show full chat management
chrome by default.

### 10.2 Artifact Strip

Replace raw data-table tabs as the primary product surface.

Internal table tabs can still exist, but the visible labels should come from
artifact summaries:

```text
[CEO Skill Framework 7 skills] [CEO Role Requirements 7 required skills]
```

For combine:

```text
[Combine Review 4 unresolved]
```

For candidate roles:

```text
[Candidate Roles 12 results, 3 selected]
```

### 10.3 Active Artifact Header

Use shared summary:

```text
CEO Skill Framework
Generated from CEO Job Description.pdf
Draft | 7 skills | 4 categories | 0 levels | 7 need levels

[Save draft] [Generate levels] [Suggest skills] [Publish] [Export]
```

Role profile:

```text
CEO Role Requirements
Linked to CEO Skill Framework
Draft | 7 required skills | 3 required | 4 optional

[Save role profile] [Map to framework] [Review gaps] [Export]
```

Combine:

```text
Combine Libraries
HR Assistant + People Ops -> People Team Framework
18 clean | 4 conflicts unresolved

[Create merged library disabled] [Export review]
```

### 10.4 Table Body

Keep existing table mechanics, but use artifact language:

- skill library: `Add skill`, `No levels yet`, `Generate levels`
- role profile: `Add required skill`, `Required level`, `Required`
- role candidates: picker language and prominent selected count
- combine/dedup: decision queue language

Do not build a new table engine in this redesign.

### 10.5 Assistant Panel

Chatbox stays intact:

- chat feed remains
- chat input remains
- attachments remain
- agent/session messaging remains
- chat-only route keeps fuller chat management

Workbench mode changes:

- hide chat history rail by default
- show current assistant conversation
- show suggested next actions based on active artifact
- hide token/session/raw tool detail unless debug mode is on

### 10.6 Debug Mode

When debug mode is off:

- summarize tool calls
- hide token counts
- hide session/tape ids

When debug mode is on:

- show raw tool calls
- show debug panel
- show session/tape/token details

## 11. Agent Context Plan

Use the same workbench context in `Rho.Stdlib.Plugins.DataTable.prompt_sections/2`.

Example markdown:

```text
Workbench context
Workflow: JD Extraction
Source: CEO Job Description.pdf

Artifacts:
- library:CEO [skill_library] currently open
  display: CEO Skill Framework
  summary: 7 skills, 4 categories, 0 proficiency levels, 7 skills missing levels
  selected: 2
- role_profile [role_profile]
  display: CEO Role Requirements
  summary: 7 required skills, 3 required, 4 optional

Selected rows in library:CEO:
- row_123 skill_name=Fundraising category=Business levels=0
- row_456 skill_name=Market Positioning category=Business levels=0

When the user says "this framework", "these skills", "selected skills", or
"the table", they mean the currently open artifact unless they name another
artifact explicitly.
```

Rules:

- include rich details only for active table and selected rows
- keep non-active artifacts compact
- never dump entire tables into prompt
- include exact table names for tool calls
- include exact field names for edits
- distinguish skill library from role requirements
- include workflow/linkage when available

XML prompt format should carry the same information in compact nodes/attrs.

## 12. Generative UI Direction

Rho should implement generative UI as an internal, Phoenix-native pattern before
adopting an external protocol or library.

Recommended internal loop:

```text
user intent + WorkbenchContext + tool/effect metadata
  -> structured UI intent
  -> RhoWeb.WorkbenchPresenter
  -> trusted Phoenix component
  -> user action
  -> DataTable / workflow tool / tape event
```

This improves user experience by making the interface match the current task:

- a JD extraction shows linked framework and role-requirement artifacts
- a role search shows a picker, not a generic spreadsheet
- a combine result shows a conflict queue with disabled merge until resolved
- a dedup result shows review decisions, not raw duplicate rows
- a gap analysis shows recommendations tied back to affected artifacts

Do not add React, Vercel AI SDK, A2UI, AG-UI, or MCP Apps for the first version.
Those are useful references and possible future interoperability targets, but
the core value comes from Rho's semantic layer:

- `Rho.Effect.Table.metadata`
- `Rho.Stdlib.DataTable.WorkbenchContext`
- `RhoWeb.WorkbenchPresenter`
- trusted `rho_web` components

External protocols become interesting later if Rho needs:

- A2UI-style portable UI across web/mobile/desktop clients
- AG-UI-style standardized agent/frontend event streaming
- MCP Apps/OpenAI Apps SDK-style interactive widgets inside external AI clients
- cross-agent or third-party agent surfaces rendered inside the Rho workbench

Until then, keep the model small and deterministic:

```text
agent chooses intent; Rho chooses rendering
```

## 13. Implementation Phases

### Phase 1: Shared Summary Layer

Goal:

- create the pure artifact/workflow summary layer
- no major visual changes yet

Files:

- add `apps/rho_stdlib/lib/rho/stdlib/data_table/workbench_context.ex`
- add tests under `apps/rho_stdlib/test/rho/stdlib/data_table/`

Tasks:

- define summary structs or plain maps
- implement artifact kind inference
- implement title derivation
- implement metrics for all known table kinds
- implement selected-row preview fields
- implement action derivation
- implement markdown prompt rendering helper

Tests:

- `library:CEO` -> `:skill_library`, title `CEO Skill Framework`
- `role_profile` -> `:role_profile`, title `Role Requirements`
- `role_candidates` -> picker metrics
- `combine_preview` -> unresolved count
- `dedup_preview` -> unresolved count
- selected rows are previewed with kind-specific fields
- unknown table falls back to generic

### Phase 2: Metadata In Workflow Effects

Goal:

- populate `Rho.Effect.Table.metadata` where workflows already know intent

Files:

- `apps/rho_frameworks/lib/rho_frameworks/tools/workflow_tools.ex`
- `apps/rho_frameworks/lib/rho_frameworks/tools/library_tools.ex`
- `apps/rho_frameworks/lib/rho_frameworks/tools/role_tools.ex`

Tasks:

- add metadata to JD extraction effects
- add metadata to import effects
- add metadata to generate framework effects
- add metadata to combine preview effects
- add metadata to dedup preview effects
- add metadata to seed-from-roles effect
- add metadata to load/fork library effects where practical

Do not block the UI on perfect metadata. The summary layer must still derive
fallbacks.

Tests:

- effect dispatcher preserves metadata into `ws_state.metadata`
- workflow tool tests assert important metadata keys for JD and combine

### Phase 3: Workbench Header And Artifact Strip

Goal:

- render artifacts instead of raw table names as the primary product surface

Files:

- `apps/rho_web/lib/rho_web/workspaces/data_table.ex`
- `apps/rho_web/lib/rho_web/components/data_table_component.ex`
- `apps/rho_web/lib/rho_web/workbench_presenter.ex`
- `apps/rho_web/lib/rho_web/inline_css.ex`
- `apps/rho_web/test/rho_web/components/data_table_component_test.exs`

Tasks:

- compute workbench context in `RhoWeb.Workspaces.DataTable.component_assigns/2`
- pass it into `DataTableComponent`
- render artifact strip
- render active artifact header
- replace `rows` language with artifact nouns
- keep raw table name as tooltip/debug label, not primary title
- keep existing table body and editing events intact

Acceptance:

- JD extraction shows framework and role requirements as linked artifacts
- role profile no longer looks like a skill library
- combine/dedup previews show decision state
- existing table switching still works

### Phase 4: Agent Prompt Context

Goal:

- agent receives the same active artifact context the user sees

Files:

- `apps/rho_stdlib/lib/rho/stdlib/plugins/data_table.ex`
- tests for DataTable plugin prompt sections

Tasks:

- call `WorkbenchContext` from `prompt_sections/2`
- include workflow/artifact summary
- include selected-row previews
- preserve exact columns and table names
- preserve current active-table instruction
- support markdown and XML prompt formats

Acceptance:

- "generate levels for selected skills" should not require the agent to call
  `list_tables` or `query_table` just to discover active table and selected rows
- "what is missing in this framework?" can answer from context first

### Phase 4.5: Generative Workbench Surfaces

Goal:

- let tools or the agent request task-specific workbench surfaces through
  structured intent, while `rho_web` renders only trusted components

Files:

- `apps/rho_web/lib/rho_web/workbench_presenter.ex`
- `apps/rho_web/lib/rho_web/workspaces/data_table.ex`
- `apps/rho_web/lib/rho_web/components/data_table_component.ex`
- `apps/rho_stdlib/lib/rho/stdlib/data_table/workbench_context.ex`
- optional later: `apps/rho/lib/rho/effect/workbench_surface.ex`

Tasks:

- define a small surface catalog in the presenter
- map artifact kind/state/action summaries to default surfaces
- read optional `metadata[:ui_intent]` as a surface request
- validate requested surface kinds and allowed actions against the catalog
- render the first surfaces with existing table data and selections:
  `:linked_artifacts`, `:role_candidate_picker`, `:conflict_review`,
  `:dedup_review`, `:gap_review`
- keep all mutations flowing through existing LiveView events, workflow tools,
  DataTable calls, and tape recording

Acceptance:

- JD extraction can show linked artifacts without relying on chat prose
- role candidates render as a picker with selected count and next action
- combine/dedup render as decision queues with unresolved counts
- invalid or unknown `ui_intent` falls back to the normal artifact table
- no generated HTML/HEEx/CSS/client code is executed

### Phase 5: Chat Panel Simplification

Goal:

- keep chatbox intact but make it support the artifact workbench

Files:

- `apps/rho_web/lib/rho_web/live/app_live.ex`
- `apps/rho_web/lib/rho_web/components/chat_components.ex`
- `apps/rho_web/lib/rho_web/inline_css.ex`

Tasks:

- hide chat history rail by default in workbench mode
- keep chat-only route full featured
- hide token/session details unless debug mode is on
- summarize tool calls outside debug mode
- show suggested next actions from active artifact summary, initially as
  prompt chips or existing event buttons

Acceptance:

- chat input/feed still work
- file upload still works
- debug mode still restores raw tool details

### Phase 6: Decision Surfaces

Goal:

- add focused UI treatment only for artifacts that need decisions

Artifacts:

- `role_candidates`
- `combine_preview`
- `dedup_preview`
- eventually `analysis_result`

Tasks:

- role candidates: stronger picker UI and selected count
- combine preview: unresolved count, disabled merge action until resolved
- dedup preview: review queue language and apply/save action
- analysis results: render findings as actionable recommendations when available

Do not redesign the entire table engine.

## 14. First Implementation Session Scope

Recommended first coding session:

1. Implement `Rho.Stdlib.DataTable.WorkbenchContext`.
2. Add tests for kind/title/metrics/action derivation.
3. Use it in `RhoWeb.Workspaces.DataTable.component_assigns/2`.
4. Render active artifact title and metrics in `DataTableComponent`.
5. Add minimal prompt-section integration for active artifact context.
6. Run focused tests and compile.

Defer:

- full artifact strip styling
- assistant action chips
- direct deterministic action wiring
- large CSS restyling
- complete metadata coverage
- generative workbench surface catalog beyond the default artifact summary
- specialized decision-surface layouts

This gives immediate benefit:

- user sees "CEO Skill Framework" instead of `library:CEO`
- user sees role requirements as a different artifact type
- agent receives active artifact context
- existing table/chat behavior remains intact

## 15. Verification Commands

Focused tests:

```bash
mix test apps/rho_stdlib/test/rho/stdlib/data_table
mix test apps/rho_stdlib/test/rho/stdlib/plugins/data_table_test.exs
mix test apps/rho_web/test/rho_web/components/data_table_component_test.exs
mix test apps/rho_web/test/rho_web/components/chat_components_test.exs
```

Broader tests:

```bash
mix test --app rho_stdlib
mix test --app rho_web
mix test --app rho_frameworks
```

Compile:

```bash
MIX_ENV=test mix compile --force --warnings-as-errors
```

## 16. Manual QA Scenarios

### Basic Skill Framework

- load `library:CEO`
- header says `CEO Skill Framework`
- metrics show skills/categories/levels/missing levels
- actions use skill-framework language

### Role Requirements

- load `role_profile`
- header says `Role Requirements`
- metrics show required skills and required/optional counts
- action labels are role-specific
- it does not look like another skill library

### JD Upload

- upload or paste JD
- UI shows both linked artifacts
- user can switch between framework and role requirements without using raw table names
- agent context mentions both linked artifacts

### Import Spreadsheet

- import a single library
- imported framework title is clear
- warnings/partial failures are visible if present

### Combine Libraries

- preview combine
- source libraries and target name are visible
- conflict/unresolved counts are visible
- merge/create action is disabled until resolved

### Dedup Library

- open dedup review
- duplicate candidates read as a review queue
- unresolved count is visible
- save/apply cleanup path is clear

### Role Candidate Picker

- find similar roles
- candidate view reads like a picker
- selected count is prominent
- next action is seed framework or clone selected role

### Chat And Debug

- chat input still works
- attachments still work
- chat-only route still shows fuller chat management
- raw tool calls hidden by default
- debug mode restores raw tool calls/tokens/session details

### Generative Workbench Surfaces

- JD extraction can request a linked-artifact surface
- role candidates can request a picker surface
- combine/dedup can request review-queue surfaces
- unknown or invalid surface requests fall back to the normal artifact table
- no generated UI code is executed

## 17. Risks And Guardrails

### Do Not Create A Second State Store

Workbench context is derived from DataTable snapshots, selections, metadata, and
schema. It is not canonical state.

### Do Not Break App Boundaries

Put shared pure derivation in `rho_stdlib`. Keep Phoenix rendering in `rho_web`.
Do not make `rho_stdlib` depend on `rho_frameworks`.

### Do Not Depend On Perfect Metadata

Metadata improves workflow context, but fallback inference from table/schema/rows
must work.

### Do Not Dump Tables Into Prompts

Prompt context should be compact. Include active artifact summary and selected
row previews. Use tools for deeper reads.

### Do Not Hide Debug Capability

Raw tool calls, token counts, and session/tape ids are still needed. Gate them
behind debug mode.

### Do Not Blur Library vs Role

A skill library defines reusable skill meaning and proficiency ladders. A role
profile selects skills and required levels for a role. The UI and prompt context
must preserve that distinction.

### Do Not Overbuild Review Mode First

The artifact summary/header/prompt layer will solve more confusion than a full
review-mode redesign. Add special layouts only where decisions require them.

### Do Not Execute Arbitrary Generated UI

Generative UI in Rho means structured surface intent plus trusted Phoenix
components. Never execute LLM-generated HTML, HEEx, CSS, JavaScript, or
component code.

### Do Not Add A Generative UI Library First

Start with Rho's native semantic layer and LiveView components. Consider A2UI,
AG-UI, MCP Apps, or a React/Next.js stack only when there is a concrete
interoperability requirement.

## 18. Definition Of Done

The redesign track is complete when:

- the active artifact is obvious without reading internal table names
- linked artifacts are visible for workflows like JD extraction
- skill libraries and role requirements are naturally distinguishable
- combine/dedup/candidate workflows read like decisions and pickers
- task-specific surfaces appear for review, picker, and confirmation moments
  without requiring the user to issue chat commands
- the assistant receives compact active artifact context
- chat remains intact but supports the workbench instead of competing with it
- debug details remain available
- existing save/publish/fork/export/edit/table-selection behavior still works
