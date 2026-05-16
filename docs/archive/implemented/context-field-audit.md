> **Partially superseded.** `Rho.Mount.Context` has been renamed to `Rho.Context`
> (10 fields, 3 removed: `model`, `input_messages`, `opts`). See CLAUDE.md.

# Rho.Mount.Context — Field Audit (Phase 6)

Audit of all 13 fields currently defined on `Rho.Mount.Context`
(`lib/rho/mount/context.ex`). For each field, this table records every
reader (module:line that reads the field off a context value) and every
writer (module:line that constructs a context with that key), and a
keep/remove recommendation.

**Reader discovery method.** grep'd across `lib/` + `test/` for four
access styles:

1. dotted struct access: `context.FIELD` / `ctx.FIELD`
2. `Access` protocol: `context[:FIELD]` / `ctx[:FIELD]`
3. pattern destructuring: `def f(_, %{FIELD: …})` inside Mount/Plugin
   callbacks (callbacks receive the context struct)
4. `Map.get(context, :FIELD)` inside the registry scope filter

Writers are grep results for `%Rho.Mount.Context{` /
`%Context{` construction sites.

**Writers (3 construction sites):**

- `lib/rho/runner.ex:62` — `build_runtime/3` (primary path)
- `lib/rho/agent/worker.ex:794` — `build_context/3` (legacy; still used
  by `resolve_all_tools/2` and info/status `info_map/1`)
- `test/support/reasoner_harness.ex:87` — test harness

## Fields

| # | Field | Readers | Recommendation |
|---|---|---|---|
| 1 | `model` | — none — | **REMOVE** |
| 2 | `tape_name` | `plugins/subagent.ex:20` (pattern), `tools/python.ex:12,15` (pattern), `tools/tape_tools.ex:14,26` (pattern), `plugins/subagent.ex:46` (pattern in transform), `mounts/multi_agent.ex:34,56` (Access) | **KEEP** |
| 3 | `memory_mod` | `plugins/subagent.ex:21` (`ctx[:memory_mod]`), `mounts/multi_agent.ex:37` (`ctx[:memory_mod]`) | **KEEP** |
| 4 | `input_messages` | — none — | **REMOVE** |
| 5 | `opts` | — none — (no `context.opts`, no `ctx.opts`, no `ctx[:opts]` anywhere in lib/test) | **REMOVE** |
| 6 | `workspace` | `plugins/subagent.ex:20` (pattern), `tools/bash.ex:5` (pattern), `tools/fs_read.ex:7` (pattern), `tools/fs_write.ex:7` (pattern), `tools/fs_edit.ex:7` (pattern), `tools/python.ex:12` (pattern), `skill/plugin.ex:26,34` (pattern), plus test `test/rho/skill/plugin_test.exs` builds `%{workspace: …}` contexts | **KEEP** |
| 7 | `agent_name` | `plugin_registry.ex:86` (`Map.get(context, :agent_name)` for `{:agent, name}` scope filter) | **KEEP** |
| 8 | `depth` | `plugins/step_budget.ex:19,23` (pattern), `mounts/multi_agent.ex:33,55` (pattern), `mounts/live_render.ex:25,40` (`context[:depth]`), `plugins/subagent.ex:22` (`ctx[:depth]`) | **KEEP** |
| 9 | `subagent` | `plugin_registry.ex:191` (`Map.get(context, :subagent) == true` — subagent-mode passthrough for every transformer stage) | **KEEP** |
| 10 | `agent_id` | `mounts/framework_persistence.ex:28` (`context.agent_id`), `mounts/py_agent.ex:51` (`context[:agent_id]`) | **KEEP** |
| 11 | `session_id` | `mounts/framework_persistence.ex:24` (`context.session_id`), `mounts/spreadsheet.ex:39` (pattern `%{session_id: …}`), `mounts/multi_agent.ex:34,56` (`ctx[:session_id]`), `mounts/py_agent.ex:51` (`context[:session_id]`) | **KEEP** |
| 12 | `prompt_format` | `runner.ex:147` (`ctx[:prompt_format] \|\| :markdown` during system-prompt assembly) | **KEEP** |
| 13 | `user_id` | `mounts/framework_persistence.ex:18,19` (pattern), `mounts/framework_persistence.ex:23` (`context.user_id`) | **KEEP** |

## Summary

- **Remove (3):** `model`, `input_messages`, `opts`
- **Keep (10):** `tape_name`, `memory_mod`, `workspace`, `agent_name`,
  `depth`, `subagent`, `agent_id`, `session_id`, `prompt_format`,
  `user_id`

## Notes on the critique's candidates

- `memory_mod` — **KEEP.** Read by `subagent` and `multi_agent` to
  carry the tape module into child agents.
- `user_id` — **KEEP.** `framework_persistence` depends on it to scope
  DB queries per user.
- `opts[:emit]` — **REMOVE.** No callsite reads `context.opts` in any
  form. The critique flagged this as a candidate; the grep confirms
  it can be dropped.
- `prompt_format` — **KEEP.** `runner.ex` reads it during
  system-prompt assembly to pick `:markdown` vs `:xml` rendering.

## Dead-code observation (out of scope for Phase 6)

`tools/sandbox.ex:12,18` pattern-matches `%{sandbox: %Rho.Sandbox{} = sandbox}`,
but `Rho.Mount.Context` has no `:sandbox` field — meaning these
clauses never match on a real Context and always fall through to the
empty-list fallback. This predates Phase 6 and is tracked separately.
