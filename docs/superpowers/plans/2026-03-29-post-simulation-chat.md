# Post-Simulation Chat with Chairman — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the hiring simulation completes, keep the Chairman agent alive and let users chat with it through the timeline.

**Architecture:** The coordinator (Simulation GenServer) receives user questions via `cast`, reads evaluator tapes for context, templates a prompt, and submits it to the still-alive Chairman worker. The Chairman's response flows back through the existing signal bus → projection → timeline pipeline. No new architectural patterns.

**Tech Stack:** Elixir, Phoenix LiveView, Rho agent framework (Worker, Comms, Tape)

**Spec:** `docs/superpowers/specs/2026-03-29-post-simulation-chat-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/rho/demos/hiring/simulation.ex` | Modify | Add `summary_delivered` to struct, remove kill timer, add `ask/2` + `handle_cast`, add `build_chat_prompt/2`, modify `task.completed` handler |
| `lib/rho_web/live/observatory_live.ex` | Modify | Add `chairman_ready` assign, add `ask_chairman` event handler, add chat input to render |
| `lib/rho_web/live/observatory_projection.ex` | Modify | Set `chairman_ready` on summary, add `chairman.reply` projection |
| `lib/rho_web/components/observatory_components.ex` | Modify | Add `:user_question`, `:chairman_reply`, `:system_notice` timeline entry rendering |
| `lib/rho_web/inline_css.ex` | Modify | Add CSS for chat input, user question bubble, chairman reply, system notice |

---

### Task 1: Simulation GenServer — struct, kill timer, ask API

**Files:**
- Modify: `lib/rho/demos/hiring/simulation.ex:16-28` (struct), `:394` (kill timer), `:30-42` (API), `:80-81` (cast handler area), `:509` (via)

- [ ] **Step 1: Add `summary_delivered` to struct and make `via/1` public**

In `lib/rho/demos/hiring/simulation.ex`, change the struct (line 16-28):

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
    round_timer_ref: nil,
    summary_delivered: false
  ]
```

Change `defp via` to `def via` (line 509):

```elixir
  def via(session_id), do: {:via, Registry, {Rho.AgentRegistry, "sim_#{session_id}"}}
```

- [ ] **Step 2: Remove the 30-second kill timer**

In `lib/rho/demos/hiring/simulation.ex`, delete line 394:

```elixir
        # DELETE THIS LINE:
        Process.send_after(self(), :stop_chairman, 30_000)
```

The `handle_info(:stop_chairman, state)` handler at lines 153-164 can stay as a safety net — it just won't fire automatically anymore.

- [ ] **Step 3: Add `ask/2` public API and cast handler**

In `lib/rho/demos/hiring/simulation.ex`, add after `begin_simulation/1` (after line 43):

```elixir
  def ask(session_id, question) do
    GenServer.cast(via(session_id), {:ask, question})
  end
```

Add the `handle_cast` clauses. Place them after the `handle_call(:begin, ...)` clauses (after line 80):

```elixir
  @impl true
  def handle_cast({:ask, question}, %{status: :completed} = state) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)

    if chairman_pid do
      prompt = build_chat_prompt(state, question)
      config = Rho.Config.agent(:chairman)
      Worker.submit(chairman_pid, prompt, tools: state.chairman_tools, model: config.model)
    end

    {:noreply, state}
  end

  def handle_cast({:ask, _question}, state), do: {:noreply, state}
```

- [ ] **Step 4: Modify the `rho.task.completed` handler**

Replace the existing handler at lines 95-110:

```elixir
  @impl true
  def handle_info({:signal, %Jido.Signal{type: "rho.task.completed", data: data}}, %{status: :completed} = state) do
    if data.agent_id == state.chairman_agent_id do
      {signal_type, state} =
        if state.summary_delivered do
          {"rho.hiring.chairman.reply", state}
        else
          {"rho.hiring.chairman.summary", %{state | summary_delivered: true}}
        end

      Logger.info("[Hiring] Chairman produced #{if state.summary_delivered, do: "reply", else: "summary"}. Publishing to timeline.")

      Comms.publish(signal_type, %{
        session_id: state.session_id,
        agent_id: state.chairman_agent_id,
        agent_role: :chairman,
        text: data.result
      }, source: "/session/#{state.session_id}")

      {:noreply, state}
    else
      {:noreply, state}
    end
  end
```

- [ ] **Step 5: Compile and verify no errors**

Run: `mix compile --warnings-as-errors 2>&1 | head -20`

Expected: Compiles successfully. `build_chat_prompt/2` is not yet defined so there will be a warning — that's OK, we add it in Task 2.

- [ ] **Step 6: Commit**

```bash
git add lib/rho/demos/hiring/simulation.ex
git commit -m "feat(hiring): add ask/2 API, remove kill timer, route chairman replies"
```

---

### Task 2: Simulation GenServer — `build_chat_prompt/2`

**Files:**
- Modify: `lib/rho/demos/hiring/simulation.ex` (add private functions at bottom, before `via/1`)

- [ ] **Step 1: Add `build_chat_prompt/2` and helpers**

In `lib/rho/demos/hiring/simulation.ex`, add before the `via/1` function:

```elixir
  defp build_chat_prompt(state, question) do
    memory_mod = Rho.Config.memory_module()

    # Gather evaluator tape histories (tapes persist after process death)
    evaluator_context =
      state.evaluators
      |> Enum.map(fn {role, agent_id} ->
        history = memory_mod.history("agent_#{agent_id}")
        {role, summarize_evaluator_history(history)}
      end)
      |> Enum.map_join("\n\n", fn {role, summary} ->
        "## #{format_role(role)}\n#{summary}"
      end)

    score_summary = format_all_scores(state)

    """
    You are the Chairman answering a follow-up question from a user who watched the hiring simulation.

    Here is the full context from the simulation:

    ### Final Scores
    #{score_summary}

    ### Evaluator Activity
    #{evaluator_context}

    ### User Question
    #{question}

    Answer conversationally and concisely. Reference specific evaluator opinions and scores when relevant. Call `finish` with your answer when done.
    """
  end

  defp summarize_evaluator_history(history) do
    history
    |> Enum.map(fn entry ->
      case entry do
        %{type: "message", role: "assistant", content: content} ->
          "Assistant: #{String.slice(to_string(content), 0, 300)}"

        %{type: "tool_call", name: "submit_scores", args: args} ->
          scores = args["scores"] || []
          formatted = Enum.map_join(scores, ", ", fn s ->
            "#{s["id"]}: #{s["score"]}"
          end)
          "Submitted scores: #{formatted} (at #{entry[:ts] || "?"})"

        %{type: "tool_call", name: "send_message", args: args} ->
          "Sent message to #{args["to"]}: #{String.slice(to_string(args["message"]), 0, 200)}"

        %{type: "tool_call", name: name} ->
          "Called #{name}"

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_all_scores(state) do
    latest_round = state.max_rounds

    state.scores
    |> Enum.filter(fn {{_role, round}, _} -> round == latest_round end)
    |> Enum.flat_map(fn {{role, _round}, scores} ->
      Enum.map(scores, fn entry ->
        candidate = Enum.find(Candidates.all(), &(&1.id == entry["id"]))
        name = if candidate, do: candidate.name, else: entry["id"]
        "#{name}: #{format_role(role)} scored #{entry["score"]}"
      end)
    end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp format_role(role) when is_atom(role) do
    role |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_role(role), do: to_string(role)
```

- [ ] **Step 2: Compile and verify**

Run: `mix compile --warnings-as-errors 2>&1 | head -20`

Expected: Compiles cleanly with no warnings.

- [ ] **Step 3: Commit**

```bash
git add lib/rho/demos/hiring/simulation.ex
git commit -m "feat(hiring): add build_chat_prompt with tape reading and score formatting"
```

---

### Task 3: Observatory Projection — `chairman_ready` and reply signal

**Files:**
- Modify: `lib/rho_web/live/observatory_projection.ex:143-161` (chairman.summary handler), add new handler after it

- [ ] **Step 1: Modify `chairman.summary` projection to set `chairman_ready`**

In `lib/rho_web/live/observatory_projection.ex`, replace the existing handler at lines 143-161:

```elixir
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

    socket
    |> assign(:timeline, timeline ++ [entry])
    |> assign(:chairman_ready, true)
  end
```

- [ ] **Step 2: Add `chairman.reply` projection**

Add immediately after the `chairman.summary` handler:

```elixir
  def project(socket, "rho.hiring.chairman.reply", data) do
    timeline = socket.assigns[:timeline] || []

    entry = %{
      type: :chairman_reply,
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

- [ ] **Step 3: Compile and verify**

Run: `mix compile --warnings-as-errors 2>&1 | head -20`

Expected: Compiles cleanly.

- [ ] **Step 4: Commit**

```bash
git add lib/rho_web/live/observatory_projection.ex
git commit -m "feat(hiring): projection for chairman_ready flag and reply signal"
```

---

### Task 4: Observatory LiveView — `chairman_ready` assign, chat event handler, render

**Files:**
- Modify: `lib/rho_web/live/observatory_live.ex:13-27` (landing mount assigns), `:31-45` (session mount assigns), `:107-114` (event handlers), `:186-232` (render)

- [ ] **Step 1: Add `chairman_ready` assign to both mount functions**

In `lib/rho_web/live/observatory_live.ex`, add `chairman_ready: false` to the landing page mount assigns (after line 25, alongside the other assigns):

```elixir
       selected_agent: nil,
       chairman_ready: false,
       bus_subs: []
```

Same for the session mount assigns (after line 43):

```elixir
       selected_agent: nil,
       chairman_ready: false,
       bus_subs: []
```

- [ ] **Step 2: Add `ask_chairman` event handler**

In `lib/rho_web/live/observatory_live.ex`, add after the `handle_event("close_drawer", ...)` handler (after line 114):

```elixir
  def handle_event("ask_chairman", %{"question" => question}, socket) do
    question = String.trim(question)

    if question == "" do
      {:noreply, socket}
    else
      sid = socket.assigns.session_id

      entry = %{
        type: :user_question,
        agent_role: nil,
        agent_id: nil,
        target: nil,
        text: question,
        candidate_id: nil,
        candidate_name: nil,
        score: nil,
        delta: nil,
        round: socket.assigns.round,
        timestamp: System.monotonic_time(:millisecond)
      }

      timeline = socket.assigns.timeline ++ [entry]

      case GenServer.whereis(Simulation.via(sid)) do
        nil ->
          notice = %{entry | type: :system_notice, text: "Session expired. Please start a new simulation."}
          {:noreply, assign(socket, timeline: timeline ++ [notice])}

        _pid ->
          Simulation.ask(sid, question)
          {:noreply, assign(socket, timeline: timeline)}
      end
    end
  end
```

- [ ] **Step 3: Add chat input form to the render template**

In `lib/rho_web/live/observatory_live.ex`, in the active observatory `render/1`, add the chat form after `<.unified_timeline>` (after line 216):

```heex
          <.unified_timeline timeline={@timeline} />
          <form :if={@chairman_ready} phx-submit="ask_chairman" class="obs-chat-input">
            <input type="text" name="question" placeholder="Ask the Chairman anything about the simulation..."
                   autocomplete="off" />
            <button type="submit">Ask</button>
          </form>
```

- [ ] **Step 4: Compile and verify**

Run: `mix compile --warnings-as-errors 2>&1 | head -20`

Expected: Compiles cleanly.

- [ ] **Step 5: Commit**

```bash
git add lib/rho_web/live/observatory_live.ex
git commit -m "feat(hiring): chat input and ask_chairman event handler in observatory"
```

---

### Task 5: Timeline components — render new entry types

**Files:**
- Modify: `lib/rho_web/components/observatory_components.ex:214-225` (inside unified_timeline, before the catch-all)

- [ ] **Step 1: Add `:chairman_reply`, `:user_question`, `:system_notice` to timeline rendering**

In `lib/rho_web/components/observatory_components.ex`, inside the `unified_timeline` component, add three new cases before the catch-all `<% _ -> %>` (before line 223):

```heex
          <% :chairman_reply -> %>
            <div class="obs-timeline-reply">
              <span class="obs-timeline-tag obs-timeline-tag-chairman">Chairman</span>
              <div class="obs-timeline-reply-body markdown-body"
                   id={"timeline-reply-#{entry.timestamp}-#{System.unique_integer([:positive])}"}
                   phx-hook="Markdown"
                   data-md={entry.text}></div>
            </div>

          <% :user_question -> %>
            <div class="obs-timeline-user-question">
              <div class="obs-timeline-user-bubble"><%= entry.text %></div>
            </div>

          <% :system_notice -> %>
            <div class="obs-timeline-system-notice"><%= entry.text %></div>
```

- [ ] **Step 2: Compile and verify**

Run: `mix compile --warnings-as-errors 2>&1 | head -20`

Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/components/observatory_components.ex
git commit -m "feat(hiring): timeline rendering for user questions, chairman replies, system notices"
```

---

### Task 6: CSS for chat input and new timeline entries

**Files:**
- Modify: `lib/rho_web/inline_css.ex:1315` (after `.obs-timeline-summary-body` line)

- [ ] **Step 1: Add CSS styles**

In `lib/rho_web/inline_css.ex`, add after line 1315 (after `.obs-timeline-summary-body { ... }`):

```css
    /* Post-simulation chat */
    .obs-chat-input {
      display: flex; gap: 8px; padding: 12px 16px;
      border-top: 1px solid var(--border);
      background: var(--bg-secondary, #1a1a2e);
    }
    .obs-chat-input input {
      flex: 1; padding: 8px 12px; border-radius: 8px;
      border: 1px solid var(--border); background: var(--bg-primary, #0f0f1a);
      color: var(--text-primary); font-size: 13px; font-family: inherit;
      outline: none;
    }
    .obs-chat-input input:focus { border-color: #5BB5A2; }
    .obs-chat-input button {
      padding: 8px 16px; border-radius: 8px; border: none;
      background: #5BB5A2; color: #fff; font-size: 13px; font-weight: 500;
      cursor: pointer;
    }
    .obs-chat-input button:hover { background: #4da392; }

    /* User question bubble */
    .obs-timeline-user-question {
      display: flex; justify-content: flex-end; margin: 8px 0;
    }
    .obs-timeline-user-bubble {
      background: rgba(91, 181, 162, 0.15); color: var(--text-primary);
      padding: 8px 14px; border-radius: 14px 14px 4px 14px;
      font-size: 13px; max-width: 75%; line-height: 1.5;
    }

    /* Chairman reply */
    .obs-timeline-reply {
      background: rgba(91, 181, 162, 0.04);
      border-left: 2px solid #5BB5A2;
      border-radius: 6px; padding: 10px 14px; margin: 8px 0;
      font-size: 13px;
    }
    .obs-timeline-reply-body { line-height: 1.6; margin-top: 6px; }

    /* System notice */
    .obs-timeline-system-notice {
      text-align: center; color: var(--text-muted);
      font-size: 11px; font-style: italic; padding: 8px 0;
    }
```

- [ ] **Step 2: Compile and verify**

Run: `mix compile --warnings-as-errors 2>&1 | head -20`

Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/inline_css.ex
git commit -m "feat(hiring): CSS for chat input, user question bubbles, chairman replies"
```

---

### Task 7: Manual integration test

**Files:** None — this is a manual verification task

- [ ] **Step 1: Start the server**

Run: `mix phx.server`

- [ ] **Step 2: Run a full simulation**

1. Navigate to `http://localhost:4000/observatory`
2. Click "Start Simulation"
3. Click "Begin"
4. Wait for 2 rounds to complete (~2-3 min)
5. Verify the Chairman summary appears in the timeline
6. Verify evaluator agent cards show as stopped/dead
7. Verify the Chairman agent card is still alive (not dead)

- [ ] **Step 3: Test the chat input**

1. After the Chairman summary appears, verify a text input appears below the timeline
2. Type "Which evaluator was slowest in submitting scores?" and press Enter
3. Verify your question appears as a right-aligned bubble in the timeline
4. Verify the Chairman agent card flashes to "busy" status
5. Verify the Chairman's reply appears as a left-aligned entry in the timeline

- [ ] **Step 4: Test rapid questions**

1. Type and submit 2-3 questions quickly without waiting
2. Verify all questions appear immediately in the timeline
3. Verify replies arrive in order (may take a few seconds each)

- [ ] **Step 5: Commit all changes**

```bash
git add -A
git commit -m "feat(hiring): post-simulation chat with Chairman

Allow users to ask follow-up questions after the hiring simulation
completes. The coordinator reads evaluator tapes, templates context
into a prompt, and submits to the still-alive Chairman agent."
```
