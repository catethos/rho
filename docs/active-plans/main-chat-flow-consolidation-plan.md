# Main Chat Flow Consolidation Plan

## Goal

Make the main chat page the only user entry point for create-framework workflows.

The create-framework experience should run inside the existing assistant chatbox
as first-class flow cards, while the Workbench remains the artifact surface for
tables, libraries, role candidates, taxonomy review, and generated skills.

The target product shape is:

```text
Main chat owns the conversation.
FlowRunner owns deterministic workflow state.
Workbench owns editable artifacts.
Agents help only inside the current step.
```

Users should not need to choose between:

- a Workbench action modal,
- a guided flow page,
- a chat skill playbook,
- or `/flows/create-framework?mode=chat_native`.

There should be one natural path: type or click in chat, then edit artifacts in
the Workbench when the flow opens them.

## Current State Audit

### Main Chat

The main chat shell is hosted by `RhoWeb.AppLive`.

Relevant modules:

- `apps/rho_web/lib/rho_web/live/app_live.ex`
- `apps/rho_web/lib/rho_web/live/app_live/message_events.ex`
- `apps/rho_web/lib/rho_web/live/app_live/chat_shell_components.ex`
- `apps/rho_web/lib/rho_web/components/chat_components.ex`
- `apps/rho_web/lib/rho_web/projections/session_state.ex`
- `apps/rho_web/lib/rho_web/session/session_core.ex`
- `apps/rho_web/lib/rho_web/session/signal_router.ex`

Today, `send_message` sends user text directly to the active agent via
`SessionCore.send_message/3`. Chat rendering is driven by `agent_messages` and
supports message types such as `:text`, `:tool_call`, `:thinking`, `:delegation`,
`:image`, `:ui`, `:welcome`, and `:error`.

There is no native `:flow_card` message type yet.

### Smart Entry

`RhoWeb.AppLive.SmartEntry` currently detects workflow intent and navigates away
from chat:

```text
"create a framework..." -> /orgs/:slug/flows/create-framework?...query...
```

This is the opposite of the desired consolidation. Smart entry should start a
chat-hosted flow session instead of pushing a route.

Relevant module:

- `apps/rho_web/lib/rho_web/live/app_live/smart_entry.ex`

### Workbench Actions

`RhoWeb.WorkbenchActionComponent` and `RhoWeb.WorkbenchActionRunner` currently
provide a Workbench home action modal for "Create from brief".

For create-framework, `WorkbenchActionRunner.build_prompt/2` generates an agent
prompt that tells the assistant which workflow tools to call. This means the
agent prompt is still acting as a workflow playbook.

Relevant modules:

- `apps/rho_web/lib/rho_web/workbench_action_component.ex`
- `apps/rho_web/lib/rho_web/workbench_action_runner.ex`
- `apps/rho_web/lib/rho_web/workbench_actions.ex`
- `apps/rho_web/lib/rho_web/live/app_live/workbench_events.ex`

The modal also contains a link to the guided flow page. That link should go away
once the chat-hosted flow is ready.

### FlowLive And FlowChat

The first chat-native implementation already exists behind the flow page mode:

```text
/orgs/:slug/flows/create-framework?mode=chat_native
```

Relevant modules:

- `apps/rho_web/lib/rho_web/live/flow_live.ex`
- `apps/rho_web/lib/rho_web/flow_chat/message.ex`
- `apps/rho_web/lib/rho_web/flow_chat/action.ex`
- `apps/rho_web/lib/rho_web/flow_chat/step_presenter.ex`
- `apps/rho_web/lib/rho_web/flow_chat/reply_parser.ex`
- `apps/rho_web/lib/rho_web/flow_chat/driver.ex`
- `apps/rho_web/lib/rho_web/flow_chat/step_agent.ex`
- `apps/rho_web/lib/rho_web/flow_chat/step_prompt.ex`

This layer is the right foundation. The missing piece is that it is hosted by
`FlowLive`, not by the main chat shell.

### Flow Source Of Truth

The flow graph and state model already exist and should remain canonical:

- `RhoFrameworks.FlowRunner`
- `RhoFrameworks.Flows.CreateFramework`
- `RhoFrameworks.Flow.Policies.Deterministic`
- `RhoFrameworks.UseCases.*`
- `RhoFrameworks.Tools.WorkflowTools`

Do not move workflow routing into agent prompts. Do not let an LLM decide the
global next step.

## Product Target

### Starting A Flow

The user should be able to start from the main chat by either:

- typing "create a framework for risk analysts",
- clicking a Workbench "Create Framework" action,
- selecting an assistant suggestion,
- or attaching a relevant file and asking to create a framework.

All of these should start the same chat-hosted `create-framework` flow.

### During A Flow

The chat feed should show flow cards inline:

```text
Pick a starting point

How would you like to start?

[From a similar role] [Start from scratch] [Extend existing] [Merge frameworks]
```

The user can click a button or type into the normal chat composer:

```text
start from a similar role
```

The typed reply should be parsed locally against the current node only.

### Artifact Review

When a table is created or selected, the Workbench opens/focuses it. Chat remains
the decision surface:

```text
Review taxonomy

Review or edit the taxonomy table before skills are generated.

[Generate skills] [Regenerate taxonomy] [Focus table]
```

The table remains editable in the Workbench. The chat card points to it and
drives the next decision.

## Non-Goals

- Do not add another route as the primary workflow surface.
- Do not keep `FlowLive` as the main user entry point.
- Do not encode workflow state only in chat text.
- Do not fake flow prompts as user-authored chat messages.
- Do not send every flow decision to the main agent.
- Do not replace Workbench/table artifacts with chat-only markdown.
- Do not remove the guided flow page until the chat-hosted path covers the same
  practical workflows and has tests.

## Architecture Proposal

### 1. Add A Chat-Hosted Flow Session Layer

Add a module under `AppLive`, for example:

```elixir
RhoWeb.AppLive.FlowSession
```

Responsibilities:

- start a flow from `flow_id` and optional intake,
- hold active `FlowRunner` state in socket assigns,
- render the current `RhoWeb.FlowChat.Message`,
- apply structured action clicks,
- parse typed replies through `RhoWeb.FlowChat.ReplyParser`,
- run action/use-case nodes,
- open/focus Workbench artifacts,
- append first-class flow messages to the chat feed,
- clear or complete the active flow.

Suggested assigns:

```elixir
:active_flow
:flow_chat_error
```

Possible `:active_flow` shape:

```elixir
%{
  id: "create-framework",
  flow_mod: RhoFrameworks.Flows.CreateFramework,
  runner: %FlowRunner{},
  status: :idle | :running | :awaiting_user | :failed | :done,
  events: [%RhoWeb.FlowChat.Message{}],
  completed_steps: [],
  selected_ids: [],
  select_items: [],
  step_error: nil
}
```

### 2. Add A Native Chat Message Type

Add `:flow_card` rendering to `RhoWeb.ChatComponents.message_row/1`.

Recommended message shape:

```elixir
%{
  id: "flow_...",
  role: :assistant,
  type: :flow_card,
  agent_id: active_agent_id,
  flow: %RhoWeb.FlowChat.Message{},
  status: :active | :past | :error,
  content: "Flow step: Pick a Starting Point"
}
```

Why not use the existing `:ui` / LiveRender message type?

- Flow cards need server-owned actions.
- Buttons must be stale-safe.
- Typed replies and button clicks must share one normalization path.
- Flow state must stay in `FlowRunner`.
- Table focus/regenerate/continue actions have side effects.

A dedicated `:flow_card` type makes those invariants explicit.

### 3. Route Composer Input Through Active Flow First

Update `RhoWeb.AppLive.MessageEvents.handle_event("send_message", ...)`.

When `:active_flow` is present and awaiting input:

1. Append the user's typed message to chat as usual.
2. Parse it with `RhoWeb.FlowChat.ReplyParser.parse_reply/2`.
3. If parsing succeeds, apply it to the flow.
4. If parsing fails but the current node has a step-scoped tool, send the text to
   `RhoWeb.FlowChat.StepAgent`.
5. If parsing fails and no step-scoped tool is available, show a flow-card error
   and keep the flow active.

Only when no flow is active should normal `SessionCore.send_message/3` run.

### 4. Replace SmartEntry Navigation With Flow Start

Change `RhoWeb.AppLive.SmartEntry.dispatch_result/3`.

Current behavior:

```text
matched flow -> push_navigate("/orgs/:slug/flows/create-framework?...query...")
```

New behavior:

```text
matched flow -> FlowSession.start(socket, flow_id, intake)
```

The same classifier can stay. The output should become initial flow intake
rather than URL query params.

### 5. Replace Workbench Prompt-Building For Create Framework

Change `RhoWeb.AppLive.WorkbenchEvents.run_action/3` for `:create_framework`.

Current behavior:

```text
build agent prompt -> send to active assistant
```

New behavior:

```text
build initial intake -> start create-framework flow in chat
```

`WorkbenchActionRunner.build_prompt(:create_framework, ...)` should be retired
or reduced to a fallback. The Workbench modal can still collect initial values,
but submitting it should produce a flow card, not an instruction prompt.

The "Open Guided Flow" secondary link in
`RhoWeb.WorkbenchActionComponent.action_modal/1` should be removed once the
chat-hosted path is stable.

### 6. Keep Workbench As Artifact Surface

Flow action nodes should continue writing tables through the existing Workbench
and DataTable paths.

When a flow card references a table artifact, the action should:

- call `DataTable.set_active_table/2` when appropriate,
- refresh the data table projection,
- show/focus the Workbench pane,
- leave the current flow card active in chat.

Do not duplicate tables inside chat. Chat should summarize and control; the
Workbench should edit.

### 7. Preserve Flow Provenance

Flow prompts and choices must remain distinguishable from user messages.

Options:

1. Store flow card messages only in `agent_messages` UI state for the first pass.
2. Later, persist them as tape entries or explicit conversation metadata.

The first implementation can use UI state if it is clearly marked as a
migration step. The eventual target should preserve flow event provenance across
reloads and debug bundles.

## Implementation Phases

### Phase 1 - Chat Message Rendering

Deliverables:

- Add `:flow_card` rendering to `RhoWeb.ChatComponents`.
- Reuse the visual vocabulary from `RhoWeb.FlowComponents.flow_chat_messages/1`.
- Add action button events such as `flow_card_action`.
- Add tests for rendering a flow card with actions, fields, and a table artifact.

No flow execution yet.

### Phase 2 - AppLive Flow Session State

Deliverables:

- Add `RhoWeb.AppLive.FlowSession`.
- Add socket assigns for active flow state.
- Add `FlowSession.start/3`.
- Add helper to append current flow card to `agent_messages`.
- Add tests that starting create-framework inserts the first flow card into the
  main chat feed.

### Phase 3 - Button And Typed Reply Handling

Deliverables:

- Add `AppLive` event handler for `flow_card_action`.
- Route active-flow composer input before normal agent submission.
- Use `RhoWeb.FlowChat.ReplyParser` for typed replies.
- Ensure button clicks and typed replies produce identical `FlowRunner` state.
- Cover `:role_transform` structured and natural-language paths in AppLive tests.

### Phase 4 - Create-Framework Vertical Slice

Deliverables:

- Start create-framework from the main chat.
- Cover this path:

```text
choose_starting_point
-> intake_template
-> similar_roles
-> role_transform
```

Success criteria:

- No route navigation.
- No prompt playbook sent to the agent.
- Flow cards appear in the main assistant chatbox.
- Workbench opens role candidates when needed.

### Phase 5 - Long Steps And Artifact Review

Deliverables:

- Support long-running use cases from AppLive flow state:
  - `GenerateFrameworkTaxonomy`
  - `GenerateSkillsForTaxonomy`
  - `GenerateFrameworkSkeletons`
- Reuse or extract the long-step seams currently in `FlowLive`.
- Render taxonomy/skill/clone review cards in main chat.
- Support:
  - continue/generate,
  - save draft,
  - regenerate,
  - focus table.

### Phase 6 - SmartEntry Integration

Deliverables:

- Change `SmartEntry` so matched flows start in chat.
- Keep confidence and library-hint resolution.
- Convert classifier output into flow intake.
- Add tests that "create a framework..." starts an active flow instead of
  navigating to `/flows/create-framework`.

### Phase 7 - Workbench Action Integration

Deliverables:

- Change Workbench "Create from brief" to start the chat-hosted flow.
- Keep the modal as optional structured intake.
- Remove or hide the "Open Guided Flow" secondary link.
- Replace `WorkbenchActionRunner.build_prompt(:create_framework, ...)` with
  flow intake construction.

### Phase 8 - Reduce The Parallel Playbook

Deliverables:

- Shrink `.agents/skills/create-framework/SKILL.md` so it no longer acts as the
  canonical create-framework workflow.
- Keep only routing/context guidance for cases where the agent is asked about
  workflows outside an active flow.
- Ensure step-scoped prompts from `RhoWeb.FlowChat.StepPrompt` are the primary
  prompt source during active flows.

### Phase 9 - Deprecate Flow Page Entry

Deliverables:

- Keep `/flows/create-framework` temporarily as a fallback/debug route.
- Once main-chat parity is proven, remove prominent links to it.
- Update any docs, Workbench copy, and tests that describe the guided page as
  the primary entry point.

## Suggested Module Boundaries

Add:

- `RhoWeb.AppLive.FlowSession`
- `RhoWeb.AppLive.FlowEvents`
- `RhoWeb.ChatComponents.flow_card/1`

Reuse:

- `RhoWeb.FlowChat.Message`
- `RhoWeb.FlowChat.Action`
- `RhoWeb.FlowChat.StepPresenter`
- `RhoWeb.FlowChat.ReplyParser`
- `RhoWeb.FlowChat.Driver`
- `RhoWeb.FlowChat.StepAgent`
- `RhoWeb.FlowChat.StepPrompt`
- `RhoFrameworks.FlowRunner`
- `RhoFrameworks.Flows.CreateFramework`

Avoid:

- adding more create-framework orchestration directly to `AppLive`,
- growing `FlowLive`,
- putting workflow branches into agent prompts,
- using URL params as the main workflow handoff.

## Tests To Add

Focused tests:

- `RhoWeb.ChatComponents` renders `:flow_card`.
- `RhoWeb.AppLive.FlowSession.start/3` creates active flow state.
- Flow action click advances `FlowRunner`.
- Typed reply advances the same way as button click.
- `SmartEntry` starts a flow without navigation.
- Workbench create action starts a flow without sending an agent prompt.
- Table artifact action focuses the Workbench table.
- Regenerate action rolls back to the generating node.

Regression tests:

- Normal chat still sends to the active agent when no flow is active.
- Uploads still send normally when no flow is active.
- Workbench load-library direct action still works.
- Guided `/flows/create-framework` still works while retained.

## Acceptance Criteria

- A user can start create-framework from the main chat.
- A user can complete at least one source path without leaving the chat page.
- Flow prompts, buttons, and typed replies appear inside the main chatbox.
- Buttons and typed replies produce the same normalized node input.
- `FlowRunner` remains the source of truth for current node, intake, summaries,
  and edge decisions.
- The LLM never owns global workflow routing.
- Workbench tables remain editable and are focused/opened from flow cards.
- Workbench "Create from brief" no longer sends a workflow playbook prompt.
- SmartEntry no longer navigates to the flow page for create-framework.
- Existing non-flow chat behavior remains intact.

## Risks And Mitigations

### Risk: Flow State Becomes Ephemeral

If flow state only lives in socket assigns, refresh/reload may lose progress.

Mitigation:

- First pass can use socket assigns for speed.
- Follow up by snapshotting `:active_flow` or writing flow events into tape.

### Risk: Chat Feed Gets Noisy

If every internal transition becomes a visible message, the chat will feel like
logs.

Mitigation:

- Render only user-meaningful prompts, choices, artifacts, completions, and
  failures.
- Keep policy/debug details behind debug mode.

### Risk: Agent And Flow Both Respond To One Message

If active-flow input falls through to `SessionCore.send_message/3`, the user may
get both a flow transition and an unrelated assistant answer.

Mitigation:

- Active flow owns composer input first.
- Fall through to agent only when no active flow exists or when explicitly
  invoking the step-scoped agent.

### Risk: Duplicated FlowLive Logic

Copying long-step and table logic from `FlowLive` into `AppLive` can create two
implementations.

Mitigation:

- Extract shared, page-agnostic functions into `RhoWeb.FlowChat.*` or
  `RhoWeb.AppLive.FlowSession`.
- Keep `FlowLive` as a thin fallback/debug host.

## First Implementation Target

Build the smallest useful main-chat slice:

```text
User opens main Chat
-> types "create a framework from a similar risk analyst role"
-> chat starts create-framework flow
-> flow card asks for starting point
-> user clicks/types from_template
-> intake card collects name/description
-> similar role candidates open in Workbench
-> role_transform card appears in chat
-> user clicks/types clone or inspire
```

This proves the consolidation without requiring the full taxonomy/save tail in
the first pass.
