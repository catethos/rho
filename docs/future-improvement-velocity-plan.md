# Future Improvement Velocity Plan

Date: 2026-05-15

This plan captures a codebase audit focused on making future product and
architecture changes faster, easier to review, and less risky. It is not a bug
fix plan. The current quality gates are clean; the main drag is concentrated
module size, mixed ownership, and a few pieces of implicit architecture that
should become executable guardrails.

## Current Baseline

Rho is a seven-app Elixir umbrella:

- `apps/rho` — core runtime kernel: sessions, agents, runner, tools, plugins,
  transformers, tapes, traces, conversations, events.
- `apps/rho_stdlib` — built-in tools/plugins, data table server, uploads,
  skills, effect dispatching.
- `apps/rho_baml` — BAML/Zoi schema generation for static and dynamic
  structured-output calls.
- `apps/rho_python` — Python runtime service and dependency/config bridge.
- `apps/rho_embeddings` — embedding server and backends.
- `apps/rho_frameworks` — skill assessment domain, Ecto schemas, use cases,
  flows, framework tools.
- `apps/rho_web` — Phoenix/LiveView edge, workspaces, projections, pages,
  components, auth.

Before changing these areas, read:

- `docs/codex-codebase-map.md`
- `docs/rho-architecture-map.html`
- `AGENTS.md`

Audit commands run:

```bash
mix rho.slop.strict --format oneline
mix rho.credence
mix compile --warnings-as-errors
mix xref graph --label compile
```

Results:

- `mix rho.slop.strict --format oneline` passed.
- `mix rho.credence` passed across 456 files.
- `mix compile --warnings-as-errors` passed.
- `mix xref graph --label compile` showed no surprising compile-time boundary
  leaks in sampled apps (`rho`, `rho_stdlib`, `rho_web`).

Important audit note: several older docs mention data-table legacy signal shims
and crash-semantics gaps. The current code has already improved here:
`Rho.Stdlib.Plugins.DataTable` no longer publishes legacy row signals, and
`Rho.Stdlib.DataTable` has tested `{:error, :not_running}` behavior.

## Guiding Principle

Prefer small extraction PRs that preserve behavior and improve ownership. Do
not combine these with product changes. Each step should have a targeted test
or snapshot check, then the standard gates.

The work should make it easier to answer:

- Where does this behavior belong?
- Which module owns this state?
- What tests should fail if this contract breaks?
- Can a future agent or engineer change this without reading thousands of
  unrelated lines?

## First-Principles Frame

The goal is not smaller files for their own sake. The goal is higher change
velocity:

```text
velocity = useful behavior shipped / (discovery time + change time + verification time + review time + recovery risk)
```

From that lens, the plan should attack the causes of drag directly:

- **Discovery time** goes down when behavior has one obvious owner, names match
  responsibilities, and current plans are easy to find.
- **Change time** goes down when modules have narrow reasons to change and
  helpers can be tested without booting LiveView, agents, databases, or LLM
  flows.
- **Verification time** goes down when critical contracts have focused tests
  and architecture rules are executable.
- **Review time** goes down when PRs separate mechanical movement from behavior
  changes and each extracted module has a small public surface.
- **Recovery risk** goes down when durable invariants are protected by tests,
  warning gates, and stable facades.

The irreducible assets to protect are:

- agent turn semantics
- tape/conversation durability
- explicit table ownership and named-table behavior
- framework library versioning and persistence semantics
- LiveView user workflows
- app boundary independence

Every improvement below should either reduce one of the velocity costs above or
protect one of these assets. If an extraction only reduces line count, postpone
it.

## Decision Rules

Use these rules to keep the work from turning into aesthetic refactoring:

1. **Start at contracts, then move code.** Before extracting, name the contract
   the new module owns and add or identify the test that proves it.
2. **Prefer pure seams first.** Export builders, table row conversion, runtime
   construction, and query helpers are safer early targets than event loops or
   lifecycle code.
3. **Keep facades stable until call sites prove they can move.** Large public
   modules can become delegating facades before callers are rewritten.
4. **Add executable guardrails before deep behavior refactors.** Warning-only
   checks can land early and prevent new debt while old debt is being paid down.
5. **Split by reason to change, not by function count.** A 300-line module with
   one owner is healthier than five 80-line modules that share hidden state.
6. **One behavioral invariant per PR.** Mechanical extraction PRs should keep
   behavior unchanged; behavior-changing PRs should be explicit and narrowly
   verified.
7. **Stop when ownership becomes obvious.** Do not keep extracting merely to
   satisfy a size target.

## Leverage Model

Score each candidate before pulling it into the active queue:

| Question | Score |
| --- | --- |
| How often will future work touch this area? | 0-3 |
| How much unrelated context must a contributor read today? | 0-3 |
| Can the first step be behavior-preserving? | 0-2 |
| Can focused tests prove the contract cheaply? | 0-2 |
| Does this protect a durable architecture invariant? | 0-3 |

Prioritize work with high total score and a small reversible first step. A
large module with low change frequency should wait behind a smaller module that
blocks weekly product work.

## Minimum Viable Breakthrough

The smallest change that materially improves future velocity is:

1. create the current backlog index,
2. add warning-only architecture checks for the most important app boundaries,
3. extract one pure helper module with focused tests,
4. document the repeatable extraction pattern in this plan.

That gives future contributors a current map, prevents new boundary drift, and
proves the extraction workflow without touching the riskiest runtime paths.

## Safe Extraction Pattern

The first implementation slice proved this repeatable pattern:

1. Name the contract before moving code.
   - Example: `RhoWeb.DataTable.Export` owns CSV/XLSX serialization, while
     `DataTableComponent` keeps interaction and download events.
   - Example: `Rho.Runner.Runtime` and `Rho.Runner.TapeConfig` own immutable
     runner configuration structs, while `Rho.Runner` keeps loop orchestration.
2. Move the code without changing public call shapes.
   - Keep existing module names stable when callers already depend on them.
   - Add aliases in the original owner rather than rewriting broad call sites.
3. Add focused tests at the new contract boundary.
   - Prefer pure tests that do not boot LiveView, agents, databases, or LLMs.
4. Run the narrow tests first, then `rho.slop.strict`, `rho.credence`, and
   `rho.arch`.
5. Only after the extraction is green, consider whether callers should move to
   the new module directly.

## Priority 1: Extract `RhoWeb.AppLive`

### Problem

`apps/rho_web/lib/rho_web/live/app_live.ex` is the highest-leverage bottleneck.
At audit time it was about 5,723 lines and owned:

- LiveView mount and root assigns
- route/page hydration
- chat session lifecycle
- agent creation/removal
- uploads
- conversations and threads
- workbench actions
- workspace shell events
- data-table refresh and tab handling
- page-specific library/role/settings behavior
- large render helpers

Some extraction has already started through:

- `RhoWeb.AppLive.LibraryEvents`
- `RhoWeb.AppLive.SettingsEvents`
- `RhoWeb.AppLive.MemberEvents`

Continue that pattern.

### Proposed Shape

Extract in this order:

1. `RhoWeb.AppLive.PageLoader`
   - Own `apply_page/3` cases for `:libraries`, `:library_show`, `:roles`,
     `:role_show`, `:settings`, `:members`, and `:chat`.
   - Keep return shape as `socket`.
   - Leave route decisions in `AppLive` initially.

2. `RhoWeb.AppLive.ChatEvents`
   - Move chat/conversation/thread events such as `send_message`,
     `open_chat`, `archive_chat`, `new_conversation`, `switch_thread`,
     `fork_from_here`, `new_blank_thread`, and `close_thread`.
   - Keep helper extraction conservative; use wrapper functions if needed.

3. `RhoWeb.AppLive.WorkspaceEvents`
   - Move `switch_workspace`, `collapse_workspace`, `pin_workspace`,
     `dismiss_overlay`, `add_workspace`, `close_workspace`, focus toggles,
     and workspace hydration helpers.

4. `RhoWeb.AppLive.DataTableEvents`
   - Move `handle_info` data-table messages and refresh helpers:
     `refresh_data_table_session`, `refresh_data_table_active`,
     tab switching, selection, save/fork/publish/suggest messages.

5. `RhoWeb.AppLive.UploadEvents`
   - Move upload consumption, upload parse task arming, avatar handling, and
     upload `DOWN`/parse completion message handling.

6. `RhoWeb.AppLive.AgentEvents`
   - Move agent tab selection, drawer selection, new-agent modal toggle,
     worker creation/removal, and stop-session events.
   - Current implementation keeps `AppLive` as the event router while
     extracting lifecycle state helpers and handlers into
     `RhoWeb.AppLive.AgentEvents`.

7. `RhoWeb.AppLive.WorkbenchEvents`
   - Move workbench suggestion sending, modal open/cancel/change/submit,
     upload-backed action preparation, prompt dispatch, load-library, and
     find-roles action execution.
   - Current implementation keeps `AppLive` as the event router while
     extracting action modal helpers and handlers into
     `RhoWeb.AppLive.WorkbenchEvents`.

8. `RhoWeb.AppLive.SmartEntry`
   - Move smart natural-language submission, classifier result dispatch,
     intake query building, starting-point whitelisting, and library-hint
     resolution.
   - Current implementation keeps `AppLive` as the event router while
     extracting the classifier boundary into `RhoWeb.AppLive.SmartEntry`.

9. `RhoWeb.AppLive.LiveEvents`
   - Move canonical `Rho.Events.Event` routing, event data deserialization,
     data-table/workspace effect dispatch, and conversation refresh
     classification.
   - Current implementation keeps `AppLive` as the mailbox owner while
     extracting event normalization and routing into
     `RhoWeb.AppLive.LiveEvents`.

10. `RhoWeb.AppLive.PageSearchEvents`
    - Move page-scoped library list filtering, skill search, cluster expansion,
      role search, semantic-search async state, and skill grouping helpers.
    - Current implementation keeps `AppLive` as the event router while
      moving page-specific query and grouping behavior into
      `RhoWeb.AppLive.PageSearchEvents`.

11. `RhoWeb.AppLive.ChatroomEvents`
    - Move chatroom mention and broadcast handling, including mention target
      resolution through direct agent ids or role lookup.
    - Current implementation keeps `AppLive` as the mailbox owner while
      extracting chatroom-originated message routing into
      `RhoWeb.AppLive.ChatroomEvents`.

12. `RhoWeb.AppLive.ChatRail`
    - Move conversation/thread/message projection into chat sidebar rows.
    - Current implementation keeps `AppLive` in charge of when conversations
      refresh, while `ChatRail` owns row ids, active-state calculation, title
      and preview fallback rules, agent names, text normalization, and labels.

13. `RhoWeb.AppLive.ChatShellComponents`
    - Move render-only chat chrome out of the root LiveView: side panel,
      saved-chat rail markup, agent tabs, session controls, upload chips,
      new-chat dialog, and workbench suggestion chips.
    - Current implementation keeps `AppLive` responsible for assembling active
      messages, agents, uploads, and workbench context while
      `ChatShellComponents` owns the markup and presentation-only label
      helpers.

14. `RhoWeb.AppLive.PageComponents`
    - Move page templates for libraries, library detail, roles, role detail,
      settings, and members out of the root LiveView.
    - Current implementation keeps `AppLive` responsible for page routing and
      assign loading while `PageComponents` owns page markup and
      presentation-only role helpers.

15. `RhoWeb.AppLive.WorkspaceChromeComponents`
    - Move workspace tab chrome, overlay chrome, and debug-panel rendering out
      of the root LiveView.
    - Current implementation keeps `AppLive` responsible for shell state,
      workspace state, and debug projection storage while
      `WorkspaceChromeComponents` owns the markup and debug presentation
      helpers.

### Acceptance Criteria

- `AppLive` remains the root LiveView but becomes mostly orchestration.
- Page-specific queries are no longer embedded directly in `AppLive`.
- Chat/thread behavior has tests covering active conversation switching,
  thread fork, new blank thread, and archive behavior.
- Data-table event behavior remains covered by component and LiveView tests.
- Agent lifecycle tab and state helper behavior is covered directly at the
  extracted module boundary and through nearby AppLive tests.
- Workbench action modal and upload acceptance behavior is covered directly at
  the extracted module boundary and through nearby AppLive tests.
- Smart-entry intake query and library-hint behavior is covered directly at the
  extracted module boundary and through nearby AppLive routing tests.
- LiveEvent payload decoding and conversation-refresh classification is
  covered directly at the extracted module boundary.
- Page-specific library and role search behavior is covered directly at the
  extracted module boundary and through nearby AppLive tests.
- Chatroom mention and broadcast guard behavior is covered directly at the
  extracted module boundary.
- Chat-rail projection is covered directly at the extracted module boundary,
  including threaded rows, active-row state, title/preview fallbacks, and mixed
  message content normalization.
- Chat shell rendering is covered directly at the extracted module boundary,
  including new-chat role choices, token/role labels, and workbench suggestion
  copy/limits.
- Page rendering helpers are covered directly at the extracted module
  boundary, including role subtitle composition and role-detail section
  detection.
- Workspace/debug chrome helpers are covered directly at the extracted module
  boundary, including debug command and content formatting.

### Verification

```bash
mix test apps/rho_web/test
mix rho.slop.strict --format oneline
mix rho.credence
mix rho.arch
```

For each extraction PR, prefer narrower tests first, for example:

```bash
mix test apps/rho_web/test/rho_web/live/app_live_mount_test.exs
mix test apps/rho_web/test/rho_web/live/app_live_agent_events_test.exs
mix test apps/rho_web/test/rho_web/live/app_live_workbench_events_test.exs
mix test apps/rho_web/test/rho_web/live/app_live_smart_entry_module_test.exs apps/rho_web/test/rho_web/live/app_live_smart_entry_test.exs
mix test apps/rho_web/test/rho_web/live/app_live_live_events_test.exs
mix test apps/rho_web/test/rho_web/live/app_live_page_search_events_test.exs
mix test apps/rho_web/test/rho_web/live/app_live_chatroom_events_test.exs
mix test apps/rho_web/test/rho_web/session/threads_test.exs
```

## Priority 1b: Extract `RhoWeb.TutorialLive`

### Problem

`apps/rho_web/lib/rho_web/live/tutorial_live.ex` was a large public page module
mostly because it embedded tutorial support data and a long CSS string beside
the LiveView interaction and markup.

### Proposed Shape

1. `RhoWeb.TutorialLive.Content`
   - Own tutorial table-of-contents data, the documented example `.rho.exs`
     agent config, and the inline CSS payload.
   - Keep `TutorialLive` responsible for mount state, focus-section events,
     and the page markup.

### Acceptance Criteria

- Tutorial support content is covered directly at the extracted module
  boundary, including TOC order, safe style wrapping, and example agent-config
  shape.
- `TutorialLive` drops below the architecture warning threshold.

## Priority 2: Split `RhoWeb.DataTableComponent`

### Problem

`apps/rho_web/lib/rho_web/components/data_table_component.ex` is described as a
renderer, but it also owns synchronous writes, command/dialog behavior,
selection forwarding, optimistic edits, grouping, lazy streams, CSV export, and
XLSX export. At audit time it was about 2,698 lines.

This makes table behavior hard to change because rendering, table commands,
and serialization all need to be understood together.

### Proposed Shape

Extract in this order:

1. `RhoWeb.DataTable.Export`
   - Move `build_csv/2`, `build_xlsx/2`, and supporting helpers.
   - Keep functions pure and unit-tested.
   - This is the safest first extraction.

2. `RhoWeb.DataTable.Commands`
   - Encapsulate command payload building for edit, group edit, add row,
     delete row, child add/delete, resolve conflict.
   - Return data-table client operation descriptors or normalized changes.
   - Current implementation owns update payloads for cell edits, child edits
     keyed by natural child keys, conflict resolution, group renames, row
     creation, and child add/delete. The LiveComponent still owns socket state,
     optimistic stream updates, and dispatching to `Rho.Stdlib.DataTable`.

3. `RhoWeb.DataTable.Streams`
   - Move stream pool lookup, grouped stream population, lazy loading, panel
     item construction, and optimistic stream update/delete helpers.
   - Current implementation owns the fixed stream atom pool, group id/slug
     generation, stream window metadata, lazy page appends, panel row item
     construction, row-to-stream lookup, and stream insert/delete wrappers. The
     LiveComponent still decides when to seed or refresh streams based on
     lifecycle and user events.

4. `RhoWeb.DataTable.Artifacts`
   - Move artifact/title/metric/table-label helpers and view-key logic.
   - Current implementation owns table/view classification, library table name
     decoding, active artifact lookup, empty workbench-home detection, artifact
     tab/header labels, selection nouns, surface selection, surface metrics, and
     linked-artifact summaries.

5. `RhoWeb.DataTable.Optimistic`
   - Move optimistic top-level and child-cell overlay logic used between a local
     edit and the next authoritative server snapshot.
   - Current implementation keeps the LiveComponent in charge of when optimistic
     state is cleared and when streams are updated, while the row transformation
     contract is pure and unit-tested.

6. `RhoWeb.DataTable.Rows`
   - Move pure row ordering, grouping, group-id collection, row-id lookup, and
     select-all state calculations.
   - Current implementation keeps the LiveComponent in charge of lifecycle,
     event dispatch, and markup, while the row-shaping contract is unit-tested
     without LiveView or stream state.

7. `RhoWeb.DataTable.RowComponents`
   - Move row/cell function components for parent rows, proficiency panels,
     provenance badges, editable cells, action cells, inline edit spans, and
     row delete/add controls.
   - Current implementation keeps table-level rendering, event dispatch, stream
     orchestration, and dialog state in the LiveComponent, while row/cell markup
     is testable through focused function-component renders.

8. `RhoWeb.DataTable.Tabs`
   - Move named-table tab ordering and row-count helpers.
   - Current implementation keeps tab markup in the LiveComponent while the
     rules for hiding empty default `"main"` and reading mixed-shape table
     summaries are pure and unit-tested.

### Acceptance Criteria

- `DataTableComponent` owns LiveComponent lifecycle and markup.
- Export logic is testable without a LiveView socket.
- Data-table command normalization is testable without rendering.
- Stream item construction, group lookup, pagination metadata, and stream atom
  allocation are covered outside the large component.
- Artifact labels, view flags, empty-home detection, surface metrics, and linked
  summaries are covered outside the large component.
- Optimistic top-level and child-cell overlays are covered outside the large
  component, including atom-key preservation and unknown string-field safety.
- Sorting, grouping, nested group counts, visible row ids, and select-all state
  are covered outside the large component.
- Parent row, proficiency panel, provenance, action, editable-cell, inline edit,
  and row add/delete-control markup are covered outside the large component.
- Named-table tab ordering and row-count helpers are covered outside the large
  component.
- No dynamic atom creation is introduced; keep the existing stream pool safety
  invariant.

### Verification

```bash
mix test apps/rho_web/test/rho_web/components/data_table_component_test.exs
mix test --app rho_web
mix rho.slop.strict --format oneline
mix rho.credence
```

Add focused tests for `RhoWeb.DataTable.Export` covering:

- flat rows
- child rows/proficiency levels
- action columns excluded
- CSV escaping
- XLSX numeric conversion

Add focused tests for `RhoWeb.DataTable.Streams` covering:

- deterministic group ids and slug fragments
- parent/panel stream item construction
- flat and nested group lookup
- pagination metadata checks
- row-to-stream lookup and fixed-pool stream atom allocation

Add focused tests for `RhoWeb.DataTable.Artifacts` covering:

- library and role-candidate view classification
- active artifact and table-artifact lookup
- empty workbench-home detection
- label/metric/surface fallbacks
- linked-artifact summary text

Add focused tests for `RhoWeb.DataTable.Optimistic` covering:

- top-level overlays for atom-key and string-key rows
- child-cell overlays for `proficiency_levels`
- unknown string fields without dynamic atom creation
- ignoring edits targeted at other rows

Add focused tests for `RhoWeb.DataTable.Rows` covering:

- atom-key and string-key sorting
- one-level and two-level grouping while preserving first-seen order
- nested group id collection and row counts
- visible row ids and select-all checkbox state

Add focused tests for `RhoWeb.DataTable.RowComponents` covering:

- selected parent row rendering with provenance and delete controls
- proficiency panel child ordering and inline-edit hooks
- grouped add-row parameters

Add focused tests for `RhoWeb.DataTable.Tabs` covering:

- hiding empty default `main` only when other tables exist
- preserving non-empty/default-only main tabs
- atom-key and string-key table summaries

## Priority 3: Decompose `Rho.Runner`

### Problem

`apps/rho/lib/rho/runner.ex` is better factored than the web edge, especially
after extracting `Rho.ToolExecutor` and `Rho.Recorder`. It still owns too much:

- `Runtime` and `TapeConfig` structs
- runtime construction from `%Rho.RunSpec{}`
- legacy `run/3`
- context building
- prompt assembly
- emit wrapping and tape event conversion
- compaction
- normal loop
- lite loop
- strategy result handling
- tool outcome classification

This makes future turn-strategy work and runtime behavior changes harder than
necessary.

### Proposed Shape

Extract in this order:

1. `Rho.Runner.Runtime` and `Rho.Runner.TapeConfig`
   - Move the nested structs to their own files.
   - Keep aliases or module names stable so call sites do not churn.

2. `Rho.Runner.RuntimeBuilder`
   - Move `%Rho.RunSpec{}` runtime construction and legacy opts runtime
     construction.
   - Own context struct construction, tape config construction, provider
     gen opts, and system prompt assembly.
   - Current implementation keeps `Rho.Runner.run/2` and `run/3` stable while
     moving RunSpec/legacy runtime construction, context construction, tape
     config, provider gen opts, and prompt splitting into
     `Rho.Runner.RuntimeBuilder`.

3. `Rho.Runner.Emit`
   - Move emit wrapping, event-to-tape-entry conversion, and event metadata.
   - Keep tape-write semantics covered by existing trace/runner tests.
   - Current implementation moves legacy callback resolution, tape append
     wrapping, runner-event entry conversion, and tape metadata construction
     into `Rho.Runner.Emit`.

4. `Rho.Runner.LiteLoop`
   - Move lite loop behavior or remove lite-specific duplication by routing it
     through `Rho.ToolExecutor` with an explicit option.
   - Prefer convergence over maintaining two tool execution paths.
   - Current implementation moves lite-mode context construction, step loop,
     direct tool execution, final-result handling, parse-error retry, strategy
     error emission, and arbitrary tool-output coercion into
     `Rho.Runner.LiteLoop`. `Rho.Runner.run/2` still owns public dispatch and
     normal-mode recording/loop orchestration. Existing regression coverage now
     proves lite-mode tuple coercion, max-step behavior, and strategy error
     emission.

5. `Rho.Runner.Loop`
   - Once the above are stable, consider moving normal loop and strategy-result
     dispatch into a dedicated module.
   - Current implementation moves normal-mode step orchestration, compaction,
     `:prompt_out` transformer dispatch, strategy-result dispatch,
     `Rho.ToolExecutor` invocation, post-step injection, and context
     advancement into `Rho.Runner.Loop`. `Rho.Runner` remains the public
     entry point and still owns initial context construction and system
     message assembly.

### Acceptance Criteria

- `Rho.Runner.run/2` remains the public entry point.
- Existing strategy tests pass unchanged.
- Tool execution semantics do not drift between normal and lite mode unless
  explicitly intended and tested.
- Tape projections and trace bundle tests still pass.

### Verification

```bash
mix test --app rho
mix rho.slop.strict --format oneline
mix rho.credence
```

Useful targeted tests:

```bash
mix test apps/rho/test/rho/runner_test.exs
mix test apps/rho/test/rho/runner/lite_loop_test.exs apps/rho/test/rho/runner_tool_coercion_test.exs apps/rho/test/rho/runner_test.exs
mix test apps/rho/test/rho/runner/loop_test.exs apps/rho/test/rho/runner/lite_loop_test.exs apps/rho/test/rho/runner_test.exs apps/rho/test/rho/tool_executor_test.exs apps/rho/test/rho/turn_strategy/typed_structured_test.exs apps/rho/test/rho/trace/projection_test.exs
mix test apps/rho/test/rho/tool_executor_test.exs
mix test apps/rho/test/rho/turn_strategy/typed_structured_test.exs
mix test apps/rho/test/rho/trace/projection_test.exs
```

## Priority 4: Shrink `Rho.Agent.Worker`

### Problem

`apps/rho/lib/rho/agent/worker.ex` is the unified process for primary,
delegated, and nested agents. That unification is valuable, but the module
mixes:

- public API (`submit`, `ask`, `collect`, `cancel`)
- bus-based await behavior
- bootstrapping
- RunSpec finalization
- sandbox/tape initialization
- lifecycle event publishing
- mailbox and queue behavior
- watchdog/inactivity behavior
- task process supervision

This makes multi-agent features risky because small lifecycle changes require
reading almost the entire worker.

### Proposed Shape

Extract in this order:

1. `Rho.Agent.Ask`
   - Move `ask/3`, `await_reply`, and result unwrapping.
   - Keep bus-only semantics documented and tested.
   - Current implementation keeps `Rho.Agent.Worker.ask/3` as the public API
     while moving session subscription, submit-and-await orchestration,
     turn-vs-finish await modes, inactivity timeouts, and final-result
     unwrapping into `Rho.Agent.Ask`.

2. `Rho.Agent.Bootstrap`
   - Move default RunSpec construction, tape bootstrap, sandbox start, and
     capability derivation.
   - Return a normalized state seed for `Worker.init/1`.
   - Current implementation prepares a `Rho.Agent.Bootstrap` seed with
     finalized RunSpec identity, tape reference/module, effective workspace,
     optional sandbox, derived capabilities, registry metadata, and
     agent-started event data. `Rho.Agent.Worker.init/1` still owns process
     flags, registry writes, lifecycle broadcasts, and initial-task
     continuation.

3. `Rho.Agent.TurnTask`
   - Encapsulate starting, monitoring, cancelling, and watchdog metadata for
     the task that runs `Rho.Runner`.
   - Current implementation moves supervised task start, busy registry status,
     task-accepted events, persistent-tool bookkeeping, cancellation, and
     inactivity watchdog enforcement into `Rho.Agent.TurnTask`. Turn
     construction and task result handling stay in `Rho.Agent.Worker`.

4. `Rho.Agent.Mailbox`
   - Encapsulate queue/mailbox operations if future multi-agent signal work
     grows further.
   - Current implementation moves busy-submit queueing, delayed signal
     queueing, and next-item selection into `Rho.Agent.Mailbox`. Queue
     processing still prefers signals over regular submits. Queued submit
     turns now preserve the `turn_id` returned to the caller when the turn is
     eventually started, which protects synchronous bus-await behavior.

### Acceptance Criteria

- `Rho.Agent.Worker` remains the GenServer owner.
- Public API remains stable.
- Worker tests and multi-agent plugin tests pass.
- Watchdog behavior remains observable and covered.

### Verification

```bash
mix test apps/rho/test/rho/agent/ask_test.exs apps/rho/test/rho/agent/event_log_test.exs
mix test apps/rho/test/rho/agent/bootstrap_test.exs apps/rho/test/rho/agent/ask_test.exs apps/rho/test/rho/agent/event_log_test.exs
mix test apps/rho/test/rho/agent/turn_task_test.exs apps/rho/test/rho/agent/bootstrap_test.exs apps/rho/test/rho/agent/ask_test.exs apps/rho/test/rho/agent/event_log_test.exs
mix test apps/rho/test/rho/agent/mailbox_test.exs apps/rho/test/rho/agent/worker_queue_test.exs apps/rho/test/rho/agent/turn_task_test.exs apps/rho/test/rho/agent/bootstrap_test.exs apps/rho/test/rho/agent/ask_test.exs apps/rho/test/rho/agent/event_log_test.exs
mix test apps/rho/test/rho/agent/event_log_test.exs
mix test apps/rho_stdlib/test/rho/stdlib/plugins/multi_agent_signal_test.exs
mix test --app rho
mix test --app rho_stdlib
mix rho.slop.strict --format oneline
mix rho.credence
```

## Priority 5: Split `RhoFrameworks.Library`

### Problem

`apps/rho_frameworks/lib/rho_frameworks/library.ex` is the main domain context
for library CRUD, skills, immutability, forking, deduplication, research notes,
prompt summaries, and data-table-shaped read models. At audit time it was about
2,333 lines.

The `UseCases.*` layer is already strong. The context can be split behind a
stable facade without forcing broad call-site churn.

### Proposed Shape

Keep `RhoFrameworks.Library` as the public facade initially. Extract internal
modules:

1. `RhoFrameworks.Library.Queries`
   - list/get/search/read-model queries
   - `library_summary/1`
   - skill index and cluster loading
   - Current implementation keeps `RhoFrameworks.Library` as the public facade
     while moving library listing, visible-library lookup, version read
     queries, skill listing/search/browse, table-shaped library rows, skill
     index/cluster loading, cross-library search, and role-profile lookup into
     `RhoFrameworks.Library.Queries`.

2. `RhoFrameworks.Library.Versioning`
   - immutable publishing
   - default version handling
   - fork/version source semantics
   - Current implementation keeps the public facade stable while moving
     version tag selection, publish validation/notes, default-version updates,
     and version diffs into `RhoFrameworks.Library.Versioning`. Duplicate
     publish attempts now preserve the intended
     `{:error, :version_exists, message}` result instead of falling through the
     publishing transaction.

3. `RhoFrameworks.Library.Dedup`
   - duplicate detection
   - semantic duplicate orchestration
   - duplicate dismissal
   - consolidation report support
   - Current implementation keeps `RhoFrameworks.Library` as the public facade
     while moving duplicate candidate generation, semantic pgvector/Jaro
     fallback detection, duplicate dismissals, role-reference enrichment, and
     consolidation report buckets into `RhoFrameworks.Library.Dedup`.

4. `RhoFrameworks.Library.Rows`
   - conversion to and from data-table rows
   - row IDs and table metadata

5. `RhoFrameworks.Library.ResearchNotes`
   - archived research note reads/writes currently tied to library save flows

### Acceptance Criteria

- Public callers can continue using `RhoFrameworks.Library`.
- Use case modules remain the preferred location for workflows.
- Query modules do not leak Ecto details into tools or web components.
- Read-model query behavior is covered directly at the extracted module
  boundary and through the existing facade/integration tests.
- Versioning behavior is covered directly at the extracted module boundary and
  through the existing facade/integration tests.
- Dedup behavior is covered directly at the extracted module boundary and
  through the existing facade/integration tests.

### Verification

```bash
mix test --app rho_frameworks
mix rho.slop.strict --format oneline
mix rho.credence
```

Useful targeted tests:

```bash
mix test apps/rho_frameworks/test/rho_frameworks/library_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/library/queries_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/library/versioning_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/library/dedup_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/library/data_path_integration_test.exs
mix test apps/rho_frameworks/test/rho_frameworks/use_cases/save_framework_test.exs
```

If `save_framework_test.exs` does not exist when this work starts, use the
nearest existing `UseCases.SaveFramework` coverage or add it as part of the
split.

## Priority 6: Move Inline Assets Toward Maintainable Assets

### Problem

`apps/rho_web/lib/rho_web/inline_css.ex` is a very large CSS string. At audit
time it was about 6,447 lines. `inline_js.ex` is smaller but follows the same
pattern.

This makes UI changes hard to review and hard to search structurally. It also
couples CSS edits to Elixir compilation.

### Proposed Shape

Use the lowest-risk step first:

1. Split the CSS source into grouped files under a static or private asset
   directory, for example:
   - base/reset/tokens
   - shell/workspaces
   - chat
   - data table
   - libraries/roles
   - forms/modals
   - Current implementation keeps grouped Elixir source modules under
     `apps/rho_web/lib/rho_web/inline_css/`:
     `Base`, `Chat`, `Workbench`, `DataTable`, `Pages`, and `Flow`.

2. Keep `RhoWeb.InlineCSS.css/0` as the public API initially.

3. Generate or concatenate the grouped CSS at compile time or runtime.
   - Current implementation concatenates the grouped modules at runtime and is
     covered by a focused composition test.

4. Only after behavior is stable, consider moving to standard Phoenix static
   asset delivery.

### Acceptance Criteria

- No visual behavior changes in the first extraction.
- The app can still serve CSS through the current code path.
- CSS sections become independently reviewable.
- `RhoWeb.InlineCSS.css/0` remains byte-for-byte stable across the mechanical
  split.

### Verification

```bash
mix compile --warnings-as-errors
mix test --app rho_web
mix rho.slop.strict --format oneline
mix rho.credence
```

For visual changes after the mechanical split, verify in browser across the
main views:

- chat
- data table/workbench
- library list/detail
- role list/detail
- settings/members

## Priority 7: Make Architecture Guardrails Executable

### Problem

The codebase has strong architecture docs, but several important rules are
currently social conventions:

- `apps/rho` should not depend on Phoenix/Ecto/web/domain code except approved
  low-level dependencies such as `phoenix_pubsub`.
- `apps/rho_stdlib` should avoid hard domain coupling to `rho_frameworks`.
- data-table named table behavior should remain explicit.
- tape entries are durable source of truth; UI snapshots are cache only.
- tool descriptions and prompt sections should not duplicate each other.

### Proposed Shape

Add a lightweight architecture check suite:

1. `mix rho.arch`
   - xref boundary checks
   - forbidden module reference checks
   - max module size warning threshold
   - stale legacy alias checks if desired

2. CI alias:

```elixir
"rho.quality": [
  "format --check-formatted",
  "compile --warnings-as-errors",
  "rho.credence",
  "rho.arch"
]
```

3. Start warning-only for module size and tighten after extractions land.

### Suggested Initial Rules

- Error if `apps/rho/lib` references `RhoWeb`.
- Error if `apps/rho/lib` references `RhoFrameworks.Repo`.
- Error if `apps/rho_baml/lib`, `apps/rho_python/lib`, or
  `apps/rho_embeddings/lib` references `RhoWeb`.
- Warning if any non-generated `.ex` file exceeds 1,500 lines.
- Warning if `prompt_sections` contain obvious tool-list duplication phrases
  such as `tool`, `parameter`, and a known tool name in the same paragraph.

### Acceptance Criteria

- The task is cheap to run locally.
- The rules catch real boundary drift without blocking current known debt on
  day one.
- The warnings point to docs explaining the invariant.

### Verification

```bash
mix rho.arch
mix rho.quality
```

## Priority 8: Consolidate Current Improvement Backlog

### Problem

The `docs/` directory contains many valuable historical plans. Some are current,
some are partially completed, and some are superseded. This makes future agents
and engineers spend time deciding whether a plan is still authoritative.

### Proposed Shape

Create `docs/current-improvement-backlog.md` with a small table:

| Area | Current Plan | Status | Source Docs | Next Action |
| --- | --- | --- | --- | --- |

Initial categories:

- AppLive extraction
- DataTable component split
- Runner decomposition
- Agent worker decomposition
- Framework library context split
- Inline asset migration
- Architecture guardrails
- Workspace projection purity
- Conversation/tape unification
- Skill-library restructuring

Statuses:

- `active`
- `queued`
- `partially done`
- `superseded`
- `historical`

### Acceptance Criteria

- A future contributor can tell which plan to follow in under two minutes.
- Superseded docs are not deleted unless explicitly requested.
- Current plans link back to source docs for context.

## Recommended Sequence

### Phase 0: Make the Work Legible

1. Add this plan and `docs/current-improvement-backlog.md`.
2. Mark superseded/historical plans in the backlog instead of deleting them.
3. Add a short "how to extract safely" note to this plan after the first
   successful extraction PR.

Outcome: a future contributor can find the current plan, understand why it is
ordered this way, and avoid re-litigating old plans.

### Phase 1: Guard New Debt

1. Add `mix rho.arch` with the highest-confidence boundary rules only.
2. Include warning-only module-size reporting.
3. Add `rho.arch` to `rho.quality` after it is cheap and stable.

Outcome: the codebase stops accumulating new cross-app drift while existing
large modules are still being decomposed.

### Phase 2: Prove the Extraction Pattern on Pure Code

1. Extract `RhoWeb.DataTable.Export`.
2. Add focused export tests for CSV/XLSX behavior.
3. Extract `Rho.Runner.Runtime` and `Rho.Runner.TapeConfig`.

Outcome: the first PRs are easy to review, behavior-preserving, and useful as
templates for later work.

### Phase 3: Reduce the Highest-Frequency Edge Bottleneck

1. Extract `AppLive.PageLoader`.
2. Extract `AppLive.DataTableEvents`.
3. Extract `AppLive.ChatEvents`.
4. Extract `AppLive.WorkspaceEvents` and `AppLive.UploadEvents` if the first
   three extractions clearly reduce review and test burden.

Outcome: common product changes no longer require reading the whole root
LiveView.

### Phase 4: De-risk Runtime and Agent Lifecycle Changes

1. Extract `Rho.Runner.RuntimeBuilder`.
2. Extract `Rho.Runner.Emit`.
3. Decide whether `Rho.Runner.LiteLoop` should converge with the normal
   `ToolExecutor` path before moving loop code.
4. Extract `Rho.Agent.Ask`.
5. Extract `Rho.Agent.Bootstrap` and `Rho.Agent.TurnTask`.

Outcome: turn-strategy, tracing, and multi-agent work can change isolated
contracts instead of editing monolithic lifecycle modules.

### Phase 5: Split Domain and Asset Ownership

1. Split `RhoFrameworks.Library` behind its facade. Queries, versioning, and
   dedup are extracted; continue with row conversion/write normalization or
   archived research notes.
2. Split inline CSS into grouped source files while preserving
   `RhoWeb.InlineCSS.css/0`.
3. Consider standard Phoenix static asset delivery only after the mechanical
   split is stable.

Outcome: domain persistence and UI styling become independently reviewable
without forcing broad call-site churn.

## Non-Goals

- Do not rewrite the agent loop.
- Do not redesign workspace UX.
- Do not change data-table persistence semantics.
- Do not remove historical docs in the same PR as code extraction.
- Do not change public tool names or schemas unless the task explicitly calls
  for it.
- Do not combine refactors with feature work.

## Standard Quality Gates

After each change:

```bash
mix rho.slop.strict --format oneline
mix rho.credence
```

For broader changes:

```bash
mix rho.quality
```

For app-specific work:

```bash
mix test --app rho
mix test --app rho_stdlib
mix test --app rho_frameworks
mix test --app rho_web
```

Run the narrowest relevant test first, then broaden once the local behavior is
stable.
