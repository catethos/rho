# Chat-Native Flow Plan

## Goal

Consolidate the freeform chat workflow and the step-by-step flow wizard into
one chat-native workflow surface.

The important design move is:

```text
FlowRunner owns deterministic workflow state.
Chat renders and drives the current flow step.
```

This keeps the safety, resumability, and testability of the existing
`RhoFrameworks.FlowRunner` / `RhoFrameworks.Flow` model while replacing the
modal/wizard feeling with a conversational UI that can still accept buttons,
forms, table actions, and natural-language replies.

## Why

Rho currently has two overlapping workflow experiences:

- Guided UI: `/orgs/:slug/flows/create-framework`, backed by
  `RhoFrameworks.Flows.CreateFramework` and `RhoFrameworks.FlowRunner`.
- Freeform chat: agent skills such as `.agents/skills/create-framework/SKILL.md`
  plus workflow tools in `RhoFrameworks.Tools.WorkflowTools`.

This creates duplicated workflow logic:

- The wizard knows the deterministic graph.
- The chat skill knows the conversational playbook.
- Both must remember review gates, source modes, role-vs-library ambiguity,
  taxonomy-first sequencing, clone-vs-inspire choices, and save timing.

The better UX is not "wizard plus chat" or "agent replaces wizard." It is one
workflow spine rendered in chat.

## Product Principle

Every workflow moment should answer three questions:

1. Where am I?
2. What artifact am I editing or approving?
3. What is the next meaningful action?

Chat should make those actions easier. It should not create a second hidden
workflow path.

## Target Experience

### Example: Similar Role Source

Instead of a modal form and separate chat instructions, the chat thread shows a
flow card:

```text
I found similar role profiles. How should we use them?

[Use as inspiration] [Clone exact skills for editing]
```

The user can click a button or type:

```text
clone them, I only want to tweak wording
```

Both inputs update the same `:role_transform` flow node. The result is
deterministic:

- `inspire` routes to taxonomy preferences and generation.
- `clone` routes to exact-skill clone, review, and save.

### Example: Taxonomy Review

The chat thread shows:

```text
Taxonomy generated for Risk Analyst.
Review or edit the taxonomy table before skills are generated.

[Generate skills] [Regenerate taxonomy] [Add cluster]
```

The table remains the artifact surface. Chat is the decision and instruction
surface.

## Non-Goals

- Do not let the LLM own global workflow routing.
- Do not replace `FlowRunner` with agent prompt logic.
- Do not encode workflow state only in chat text.
- Do not fake system workflow prompts as user-authored messages.
- Do not remove table/artifact surfaces; chat should coordinate them.

## Architecture

### Source Of Truth

`RhoFrameworks.FlowRunner` remains canonical for:

- current node
- intake values
- summaries
- edge selection
- completed steps
- resumability

`RhoFrameworks.Flow` definitions remain canonical for:

- node ids
- node type
- forms/select fields
- use case modules
- routing mode
- next edges

### New Chat Rendering Layer

Add a renderer that converts a flow node into chat-native messages:

```text
Flow node + runner state + scope -> ChatStep
```

Possible module shape:

```elixir
RhoWeb.FlowChat.StepPresenter
RhoWeb.FlowChat.Message
RhoWeb.FlowChat.Action
```

Example output shape:

```elixir
%RhoWeb.FlowChat.Message{
  kind: :flow_prompt,
  flow_id: "create-framework",
  node_id: :role_transform,
  title: "Use selected roles",
  body: "How should the selected roles shape this framework?",
  actions: [
    %{id: "inspire", label: "Use as inspiration", payload: %{role_transform: "inspire"}},
    %{id: "clone", label: "Clone exact skills for editing", payload: %{role_transform: "clone"}}
  ],
  artifact: nil
}
```

### Flow Events, Not Fake User Messages

Persist and render first-class flow events instead of injecting fake user
messages.

Suggested event kinds:

- `:flow_prompt` — system asks for the next step input.
- `:flow_choice` — user clicked or typed a choice for a node.
- `:flow_artifact` — table/workspace artifact opened or updated.
- `:flow_decision` — policy chose an edge.
- `:flow_step_completed` — node completed.
- `:flow_error` — use case or policy failed.

These events can project into chat while preserving provenance.

## User Input Handling

Each node accepts two input paths:

1. **Structured action**: button, select, checkbox, table toolbar action.
2. **Natural language**: user types a message.

Natural language should be interpreted locally against the current node only:

```text
current node + allowed actions + user reply -> normalized node input
```

Do not ask an LLM to choose among all workflow steps. It only maps the user's
reply to the current node's expected fields or edge choices.

Example:

```text
node: :role_transform
allowed values: inspire | clone
message: "clone them, I only want surgical edits"
result: %{role_transform: "clone"}
```

## Step-Scoped Chat Tools

For action nodes, expose only the current step's tool surface.

Existing hook:

- `RhoFrameworks.Tools.WorkflowTools.tool_for_use_case/1`
- `RhoFrameworks.Tools.WorkflowTools.clarify_tool/0`

Target:

```text
current flow node -> allowed tools -> step-scoped agent/chat runner
```

The agent can clarify, summarize, or call the one relevant use case, but it
cannot wander into unrelated workflow tools.

## Relationship To Existing UI

### Keep

- `RhoFrameworks.FlowRunner`
- `RhoFrameworks.Flows.*`
- use case modules
- DataTable artifacts
- Workbench surfaces
- step-chat tool constraints

### Replace Gradually

- Replace modal/form-first flow pages with chat-rendered flow cards.
- Replace static wizard navigation with chat transcript plus current-step card.
- Replace broad skill playbooks with generated current-step instructions.

### Keep As Fallback During Migration

The existing `/flows/:flow_id` route can continue to render the current wizard
while chat-native flow is developed behind a mode flag.

Possible modes:

```text
mode=guided        existing wizard
mode=chat_native   new chat-first flow surface
mode=copilot       existing hybrid/step-chat behavior
```

## Implementation Plan

### Phase 1 — Chat Message Model

Add a small internal representation for flow chat messages/actions.

Deliverables:

- `RhoWeb.FlowChat.Message`
- `RhoWeb.FlowChat.Action`
- tests for rendering basic form/select/action/table-review nodes into message
  structs

No LiveView rewrite yet.

### Phase 2 — Node Presenter

Build `Flow node -> ChatStep` presentation.

Start with:

- `:form`
- `:select`
- `:table_review`
- `:action`

For create-framework, ensure these nodes render well:

- `:choose_starting_point`
- `:similar_roles`
- `:role_transform`
- `:taxonomy_preferences`
- `:review_taxonomy`
- `:review_clone`

### Phase 3 — Local Reply Parser

Add a local parser for current-node replies.

For deterministic nodes, this can start rule-based:

- button payload wins
- exact option label/value match
- simple synonym map for high-value choices

Only add LLM interpretation after the deterministic path exists.

Examples:

```text
"clone them" -> %{role_transform: "clone"}
"use them as inspiration" -> %{role_transform: "inspire"}
"balanced" -> %{taxonomy_size: "balanced"}
"continue" on :review_taxonomy -> advance to :generate_skills
```

### Phase 4 — Chat-Native Create-Framework Prototype

Prototype one vertical slice:

```text
choose_starting_point
-> intake_template
-> similar_roles
-> role_transform
```

Success criteria:

- User sees the steps as chat cards.
- User can click buttons or type replies.
- `FlowRunner` state updates exactly as the wizard would.
- The transcript shows what happened without pretending system prompts were
  user messages.

### Phase 5 — Artifact Actions

Render artifact-aware chat cards for table review nodes.

Examples:

- taxonomy table generated
- skill table generated
- cloned role skills ready for surgical edits

Actions:

- continue/generate next artifact
- save draft
- regenerate
- open/focus workspace table

### Phase 6 — Step-Scoped Agent

Move freeform chat behavior from whole-workflow skill playbooks into
step-scoped prompts generated from flow metadata.

For each node, build a compact prompt:

```text
Current step: role_transform
Goal: decide how selected roles should shape the framework
Allowed actions: inspire, clone
Current artifacts: selected role profiles
Do not advance unless the user chooses one action.
```

This should shrink `.agents/skills/create-framework/SKILL.md` over time. The
skill becomes routing/context guidance, not a parallel workflow spec.

### Phase 7 — Migrate FlowLive

Once the create-framework slice is proven, move `FlowLive` toward a
chat-native shell:

- chat transcript on the left/main surface
- current artifact/workbench on the right or below
- current-step action card pinned near the composer

Do this after the presenter and message/event model are stable.

## Acceptance Criteria

- A create-framework user can complete at least one source path entirely from
  chat cards and typed replies.
- Flow state is still stored in `FlowRunner` state, not inferred from text.
- Buttons and typed replies produce the same normalized node input.
- Flow messages are distinguishable from user-authored chat messages.
- Table artifacts remain editable and are referenced from chat messages.
- The old wizard path still works until explicitly retired.
- Tests cover both structured-click and natural-language input for
  `:role_transform`.

## Risks

- Chat transcript could become noisy if every internal state change renders.
  Mitigation: render only user-meaningful prompts, decisions, artifacts, and
  failures.
- Natural-language parsing could become another hidden workflow brain.
  Mitigation: scope parsing to the current node and allowed options only.
- FlowLive is already large.
  Mitigation: add `RhoWeb.FlowChat.*` modules first; avoid growing FlowLive.
- Existing tests assume wizard-specific step rendering.
  Mitigation: add chat-native tests alongside current tests before replacing
  behavior.

## First Implementation Target

Build the smallest useful slice:

```text
CreateFramework:
choose_starting_point
-> intake_template
-> similar_roles
-> role_transform
```

This slice proves the key UX idea:

- deterministic flow
- chat-native prompts
- button or typed reply
- explicit clone-vs-inspire branch

After that, extend to taxonomy review and cloned-skill review.
