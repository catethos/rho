# Workbench Home And Action Plumbing Plan

## 1. Goal

Make the artifact workbench the obvious first-class product surface, while keeping
chat as an assistant inside the workbench rather than the only way to discover
workflows.

The target first screen is:

```text
Workbench
Create, import, review, or load an HR artifact.

[Create Framework] [Extract JD] [Import Library] [Load Library] [Find Roles]

Assistant panel
```

The buttons should not be decorative shortcuts. Each one needs real plumbing
into the same workflow/use-case/tool paths the chat agent already uses.

## 2. Current State

The pieces already exist, but the entry points are scattered:

- `RhoWeb.Workspaces.DataTable` is registered as the `:data_table` workspace.
- `RhoWeb.Projections.DataTableProjection.init/0` initializes data-table
  workspace state with `active_table: "main"`.
- `RhoWeb.AppLive.determine_workspaces/1` currently returns `%{}`, so no
  workbench panel is open on initial load.
- The workbench becomes visible when tools emit
  `%Rho.Effect.OpenWorkspace{key: :data_table}`.
- Workflow tools already emit `%Rho.Effect.Table{}` with metadata:
  - `generate_framework_skeletons`
  - `extract_role_from_jd`
  - `import_library_from_upload`
  - `load_library`
  - `analyze_role(action: "find_similar")`
- The table surface now hides empty `"main"` when real artifacts exist, and
  treats non-empty `"main"` as `Scratch Table`.

The UX issue is that the user learns:

```text
type something in chat -> maybe a workbench appears
```

Instead, they should learn:

```text
start from the workbench -> use chat when language helps
```

## 3. Product Model

The workbench should always be conceptually present.

The workbench should render one of three states:

1. **Home state**
   - No meaningful artifacts exist.
   - No table body is shown.
   - Shows workflow action cards.

2. **Artifact state**
   - One or more named artifacts exist.
   - Shows artifact strip, header, surface notice/review UI, and table body.

3. **Scratch state**
   - Only `"main"` has rows.
   - Shows `Scratch Table`, not `Main`.
   - Presents it as ad hoc data that can later be converted/imported into a
     named artifact.

## 4. Implementation Strategy

Use a small, explicit action layer instead of wiring five bespoke button
handlers directly into `AppLive`.

Add:

```text
RhoWeb.WorkbenchActions
RhoWeb.WorkbenchActionRunner
RhoWeb.WorkbenchActionComponent
```

Suggested ownership:

- `RhoWeb.WorkbenchActions`
  - Pure catalog of workbench actions, labels, descriptions, required inputs,
    and execution mode.

- `RhoWeb.WorkbenchActionComponent`
  - Renders the home-state action cards and lightweight forms/modals.
  - Contains no domain execution logic.

- `RhoWeb.WorkbenchActionRunner`
  - Bridges LiveView events to either:
    - existing chat-agent prompts,
    - existing use cases,
    - existing `RhoFrameworks.Workbench` APIs,
    - existing upload registry/observer APIs,
    - or existing effects.

The runner should return a small tagged result:

```elixir
{:ok, socket}
{:error, user_message, socket}
{:prompt, prompt_text, socket}
{:navigate, path, socket}
```

This keeps LiveView event handlers thin.

## 5. Open Workbench By Default

Change the initial workspace model so the Workbench is visible from the start.

In `RhoWeb.AppLive.determine_workspaces/1`, return:

```elixir
%{data_table: RhoWeb.Workspaces.DataTable}
```

Then rename the workspace label:

```elixir
def label, do: "Workbench"
```

Do not show a raw empty table. `DataTableComponent` should detect the home
state and render the home action surface.

Home-state condition:

```elixir
artifact_home? =
  no_non_main_tables? and
  active_artifact.table_name == "main" and
  active_artifact.row_count == 0
```

Where `no_non_main_tables?` means:

```elixir
Enum.all?(table_order, &(&1 == "main"))
```

or the table list is empty because the DataTable server has not started yet.

## 6. Workbench Home UI

Add a home component inside `DataTableComponent`:

```elixir
<.workbench_home actions={WorkbenchActions.home_actions()} />
```

Recommended cards:

```text
Create Framework
Build a new skill framework from a short brief.

Extract JD
Upload or paste a job description to create linked framework and role artifacts.

Import Library
Turn a CSV/XLSX skills file into a framework artifact.

Load Library
Open a saved framework for review or editing.

Find Roles
Search similar roles, pick candidates, then seed a framework.
```

Each card should emit:

```elixir
phx-click="workbench_action_open"
phx-value-action={action.id}
```

Because `DataTableComponent` is a LiveComponent, it should forward to the
parent process:

```elixir
send(self(), {:workbench_action_open, action_id})
```

`AppLive` owns the modal state.

## 7. Action Catalog

Create `apps/rho_web/lib/rho_web/workbench_actions.ex`.

Initial shape:

```elixir
defmodule RhoWeb.WorkbenchActions do
  def home_actions do
    [
      %{
        id: :create_framework,
        label: "Create Framework",
        summary: "Build a new skill framework from a short brief.",
        mode: :form,
        fields: [:name, :description, :domain, :target_roles, :skill_count],
        execution: :agent_prompt
      },
      %{
        id: :extract_jd,
        label: "Extract JD",
        summary: "Create linked skill framework and role requirements from a JD.",
        mode: :upload_or_text,
        fields: [:upload_id, :text, :role_name, :library_name],
        execution: :agent_prompt
      },
      %{
        id: :import_library,
        label: "Import Library",
        summary: "Import CSV/XLSX skills into a framework.",
        mode: :upload,
        fields: [:upload_id, :library_name, :sheet],
        execution: :direct_or_prompt
      },
      %{
        id: :load_library,
        label: "Load Library",
        summary: "Open an existing saved framework.",
        mode: :picker,
        fields: [:library_id],
        execution: :direct
      },
      %{
        id: :find_roles,
        label: "Find Roles",
        summary: "Search similar roles and choose source roles.",
        mode: :form,
        fields: [:queries, :library_id, :limit],
        execution: :direct
      }
    ]
  end
end
```

Use maps first. A struct can come later if pattern matching grows.

## 8. AppLive Event Plumbing

Add assigns:

```elixir
assign(:workbench_action_modal, nil)
assign(:workbench_action_form, %{})
assign(:workbench_action_error, nil)
assign(:workbench_action_busy?, false)
```

Add parent handlers:

```elixir
def handle_info({:workbench_action_open, action_id}, socket)
def handle_event("workbench_action_cancel", _params, socket)
def handle_event("workbench_action_submit", params, socket)
```

Optional:

```elixir
def handle_event("workbench_action_upload_validate", params, socket)
```

Do not overload `send_workbench_suggestion`. Suggestions are action chips for
existing artifacts. Home actions are workflow starters and should have their
own events.

## 9. Execution Model

Use two execution lanes.

### Lane A: Agent-Assisted Prompt

Best for LLM-heavy or conversationally ambiguous actions.

Implementation:

```elixir
WorkbenchActionRunner.send_prompt(socket, prompt)
```

This should reuse the existing session creation path:

- ensure session with `SessionCore.ensure_session/3`
- subscribe/hydrate
- maybe patch URL with `maybe_push_new_session_patch/3`
- call `SessionCore.send_message/2`

The prompt should be explicit and tool-shaped, but user-readable.

Example:

```text
Create a new skill framework.

Use generate_framework_skeletons with:
- name: Product Manager
- description: ...
- domain: ...
- target_roles: ...
- skill_count: 12

Open the Workbench when the artifact is ready.
```

This is the fastest path because the existing tools already open the
workbench, stream rows, and attach metadata.

### Lane B: Direct Deterministic Runner

Best for actions that do not require language reasoning:

- Load Library
- Find Roles
- eventually Import Library after upload/sheet selection is clear

Implementation:

```elixir
WorkbenchActionRunner.run(socket, :load_library, params)
WorkbenchActionRunner.run(socket, :find_roles, params)
```

Direct runners should:

- ensure a session exists,
- ensure `DataTable` and `Uploads` servers as needed,
- call existing domain APIs,
- write named tables through `RhoFrameworks.Workbench` or `DataTable`,
- emit or apply the same metadata shape that tool effects use,
- open/activate the workbench.

## 10. Shared Helper: Ensure Workbench Session

Add a helper in `WorkbenchActionRunner` or `AppLive`:

```elixir
ensure_workbench_session(socket) ::
  {session_id, socket}
```

It should mirror existing chat submission behavior:

```elixir
if socket.assigns.session_id do
  {sid, socket}
else
  ensure_opts = session_ensure_opts(:data_table)
  {sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
  socket = SessionCore.subscribe_and_hydrate(socket, sid, ensure_opts)
  socket = maybe_push_new_session_patch(socket, sid, true)
  {sid, socket}
end
```

Then:

```elixir
socket = open_data_table_workspace(socket)
```

If `open_data_table_workspace/1` remains private in `AppLive`, either:

- keep the runner inside `AppLive` initially, or
- extract a small public helper module for workspace shell mutations.

Prefer initial locality over over-abstraction.

## 11. Action: Create Framework

### UX

Clicking **Create Framework** opens a compact form:

- Framework name
- Description
- Domain
- Target roles
- Skill count, default `12`

Primary button:

```text
Create Framework
```

Secondary:

```text
Open Guided Flow
```

### V1 Plumbing

Use the agent-assisted lane.

Submit builds a prompt:

```text
Create a new skill framework in the Workbench.

Call generate_framework_skeletons with:
- name: ...
- description: ...
- domain: ...
- target_roles: ...
- skill_count: ...

After the skeleton is generated, keep it open in the Workbench and suggest the
next step for missing proficiency levels.
```

Why V1 prompt lane:

- `generate_framework_skeletons` already pre-opens the table before streaming.
- It already emits `%Rho.Effect.OpenWorkspace{key: :data_table}`.
- It already emits a `%Rho.Effect.Table{schema_key: :skill_library}` metadata
  effect.
- It already handles BAML streaming/watchdog concerns.

### V2 Direct Lane

Create `WorkbenchActionRunner.create_framework/2`:

- ensure session,
- create `Scope.from_context`-equivalent scope,
- call `GenerateFrameworkSkeletons.run/2`,
- dispatch the same effects as `WorkflowTools.generate_framework_skeletons`.

Do this only after the V1 prompt path is stable, because direct execution must
preserve streaming/progress behavior.

## 12. Action: Extract JD

### UX

Clicking **Extract JD** opens a modal with:

- Upload file dropzone: `.pdf`, `.docx`, `.txt`, `.md`
- Paste text area
- Optional role name
- Optional library name

Validation:

- require either upload or pasted text,
- disallow both only if that simplifies the first version,
- show the uploaded filename before submit.

### V1 Plumbing

Use agent-assisted lane after registering the upload.

Steps:

1. Ensure session.
2. Ensure `Rho.Stdlib.Uploads` server.
3. Use the existing LiveView upload pipeline:
   - `consume_uploaded_entries/3`
   - `Rho.Stdlib.Uploads.put/2`
4. For text paste, no upload is required.
5. Build prompt:

```text
Extract a job description into linked Workbench artifacts.

Use extract_role_from_jd with:
- upload_id: upl_...
- text: ...       # only when pasted text was used
- role_name: ...
- library_name: ...

Create both the skill framework and role requirements artifacts.
```

The existing tool returns:

- `OpenWorkspace(:data_table)`
- `Effect.Table` for the skill library
- `Effect.Table` for `role_profile`
- linked metadata between both artifacts

### V2 Direct Lane

Call `RhoFrameworks.UseCases.ExtractFromJD.run/2` directly and dispatch the same
effects built by `WorkflowTools.extract_role_from_jd`.

Extract helper functions from `WorkflowTools` if duplication grows:

```elixir
RhoFrameworks.WorkbenchEffects.jd_extraction(result, input)
```

## 13. Action: Import Library

### UX

Clicking **Import Library** opens a modal with:

- Upload file dropzone: `.csv`, `.xlsx`
- Optional library name
- Optional sheet selector once observation is available

First version can defer sheet picker and let the tool/use case use its default
sheet. The modal should still display observation warnings if available.

### Recommended V1 Plumbing

Use direct upload registration plus agent-assisted execution.

Steps:

1. Ensure session.
2. Ensure `Uploads` server.
3. Register file through `Uploads.put/2`.
4. Optionally call `Rho.Stdlib.Uploads.Observer.observe/2` to get:
   - sheet names,
   - detected hints,
   - warnings.
5. If multiple sheets or ambiguous shape:
   - keep modal open,
   - ask user for `library_name` and/or `sheet`.
6. Submit prompt:

```text
Import the uploaded structured file as a skill library.

Use import_library_from_upload with:
- upload_id: upl_...
- library_name: ...
- sheet: ...

Open the imported framework in the Workbench.
```

### V2 Direct Lane

Once the sheet/name UI is solid, call:

```elixir
RhoFrameworks.UseCases.ImportFromUpload.run(input, scope)
```

Then dispatch the same effects as `WorkflowTools.import_library_from_upload`.

This action is a good candidate for direct execution because spreadsheet import
is mostly deterministic after upload observation.

## 14. Action: Load Library

### UX

Clicking **Load Library** opens a picker:

- Search saved libraries by name.
- Show name, version/draft status, skill count if cheap.
- Support direct selection.

### V1 Plumbing

Use direct lane.

There is already direct loading code in `AppLive`:

```elixir
load_library_into_data_table(socket, library_id)
load_library_rows_into_data_table(socket, sid, lib)
```

Refactor this into `WorkbenchActionRunner.load_library/2` or keep it private
and call it from the new event handler.

On submit:

1. Ensure session.
2. Ensure/open workbench.
3. Load library rows:
   - `RhoFrameworks.Library.get_library/2`
   - `RhoFrameworks.Library.load_library_rows/1`
4. Ensure named table:
   - `table_name = "library:" <> lib.name`
   - `DataTable.ensure_table/4`
5. Write rows:
   - `DataTable.replace_all/3`
6. Update `ws_state`:
   - `active_table: table_name`
   - `view_key: :skill_library`
   - `metadata: %{workflow: :edit_existing, artifact_kind: :skill_library, ...}`
7. Publish view focus if active table changed.

This avoids routing through the agent for a deterministic load.

### Follow-Up

Unify with `LibraryTools.load_library` metadata so direct loads and chat loads
produce identical workbench summaries.

## 15. Action: Find Roles

### UX

Clicking **Find Roles** opens a form:

- Query or multiple role names
- Optional library filter
- Limit, default `10` or `20`

Submit button:

```text
Find Roles
```

Result:

- opens `role_candidates` as a picker surface,
- user checks rows,
- existing **Done — Seed Framework** button can continue the flow.

### V1 Plumbing

Use direct lane.

Steps:

1. Ensure session.
2. Build `Scope`.
3. For each query:
   - `RhoFrameworks.Roles.find_similar_roles/3`
4. Write candidates:
   - `RhoFrameworks.Workbench.write_role_candidates(scope, groups)`
5. Apply the same UI metadata used by `RoleTools.emit_role_candidates/2`:

```elixir
%{
  workflow: :role_search,
  artifact_kind: :role_candidates,
  title: "Candidate Roles",
  output_table: "role_candidates",
  source_role_names: queries,
  source_label: Enum.join(queries, ", "),
  candidate_count: total,
  query_count: length(per_query),
  ui_intent: %{
    surface: :role_candidate_picker,
    artifact_table: "role_candidates",
    allowed_actions: [:seed_framework_from_selected, :clone_selected_role],
    props: %{queries: queries}
  }
}
```

6. Open/activate workbench.
7. Set:
   - `active_table: "role_candidates"`
   - `view_key: :role_candidates`
   - `mode_label: "Candidate Roles"`
   - metadata above.

### Existing Continuation

The DataTableComponent already has:

```elixir
phx-click="candidates_done"
```

which sends:

```elixir
{:role_candidates_done}
```

`AppLive` currently turns that into a chat prompt asking the agent to call:

```text
seed_framework_from_roles(from_selected_candidates: "true")
```

Keep that for V1. Later, replace it with a direct seed modal:

- ask for new framework name,
- call `PickTemplate.run/2`,
- drop `role_candidates`,
- show resulting `skill_library`.

## 16. Home Actions Versus Artifact Suggestions

Keep these distinct:

- **Home actions** start workflows.
- **Workbench suggestions** continue the active artifact.

Current `workbench_suggestions/1` can stay in the chat input area.

New home actions should live in the workbench home surface, not the chat panel.

Do not make home action cards call `send_workbench_suggestion`; they need their
own event lifecycle because they may open forms, upload files, or pick existing
records before sending any prompt.

## 17. Upload Handling Details

Current chat upload path is embedded in `AppLive`:

- `consume_uploaded_entries/3`
- `Rho.Stdlib.Uploads.put/2`
- optional `Rho.Stdlib.Uploads.Observer.observe/2`
- `build_enriched_message/3`
- `submit_to_session/4`

For workbench actions, extract only the reusable pieces:

```elixir
register_workbench_uploads(socket, accepted_kinds) ::
  {:ok, socket, [Rho.Stdlib.Uploads.Handle.t()]} | {:error, socket, msg}
```

Do not duplicate the full chat enrichment path. Workbench actions need upload
ids and observations, not a rich chat transcript.

## 18. Effect/Metadata Consistency

Direct runners must produce the same metadata shape as chat tools. If they do
not, the UI will drift.

Add a shared module in `rho_frameworks`:

```text
apps/rho_frameworks/lib/rho_frameworks/workbench_effects.ex
```

Responsibilities:

- build `Effect.Table` for skill libraries,
- build `Effect.Table` for role profiles,
- build `Effect.Table` for role candidates,
- build metadata for JD extraction,
- build metadata for import,
- build metadata for edit/load,
- build metadata for seed-from-roles.

Then both:

- `RhoFrameworks.Tools.WorkflowTools`
- `RhoWeb.WorkbenchActionRunner`

can call the same builders.

This prevents chat-created artifacts and button-created artifacts from looking
different.

## 19. DataTable Visibility Rules

Keep these rules:

1. Empty `"main"` is never a visible artifact tab.
2. Non-empty `"main"` is `Scratch Table`.
3. Named tables are artifacts.
4. The Workbench home renders when no meaningful artifact exists.
5. The workbench opens by default, but the DataTable server does not need to
   start until an action or tool needs it.

Implementation detail:

- `DataTableComponent` can render home state from initialized projection state,
  even when `DataTable.get_session_snapshot/1` has never been called.

## 20. Routing And Navigation

The home actions should not navigate away unless the user chooses a guided flow.

Default:

- stay on the Workbench,
- open modal,
- submit,
- show progress or chat activity,
- artifact appears in same surface.

Optional secondary route:

```text
Open Guided Flow
```

For Create Framework, this can navigate to:

```text
/orgs/:slug/flows/create-framework
```

with intake encoded as query params if available.

## 21. Busy And Error States

Add a small workbench action status model:

```elixir
%{
  action: :import_library,
  status: :idle | :validating | :running | :error,
  message: nil | String.t()
}
```

UX:

- disable the submitting action while running,
- show "Importing..." or "Searching...",
- keep modal open on validation errors,
- close modal when an artifact appears,
- show errors as workbench-local flash, not only chat prose.

## 22. Testing Plan

### Unit Tests

Add tests for `RhoWeb.WorkbenchActions`:

- all five home actions exist,
- labels match expected text,
- action ids are stable atoms,
- each action declares a mode and execution lane.

Add tests for `WorkbenchActionRunner` pure helpers:

- prompt builder for Create Framework,
- prompt builder for Extract JD,
- prompt builder for Import Library,
- metadata builder parity where extracted.

### Component Tests

Extend `DataTableComponentTest`:

- renders Workbench home when no artifacts exist,
- home shows all five action cards,
- does not render a table body in home state,
- emits/forwards action open messages from card clicks if using LiveComponent
  event tests.

### LiveView Tests

Add tests for `AppLive`:

- initial chat page opens Workbench by default,
- clicking Create Framework opens modal,
- submitting Create Framework sends the expected message to the session,
- clicking Load Library opens picker,
- selecting a library writes/activates a named `library:<name>` table,
- clicking Find Roles writes/activates `role_candidates`.

### Integration Tests

Use focused tests rather than a full e2e first:

- Import CSV upload path registers upload and prompts/imports.
- Extract JD with pasted text sends/executes extraction path.
- Role search direct runner creates picker metadata.

## 23. Implementation Phases

### Phase 1: Visible Workbench Home

Files:

- `apps/rho_web/lib/rho_web/live/app_live.ex`
- `apps/rho_web/lib/rho_web/workspaces/data_table.ex`
- `apps/rho_web/lib/rho_web/components/data_table_component.ex`
- `apps/rho_web/lib/rho_web/workbench_actions.ex`
- `apps/rho_web/lib/rho_web/inline_css.ex`

Tasks:

- open DataTable workspace by default,
- rename label from `Skills Editor` to `Workbench`,
- render home state when no artifacts exist,
- render five action cards,
- wire click events to open a modal placeholder,
- tests for home rendering.

### Phase 2: Agent-Prompt Starters

Actions:

- Create Framework
- Extract JD
- Import Library

Tasks:

- add modal forms,
- add prompt builders,
- reuse session creation/send path,
- for upload actions, register files and pass upload ids into prompts,
- close modal after prompt send,
- show chat pending state.

This phase gives immediate working buttons without reimplementing LLM workflow
execution.

### Phase 3: Direct Deterministic Starters

Actions:

- Load Library
- Find Roles

Tasks:

- build library picker,
- refactor existing `load_library_into_data_table/2` into reusable runner,
- build role search form,
- write `role_candidates` directly with `RhoFrameworks.Workbench.write_role_candidates/2`,
- apply role picker metadata,
- tests for direct DataTable state.

### Phase 4: Shared Effect Builders

Files:

- `apps/rho_frameworks/lib/rho_frameworks/workbench_effects.ex`
- update `WorkflowTools`
- update `LibraryTools`
- update `RoleTools`
- update `WorkbenchActionRunner`

Tasks:

- deduplicate metadata/effect construction,
- ensure chat and direct actions produce identical artifact summaries,
- add tests for metadata parity.

### Phase 5: Direct Import/JD Execution

Actions:

- Import Library
- Extract JD

Tasks:

- after upload observation, call use cases directly when inputs are unambiguous,
- dispatch same effects as tools,
- keep agent prompt fallback for ambiguous cases,
- display import/JD errors locally.

### Phase 6: Direct Seed From Role Picker

Tasks:

- replace `Done — Seed Framework` prompt-only path with a modal asking for the
  new framework name,
- call the same path as `seed_framework_from_roles(from_selected_candidates: true)`,
- drop stale `role_candidates`,
- activate generated `library:<name>`.

## 24. Acceptance Criteria

The work is complete when:

- The Workbench is visible on first load.
- Empty `main` never appears as a product artifact.
- Home state shows five working workflow actions.
- Create Framework can start a framework without hand-typing a chat prompt.
- Extract JD can start from upload or pasted text.
- Import Library can start from CSV/XLSX upload.
- Load Library can open an existing framework directly.
- Find Roles can populate the role candidate picker directly.
- Chat-created and button-created artifacts have the same titles, metrics,
  metadata, and surfaces.
- Existing chat workflows still work.
- Existing file upload/chat input still work.
- Debug details remain available in debug mode.

## 25. Key Design Decision

The Workbench buttons should not bypass the agent everywhere.

Use this rule:

```text
If the action is mostly data movement, run it directly.
If the action is LLM-heavy or ambiguous, start with a structured agent prompt.
Once the direct path can preserve streaming, progress, metadata, and errors,
graduate it out of the prompt lane.
```

That gives us a better UX quickly without forking the business logic into a
parallel product.
