# Docs Plan Inventory

Date: 2026-05-15

This inventory organizes the plan-shaped documents in `docs/` by current
implementation state and intended use. It is a routing map, not a replacement
for the detailed plans. Keep `docs/current-improvement-backlog.md` as the short
active queue; use this file when deciding what to revive or fold into that
queue.

The docs root is intentionally small:

- `docs/` — canonical maps and navigation.
- `docs/active-plans/` — still-useful active or partial plans.
- `docs/backlog-plans/` — designed but not currently scheduled.
- `docs/archive/implemented/` — plans for work that landed.
- `docs/archive/superseded/` — old shapes replaced by the current architecture.
- `docs/archive/research/` — exploratory or product/domain research.

## Disposition Legend

- **Canonical** — current source of truth; keep prominent.
- **Active / Partial** — implemented in part; still has live next actions.
- **Backlog** — designed but not currently implemented; keep indexed.
- **Implemented / Historical** — landed enough that the plan should not drive
  new work directly.
- **Superseded / Reference** — architecture moved on; keep only as research
  context.
- **Research / Critique** — useful thinking, not an implementation plan.

## Current Canonical Docs

| Doc | Disposition | Notes |
| --- | --- | --- |
| `docs/current-improvement-backlog.md` | Canonical | Short routing table for active improvement work. Keep updated after each extraction or feature landing. |
| `docs/future-improvement-velocity-plan.md` | Canonical / Active | Current refactor/velocity plan. Most listed extractions have landed; remaining useful actions are focused follow-up audits and the next small extractions. |
| `docs/codex-codebase-map.md` | Canonical | Compact module map for agents. |
| `docs/rho-architecture-detailed.md` | Canonical | Current detailed architecture guide. |
| `docs/rho-architecture-map.html` | Canonical | Current visual architecture map. |
| `docs/conversation-trace-system-plan.md` | Canonical / Partial | Current direction for durable conversations, trace projections, and debug bundles. Core modules exist; continue auditing UI snapshot paths against tape projections. |
| `docs/backlog.md` | Canonical / Backlog Index | Current backlog index for designed but unscheduled work. |

## Implemented Or Mostly Implemented

These were moved to `docs/archive/implemented/` unless noted otherwise.

| Area | Docs | Evidence / Current State | Recommendation |
| --- | --- | --- | --- |
| Concept alignment / plugin-transformer refactor | `docs/archive/implemented/concept-alignment-plan.md`, `docs/archive/implemented/concept-alignment-tasks.md`, `docs/archive/research/concept-alignment-plan-critique.md`, `docs/archive/implemented/acceptance-gate-verification.md`, `docs/archive/implemented/context-field-audit.md`, `docs/archive/implemented/tagged-removal-and-lenient-streaming-plan.md` | Acceptance gate doc marks all 10 checks PASS. Current code has `Rho.Plugin`, `Rho.Transformer`, `Rho.Context`, `Rho.Runner`, `Rho.TurnStrategy`, `Rho.ToolExecutor`, and tape-write transformer path. | Historical proof only. |
| Umbrella migration / app boundaries | `docs/archive/implemented/umbrella-migration-plan.md`, `docs/archive/implemented/rho-frameworks-extraction.md`, `docs/archive/superseded/frameworks-simplification.md`, `docs/archive/superseded/kernel-minimisation-plan.md`, `docs/archive/superseded/extension-simplification-plan.md`, `docs/archive/superseded/plan-decouple-agents-channels.md` | Repo is now a seven-app umbrella; `rho` core has no Phoenix/Ecto ownership; `rho_stdlib`, `rho_baml`, `rho_python`, `rho_embeddings`, `rho_web`, and `rho_frameworks` exist. | Future boundary work belongs in `future-improvement-velocity-plan.md` and `mix rho.arch`. |
| BAML action union / structured turn work | `docs/archive/superseded/reasoner-baml-plan.md`, `docs/archive/superseded/reasoner-baml-critique.md`, `docs/archive/implemented/reasoner-baml-results.md`, `docs/archive/implemented/baml-action-union-plan.md`, `docs/archive/superseded/combined-simplification-plan.md` | `RhoBaml.SchemaWriter` emits discriminated action unions; `Rho.TurnStrategy.TypedStructured` exists; `Rho.ActionSchema` and tests cover dispatch/deferred behavior. Older `:tagged` path was explicitly pivoted away. | Historical reference only. |
| DataTable rename, named tables, streams, active table, row selection, edit row | `docs/archive/implemented/data-table-abstraction-plan.md`, `docs/archive/implemented/data-table-architecture-plan.md`, `docs/archive/implemented/plan-structured-datatable.md`, `docs/archive/implemented/spreadsheet-streams-plan.md`, `docs/archive/implemented/data-table-streams-plan.md`, `docs/archive/implemented/data-table-liveview-rewrite-handoff.md`, `docs/archive/implemented/active-table-and-edit-row-plan.md`, `docs/archive/implemented/row-selection-plan.md`, `docs/archive/superseded/proficiency-level-edit-plan.md`, `docs/archive/superseded/proficiency-level-edit-redesign.md`, `docs/archive/implemented/spreadsheet-editor-plan.md`, `docs/archive/implemented/spreadsheet-agent-handoff.md` | Code has `Rho.Stdlib.DataTable`, named tables, active table, selections, `ActiveViewListener`, `edit_row`, row selection UI, extracted `RhoWeb.DataTable.*` helpers, and focused tests. | Use current backlog for remaining DataTable extraction. |
| Upload handles and import from upload | `docs/archive/implemented/2026-05-06-file-upload-design.md`, `docs/archive/implemented/2026-05-06-file-upload-implementation.md`, `docs/archive/implemented/pdf-text-ingestion-plan.md` | Code has `Rho.Stdlib.Uploads.*`, upload observers for CSV/Excel/PDF/prose/image, `:uploads` plugin tools, and `RhoFrameworks.UseCases.ImportFromUpload` with workflow tool surface. | Historical reference only. |
| Python integration simplification | `docs/archive/implemented/python-integration-simplification-plan.md` | Code uses `apps/rho_python`, `RhoPython.Server`, `:erlang_python`, and no live Pythonx backend references. | Historical reference only. |
| Calendar versioning / publish lifecycle | `docs/archive/implemented/calendar-versioning-plan.md` | Libraries have `version`, `published_at`, default-version behavior, `RhoFrameworks.Library.Versioning`, and versioning tests. | Historical reference only. |
| Prompt caching fix | `docs/archive/implemented/prompt-caching-fix-plan.md` | `Rho.Runner` caching behavior has tests (`runner_caching_test.exs`) and projections preserve `cache_control`. | Historical reference unless new provider-specific cache work appears. |
| Flow UI and composable primitive workflow | `docs/archive/implemented/composable-primitives-plan.md`, `docs/archive/implemented/flow-ui-plan.md`, `docs/archive/implemented/handoff-post-edit-framework.md`, `docs/archive/superseded/workbench-home-actions-plan.md`, `docs/active-plans/workbench-display-refactor-plan.md` | Code has `RhoFrameworks.FlowRunner`, `RhoFrameworks.Flows.CreateFramework`, `EditFramework`, `FinalizeSkeleton`, flow policies, `RhoWeb.FlowLive`, research panel, and broad tests. | Keep only workbench-display follow-ups active. |
| Multi-tenant org/account base | `docs/archive/superseded/multi-tenant-org-plan.md`, `docs/archive/superseded/multi-user-scalability-analysis.md`, `docs/archive/superseded/finch-pool-exhaustion.md`, `docs/archive/superseded/fly-scale-to-zero.md` | Accounts, organizations, memberships, org picker/settings, rate limiter, remote IP handling, and org-scoped data exist. | Create new backlog items only for explicit scalability gaps. |
| Hiring committee demo | `docs/archive/implemented/hiring-committee-plan.md`, `docs/archive/research/multi-agent-simulation-plan.md` | `.rho.exs` has evaluator agents; `RhoFrameworks.Demos.Hiring.*` exists; multi-agent signal tests exist. | Historical demo/reference unless productizing hiring becomes a goal. |
| ESCO import | `docs/archive/implemented/esco-import-plan.md` | `Mix.Tasks.Rho.ImportEsco`, ESCO loader, and tests exist. | Historical reference only. |
| Rho CLI removal | `docs/archive/implemented/rho-cli-removal-plan.md` | No `apps/rho_cli`; core mix tasks live in `apps/rho/lib/mix/tasks`. | Historical reference only. |

## Active / Partial Plans

These should stay findable because they still describe useful next work.

| Area | Current Plan | Implemented | Still Worth Doing |
| --- | --- | --- | --- |
| AppLive and edge extraction | `future-improvement-velocity-plan.md`, older `workspace-unification-*`, `live-patch-navigation-plan.md`, `tape-driven-ui-plan.md` | Many `RhoWeb.AppLive.*` modules now exist: page loader, chat, workspace, data-table, upload/message, agent, workbench, smart entry, live events, page search, chatroom, chat rail, render components. | Audit root `AppLive` for remaining ownership leaks and stale warnings; avoid implementing older workspace plans directly. |
| DataTable component split | `future-improvement-velocity-plan.md` plus DataTable source docs above | `Export`, `Commands`, `Streams`, `Artifacts`, `Optimistic`, `Rows`, `RowComponents`, `Tabs`, event modules, and tests exist. | Check whether table-level markup/lifecycle is now clean enough; continue only with small extracted contracts. |
| Runner decomposition | `future-improvement-velocity-plan.md`, `agent-loop-*`, `reasoner-baml-*` | `Runtime`, `TapeConfig`, `RuntimeBuilder`, `Emit`, `LiteLoop`, and `Loop` are extracted. | Decide whether lite tool execution should converge with `Rho.ToolExecutor`; otherwise leave intentionally direct and document why. |
| Agent worker decomposition | `future-improvement-velocity-plan.md`, `lightweight-subagent-plan.md`, `subagent-unification-plan.md`, `multi-agent-plan.md`, `signal-plumbing.md` | `Ask`, `Bootstrap`, `TurnTask`, `Mailbox`, primary/lite tracking, registry, and multi-agent signal coverage exist. | Keep only narrowly scoped lifecycle or mailbox follow-ups in active backlog. |
| Framework library context split | `future-improvement-velocity-plan.md`, `docs/active-plans/skill-library-restructure-plan-v2.md` | `RhoFrameworks.Library.Queries`, `Versioning`, `Dedup`, `Library.Editor`, `Skeletons`, and version/dedup tests exist. | Remaining candidate extractions: row conversion/write normalization and research-note archive helpers. |
| Inline CSS/assets | `future-improvement-velocity-plan.md`, `ui-plan.md`, `ui-ux-workbench-redesign-plan.md`, `web-frameworks-redesign.md` | Inline CSS split into grouped modules (`Base`, `Chat`, `Workbench`, `DataTable`, `Pages`, `Flow`). | Optional future: move from Elixir inline CSS modules to standard Phoenix static assets after visual verification. |
| Conversation/tape unification | `conversation-trace-system-plan.md`, `docs/archive/superseded/durable-agent-chat-plan.md`, `docs/archive/superseded/conversation-threads-plan.md`, `docs/archive/superseded/workspace-unification-conversation-threads.md`, `docs/archive/superseded/workspace-unification-tape-resume.md`, `docs/active-plans/tape-system.md` | Core `Rho.Conversation.*`, `Rho.Trace.*`, tape projection, fork/compact/service/store/view modules exist. | Continue projection purity work. `RhoWeb.Session.Threads` should remain a compatibility shim, not the canonical model. |
| Skill-library restructure | `docs/active-plans/skill-library-restructure-plan-v2.md`, older `docs/archive/superseded/skill-library-restructure-plan.md`, `docs/archive/superseded/skill-framework-generation-plan.md`, `docs/active-plans/skill-embedding-dedup-plan.md` | Named-table library workflows, versioning, dedup, generation, role tools, and save framework flows exist. | Use v2 only; avoid reviving superseded save flows. |

## Backlog / Not Yet Implemented

These are real candidate backlog items. Keep the plan docs, and add or keep
short index entries in `docs/backlog.md`.

| Backlog Item | Docs | Current State | Trigger / Next Step |
| --- | --- | --- | --- |
| Self-promoting deferred tools | `docs/backlog-plans/agent-deferred-tool-promotion.md`, `docs/backlog-plans/progressive-tool-loading-plan.md` | Not implemented. Deferred tools are still static config; no `enable_tool` or `enabled_deferred_tools` exists. | Keep in backlog. Build when tool-schema token cost or deferred-tool misses become painful. |
| Dynamic skill loading | `docs/backlog-plans/dynamic-skill-loading.md` | Not implemented. Skills are still boot/config driven; no `load_skill` tool. | Keep in backlog after deferred-tool promotion. |
| Skill description optimization and eval harness | `docs/backlog-plans/skill-description-optimization.md` | Not implemented. Local skill descriptions still mostly begin with "Workflow for..."; no `mix rho.eval_skill`. | Keep in backlog; low-risk quality improvement before dynamic loading. |
| AI readiness assessment agent | `docs/backlog-plans/ai-readiness-assessment-plan.md` | Not implemented; no `AIReadiness` plugin/tools found. | Backlog as a product experiment, not architecture work. |
| Research-as-tool Option A | `docs/backlog-plans/research-as-tool-option-a.md` | Not implemented. `ResearchDomain` still spawns a worker agent; there is no `RhoFrameworks.ExaClient` or chat tool surface. | Backlog if research cost/latency or worker-agent complexity hurts. |
| Research notes/library helper extraction | `future-improvement-velocity-plan.md`, `docs/backlog-plans/research-as-tool-option-a.md` | Research notes exist and are persisted from the named table, but helper ownership can still be cleaner. | Fold into framework library context split if touched. |
| Static asset migration | `future-improvement-velocity-plan.md`, UI docs | Inline CSS is grouped but still compiled through Elixir. | Backlog only after visual regression process is reliable. |
| Lite-loop/tool-executor convergence | `future-improvement-velocity-plan.md` | Lite loop is extracted but still has direct tool execution behavior. | Decide/document whether divergence is intentional. |
| Pluggable memory beyond tape projection | `docs/archive/research/pluggable-memory-plan.md` | Current canonical path is tape projection (`Rho.Tape.Projection.JSONL`) plus trace/conversation projections. | Archived unless a non-tape backend is explicitly needed; otherwise write a new concrete storage adapter plan. |
| Simulation / SMC / multiverse research | `docs/archive/research/cps-rewrite-plan.md`, `docs/archive/research/cps-rewrite-critique.md`, `docs/archive/research/simulation-engine-plan.md`, `docs/archive/research/simulation-as-multiverse.md`, `docs/archive/research/eltv-multiverse.md`, `docs/archive/research/eltv-implementation-plan.md`, `docs/archive/research/intelligent-agent-systems-paper.md` | Not implemented as a runtime direction; CPS plan explicitly says architecture took another path. | Research archive only unless simulation becomes a named roadmap item. |
| Swappable decision policy beyond flow policies | `docs/archive/research/swappable-decision-policy-plan.md` | Flow policies exist (`Deterministic`, `Hybrid`), but no broad agent decision-policy runtime was found. | Write a new smaller agent-runtime policy plan if needed. |
| Prism/multi-dimensional role model | `docs/archive/research/prism-design-review.md`, `docs/archive/research/prism-design-review-response.md`, `docs/archive/research/prism-lens-system-plan.md`, `docs/archive/research/prism-observation-model-plan.md`, `docs/archive/research/prism-implementation-order.md`, `docs/archive/research/prism-lens-implementation.md` | Lenses exist, but the larger multi-dimensional Prism model is not the canonical current model. | Product/domain research; do not implement directly without a fresh model decision. |

## Archive Buckets

| Cluster | Location | Why |
| --- | --- | --- |
| Old workspace unification | `docs/archive/superseded/` and `docs/archive/implemented/tape-driven-ui-plan.md` | Current AppLive/conversation/trace architecture supersedes the original shape. Keep only projection-purity lessons. |
| Old architecture refactor plans | `docs/archive/superseded/` | Useful context, but current canonical path is `future-improvement-velocity-plan.md` plus architecture gates. |
| Old data-table/spreadsheet docs | `docs/archive/implemented/` and `docs/archive/superseded/` | Implemented or superseded by current named-table/DataTable architecture. |
| Old BAML/reasoner docs | `docs/archive/implemented/` and `docs/archive/superseded/` | BAML union path landed; `:tagged` experiment is historical. |
| Product/domain research | `docs/archive/research/` | Keep as context only unless a fresh roadmap item revives it. |
| Deployment/scalability notes | `docs/archive/superseded/` | Infrastructure notes, not active implementation plans. |

## Removed

- `docs/xref-baseline.txt` — obsolete generated baseline referenced only by the
  archived concept-alignment tracker.
