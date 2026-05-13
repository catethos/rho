# Research-as-tool (Option A): kill the worker agent, call Exa directly

## Goal

Replace `RhoFrameworks.UseCases.ResearchDomain.run/2`'s worker-agent spawn
with a `Task`-backed function that calls Exa once, maps each result to a
`research_notes` row, and emits the same `:task_completed` event
`FlowLive` already listens for. Zero LLM calls in the research path.

Surface the same primitive in **two places**:

1. **Wizard path** — `ResearchDomain.run/2` returns `{:async, …}` and
   plays nicely with FlowLive's pin/continue panel UX (unchanged).
2. **Chat path** — a new `RhoFrameworks.Tools.WorkflowTools.research_domain`
   tool calls the same primitive synchronously and returns a one-line
   ack to the calling agent; rows land in the shared `research_notes`
   table.

Single Exa client, single result-to-row mapper, two thin adapters.

## Why

The current worker is the LLM-reads-untrusted-content surface in this flow:
it has `web_search` + `web_fetch` + `save_finding` + `finish`, and a system
prompt instructing it to fetch pages and synthesise atomic findings. A
sufficiently persuasive fetched page could redirect what the worker saves
or fetches. The architectural fix (Pillar 2 of the agent-engineering audit)
is to separate "read attacker-controlled content" from "take privileged
action". Tool-ifying the research step *is* that split for this path —
untrusted content (Exa's per-result summary) flows downstream as bounded
text into a tool result, never into an agent with tools.

Exposing the same primitive to chat does **not** by itself fix chat's
security posture: the default/spreadsheet agents still hold `web_fetch`,
which is the unbounded surface. Adding `research_domain` to chat is a
prerequisite for eventually removing `web_fetch` there — separate plan,
tracked in §Out-of-scope.

## Current state (precise)

- `RhoFrameworks.UseCases.ResearchDomain.run/2`
  - Ensures `research_notes` named table on the session's DataTable.
  - Calls `spawn_fn().(spawn_args)` — default `RhoFrameworks.AgentJobs.start/1`.
  - Worker tools: `web_search`, `web_fetch`, `save_finding`, `finish`.
  - System prompt drives: search → pick 1–3 URLs → `web_fetch` → emit `save_finding` rows → `finish`.
  - Returns `{:async, %{agent_id: id, table_name: "research_notes"}}`.
  - Broadcasts `:task_requested` event with `role: :researcher`.
- `apps/rho_stdlib/lib/rho/stdlib/tools/web_search.ex` calls Exa with
  `contents: %{highlights: true}` and flattens the JSON response into a
  numbered text blob for the LLM.
- `FlowLive` (apps/rho_web/lib/rho_web/live/flow_live.ex)
  - Stores `:research_agent_id` on assigns (line 999).
  - Subscribes to `:task_completed` events.
  - `handle_worker_completed/2` (line 1226) reads **only** `agent_id` from
    the payload — no inspection of `status`, `result`, or any `notes_saved`
    counter.
  - `AgentJobs.cancel(id)` at flow_live.ex:549 and :910 cancels via
    `Rho.Agent.LiteTracker.lookup/1` + `Process.exit(pid, :shutdown)`.
- `research_notes_schema` columns: `source` (req), `fact` (req), `tag`,
  `pinned`, `_source` (provenance, optional).
- `RhoFrameworks.Tools.WorkflowTools` (chat-side) uses the `Rho.Tool` DSL.
  Its `@use_case_tool_names` map explicitly notes `ResearchDomain` has no
  chat surface today (line 44 docstring).
- Chat-side default + spreadsheet agents include `:web_search` and
  `:web_fetch` plugins. They do their own ad-hoc research today.

## Target state

### Shared core (new modules)

- `RhoFrameworks.ExaClient` — `search/2` returning
  `{:ok, [%{url, title, summary, highlights, published_date, author}]}` or
  `{:error, reason}`. Reads `EXA_API_KEY`. Test seam via Application env.
- `RhoFrameworks.UseCases.ResearchDomain.Mapper` — pure
  `to_research_notes_row/1`. Falls back `summary || highlights[0] || title`
  for `fact`; skips rows where all three are nil.
- `RhoFrameworks.UseCases.ResearchDomain.Insert` — synchronous workhorse:

  ```elixir
  @spec run(input :: map(), session_id :: String.t(), source :: atom()) ::
          {:ok, %{inserted: non_neg_integer(), seen: non_neg_integer()}} | {:error, term()}
  ```

  Steps: build 1–2 templated queries from `input.name`/`input.domain`,
  call `ExaClient.search/2` for each, dedup by URL, cap at 10, map to
  rows, `Process.put(:rho_source, source)`, `DataTable.add_rows/3`. Both
  paths call this.

### Wizard path

- `ResearchDomain.run/2` ensures the table, spawns a `Task` (via
  `Rho.TaskSupervisor`) that calls `Insert.run(input, sid, :flow)`, then
  broadcasts `:task_completed`.
- Returns `{:async, %{agent_id: agent_id, table_name: "research_notes"}}`
  with `agent_id = "research_task_" <> :erlang.unique_integer([:positive]) |> Integer.to_string()`.
- Registers via `Rho.Agent.LiteTracker.register/3` so existing
  `AgentJobs.cancel/1` works unchanged.
- No worker agent, no tape, no agentic loop.

### Chat path

- `WorkflowTools.research_domain` tool — synchronous wrapper that calls
  `Insert.run(input, ctx.session_id, :agent)` directly (no task, no
  events) and returns a string ack to the agent: `"Saved N research
  notes from M Exa results"`.
- Add `ResearchDomain => "research_domain"` to `WorkflowTools.@use_case_tool_names`
  so the wizard's step-chat `<.step_chat />` component can scope a per-step
  agent to just this tool when the user clarifies mid-research.
- Agent can call `get_table(table: "research_notes")` afterwards if it
  wants to read the rows; otherwise rows live in the table for later
  wizard escalation or downstream chat tools.

## Resolved decisions (open Qs from earlier draft)

1. **Exa request shape**: `contents: %{summary: %{query: q}}` only.
   `CreateFramework.build_input(:generate, …)` consumes only `fact`, `source`,
   `tag` per row (apps/rho_frameworks/lib/rho_frameworks/flows/create_framework.ex:588-594),
   so one summary paragraph per row is exactly what downstream wants.
   Summary query = `"#{name} — #{description}"` (or just `name` if no
   description).

2. **`tag` column**: insert as `nil`. Schema already declares it optional
   (data_table_schemas.ex:244). `format_research_row` handles nil cleanly
   (line 591-593). No panel changes.

3. **Cancel registry**: reuse `Rho.Agent.LiteTracker`. After
   `Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn -> ... end)`, call
   `LiteTracker.register(agent_id, task.ref, task.pid)`. Inside the task,
   `LiteTracker.complete(agent_id, result)` on the way out. `AgentJobs.cancel/1`
   keeps working unchanged because it just looks up by id and `Process.exit`s
   the pid. FlowLive's `AgentJobs.cancel(id)` calls at flow_live.ex:549
   and :910 need no changes.

4. **`:task_completed` payload shape**: match `AgentJobs.publish_completion/3`
   field-for-field — `%{session_id, agent_id, status: :ok | :error, result: text}`.
   `FlowLive.handle_worker_completed/2` reads only `agent_id` —
   no `status`, no `result`, no `notes_saved` counter. Zero FlowLive
   changes required.

5. **Provenance**: pass `source` atom into `Insert.run/3` and let it
   `Process.put(:rho_source, source)` before `DataTable.add_rows/3`.
   Wizard uses `:flow`, chat tool uses `:agent`. No new provenance string
   — stay in the existing `:user/:flow/:agent` vocabulary.

6. **`:task_failed` event**: drop. There is no such event in
   `Rho.Events.Event` — failure today is `:task_completed` with
   `status: :error`. Use that shape.

## Implementation outline

### Shared core

1. **Add `RhoFrameworks.ExaClient`** — HTTP + parse. Single `search/2`:

   ```elixir
   @spec search(query :: String.t(), opts :: keyword()) ::
           {:ok, [result]} | {:error, term()}
   ```

   `opts`: `:num_results` (default 5), `:summary_query` (passed as
   `contents.summary.query`). Reads `EXA_API_KEY` env.
   Test seam: `Application.get_env(:rho_frameworks, :exa_client, RhoFrameworks.ExaClient)`.

2. **Add `ResearchDomain.Mapper`** — pure function. Easy to unit test in
   isolation.

3. **Add `ResearchDomain.Insert`** — orchestrates table ensure + Exa
   calls + dedup + map + insert. Returns `{:ok, %{inserted, seen}}` or
   `{:error, reason}`. Used by both wizard task and chat tool.

### Wizard path

4. **Rewrite `ResearchDomain.spawn_worker/2`** as `start_research_task/2`:
   - Build `agent_id = "research_task_<uniq>"`.
   - `task = Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn -> ... end)`.
   - `LiteTracker.register(agent_id, task.ref, task.pid)` immediately.
   - Inside task: `Insert.run(input, session_id, :flow)` →
     `LiteTracker.complete(agent_id, result)` →
     broadcast `:task_completed` with `status: :ok | :error`.

5. **`publish_started/2`** unchanged — same shape, same `role: :researcher`.

6. **`ResearchDomain.run/2`** returns
   `{:async, %{agent_id: agent_id, table_name: @table_name}}` as today.

7. **Delete dead code**: `save_finding_tool_def/0`, `execute_save_finding/2`,
   `research_system_prompt/0`, `build_task_prompt/1`, `research_tools/1`,
   `spawn_fn/0`. The `:research_domain_spawn_fn` app-env seam goes away
   too — replace with `:exa_client` seam (§Test seams).

### Chat path

8. **Add `research_domain` tool to `WorkflowTools`** via the existing
   `tool :name, "desc" do ... end` DSL:

   ```elixir
   tool :research_domain,
        "Research a domain for framework creation. Calls Exa once and " <>
          "saves summaries to the research_notes table. Call get_table(table: \"research_notes\") " <>
          "to read the results, or pin them for downstream generation." do
     param(:name, :string, doc: "Framework name")
     param(:description, :string)
     param(:domain, :string)
     param(:target_roles, :string, doc: "Comma-separated role list")

     handle fn args, ctx ->
       # Insert.run returns {:ok, %{inserted, seen}} | {:error, reason}
       # Build %Rho.ToolResponse{text: "Saved N research notes from M Exa results"}
     end
   end
   ```

9. **Update `WorkflowTools.@use_case_tool_names`** — add
   `ResearchDomain => "research_domain"`. The line-44 docstring carve-out
   (`PickTemplate`, `ResearchDomain`) drops `ResearchDomain`.

10. **`FlowLive` changes**: none expected. Verify after step 4.

## Error handling

| Failure | Wizard behavior | Chat behavior |
|---|---|---|
| `EXA_API_KEY` missing | `run/2` returns `{:error, :no_api_key}`; no `:async` shape. FlowLive surfaces error toast. | Tool returns `{:error, "Exa API key not configured"}`. |
| Exa HTTP error | Emit `:task_completed` with `status: :error`. Zero rows. | Tool returns `{:error, "Exa request failed: <reason>"}`. |
| Exa returns 0 results | Emit `:task_completed` with `status: :ok`, zero rows. Panel shows "no results". | Tool returns `{:ok, "Saved 0 research notes from 0 Exa results"}`. |
| Result missing summary AND highlights AND title | Skip silently in `Mapper`. | Skip silently in `Mapper`. |
| `DataTable.add_rows` fails | Emit `:task_completed` with `status: :error`. Log. | Tool returns `{:error, "DataTable insert failed: <reason>"}`. |

## Test seams

- **Replace** existing `:research_domain_spawn_fn` Application env seam.
- **Add** `Application.get_env(:rho_frameworks, :exa_client, RhoFrameworks.ExaClient)`
  for stubbing Exa in tests. Use a stub module that implements `search/2`.
  Check `apps/rho_stdlib` for `Req.Test` usage to match prevailing style;
  fall back to a behaviour-based stub if Req.Test isn't in use.

## Test plan

Foreground (must pass before merge):

- `mix test --app rho_frameworks test/rho_frameworks/use_cases/research_domain_test.exs`
- `mix test --app rho_frameworks test/rho_frameworks/tools/workflow_tools_test.exs` (NEW chat-path tests)
- `mix test --app rho` (regression — recorder/tape touched recently)
- `mix test --app rho_stdlib` (regression)

New tests:

**Wizard path (`research_domain_test.exs`)**

- Happy path: Exa returns 3 results → 3 rows with `_source: :flow`, no
  tag, `:task_completed` emitted with `status: :ok`.
- Exa failure: `:task_completed` emitted with `status: :error`, zero rows.
- Cancel mid-task (via `AgentJobs.cancel/1`): no rows written, no
  `:task_completed` (or one with `status: :error` if cancel races completion
  — pick a spec and assert it).
- Missing `EXA_API_KEY`: `run/2` returns `{:error, :no_api_key}`, no
  `:async`, no rows.
- Existing happy-path / spawn-error / missing-session tests adjusted to
  new return shape and `:exa_client` seam.

**Chat path (`workflow_tools_test.exs`)**

- Happy path: tool returns `{:ok, "Saved N research notes ..."}` and
  inserts rows with `_source: :agent`.
- Exa failure: tool returns `{:error, ...}` string. No rows.
- Missing API key: tool returns `{:error, ...}` string. No rows.

Manual (in dev):

- **Wizard**: full framework-creation flow with `EXA_API_KEY` set. Confirm
  rows appear in panel with summaries + URLs; pin some, continue, confirm
  framework generation reads pinned summaries.
- **Wizard** with `EXA_API_KEY` unset → friendly error.
- **Wizard** "Stop" mid-flight → no orphan task, no partial rows (or define
  explicitly that partial rows are OK and the user can pin/discard them).
- **Chat**: open a spreadsheet-agent session, ask it to research a
  domain. Confirm tool call returns the ack, rows land in `research_notes`,
  agent can `get_table(table: "research_notes")` to read them. Pin in
  panel UI if open simultaneously.

## What this does NOT change

- `web_search` / `web_fetch` general tools — still available to other
  agents. Their security posture is a separate plan (see Out-of-scope).
- The `<untrusted_data>` wrapper question for `web_fetch` — explicitly
  *not* doing it here.
- `Recorder` / `Rho.ToolExecutor` error-shape work — unrelated.

## Risk

- **UX regression** if Exa summaries are too generic to drive good
  framework generation. Mitigation: smoke-test on 2-3 real intake examples
  after the change. Fallback: Option B (one capability-less BAML/zoi
  extraction per URL) as a follow-up. Plumbing here is reusable.
- **Chat tool overuse**: the agent might call `research_domain` for every
  question instead of using cached knowledge. Mitigation: tool description
  steers toward "use when the user is researching a domain for framework
  creation". Cost is bounded (one Exa call per invocation).
- **Provenance shift** (`:flow` for wizard, was `:agent` before via
  `Process.put`). Audit `_source` consumers — current grep shows only
  test assertions on *other* tables (suggest_skills_test.exs:79,
  generate_framework_skeletons_test.exs:192), nothing on `research_notes`.

## Out-of-scope follow-ups (parked)

- **`web_fetch` consolidation over Exa `/contents`**: reimplement `web_fetch`
  to use Exa's `/contents` endpoint. Gives chat agents the same
  bounded-output property `research_domain` has, dissolving the Pillar 2
  "wrap `web_fetch`" item. Separate plan — sketched in conversation, not
  yet drafted. Trade-offs: Exa coverage gap, per-fetch billing, loss of
  raw HTML for the rare parsing case.
- Removing `web_fetch` from default/spreadsheet `.rho.exs` once
  `research_domain` is proven in chat — security upgrade that requires
  usage audit first.
- Provenance + capability-degradation policy for `web_fetch` exposure
  (Pillar 2 #1, separate plan).
- Typed sub-agent RPC contracts (Pillar 4, separate plan).
- Destructive-tool gate (`destructive: true` flag + `:tool_args_out`
  default deny policy).
