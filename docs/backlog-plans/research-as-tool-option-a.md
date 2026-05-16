# Research-as-tool Option A: call Exa directly

## Goal

Replace `RhoFrameworks.UseCases.ResearchDomain`'s worker-agent research loop
with a direct Exa-backed use case.

The current flow is slow because research is not just an Exa request. It is an
agent loop:

```text
LLM turn -> web_search -> LLM turn -> web_fetch -> LLM turn -> save_finding -> repeat
```

The target fast path is:

```text
ResearchDomain -> Exa search -> map results -> research_notes rows
```

No LLM calls should happen inside the research step. Downstream generation can
still use the saved research notes as context.

## Current state

- `RhoFrameworks.UseCases.ResearchDomain.run/2`
  - Ensures the `"research_notes"` named table.
  - Spawns an `AgentJobs` worker through the `:research_domain_spawn_fn` seam.
  - Gives that worker `web_search`, `web_fetch`, `save_finding`, and `finish`.
  - Uses the `:default` agent model, so logs show repeated
    `openrouter:anthropic/claude-sonnet-4.6` LLM streams.
  - Returns `{:async, %{agent_id: id, table_name: "research_notes"}}`.
  - Broadcasts `:task_requested`.
- `Rho.Stdlib.Tools.WebSearch` already calls Exa:
  `https://api.exa.ai/search`.
- `CreateFramework` reads only **pinned** research rows when building
  generation input.
- Standalone `FlowLive` has a research panel where users can pin rows.
- Chat-native flow now runs through `RhoWeb.AppLive.FlowSession`, not just
  `FlowLive`.

## Updated target state

### Shared core

Add three small modules:

- `RhoFrameworks.ExaClient`
  - `search(query, opts)` returns parsed Exa results:
    `%{url, title, summary, highlights, published_date, author}`.
  - Reads `EXA_API_KEY`.
  - Uses an Application env seam for tests:
    `Application.get_env(:rho_frameworks, :exa_client, RhoFrameworks.ExaClient)`.
- `RhoFrameworks.UseCases.ResearchDomain.Mapper`
  - Pure result-to-row mapper.
  - Uses `summary || first_highlight || title` as `fact`.
  - Skips results without URL or usable fact text.
  - Sets `tag: nil`.
  - Sets `pinned: true` for the fast path.
- `RhoFrameworks.UseCases.ResearchDomain.Insert`
  - Synchronous workhorse:

    ```elixir
    @spec run(input :: map(), session_id :: String.t(), source :: atom()) ::
            {:ok, %{table_name: String.t(), inserted: non_neg_integer(), seen: non_neg_integer()}}
            | {:error, term()}
    ```

  - Ensures `"research_notes"`.
  - Builds one or two focused queries from `name`, `description`, `domain`,
    and `target_roles`.
  - Calls Exa for each query.
  - Deduplicates by URL.
  - Caps rows, initially 8-10.
  - Inserts into `research_notes` with `Process.put(:rho_source, source)`.

### ResearchDomain use case

Change `ResearchDomain.run/2` from worker-spawn async to direct synchronous
work:

```elixir
def run(input, %Scope{session_id: session_id}) do
  Insert.run(input, session_id, :flow)
end
```

The return should be:

```elixir
{:ok, %{table_name: "research_notes", inserted: n, seen: m}}
```

or

```elixir
{:error, reason}
```

Delete the worker-agent pieces:

- `spawn_worker/2`
- `spawn_fn/0`
- `research_system_prompt/0`
- `build_task_prompt/1`
- `research_tools/1`
- `save_finding_tool_def/0`
- `execute_save_finding/2`
- the `:research_domain_spawn_fn` test seam

Update `describe/0`:

- `cost_hint` should no longer be `:agent`; use `:network` or `:tool`.
- `doc` should say this calls Exa and writes research notes.

## AppLive/chat-native integration

This is the current primary path for the chat-hosted create-framework flow.

Update `RhoWeb.AppLive.FlowSession.long_running_use_case?/1` so
`ResearchDomain` is treated as a long-running use case alongside taxonomy and
skill generation.

That lets AppLive own the async boundary:

```text
AppLive.FlowSession task -> ResearchDomain.run/2 -> Insert.run/3 -> Exa
```

When the task completes, AppLive already receives:

```elixir
{:flow_long_step_completed, :research, summary}
```

Then `FlowSession.complete_long_step/3` can store the summary and append the
next card.

### Pinned-row decision

Because chat-native flow does not currently have a research pin/unpin panel,
the fast Exa rows must be inserted with `pinned: true`.

This is deliberate. `CreateFramework.build_input/3` only reads pinned research
rows. If Exa rows are saved as unpinned in chat-native flow, generation will
ignore them and research will appear to do nothing.

Standalone `FlowLive` can still expose a richer review/pin panel later, but
the fast path should prioritize:

- no LLM calls during research
- rows visible in `research_notes`
- rows consumed by generation without extra user work

## Standalone FlowLive integration

The old plan assumed `ResearchDomain.run/2` would keep returning
`{:async, ...}` and emit `:task_completed`. That is no longer the preferred
shape.

For standalone `FlowLive`, update the research action path to match the same
caller-owned async pattern, or allow synchronous `{:ok, summary}` from
`ResearchDomain.run/2` and move the async wrapper into `FlowLive`.

Do not keep a hidden async use case just to preserve the old
`:task_completed` contract. The use case should be direct and testable; UI
layers should decide whether to run it in a task.

## Exa request shape

Use Exa search with summaries, not full page fetches:

```elixir
%{
  query: query,
  numResults: num_results,
  type: "auto",
  contents: %{
    summary: %{query: summary_query}
  }
}
```

`summary_query` should be derived from the framework prompt, for example:

```text
<name> - <description>
```

Fallback to `name`, `domain`, or `target_roles` if description is missing.

The mapper should also tolerate Exa returning highlights but no summary, so
tests can cover both current `web_search`-style responses and summary-style
responses.

## Chat tool follow-up

Expose a chat tool after the flow step is fast and stable.

Add `WorkflowTools.research_domain` as a phase-2 wrapper around
`ResearchDomain.Insert.run/3`:

```elixir
tool :research_domain,
     "Research a domain for framework creation. Calls Exa and saves bounded summaries to research_notes." do
  param(:name, :string, required: true, doc: "Framework name")
  param(:description, :string)
  param(:domain, :string)
  param(:target_roles, :string, doc: "Comma-separated role list")

  run(fn args, ctx ->
    case Insert.run(args, ctx.session_id, :agent) do
      {:ok, %{inserted: n, seen: m}} ->
        {:ok, "Saved #{n} research notes from #{m} Exa results."}

      {:error, reason} ->
        {:error, "research_domain failed: #{inspect(reason)}"}
    end
  end)
end
```

Then add:

```elixir
ResearchDomain => "research_domain"
```

to `WorkflowTools.@use_case_tool_names` only if step-chat should be able to
invoke the research tool for this step.

This is useful, but not required for fixing the slow research step.

## Error handling

| Failure | Use case result | UI behavior |
|---|---|---|
| `EXA_API_KEY` missing | `{:error, :no_api_key}` or `{:error, "EXA_API_KEY environment variable is not set"}` | Show flow error; do not advance. |
| Exa HTTP error | `{:error, {:exa_failed, reason}}` | Show flow error; zero rows. |
| Exa returns 0 results | `{:ok, %{inserted: 0, seen: 0, table_name: "research_notes"}}` | Advance with no research context, or show an empty-state card. |
| Result missing URL or fact | skip row | Continue with remaining rows. |
| `DataTable.add_rows` fails | `{:error, {:insert_failed, reason}}` | Show flow error; do not advance. |

## Implementation order

1. Add `RhoFrameworks.ExaClient`.
2. Add `ResearchDomain.Mapper`.
3. Add `ResearchDomain.Insert`.
4. Rewrite `ResearchDomain.run/2` to call `Insert.run/3`.
5. Delete the worker-agent research code.
6. Add `ResearchDomain` to `AppLive.FlowSession.long_running_use_case?/1`.
7. Adjust standalone `FlowLive` if needed so it accepts `{:ok, summary}` for
   research.
8. Update tests that use `:research_domain_spawn_fn` to use the Exa client
   seam.
9. Add chat tool support only after the flow-step path is passing.

## Test plan

### Unit tests

- `ExaClient` parses Exa search responses with summaries.
- `ExaClient` returns a clear error when `EXA_API_KEY` is missing.
- `Mapper` maps summary, highlight fallback, title fallback.
- `Mapper` skips unusable results.
- `Insert.run/3` deduplicates by URL and caps rows.
- `Insert.run/3` inserts rows with:
  - `source`
  - `fact`
  - `tag: nil`
  - `pinned: true`
  - `_source: :flow` or `_source: :agent`

### Use case tests

Update `apps/rho_frameworks/test/rho_frameworks/use_cases/research_domain_test.exs`:

- Happy path: Exa returns 3 results, use case returns `{:ok, summary}`, table
  has 3 pinned rows.
- Missing session: returns `{:error, :missing_session_id}`.
- Exa failure: returns `{:error, ...}`, zero rows.
- Zero results: returns `{:ok, %{inserted: 0, seen: 0}}`.
- Existing schema and pin/update round-trip tests still pass.

### AppLive/chat-native tests

Add or update AppLive/FlowSession coverage:

- Research action is treated as long-running.
- `{:flow_long_step_completed, :research, summary}` stores the research
  summary on the runner.
- Rows inserted by research are pinned.
- The next generation input sees `research` populated from those pinned rows.
- The research step does not spawn `AgentJobs` and does not use
  `:research_domain_spawn_fn`.

### Standalone FlowLive tests

Update tests currently stubbing `:research_domain_spawn_fn`:

- Use the Exa client seam instead.
- Verify research can complete and leave the user at review/continue state if
  the standalone research panel is still shown.
- Verify stop/cancel behavior is either removed for this direct path or moved
  to the UI-owned task wrapper.

### Workflow tool tests, phase 2

When adding `WorkflowTools.research_domain`:

- Happy path returns `"Saved N research notes from M Exa results."`
- Exa failure returns an error tuple.
- Rows are inserted with `_source: :agent`.
- Tool appears through `WorkflowTools.tool_for_use_case(ResearchDomain)` only
  after explicitly adding it to `@use_case_tool_names`.

## Manual verification

- Start a chat-native create-framework flow with `EXA_API_KEY` set.
- Choose the researched/scratch path.
- Confirm no `[direct] starting LLM stream ...` logs appear during the
  research step.
- Confirm Exa HTTP logs appear once or twice.
- Confirm `research_notes` rows appear quickly and are pinned.
- Continue generation and confirm the generated taxonomy/skills reflect the
  research notes.
- Run once with `EXA_API_KEY` unset and confirm the error is understandable.

## What this does not change

- General `web_search` and `web_fetch` tools remain available to other
  agents.
- This does not remove `web_fetch` from `.rho.exs`.
- This does not add a full research-review UI to chat-native flow.
- This does not change recorder, tape, or tool-executor error shapes.

## Risks

- **Exa summaries may be too generic.** Mitigation: smoke-test 2-3 real
  framework prompts. If quality drops, add a bounded extraction follow-up:
  one capability-less summarization call over Exa summaries, not a tool-using
  agent.
- **Auto-pinning can pass weak research into generation.** Mitigation: cap
  rows, dedupe by URL, prefer summaries with source URLs, and add review UI
  later.
- **Standalone FlowLive may still assume async research events.** Mitigation:
  update it to own the task boundary rather than keeping hidden async in the
  use case.

## Out-of-scope follow-ups

- Add a chat-native research review card with pin/unpin controls.
- Reimplement `web_fetch` through Exa `/contents`.
- Remove `web_fetch` from default/spreadsheet agents after `research_domain`
  is proven in chat.
- Add a bounded, non-tool extraction step if Exa summaries are not enough.
