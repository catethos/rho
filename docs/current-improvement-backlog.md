# Current Improvement Backlog

Date: 2026-05-15

This is the quick routing table for active improvement work. Historical plans
stay in `docs/` for context, but this file says which plan to follow now and
what the next action should be.

| Area | Current Plan | Status | Source Docs | Next Action |
| --- | --- | --- | --- | --- |
| Improvement velocity | `docs/future-improvement-velocity-plan.md` | active | `docs/architecture-review.md`, `docs/architecture-tasks.md`, `docs/backlog.md` | Implement the minimum viable breakthrough: guardrails plus one pure extraction. |
| AppLive/TutorialLive extraction | `docs/future-improvement-velocity-plan.md` | active | `docs/mount-architecture-refactor.md`, `docs/live-patch-navigation-plan.md`, `docs/workspace-unification-plan.md` | PageLoader, data-table, chat, workspace shell, message/upload events, agent lifecycle events, workbench actions, smart-entry flow dispatch, LiveEvent routing, page-specific library/role search handlers, chatroom message helpers, chat-rail projection, chat shell render components, page render components, and workspace/debug chrome components are extracted; `RhoWeb.TutorialLive.Content` now owns tutorial support data/CSS. Next: run full gates and audit remaining plan items. |
| DataTable component split | `docs/future-improvement-velocity-plan.md` | partially done | `docs/data-table-abstraction-plan.md`, `docs/data-table-architecture-plan.md`, `docs/data-table-liveview-rewrite-handoff.md`, `docs/plans/data-table-streams-plan.md` | `RhoWeb.DataTable.Export`, `Commands`, `Streams`, `Artifacts`, `Optimistic`, `Rows`, `RowComponents`, and `Tabs` are extracted with focused tests. Next: audit remaining table-level render helpers or AppLive/TutorialLive warnings. |
| Runner decomposition | `docs/future-improvement-velocity-plan.md` | partially done | `docs/agent-loop-funx-refactor.md`, `docs/agent-loop-plumbing-problems.md`, `docs/reasoner-baml-plan.md`, `docs/plans/baml-action-union-plan.md` | `Rho.Runner.Runtime`, `TapeConfig`, `RuntimeBuilder`, `Emit`, `LiteLoop`, and `Loop` are extracted. Next: decide whether lite tool execution should converge with `ToolExecutor` or leave it intentionally direct. |
| Agent worker decomposition | `docs/future-improvement-velocity-plan.md` | partially done | `docs/lightweight-subagent-plan.md`, `docs/subagent-unification-plan.md`, `docs/multi-agent-plan.md`, `docs/signal-plumbing.md` | `Rho.Agent.Ask`, `Rho.Agent.Bootstrap`, `Rho.Agent.TurnTask`, and `Rho.Agent.Mailbox` are extracted with focused tests and multi-agent signal coverage. Next: return to runner lite-loop convergence or AppLive/DataTable follow-up extraction. |
| Framework library context split | `docs/future-improvement-velocity-plan.md` | partially done | `docs/frameworks-simplification.md`, `docs/rho-frameworks-extraction.md`, `docs/skill-library-restructure-plan-v2.md` | `RhoFrameworks.Library.Queries`, `Versioning`, and `Dedup` are extracted behind the facade with focused DB-backed tests. Next: split row conversion/write normalization or archived research notes. |
| Inline asset migration | `docs/future-improvement-velocity-plan.md` | partially done | `docs/ui-plan.md`, `docs/ui-ux-workbench-redesign-plan.md`, `docs/web-frameworks-redesign.md` | CSS is split into `RhoWeb.InlineCSS.Base`, `Chat`, `Workbench`, `DataTable`, `Pages`, and `Flow` while preserving `RhoWeb.InlineCSS.css/0`. Next: verify visual views before any styling changes or consider moving grouped CSS to Phoenix static assets. |
| Architecture guardrails | `docs/future-improvement-velocity-plan.md` | partially done | `docs/codex-codebase-map.md`, `docs/rho-architecture-map.html`, `docs/state-boundaries.md` | `mix rho.arch` is added and included in `mix rho.quality`. Next: add targeted rules as new boundary failures are discovered. |
| Workspace projection purity | `docs/workspace-unification-conversation-threads.md` | partially done | `docs/workspace-unification-plan.md`, `docs/workspace-unification-tape-resume.md`, `docs/tape-driven-ui-plan.md` | Reconcile remaining UI snapshot cache paths against tape projections. |
| Conversation/tape unification | `docs/conversation-trace-system-plan.md` | partially done | `docs/conversation-threads-plan.md`, `docs/durable-agent-chat-plan.md`, `docs/tape-system.md` | Keep tape entries as source of truth; audit future thread work against projection tests. |
| Skill-library restructuring | `docs/skill-library-restructure-plan-v2.md` | partially done | `docs/skill-library-restructure-plan.md`, `docs/skill-framework-generation-plan.md`, `docs/skill-embedding-dedup-plan.md` | Use current framework tools and table naming conventions; avoid reviving superseded save flows. |

Status meanings:

- `active` means current implementation work may start here.
- `queued` means the plan is current but should wait for earlier active steps.
- `partially done` means some design has landed and the next action needs a
  focused audit before new code.
- `superseded` means keep for context but do not implement directly.
- `historical` means research/background only.
