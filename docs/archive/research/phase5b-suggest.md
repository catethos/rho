# Phase 5b — "Suggest" button (completed)

**Status:** landed 2026-04-27 on `feat/decision-policy`. Builds the
Direct → escalate-once affordance from §11.3 of
`docs/swappable-decision-policy-plan.md` on top of Phase 5's
mode-toggle / Workbench / `Rho.Events` `source`/`reason` plumbing.

## What shipped

### 1. BAML structured-output function

`RhoFrameworks.LLM.SuggestSkills`
(`apps/rho_frameworks/lib/rho_frameworks/llm/suggest_skills.ex`).

Zoi schema:

```elixir
%SuggestSkills{
  skills: [%{category, cluster, name, description}]
}
```

`category` is included (the brief named only `cluster, name, description`)
because the strict `library` schema requires it — the model is told to
reuse existing categories when semantically equivalent. Auto-emits to
`apps/rho_frameworks/priv/baml_src/functions/suggest_skills.baml` at
compile time.

This is the first BAML function in the codebase that uses
`RhoBaml.Function.stream/3`. The default seam impl
(`UseCases.SuggestSkills.default_suggest/4`) tracks how many array
entries have already been forwarded via the Process dictionary so each
fully-formed skill is emitted to `on_partial` exactly once as the
structured stream grows.

### 2. UseCase + Application env seam

`RhoFrameworks.UseCases.SuggestSkills` reads
`Application.get_env(:rho_frameworks, :suggest_fn)` (mirroring
`:research_domain_spawn_fn`). The seam shape is:

    (existing :: String.t(), intake :: String.t(), n :: pos_integer(),
     on_partial :: (skill -> any())) :: {:ok, [skill]} | {:error, term()}

Persistence stays inside the UseCase: each `on_partial.(skill)` call
maps the skill onto a `library` row and pushes it through
`Workbench.add_skill/3`. Duplicate-`skill_name` errors are treated as
benign (BAML may re-emit the same partial as the array grows; the
model may also propose a name that already exists). Partials missing
any of `{category, cluster, name, description}` are silently skipped.

Inputs:

- **`existing`** — bullet-list rendering of the active library's rows
  (`[category / cluster] name`) read from
  `Rho.Stdlib.DataTable.get_rows`.
- **`intake`** — `Name:` / `Description:` lines pulled from the session's
  `meta` table; falls back to "(no intake provided)".
- **`n`** — clamped to `1..10`. Default 5 if missing/invalid.

Each row lands with `source: :agent, reason: "user requested
suggest_skills"`. Rationale: rows are AI-authored even though the
click is user-initiated. The `A` provenance badge renders correctly;
`reason` distinguishes Suggest from chat-driven `add_skill`. (`:user`
stays reserved for "human typed it cell-by-cell".)

### 3. UI

- New "Suggest" button in `RhoWeb.DataTableComponent`'s toolbar,
  positioned next to Save / Publish / Fork and gated by the same
  `library_view?(@view_key, @active_table)` predicate.
- In-component dialog (consistent with the Save / Publish dialogs):
  one numeric field "How many?" (default 5, min 1, max 10),
  Cancel / Suggest buttons.
- Submit fires `confirm_suggest` → `send(self(), {:suggest_skills, n,
  active_table, session_id})` to the parent LiveView. The component
  doesn't run the UseCase itself.
- `RhoWeb.AppLive.handle_info({:suggest_skills, n, table, sid}, ...)`
  builds a `RhoFrameworks.Scope` from the LV's `current_organization`
  / `current_user` / `session_id` and spawns the UseCase under
  `Rho.TaskSupervisor` so the LV process never blocks on the LLM
  call. Rows arrive progressively — the existing `:data_table`
  invalidation events that `Workbench.add_skill` emits drive the
  table refresh; no new pubsub plumbing.
- CSS: `dt-suggest-btn` hover styling in `inline_css.ex`,
  reusing the orange palette so the four library actions
  (Save / Publish / Fork / Suggest) read as a related cluster.

### 4. Tests

- `RhoFrameworks.UseCases.SuggestSkillsTest` (7 tests) — stubs
  `:suggest_fn`, asserts:
  - rows arrive via `Workbench.add_skill/3` in order,
  - duplicate `skill_name` partials don't blow up the stream,
  - partials missing required fields are skipped silently,
  - `n` is clamped to 10 / defaulted to 5,
  - seam errors propagate as `{:error, reason}`,
  - `:agent` provenance is stamped onto every row,
  - a custom `:table` opt routes to `library:<name>`.
- `RhoWeb.DataTableComponentTest` — 2 new render tests asserting
  the Suggest button renders on a library view (via
  `view_key: :skill_library`) and is hidden on a `role_profile` view.

## Files touched

```
A apps/rho_frameworks/lib/rho_frameworks/llm/suggest_skills.ex
A apps/rho_frameworks/lib/rho_frameworks/use_cases/suggest_skills.ex
A apps/rho_frameworks/priv/baml_src/functions/suggest_skills.baml         (auto-generated)
A apps/rho_frameworks/test/rho_frameworks/use_cases/suggest_skills_test.exs
M apps/rho_web/lib/rho_web/components/data_table_component.ex
M apps/rho_web/lib/rho_web/inline_css.ex
M apps/rho_web/lib/rho_web/live/app_live.ex
M apps/rho_web/test/rho_web/components/data_table_component_test.exs
M docs/phase5b-suggest.md                                                  (this file)
```

## What's next

Phase 6 (skeleton via BAML, single implementation) is now landed —
see `notebooks/phase6_baml_skeleton.livemd` and
`apps/rho_frameworks/lib/rho_frameworks/use_cases/generate_framework_skeletons.ex`.

What actually got shared between Phase 5b (Suggest) and Phase 6
(GenerateSkeleton):

- **Streaming-callback shape.** `default_suggest/4`'s
  Process-dictionary pattern — track persisted count, drop already-emitted
  partials, take-while fully-formed — ports verbatim to
  `default_generate/2`. Only the seam signature differs.
- **`Workbench.add_skill/3` persistence path.** Both UseCases route
  fully-formed skills through the same domain primitive; the only
  variable is `source` on the Scope (`:agent` for Suggest,
  `:flow` for the wizard, `:agent` for the chat tool wrapper).
- **Application-env seam.** Same shape: `Application.put_env`
  swaps the LLM half so tests run without BAML/OpenRouter.
- **AppLive's `Task.Supervisor` → `:foo_completed` send-and-receive
  pattern.** Reused verbatim in `FlowLive.spawn_generate_skeletons/4`
  for the wizard's `:generate` node.

What forked:

- **`:meta` callback variant.** `GenerateSkeleton` emits framework-level
  `name` / `description` ahead of the skills array. `default_generate/2`
  watches for those fields completing once and triggers a single
  `Workbench.set_meta/2` write. Suggest had no need for this.
- **Library lookup-or-create on save.** `SaveFramework` was extended
  to look up the framework by name from the `meta` table and create
  the Library record if it doesn't exist. Phase 5b's library was
  always preexisting, so this didn't apply. The change keeps the
  generation step pure (no Ecto writes during streaming).
- **Open-mode verbose log.** `default_generate/2` broadcasts a
  `:structured_partial` event per persistence write. `FlowLive`'s
  existing `handle_text_delta/2` pipes that into `streaming_text`,
  which only renders when `show_theater?(:open, _)` is true. Suggest
  doesn't expose a "verbose progress" mode — it lives on a chat page
  with no theater toggle.

`SkeletonGenerator` and its dedicated test were deleted; the agentic
path is fully gone.

---

Phase 7 (proficiency writer via BAML) is now landed — see
`apps/rho_frameworks/lib/rho_frameworks/llm/write_proficiency_levels.ex`
and `apps/rho_frameworks/lib/rho_frameworks/use_cases/generate_proficiency.ex`.

What got shared with Phase 5b/6:

- **Streaming-callback shape.** `default_write/2` is the same
  Process-dictionary pattern as `default_suggest/4` and
  `default_generate/2` — track persisted count, drop already-emitted
  partials, take-while fully-formed. Lifted verbatim, only the
  per-skill predicate differs (proficiency requires nested fully-formed
  `levels`, not just top-level fields).
- **Application-env seam.** `:write_proficiency_levels_fn` is a peer
  of `:suggest_fn` and `:generate_skeleton_fn` — same `(input,
  on_partial)` shape, same on_exit cleanup. Tests stub it without
  hitting BAML.
- **`Workbench.set_proficiency/4` persistence path.** Same domain-API
  surface used elsewhere; the UseCase only knows about Workbench, not
  DataTableOps.

What forked:

- **Per-category fan-out.** Unlike Suggest/Skeleton, which run one
  streaming call per UseCase invocation, GenerateProficiency spawns N
  Tasks under `Rho.TaskSupervisor` (one per category) and returns
  `{:async, %{workers: [...]}}`. Each Task runs the seam independently
  and emits its own `:task_requested` / `:task_completed` event with a
  per-worker `worker_agent_id`.
- **No stagger.** The old `:proficiency_writer` agent loop staggered
  spawns 250ms apart to avoid connection-pool exhaustion. With BAML
  streaming, each Task is a single HTTP request — light enough that
  per-Task connection cost no longer warrants staggering.
- **Sibling failure isolation.** Each Task wraps its body in a
  try/rescue that emits a `:task_completed` with `status: :error`
  before exiting. A crash in one category never prevents siblings from
  finishing or stops the FlowLive UI from collapsing the fan-out card
  to "Done" once all workers report.
- **No `:structured_partial` verbose log.** Proficiency-writer
  partials don't surface as text deltas — the wizard's fan-out card
  shows worker status, not a streaming text panel. Open mode would
  re-add it later if needed.

What didn't change:

- The `:add_proficiency_levels` chat-side tool in
  `apps/rho_frameworks/lib/rho_frameworks/tools/shared_tools.ex` stays
  put. It's the agent-callable equivalent of the same Workbench write
  and uses the same `Editor.apply_proficiency_levels/2` path. A future
  unification could route the tool through `Workbench.set_proficiency`
  per-skill, but that's mechanical and out of scope for Phase 7.
- The fan-out UI in `flow_live.ex` (`fan_out_step` component,
  `handle_worker_completed/2`, `mark_worker_completed/2`) is unchanged.
  The new code emits the same event shape with the same
  `worker_agent_id` field the LV already reads.

## Phase 8 — what was shared/forked

What was shared:

- **`AgentJobs.start/1`.** The per-step chat agent uses the same lite
  spawn path as the research worker — `Task.Supervisor.async_nolink`
  under `Rho.TaskSupervisor`, no tape, direct turn strategy. The only
  difference is the tool list (a single use-case tool plus `clarify`)
  and `agent_name: :step_chat` for telemetry.
- **The streaming/tool-event assigns on `FlowLive`.** The chat agent
  writes to the same `:streaming_text` and `:tool_events` assigns the
  active step uses. The gate that filters incoming `:text_delta` /
  `:tool_start` / `:tool_result` events was widened from
  `step_status == :running` to *that* OR `step_chat_agent_id != nil`.
  No second pane, no separate transport.
- **The `:task_completed` handler.** Step-chat agent completion is
  matched in the same `cond` that already handles `research_agent_id`
  vs the fan-out worker list. New cond branch, same shape.
- **The Application-env spawn seam pattern.** `:step_chat_spawn_fn`
  mirrors `:research_domain_spawn_fn` exactly — a one-arg function the
  test stubs to bypass the real LLM call. Same on_exit cleanup, same
  message-send-back-to-parent pattern.

What was *not* reused — and why:

- **`chat_side_panel/1` (`session_live/layout_components.ex`).** That
  component is the chat overlay's history pane: persisted
  conversation, thread list, agent avatar, drag handle. The
  per-step chat is intentionally tiny — one textarea, one submit,
  optional clarify callout, and a minimal streaming/tool-event log.
  Reusing the side panel would have meant either fighting its
  history-persistence assumptions or stripping out 80% of its render
  surface; cleaner to write a fresh ~100-line component.
- **The chat overlay's persisted-thread machinery.** Each step-chat
  turn is independent — no `chatroom_component`, no message store,
  no tape. If the user wants a multi-turn refinement they re-submit.
  This keeps the per-turn cost proportional to the per-turn
  benefit.
- **`worker_prompt`'s "do not ask clarifying questions" suffix.** The
  template appends this as a generic worker discipline, but `clarify`
  is exactly that — asking back when ambiguity warrants it. The
  step-chat system_prompt explicitly authorizes `clarify` for
  genuinely ambiguous requests; the trailing suffix is tolerated
  because the tool def is right there with concrete usage guidance.
  Plumbing a way to skip the suffix is a future option only if
  practice shows agents over-clarifying.
