# Chairman Agent + Timeline Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a chairman agent as the narrative voice of the hiring simulation, render timeline messages as markdown, and display agent-to-agent references as colored role pills.

**Architecture:** The deterministic `Simulation` coordinator spawns a chairman agent alongside evaluators. Coordinator triggers the chairman at 3 moments (opening, nudge, closing). Timeline component gains markdown rendering via existing `Markdown` JS hook. Target names become colored pills matching sender style.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.0, inline CSS, marked.js (CDN, already loaded), jido_signal bus.

**Spec:** `docs/superpowers/specs/2026-03-25-chairman-agent-design.md`

---

## Critical Context for Implementers

- **No asset pipeline.** CSS in `lib/rho_web/inline_css.ex`, JS in `lib/rho_web/inline_js.ex`.
- **`marked.js` already loaded** via CDN in `lib/rho_web/components/layouts/root.html.heex:17`. The `Markdown` JS hook is already defined in `inline_js.ex` — it reads `data-md` attr and renders via `window.marked.parse()`.
- **Agent worker spawning pattern:** See `spawn_evaluators/1` in `simulation.ex:83-141`. Chairman follows the same pattern but with different tools (no `submit_scores`).
- **Chairman MUST be depth: 1** so `maybe_publish_task_completed` fires in `worker.ex:694-709`.
- **Evaluator role colors:** Technical `#5B8ABA`, Culture `#B55BA0`, Compensation `#D4A855`, Chairman `#5BB5A2` (teal).

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `.rho.exs` | Modify | Add `chairman` agent profile |
| `lib/rho/demos/hiring/simulation.ex` | Modify | New state fields, spawn_chairman, timeout/nudge, stop evaluators, closing prompt |
| `lib/rho_web/live/observatory_projection.ex` | Modify | Handle `rho.hiring.chairman.message` and `rho.hiring.chairman.summary` |
| `lib/rho_web/components/observatory_components.ex` | Modify | Target pills, markdown on debate text, `:chairman` and `:chairman_summary` entry types |
| `lib/rho_web/inline_css.ex` | Modify | Chairman tag color, summary block CSS |
| `lib/rho_web/live/observatory_live.ex` | Modify | Add `rho.hiring.chairman.*` subscription |

---

### Task 1: Add Chairman Config

**Files:**
- Modify: `.rho.exs:113` (before closing `}`)

- [ ] **Step 1: Add chairman profile**

Add before the closing `}` at line 114 of `.rho.exs` (after `compensation_evaluator`):

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
    Use the `finish` tool with your final summary when done.
    """,
    mounts: [:multi_agent],
    reasoner: :direct,
    max_steps: 10
  ]
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile`
Expected: compiles clean. `Rho.Config.agent(:chairman)` now returns the chairman config.

- [ ] **Step 3: Commit**

```bash
git add .rho.exs
git commit -m "feat(hiring): add chairman agent profile to .rho.exs"
```

---

### Task 2: Update Simulation Coordinator

**Files:**
- Modify: `lib/rho/demos/hiring/simulation.ex`

This is the largest and most critical task. The coordinator gains: new state fields, `spawn_chairman/1`, modified `:begin` flow, round timeout with nudge, and completion with evaluator shutdown + closing prompt.

- [ ] **Step 1: Add new state fields to defstruct**

Replace the defstruct at lines 16-24:

```elixir
  defstruct [
    :session_id,
    round: 0,
    evaluators: %{},
    evaluator_tools: %{},
    scores: %{},
    status: :not_started,
    max_rounds: 2,
    chairman_agent_id: nil,
    chairman_tools: nil,
    round_started_at: nil,
    round_timer_ref: nil
  ]
```

- [ ] **Step 2: Add `spawn_chairman/1` helper**

Add after `spawn_evaluators/1` (after line 141):

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

- [ ] **Step 3: Update `:begin` handler to spawn chairman + publish opening**

Replace lines 54-63:

```elixir
  @impl true
  def handle_call(:begin, _from, %{status: :not_started} = state) do
    Comms.publish("rho.hiring.simulation.started", %{
      session_id: state.session_id
    }, source: "/session/#{state.session_id}")

    state = spawn_chairman(state)

    # Publish hardcoded opening message (no LLM call)
    Comms.publish("rho.hiring.chairman.message", %{
      session_id: state.session_id,
      agent_id: state.chairman_agent_id,
      agent_role: :chairman,
      text: "I've convened this committee to evaluate 5 candidates for Senior Backend Engineer. Budget: $160K–$190K. Maximum 3 offers. Let's begin with Round 1 — evaluators, please score all candidates."
    }, source: "/session/#{state.session_id}")

    state = spawn_evaluators(state)
    state = start_round(state, 1)
    {:reply, :ok, %{state | status: :running}}
  end
```

- [ ] **Step 4: Update `start_round/2` to manage round timer**

Replace lines 143-171:

```elixir
  defp start_round(state, round_num) do
    prompt = round_prompt(round_num, state)

    # Cancel previous round timer if exists
    if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

    Comms.publish("rho.hiring.round.started", %{
      session_id: state.session_id,
      round: round_num
    }, source: "/session/#{state.session_id}")

    Logger.info("[Hiring] Starting round #{round_num}")

    # Submit prompt to each evaluator with their custom tools
    # Stagger starts by 1s to avoid Finch connection pool exhaustion
    state.evaluators
    |> Enum.with_index()
    |> Enum.each(fn {{role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)
      if pid do
        role_info = Map.get(state.evaluator_tools, role, %{})
        Worker.submit(pid, prompt,
          tools: role_info[:tools],
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end)

    # Schedule round timeout check (with round number to prevent stale timer issues)
    ref = Process.send_after(self(), {:check_round_timeout, round_num}, 90_000)

    %{state | round: round_num, round_started_at: System.monotonic_time(:millisecond), round_timer_ref: ref}
  end
```

- [ ] **Step 5: Add timeout handler**

Add **BOTH clauses** below before the catch-all `def handle_info(_msg, state)` at line 79. They MUST come before the generic catch-all or they will be shadowed. Insert them between the scores.submitted handler (line 77) and the catch-all (line 79):

```elixir
  @impl true
  def handle_info({:check_round_timeout, round_num}, %{status: :running, round: current_round} = state)
      when round_num == current_round do
    submitted_roles =
      state.scores
      |> Map.keys()
      |> Enum.filter(fn {_role, r} -> r == state.round end)
      |> Enum.map(fn {role, _r} -> role end)

    missing = Map.keys(state.evaluators) -- submitted_roles

    if missing != [] do
      Logger.warning("[Hiring] Round #{state.round} timeout — nudging #{length(missing)} evaluators: #{inspect(missing)}")

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

      ref = Process.send_after(self(), {:check_round_timeout, round_num}, 60_000)
      {:noreply, %{state | round_timer_ref: ref}}
    else
      {:noreply, state}
    end
  end

  # Stale timer from previous round or non-running state — ignore
  def handle_info({:check_round_timeout, _}, state), do: {:noreply, state}
```

**IMPORTANT:** Both clauses above must be placed before `def handle_info(_msg, state), do: {:noreply, state}`. The `@impl true` annotation from the first clause covers both since they are the same function head.

- [ ] **Step 6: Add closing prompt builder and shortlist formatter FIRST (needed by Step 7)**

Add before `via/1` at the end of the module. These MUST exist before updating `maybe_advance_round` which calls them:

```elixir
  defp maybe_advance_round(state) do
    expected = map_size(state.evaluators)

    submitted =
      state.scores
      |> Map.keys()
      |> Enum.count(fn {_role, r} -> r == state.round end)

    if submitted >= expected do
      if state.round >= state.max_rounds do
        # Cancel round timer
        if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

        final = compute_final_shortlist(state)

        # Stop all evaluator agents to prevent further debate
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

        Logger.info("[Hiring] Evaluators stopped. Sending closing prompt to chairman.")

        # Build and send closing prompt to chairman
        closing_prompt = build_closing_prompt(state, final)
        chairman_pid = Worker.whereis(state.chairman_agent_id)
        config = Rho.Config.agent(:chairman)

        if chairman_pid do
          Worker.submit(chairman_pid, closing_prompt,
            tools: state.chairman_tools,
            model: config.model
          )
        else
          Logger.warning("[Hiring] Chairman agent not available for closing summary")
        end

        # Publish structured summary (deterministic, immediate)
        Comms.publish("rho.hiring.chairman.summary", %{
          session_id: state.session_id,
          agent_id: state.chairman_agent_id,
          agent_role: :chairman,
          shortlist: final,
          text: format_shortlist_text(final)
        }, source: "/session/#{state.session_id}")

        Comms.publish("rho.hiring.simulation.completed", %{
          session_id: state.session_id,
          shortlist: final
        }, source: "/session/#{state.session_id}")

        Logger.info("[Hiring] Simulation complete. Shortlist: #{inspect(final)}")
        %{state | status: :completed, round_timer_ref: nil}
      else
        start_round(state, state.round + 1)
      end
    else
      Logger.info("[Hiring] Waiting for scores: #{submitted}/#{expected} for round #{state.round}")
      state
    end
  end
```

- [ ] **Step 7: Update `maybe_advance_round/1` — stop evaluators + send closing prompt on completion**

Replace lines 205-231:

```elixir
  defp build_closing_prompt(state, shortlist) do
    # Format all scores as a readable table
    score_table =
      state.scores
      |> Enum.filter(fn {{_role, round}, _} -> round == state.max_rounds end)
      |> Enum.flat_map(fn {{role, _round}, scores} ->
        Enum.map(scores, fn entry ->
          candidate = Enum.find(Candidates.all(), &(&1.id == entry["id"]))
          name = if candidate, do: candidate.name, else: entry["id"]
          "#{name}: #{role} scored #{entry["score"]} — #{entry["rationale"] || ""}"
        end)
      end)
      |> Enum.join("\n")

    shortlist_text =
      shortlist
      |> Enum.map_join("\n", fn s ->
        candidate = Enum.find(Candidates.all(), &(&1.id == s.id))
        salary = if candidate, do: "$#{candidate.salary_expectation}", else: "N/A"
        "- #{s.name} (avg: #{s.avg_score}, salary: #{salary})"
      end)

    disagreement = build_disagreement_summary(state)

    """
    The committee has completed #{state.max_rounds} rounds of evaluation. Here are the final scores:

    #{score_table}

    Shortlist (top 3 by average):
    #{shortlist_text}

    Key disagreements from the debate:
    #{disagreement}

    Please produce the committee's final recommendation report. Use the `finish` tool with your summary when done.
    """
  end

  defp format_shortlist_text(shortlist) do
    shortlist
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {s, i} ->
      candidate = Enum.find(Candidates.all(), &(&1.id == s.id))
      salary = if candidate, do: "$#{candidate.salary_expectation}", else: "N/A"
      "#{i}. **#{s.name}** — avg score #{s.avg_score}, recommended at #{salary}"
    end)
  end
```

- [ ] **Step 8: Verify compilation**

Run: `mix compile`
Expected: compiles clean.

- [ ] **Step 9: Commit**

```bash
git add lib/rho/demos/hiring/simulation.ex
git commit -m "feat(hiring): chairman agent spawning, round timeout/nudge, evaluator shutdown, closing prompt"
```

---

### Task 3: Update Projection — Chairman Events

**Files:**
- Modify: `lib/rho_web/live/observatory_projection.ex`

- [ ] **Step 1: Add chairman message projection handler**

Add after the `"rho.hiring.simulation.completed"` handler (after line 121):

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

  def project(socket, "rho.hiring.chairman.summary", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :chairman_summary,
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

- [ ] **Step 2: Verify compilation**

Run: `mix compile`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/live/observatory_projection.ex
git commit -m "feat(observatory): projection handlers for chairman message and summary events"
```

---

### Task 4: Update Components — Target Pills, Markdown, Chairman Types

**Files:**
- Modify: `lib/rho_web/components/observatory_components.ex`

- [ ] **Step 1: Change debate target from colored text to pill tag**

In `unified_timeline/1`, replace the debate target rendering at line 185-186:

Old:
```elixir
                <div class="obs-timeline-debate-to">
                  → <span class={"obs-role-#{role_css_key(entry.target)}"}><%= if entry.target == :all, do: "ALL", else: format_agent_name(entry.target) %></span>
                </div>
```

New:
```elixir
                <div class="obs-timeline-debate-to">
                  → <span class={"obs-timeline-tag obs-timeline-tag-#{role_css_key(entry.target)}"}><%= if entry.target == :all, do: "ALL", else: format_role_short(entry.target) %></span>
                </div>
```

- [ ] **Step 2: Add markdown rendering to debate text**

Replace line 188:

Old:
```elixir
                <div class="obs-timeline-debate-text"><%= entry.text %></div>
```

New:
```elixir
                <div class="obs-timeline-debate-text markdown-body"
                     id={"timeline-debate-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                     phx-hook="Markdown"
                     data-md={entry.text}></div>
```

- [ ] **Step 3: Add `:chairman` and `:chairman_summary` entry types to the case statement**

In the `unified_timeline/1` template, add before the `<% _ -> %>` catch-all (before line 192):

```elixir
          <% :chairman -> %>
            <div class="obs-timeline-row">
              <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman</span>
              <div class="markdown-body"
                   id={"timeline-chairman-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :chairman_summary -> %>
            <div class="obs-timeline-summary">
              <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman — Final Recommendation</span>
              <div class="obs-timeline-summary-body markdown-body"
                   id={"timeline-summary-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>
```

- [ ] **Step 4: Verify compilation**

Run: `mix compile`
Expected: compiles clean.

- [ ] **Step 5: Commit**

```bash
git add lib/rho_web/components/observatory_components.ex
git commit -m "feat(observatory): colored target pills, markdown in timeline, chairman entry types"
```

---

### Task 5: CSS + LiveView Subscription

**Files:**
- Modify: `lib/rho_web/inline_css.ex`
- Modify: `lib/rho_web/live/observatory_live.ex`

- [ ] **Step 1: Add chairman tag color and summary block CSS**

In `inline_css.ex`, add after the existing `.obs-timeline-tag-compensation_evaluator` line (after the debate CSS section):

```css
    .obs-timeline-tag-chairman { background: #5BB5A2; }

    /* Chairman summary block */
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

- [ ] **Step 2: Add chairman subscription in LiveView**

In `lib/rho_web/live/observatory_live.ex`, add `"rho.hiring.chairman.*"` to the subscription list at line 50-57. Add it after `"rho.hiring.simulation.*"`:

```elixir
      subs =
        [
          "rho.agent.*",
          "rho.session.#{sid}.events.*",
          "rho.task.*",
          "rho.hiring.scores.*",
          "rho.hiring.round.*",
          "rho.hiring.simulation.*",
          "rho.hiring.chairman.*"
        ]
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile`
Expected: compiles clean.

- [ ] **Step 4: Commit**

```bash
git add lib/rho_web/inline_css.ex lib/rho_web/live/observatory_live.ex
git commit -m "feat(observatory): chairman CSS, summary block styling, chairman event subscription"
```

---

## Verification Checklist

After all tasks are complete:

- [ ] `mix compile` passes with no errors
- [ ] Clear old tapes: `rm -f ~/.rho/tapes/agent_agent_*.jsonl`
- [ ] Start server: `RHO_WEB_ENABLED=true elixir --no-halt -S mix run`
- [ ] Open http://localhost:4001/observatory
- [ ] Landing page loads with evaluator + candidate cards
- [ ] Click Start → Begin
- [ ] Timeline shows chairman opening message with teal pill: "I've convened this committee..."
- [ ] Timeline shows Round 1 divider
- [ ] Evaluator scores appear with colored tags
- [ ] Debate messages show both sender AND target as colored pills
- [ ] Debate text renders as markdown (bold, lists, etc.)
- [ ] If a round takes >90s with missing scores, chairman nudges appear in timeline
- [ ] After all round 2 scores: evaluators stop (no more ping-pong)
- [ ] Chairman summary block appears — teal border, highlighted, markdown rendered
- [ ] Status shows "COMPLETED"
- [ ] Agent cards show evaluators as stopped/dead, chairman may still be active briefly
