# Rho Detailed Architecture Guide

Date: 2026-05-15

This guide describes Rho below the umbrella-app level. Use it when you need to
change behavior, not just find the right top-level app. The compact map remains
`docs/codex-codebase-map.md`; the interactive visual map is
`docs/rho-architecture-map.html`.

## Architecture Invariants

- `apps/rho` is the runtime kernel. It must not depend on Phoenix, Ecto,
  `RhoWeb`, or framework-domain persistence.
- Tape entries are the durable source of truth. Conversations, threads, chat
  UI, debug context, and trace bundles are projections over tape-backed state.
- Plugins add tools, prompt sections, and bindings. Transformers mutate or
  enforce policy at named pipeline stages.
- The data-table server owns per-session table state. Named table writes must
  be explicit with `table:`.
- `rho_frameworks` owns skill-assessment domain persistence and use cases.
  `rho_web` may call it at the edge; `rho` and `rho_stdlib` must not know it.
- Root LiveViews orchestrate. Extracted helper modules own page loading, event
  handling, render-only chrome, and pure data shaping.
- Public facades stay stable until call sites prove they can safely move.

## Runtime Kernel: `apps/rho`

### Session And Configuration

`Rho.Session` is the programmatic entry point used by web, CLI, and tests. It
normalizes caller options into session handles, resolves agent configuration,
and starts or finds the primary agent for a session.

Configuration flows through:

- `Rho.AgentConfig` loads `.rho.exs`, normalizes legacy keys, resolves agent
  names, and exposes per-agent config queries.
- `Rho.RunSpec` is the explicit runtime contract: model, provider, system
  prompt, plugins, turn strategy, skills, max steps, prompt format, avatar, and
  workspace details.
- `Rho.RunSpec.FromConfig` turns loaded config into a `RunSpec`, including
  plugin resolution through `Rho.Stdlib.resolve_plugin/1`.

### Agent Process Boundary

`Rho.Agent.Worker` is still the GenServer owner for primary, delegated, and
nested agents. It owns process lifecycle, public API compatibility, registry
updates, lifecycle broadcasts, and task result handling.

The worker internals are split by reason to change:

- `Rho.Agent.Ask` owns bus-based synchronous asks: submit-and-await,
  turn-vs-finish await modes, inactivity timeouts, and final-result unwrapping.
- `Rho.Agent.Bootstrap` prepares the initial state seed: finalized `RunSpec`,
  tape identity/module, effective workspace, optional sandbox, derived
  capabilities, registry metadata, and agent-started event data.
- `Rho.Agent.TurnTask` owns supervised runner task start, monitor/cancel,
  busy registry status, task-accepted events, persistent-tool bookkeeping, and
  inactivity watchdog enforcement.
- `Rho.Agent.Mailbox` owns busy-submit queueing, delayed signal queueing, and
  next-item selection. Signals are preferred over regular submits.
- `Rho.Agent.Registry`, `Primary`, `Supervisor`, `EventLog`, and `LiteTracker`
  provide discovery, session namespace helpers, process supervision, event-log
  processes, and lightweight worker tracking.

When changing multi-agent or queue behavior, start with `Worker`, then inspect
`Mailbox`, `TurnTask`, and the multi-agent plugin signal tests.

### Runner Boundary

`Rho.Runner` is the public entry point for executing a turn. It preserves
`run/2` and legacy call shapes, but the implementation is split:

- `Rho.Runner.Runtime` is the immutable run config struct.
- `Rho.Runner.TapeConfig` is the tape config struct.
- `Rho.Runner.RuntimeBuilder` builds runtime/context/tape config from
  `%Rho.RunSpec{}` and legacy opts. It owns provider generation opts and system
  prompt assembly.
- `Rho.Runner.Emit` wraps emit callbacks and converts runner events to tape
  entries with metadata.
- `Rho.Runner.LiteLoop` owns lite-mode context construction, step loop, direct
  tool execution, final-result handling, parse-error retry, strategy error
  emission, and arbitrary tool-output coercion.
- `Rho.Runner.Loop` owns normal-mode orchestration: compaction,
  `:prompt_out` transformer dispatch, strategy-result dispatch,
  `Rho.ToolExecutor` invocation, post-step injection, and context advancement.

The inner turn remains under `Rho.TurnStrategy`:

- `Rho.TurnStrategy.Direct` calls LLMs directly through `ReqLLM`.
- `Rho.TurnStrategy.TypedStructured` uses `RhoBaml.SchemaWriter` to produce a
  discriminated action union and parse exactly one selected action.
- `Rho.ActionSchema`, `Rho.SchemaCoerce`, `Rho.ToolArgs`, and
  `Rho.ToolResponse` support structured tool/action normalization.

### Tool And Transformer Pipeline

`Rho.ToolExecutor` is the shared normal-mode tool dispatch boundary. It applies
transformers, dispatches tool calls, normalizes results, handles timeouts, and
emits tool lifecycle events.

Transformer stages are:

- `:prompt_out`
- `:response_in`
- `:tool_args_out`
- `:tool_result_in`
- `:post_step`
- `:tape_write`

Use `Rho.Transformer` for cross-cutting policy. Use `Rho.Plugin` for optional
tools, prompt sections, and bindings. Avoid duplicating tool schema text in
plugin prompt sections.

### Tape, Conversation, And Trace

Tape modules under `Rho.Tape.*` provide append-only event history. The runner
and recorder write durable entries; projections rebuild views.

Important owners:

- `Rho.Recorder` writes messages, tool calls, and tool results during the agent
  loop.
- `Rho.Conversation.*` maps user-visible conversations and threads to
  tape-backed metadata.
- `Rho.Trace.Projection` derives chat, context, debug, cost, and failure views
  from tape entries.
- `Rho.Trace.Analyzer` performs deterministic trace checks.
- `Rho.Trace.Bundle` writes portable debug bundles.

Fork points are tape entry ids. Do not fork by UI message index.

## Built-In Tools And Surfaces: `apps/rho_stdlib`

`rho_stdlib` contains generic tools and plugins that can be used without the
framework-domain app.

Major clusters:

- `Rho.Stdlib` maps plugin shorthand atoms to modules.
- `Rho.Stdlib.Tools.*` owns bash, filesystem, web fetch/search, Python,
  sandbox, finish/end-turn, path utils, and tape tools.
- `Rho.Stdlib.Plugins.*` owns multi-agent, step budget, live render, py-agent,
  data table, uploads, tape/debug tape, control, and skill loading.
- `Rho.Stdlib.EffectDispatcher` consumes `%Rho.Effect.*{}` values from tool
  results and bridges them into data-table writes and workspace events.

### Data Table Server

`Rho.Stdlib.DataTable` is the client API for per-session named tables.

`Rho.Stdlib.DataTable.Server` is the process owner. It stores table state,
publishes coarse invalidation events through `Rho.Events`, tracks active table
UI focus, and tracks per-table selected rows. It uses `restart: :temporary`;
callers should handle `{:error, :not_running}`.

The server-side active table is UI context only. Tools that load a named table
must pass `table:` on future operations. There is no implicit write target.

### Uploads

`Rho.Stdlib.Uploads.*` owns per-session upload registry/supervision and file
observers for CSV, Excel, PDF, prose, image, and hints. Web upload events route
through `RhoWeb.AppLive.MessageEvents` and nearby LiveView/session code, while
the ingestion/runtime details stay in stdlib.

## Structured Output Support: `apps/rho_baml`

`rho_baml` owns BAML helper code, not consumer schemas.

- `RhoBaml.SchemaCompiler` converts Zoi schemas into BAML classes/functions.
- `RhoBaml.Function` is the compile-time macro for static LLM function modules
  in consumer apps.
- `RhoBaml.SchemaWriter` writes runtime agent action unions for
  `Rho.TurnStrategy.TypedStructured`.
- `RhoBaml.baml_path/1` resolves an OTP app's `priv/baml_src`.

Consumer apps own their own `.baml` trees:

- `apps/rho/priv/baml_src/dynamic` for runtime agent action schemas.
- `apps/rho_frameworks/priv/baml_src/functions` for generated static domain
  LLM functions.

## Python And Embeddings Services

`apps/rho_python` owns `RhoPython.Server`, dependency declaration, py-agent
configuration, and readiness checks. `rho_stdlib` depends on it instead of
owning Python runtime state.

`apps/rho_embeddings` owns:

- `RhoEmbeddings.Server`
- `RhoEmbeddings.Backend`
- `RhoEmbeddings.Backend.OpenAI`
- `RhoEmbeddings.Backend.Fake`

Framework search and duplicate-detection workflows use embeddings through this
service.

## Framework Domain: `apps/rho_frameworks`

`rho_frameworks` is the skill-assessment domain. It owns Ecto schemas,
Postgres/pgvector persistence, accounts/org membership, libraries, roles,
lenses, flows, use cases, domain tools, and static BAML LLM modules.

### Public Domain Facades

- `RhoFrameworks.Library` is the public facade for library CRUD, reads,
  publish/version behavior, duplicate workflows, prompt summaries, and
  table-shaped read models.
- `RhoFrameworks.Roles`, `Lenses`, `GapAnalysis`, `Workbench`, and
  `DataTableOps.*` own adjacent domain APIs.
- `RhoFrameworks.DataTableSchemas` defines strict schemas for named tables such
  as library and role-profile views.

`RhoFrameworks.Library` is split internally:

- `RhoFrameworks.Library.Queries` owns listing, visible-library lookup,
  version read queries, skill listing/search/browse, table-shaped rows, skill
  index/cluster loading, cross-library search, and role-profile lookup.
- `RhoFrameworks.Library.Versioning` owns version tag selection, publish
  validation/notes, default-version updates, and version diffs.
- `RhoFrameworks.Library.Dedup` owns duplicate candidate generation, semantic
  pgvector/Jaro fallback detection, duplicate dismissals, role-reference
  enrichment, and consolidation report buckets.
- `RhoFrameworks.Library.Editor` and `Skeletons` remain focused support modules.

Keep `RhoFrameworks.Library` as the call-site facade unless there is a clear
reason to call an extracted module directly.

### Use Cases, Tools, And Flows

Use cases are the preferred home for workflows:

- import/load/list/save frameworks
- merge/diff/conflict resolution
- research and gap identification
- skeleton/proficiency generation
- load similar roles and extract job descriptions

Chat tools and deterministic/hybrid flow UI share those use cases:

- `RhoFrameworks.Tools.WorkflowTools` exposes chat-side workflow tools.
- `RhoFrameworks.FlowRunner` executes flow nodes.
- `RhoFrameworks.Flows.*` declare flow graphs.
- `RhoFrameworks.Flow.Policies.*` choose next edges.

When changing framework creation/editing, start in `UseCases.*`, then update
tools or flow nodes only if the workflow boundary changes.

## Web Edge: `apps/rho_web`

`rho_web` is the Phoenix/LiveView edge. It can depend on runtime, stdlib, and
framework domain apps. It owns session orchestration, UI projections,
workspace surfaces, page rendering, auth, and browser-facing events.

### Root App LiveView

`RhoWeb.AppLive` remains the org-scoped root LiveView. It owns mount/root
assign orchestration, route handling, subscription setup, and high-level event
dispatch.

Extracted owners under `RhoWeb.AppLive.*`:

- `PageLoader` loads page assigns for libraries, roles, settings, members, and
  chat.
- `ChatEvents` handles conversation/thread events such as sending messages,
  opening chats, archiving, switching/forking threads, and creating blanks.
- `WorkspaceEvents` owns workspace shell events and hydration helpers.
- `DataTableEvents` owns data-table invalidation, refresh, tab, selection,
  save/fork/publish/suggest messages.
- `MessageEvents` owns upload consumption, parse task messages, avatar
  handling, and message/upload-related mailbox work.
- `AgentEvents` owns agent tab/drawer/modal helpers and worker lifecycle
  state transitions.
- `WorkbenchEvents` owns workbench suggestion dispatch, action modal handling,
  upload-backed action preparation, prompt dispatch, load-library, and
  find-roles actions.
- `SmartEntry` owns natural-language submission classification, intake query
  building, starting-point allowlists, and library-hint resolution.
- `LiveEvents` owns canonical `Rho.Events.Event` decoding/routing,
  data-table/workspace effect dispatch, and conversation-refresh
  classification.
- `PageSearchEvents` owns page-scoped library filtering, skill search, cluster
  expansion, role search, semantic-search async state, and skill grouping.
- `ChatroomEvents` owns mention/broadcast handling and mention target
  resolution.
- `ChatRail` owns conversation/thread/message projection into chat sidebar
  rows.
- `ChatShellComponents` owns render-only chat chrome: side panel, saved-chat
  rail markup, agent tabs, session controls, upload chips, new-chat dialog, and
  workbench suggestions.
- `PageComponents` owns page templates for libraries, library detail, roles,
  role detail, settings, and members.
- `WorkspaceChromeComponents` owns workspace tab chrome, overlay chrome, and
  debug-panel rendering.
- `LibraryEvents`, `SettingsEvents`, and `MemberEvents` own page-specific
  handlers that predated or accompany the extraction.

When adding AppLive behavior, decide whether the root needs to route the event
or whether an extracted owner should hold the logic.

### Web Data Table Component

`RhoWeb.DataTableComponent` is the LiveComponent owner for lifecycle,
assigns/socket state, high-level event dispatch, and table-level markup.

Pure or focused boundaries live under `RhoWeb.DataTable.*`:

- `Export` builds CSV/XLSX.
- `Commands` normalizes edit/add/delete/group/conflict payloads.
- `Streams` owns fixed stream pools, group ids, stream-window metadata, lazy
  page appends, row-to-stream lookup, and stream insert/delete helpers.
- `Artifacts` owns artifact lookup, labels, metrics, surface selection, empty
  workbench-home detection, and linked-artifact summaries.
- `Optimistic` overlays pending top-level and child-cell edits while awaiting
  authoritative server snapshots.
- `Rows` owns sorting, grouping, nested group ids, visible row ids, and
  select-all state.
- `RowComponents` owns parent-row, proficiency panel, provenance, action,
  editable-cell, inline-edit, and add/delete-control markup.
- `Tabs` owns named-table tab ordering and row-count rules.
- `Schema` / `Schemas` support web-facing schema behavior.

Do not introduce dynamic atom creation in row or stream helpers.

### Session, Workspace, And Projection System

Important web clusters:

- `RhoWeb.Session.SessionCore` ensures sessions, conversations, active threads,
  subscriptions, and hydration.
- `RhoWeb.Session.SignalRouter` routes session signals.
- `RhoWeb.Session.SessionEffects` is the impure boundary for pushes, timers,
  and `%Rho.Effect.*{}` dispatch.
- `RhoWeb.Session.Snapshot`, `Threads`, `Shell`, and `Welcome` support session
  state, thread operations, shell state, and startup UX.
- `RhoWeb.Workspace` and `RhoWeb.Workspace.Registry` define pluggable
  workbench surfaces.
- `RhoWeb.Workspaces.*` and `RhoWeb.Projections.*` own surface-specific
  projections such as chatroom, data table, and lens dashboards.

Pure reducers/projections should stay pure. Side effects belong in
`SessionEffects`, explicit dispatchers, or root LiveView process code.

### Tutorial And Inline Assets

- `RhoWeb.TutorialLive` owns page interaction and markup.
- `RhoWeb.TutorialLive.Content` owns tutorial table-of-contents data, example
  agent config, and CSS payload.
- `RhoWeb.InlineCSS` remains the public `css/0` API.
- `RhoWeb.InlineCSS.Base`, `Chat`, `Workbench`, `DataTable`, `Pages`, and
  `Flow` own grouped CSS sections.

The first CSS split is behavior-preserving. Consider standard Phoenix static
asset delivery only after visual behavior is verified.

## End-To-End Runtime Handoff

1. A caller starts a session through `Rho.Session`.
2. `Rho.AgentConfig` and `Rho.RunSpec.FromConfig` resolve `.rho.exs` into a
   `RunSpec`.
3. `Rho.Agent.Primary` starts or finds the primary `Rho.Agent.Worker`.
4. `Rho.Agent.Bootstrap` prepares tape, sandbox, capabilities, context, and
   lifecycle metadata for the worker.
5. A user or tool submits work to the worker. Synchronous ask flows go through
   `Rho.Agent.Ask`; queued/busy work goes through `Rho.Agent.Mailbox`.
6. `Rho.Agent.TurnTask` starts the supervised task that calls
   `Rho.Runner.run/2`.
7. `Rho.Runner.RuntimeBuilder` builds runtime state.
8. `Rho.Runner.Loop` or `LiteLoop` executes steps.
9. The selected `Rho.TurnStrategy` calls the LLM and classifies the response.
10. Tool calls go through `Rho.ToolExecutor` in normal mode.
11. `Rho.Recorder` and `Rho.Runner.Emit` write tape/lifecycle events.
12. `Rho.Events` broadcasts updates.
13. `RhoWeb.SessionCore`, `RhoWeb.AppLive.*`, and projections refresh UI state.
14. `%Rho.Effect.Table{}` and `%Rho.Effect.OpenWorkspace{}` flow through
    `Rho.Stdlib.EffectDispatcher` and web session/workspace dispatch paths.

## Common Change Paths

| Task | Start Here | Then Check |
| --- | --- | --- |
| New generic tool | `apps/rho_stdlib/lib/rho/stdlib/tools` | `Rho.Stdlib` shorthand map, tool tests, prompt-section budget |
| New framework tool | `RhoFrameworks.UseCases.*` | `Tools.WorkflowTools` or domain tool module, `RhoFrameworks.Plugin` |
| Runner behavior | `Rho.Runner` | `RuntimeBuilder`, `Loop`, `LiteLoop`, `Emit`, turn strategy tests |
| Agent queue/lifecycle | `Rho.Agent.Worker` | `Ask`, `Bootstrap`, `TurnTask`, `Mailbox`, multi-agent signal tests |
| Chat/thread projection | `Rho.Trace.Projection` / `Rho.Conversation.*` | `RhoWeb.AppLive.ChatEvents`, `ChatRail`, thread tests |
| Data-table server semantics | `Rho.Stdlib.DataTable.Server` | `RhoWeb.DataTableEvents`, `DataTableComponent`, projection tests |
| Data-table UI shaping | `RhoWeb.DataTable.*` | Component tests, no dynamic atoms |
| Framework library reads | `RhoFrameworks.Library` | `Library.Queries` and facade tests |
| Framework versioning | `RhoFrameworks.Library.Versioning` | Publish/default-version tests |
| Framework duplicate workflows | `RhoFrameworks.Library.Dedup` | Embedding/fallback/dismissal tests |
| AppLive page/event work | `RhoWeb.AppLive.*` | Nearby module-boundary tests and AppLive integration tests |
| CSS or tutorial content | `RhoWeb.InlineCSS.*` / `TutorialLive.Content` | Composition/hash tests and visual smoke if styling changes |

## Verification Matrix

Use the narrowest relevant tests first, then broaden.

Core runtime:

```bash
mix test --app rho
mix test apps/rho/test/rho/runner/loop_test.exs apps/rho/test/rho/runner/lite_loop_test.exs
mix test apps/rho/test/rho/agent/ask_test.exs apps/rho/test/rho/agent/turn_task_test.exs apps/rho/test/rho/agent/mailbox_test.exs
```

Stdlib:

```bash
mix test --app rho_stdlib
```

Framework domain:

```bash
mix test --app rho_frameworks
mix test apps/rho_frameworks/test/rho_frameworks/library/queries_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/library/versioning_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/library/dedup_test.exs
```

Web:

```bash
mix test apps/rho_web/test
mix test apps/rho_web/test/rho_web/data_table
mix test apps/rho_web/test/rho_web/live/app_live_live_events_test.exs
mix test apps/rho_web/test/rho_web/live/tutorial_live_content_test.exs
```

Post-change gates:

```bash
mix compile --warnings-as-errors
mix rho.slop.strict --format oneline
mix rho.credence
mix rho.arch
```

For broad or boundary-changing work:

```bash
mix rho.quality
```

`mix rho.arch` currently checks high-confidence app boundaries, module-size
warnings, and prompt/tool duplication patterns. Add rules when a new invariant
becomes important enough to protect automatically.
