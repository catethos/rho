# Chairman Agent + Timeline Polish — Design Spec

## Goal

Add a chairman agent as the narrative voice of the hiring simulation, fix timeline rendering so messages are readable (markdown), and make agent-to-agent references visually clear (colored pills for both sender and target).

---

## Changes

### 1. Chairman Agent

**Role:** Meeting facilitator. Does NOT orchestrate — the `Simulation` coordinator still manages rounds, counts scores, and advances state. The chairman provides the narrative voice.

**Color:** Teal `#5BB5A2` (system accent, distinct from evaluator colors)

**Config in `.rho.exs`:**
```elixir
chairman: [
  model: "openrouter:anthropic/claude-haiku-4.5",
  description: "Meeting facilitator who manages the hiring committee process",
  skills: ["facilitation", "summarization"],
  system_prompt: """
  You are the Chairman of a hiring committee for Senior Backend Engineer.
  You do NOT evaluate candidates. You facilitate the process.

  When asked to nudge evaluators, send them a firm but professional message
  asking them to submit their scores immediately using submit_scores.

  When asked to produce a closing summary, synthesize the committee's scores
  and debate into a clear recommendation. Include:
  - Who gets offers (top 3 by average score) with recommended salary
  - Key debate points that influenced the outcome
  - Notable rejections and why

  Be concise and decisive. This is a committee report, not an essay.
  """,
  mounts: [:multi_agent],
  reasoner: :direct,
  max_steps: 10
]
```

**Three moments the chairman speaks:**

1. **Opening (hardcoded, not LLM):** Coordinator publishes a chairman timeline entry with a template string when simulation begins. No LLM call — instant and free.

```
"I've convened this committee to evaluate 5 candidates for Senior Backend Engineer.
Budget: $160K–$190K. Maximum 3 offers. Let's begin with Round 1 —
evaluators, please score all candidates."
```

2. **Nudge (LLM call, conditional):** If a round exceeds 90 seconds with missing scores, coordinator sends the chairman a prompt listing who hasn't submitted. Chairman uses `send_message` to nudge them. Scheduled via `Process.send_after(self(), :check_round_timeout, 90_000)`. Re-checks every 60 seconds if still missing.

Coordinator prompt to chairman:
```
"The following evaluators have not submitted scores for round {N}: {list}.
Please send each of them a message asking them to submit their scores now."
```

3. **Closing summary (LLM call, always):** After all round 2 scores are in, coordinator stops all evaluator agents first (preventing further debate), then sends chairman the full score data. Chairman produces a summary. Rendered as a special highlighted block in the timeline.

Coordinator prompt to chairman:
```
"The committee has completed 2 rounds. Here are the final scores:
{formatted score table with all candidates × all evaluators}

Shortlist (top 3 by average): {shortlist}

Key disagreements from the debate:
{disagreement summary}

Please produce the committee's final recommendation report."
```

### 2. Simulation Coordinator Changes

**File:** `lib/rho/demos/hiring/simulation.ex`

**New state fields:**
```elixir
defstruct [
  # ... existing fields ...
  chairman_agent_id: nil,
  chairman_tools: nil,
  round_started_at: nil,
  round_timer_ref: nil
]
```

**Flow changes:**

**Spawn chairman helper** (`spawn_chairman/1`):

Follows the same pattern as `spawn_evaluators/1`:

```elixir
defp spawn_chairman(state) do
  agent_id = Rho.Session.new_agent_id()
  config = Rho.Config.agent(:chairman)

  tool_context = %{
    tape_name: "agent_#{agent_id}",
    workspace: File.cwd!(),
    agent_name: :chairman,
    agent_id: agent_id,
    session_id: state.session_id,
    depth: 1,
    sandbox: nil
  }

  # Chairman only gets communication tools + finish
  allowed_tools = ~w(send_message list_agents)
  mount_tools =
    Rho.MountRegistry.collect_tools(tool_context)
    |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

  finish_tool = Rho.Tools.Finish.tool_def()
  all_tools = mount_tools ++ [finish_tool]

  memory_mod = Rho.Config.memory_module()
  tape = "agent_#{agent_id}"
  memory_mod.bootstrap(tape)

  {:ok, _pid} =
    Supervisor.start_worker(
      agent_id: agent_id,
      session_id: state.session_id,
      workspace: File.cwd!(),
      agent_name: :chairman,
      role: :chairman,
      depth: 1,
      memory_ref: tape,
      max_steps: config.max_steps,
      system_prompt: config.system_prompt,
      tools: all_tools,
      model: config.model
    )

  Logger.info("[Hiring] Spawned chairman as #{agent_id}")
  %{state | chairman_agent_id: agent_id, chairman_tools: all_tools}
end
```

**Important:** Chairman MUST be spawned at `depth: 1` (not 0) so that `maybe_publish_task_completed` fires when it finishes.

**On `:begin`:**
1. Spawn chairman agent via `spawn_chairman/1`
2. Publish hardcoded opening message as a chairman timeline event: `rho.hiring.chairman.message` with `%{text: "I've convened...", agent_role: :chairman, agent_id: state.chairman_agent_id}`
3. Spawn evaluators (existing logic)
4. Start round 1 (existing logic)

**On `start_round/2` (both rounds):**
- Cancel previous round timer if exists: `if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)`
- Record `round_started_at: System.monotonic_time(:millisecond)`
- Schedule timer with round number: `ref = Process.send_after(self(), {:check_round_timeout, round_num}, 90_000)`
- Store ref: `%{state | round_started_at: ..., round_timer_ref: ref}`

**New handler `{:check_round_timeout, round_num}`:**

The round number is embedded in the message so stale timers from previous rounds are safely ignored.

```elixir
def handle_info({:check_round_timeout, round_num}, %{status: :running, round: current_round} = state)
    when round_num == current_round do
  # Find evaluators who haven't submitted for current round
  submitted_roles = state.scores
    |> Map.keys()
    |> Enum.filter(fn {_role, r} -> r == state.round end)
    |> Enum.map(fn {role, _r} -> role end)

  missing = Map.keys(state.evaluators) -- submitted_roles

  if missing != [] do
    chairman_pid = Worker.whereis(state.chairman_agent_id)
    config = Rho.Config.agent(:chairman)

    if chairman_pid do
      missing_names = Enum.map_join(missing, ", ", &Atom.to_string/1)
      Worker.submit(chairman_pid,
        "The following evaluators have not submitted scores for round #{state.round}: #{missing_names}. Please send each of them a message asking them to submit their scores now using submit_scores.",
        tools: state.chairman_tools,
        model: config.model
      )
    end

    # Re-check in 60 seconds (same round number — will be ignored if round advances)
    ref = Process.send_after(self(), {:check_round_timeout, round_num}, 60_000)
    {:noreply, %{state | round_timer_ref: ref}}
  else
    {:noreply, state}
  end
end

# Ignore stale timers from previous rounds or non-running states
def handle_info({:check_round_timeout, _}, state), do: {:noreply, state}
```

**On simulation complete (all round 2 scores in):**
1. Cancel round timer: `if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)`
2. Stop all evaluator agents (async, don't block coordinator):
```elixir
for {_role, agent_id} <- state.evaluators do
  pid = Worker.whereis(agent_id)
  if pid, do: GenServer.stop(pid, :normal, 1_000)
catch
  :exit, _ -> :ok
end
```
3. Build closing prompt with full score data + shortlist + disagreement summary
4. Send to chairman via `Worker.submit/3`
5. Publish `rho.hiring.simulation.completed` with shortlist (UI shows "COMPLETED")
6. Set `status: :completed`

No intermediate `:completing` state — go straight to `:completed`. The chairman's closing summary appears in the timeline via the existing `rho.session.*.events.text_delta` stream (its LLM output). The coordinator does not need to know when the chairman finishes — the chairman simply processes its turn and stops naturally when it hits `end_turn` or `max_steps`.

**Closing summary as special block:** After the chairman produces its text response, the coordinator also publishes `rho.hiring.chairman.summary` with the structured shortlist data, which the projection renders as the highlighted summary block. This is published immediately (deterministic), independent of the chairman's LLM call. The chairman's narrative enriches it, but the structured data is always available.

### 3. Timeline Event for Chairman

**File:** `lib/rho_web/live/observatory_projection.ex`

**New projection handler for chairman messages:**

The coordinator publishes `rho.hiring.chairman.message` for the hardcoded opening. The chairman's `send_message` and LLM responses flow through existing `rho.session.*.message_sent` events and are already captured as `:debate` timeline entries.

For the opening:
```elixir
def project(socket, "rho.hiring.chairman.message", data) do
  timeline = socket.assigns[:timeline] || []

  entry = %{
    type: :chairman,
    agent_role: :chairman,
    agent_id: data[:agent_id],
    target: nil,
    text: data[:text] || "",
    candidate_id: nil,
    candidate_name: nil,
    score: nil,
    delta: nil,
    round: socket.assigns[:round] || 0,
    timestamp: System.monotonic_time(:millisecond)
  }

  assign(socket, :timeline, timeline ++ [entry])
end
```

For the closing summary, use a distinct type:
```elixir
def project(socket, "rho.hiring.chairman.summary", data) do
  # Same as above but type: :chairman_summary
  # This renders as a special highlighted block
end
```

### 4. Colored Target Pills in Timeline

**File:** `lib/rho_web/components/observatory_components.ex`

The debate entry currently renders the target as:
```html
→ <span class="obs-role-{role}">Culture Evaluator</span>
```

Change to a proper pill tag (same as sender):
```html
<span class="obs-timeline-tag obs-timeline-tag-{role}">{name}</span>
```

So a debate entry becomes:
```
[Technical] → [Culture] "message text..."
```

Both are the same `obs-timeline-tag` pill shape with their respective role colors.

Add chairman tag color:
```css
.obs-timeline-tag-chairman { background: #5BB5A2; }
```

### 5. Markdown Rendering in Timeline

**File:** `lib/rho_web/components/observatory_components.ex`

Debate text and chairman messages use the existing `Markdown` JS hook (already loaded via CDN `marked.js`):

```html
<!-- Debate text: -->
<div class="obs-timeline-debate-text markdown-body"
     id={"timeline-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
     phx-hook="Markdown"
     data-md={entry.text}></div>

<!-- Chairman messages: same pattern -->
```

**Note:** Use `System.unique_integer` appended to timestamp to guarantee DOM ID uniqueness, since two events could share the same millisecond timestamp.

Score rationale stays as plain truncated text (short, doesn't need markdown).

The `markdown-body` CSS class already exists in `inline_css.ex` for the session chat. It handles headings, bold, lists, code blocks, etc.

### 6. Chairman Closing Summary — Special Block

**File:** `lib/rho_web/components/observatory_components.ex`

New timeline entry type `:chairman_summary` rendered as:

```html
<div class="obs-timeline-summary">
  <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman</span>
  <div class="obs-timeline-summary-body markdown-body"
       id={"timeline-#{entry.timestamp}"}
       phx-hook="Markdown"
       data-md={entry.text}></div>
</div>
```

CSS:
```css
.obs-timeline-summary {
  background: rgba(91, 181, 162, 0.06);
  border-left: 3px solid #5BB5A2;
  border-radius: 8px;
  padding: 12px 14px;
  margin: 12px 0;
  font-size: 13px;
}
.obs-timeline-summary-body { line-height: 1.6; margin-top: 8px; }
```

Visually larger and more prominent than debate messages — this is the final verdict.

### 7. Stop Evaluators on Completion

**File:** `lib/rho/demos/hiring/simulation.ex`

After all round 2 scores are in and before sending the chairman its closing prompt:

```elixir
# Stop all evaluator workers
for {_role, agent_id} <- state.evaluators do
  pid = Worker.whereis(agent_id)
  if pid do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end
end
```

This prevents the infinite ping-pong debate that currently happens after completion.

---

## Observatory LiveView Changes

**File:** `lib/rho_web/live/observatory_live.ex`

Subscribe to chairman events in the session mount:
- Pattern `"rho.hiring.chairman.*"` added to the subscription list

No new assigns needed — chairman messages flow into the existing `timeline` list.

---

## Files Changed

| File | Changes |
|------|---------|
| `.rho.exs` | Add `chairman` agent profile |
| `lib/rho/demos/hiring/simulation.ex` | Spawn chairman, timeout/nudge logic, stop evaluators, send closing prompt |
| `lib/rho_web/live/observatory_projection.ex` | Handle `rho.hiring.chairman.message` and `rho.hiring.chairman.summary` |
| `lib/rho_web/components/observatory_components.ex` | Colored target pills, markdown hook on debate text, `:chairman` and `:chairman_summary` timeline entry types |
| `lib/rho_web/inline_css.ex` | Chairman tag color, summary block CSS |
| `lib/rho_web/live/observatory_live.ex` | Subscribe to `rho.hiring.chairman.*` |

## Not Changed

- `lib/rho/demos/hiring/candidates.ex` — no changes
- `lib/rho/demos/hiring/tools.ex` — no changes (chairman doesn't use `submit_scores`)
- Backend agent worker / signal bus — no changes
