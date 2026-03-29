# Post-Simulation Chat with the Chairman

**Date:** 2026-03-29
**Status:** Draft
**Scope:** Hiring demo enhancement — allow users to chat with the Chairman after simulation completes

## Problem

After the hiring simulation completes two rounds and the Chairman delivers its summary, the Chairman agent is killed after 30 seconds. The simulation feels "dead." Users can't ask follow-up questions like "Why Candidate X?" or "Which evaluator was slowest?"

This is a missed opportunity to demonstrate a core Rho capability: agents can sleep and wake up. They're just BEAM processes — cheap to keep alive, instant to resume.

## Design

### Core Concept

Remove the 30-second kill timer. After the simulation completes and the Chairman delivers its summary, the timeline becomes a bidirectional chat interface. The user types a question, the coordinator receives it, reads evaluator tapes to gather context, templates a data-enriched prompt, and submits it to the still-alive Chairman. The Chairman's response streams back into the timeline via the existing signal flow.

### Architecture

The flow reuses the exact same pattern as the simulation itself:

```
User question → LiveView event → Coordinator.ask/2 → (read tapes, build prompt) → Chairman.submit → response signal → timeline
```

No new architectural patterns. No new signal types beyond one `rho.hiring.chairman.reply`. The coordinator remains the brain; the Chairman remains the mouthpiece.

### Data Flow

```
┌──────────┐    phx-submit     ┌─────────────┐
│ Timeline  │ ────────────────→ │  LiveView    │
│ Input Box │                   │              │
└──────────┘                   └──────┬───────┘
                                       │ Simulation.ask(sid, question)
                                       ▼
                               ┌──────────────┐
                               │  Coordinator  │
                               │  (GenServer)  │
                               │               │
                               │ 1. Read tapes │
                               │ 2. Build      │
                               │    prompt     │
                               └──────┬───────┘
                                       │ Worker.submit(chairman_pid, prompt)
                                       ▼
                               ┌──────────────┐
                               │   Chairman    │
                               │   (Worker)    │
                               │               │
                               │ LLM call →    │
                               │ finish(text)  │
                               └──────┬───────┘
                                       │ signal: rho.task.completed
                                       ▼
                               ┌──────────────┐
                               │  Coordinator  │
                               │               │
                               │ Publishes:    │
                               │ rho.hiring.   │
                               │ chairman.reply│
                               └──────┬───────┘
                                       │ signal → LiveView
                                       ▼
                               ┌──────────────┐
                               │  Timeline     │
                               │  (new entry)  │
                               └──────────────┘
```

## Changes by File

### 1. `lib/rho/demos/hiring/simulation.ex`

**Remove** the 30-second kill timer:
- Delete `Process.send_after(self(), :stop_chairman, 30_000)` (line 394)
- Keep the `handle_info(:stop_chairman, state)` handler for safety, but it won't fire automatically

**Add** `summary_delivered: false` to the struct. Set to `true` when the Chairman's first `rho.task.completed` fires (the closing summary). This distinguishes the initial summary from subsequent chat replies — no new state machine needed.

**Add** public API function (cast, not call — fire-and-forget, response comes back via signal bus):
```elixir
def ask(session_id, question) do
  GenServer.cast(via(session_id), {:ask, question})
end
```

**Add** handler:
```elixir
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

Note: `cast` instead of `call` because the response comes async via the signal bus. The Worker queues multiple submissions naturally, so rapid user questions are handled in order. The LiveView should check if the coordinator process is alive before casting — if dead, show a "Session expired" message in the timeline instead of silently dropping the question.

**Add** `build_chat_prompt/2`:
- Reads evaluator tapes via `Rho.Memory.Tape.history("agent_#{agent_id}")` for each evaluator in `state.evaluators`. Note: evaluator processes are dead by this point, but tapes persist in the Store (ETS/file) — they outlive the process.
- Reads `state.scores` for structured score data
- Extracts timestamps from tape entries to answer timing questions
- Extracts debate messages (tool calls to `send_message`) for disagreement context
- Templates everything into a prompt:

```elixir
defp build_chat_prompt(state, question) do
  memory_mod = Rho.Config.memory_module()

  # Gather evaluator histories
  evaluator_context =
    state.evaluators
    |> Enum.map(fn {role, agent_id} ->
      history = memory_mod.history("agent_#{agent_id}")
      # Extract key entries: messages, tool calls, timestamps
      {role, summarize_evaluator_history(history)}
    end)
    |> Enum.map_join("\n\n", fn {role, summary} ->
      "## #{role}\n#{summary}"
    end)

  # Score data (reuse existing helpers)
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
```

**Modify** the `rho.task.completed` handler (lines 95-110):
- Use `summary_delivered` to distinguish closing summary from chat replies

```elixir
def handle_info({:signal, %Jido.Signal{type: "rho.task.completed", data: data}}, %{status: :completed} = state) do
  if data.agent_id == state.chairman_agent_id do
    {signal_type, state} =
      if state.summary_delivered do
        {"rho.hiring.chairman.reply", state}
      else
        {"rho.hiring.chairman.summary", %{state | summary_delivered: true}}
      end

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

### 2. `lib/rho_web/live/observatory_live.ex`

**Add** a `chairman_ready` assign (default `false`), set to `true` when the `rho.hiring.chairman.summary` signal arrives (in the projection). This ensures the chat input only appears after the Chairman has delivered its summary, not immediately when the simulation status flips to `:completed`.

**Add** a chat input that appears when the Chairman is ready:

In the `render/1` for the active observatory, after `<.unified_timeline>`:
```heex
<form :if={@chairman_ready} phx-submit="ask_chairman" class="obs-chat-input">
  <input type="text" name="question" placeholder="Ask the Chairman a question..."
         autocomplete="off" phx-hook="FocusOnMount" />
  <button type="submit">Ask</button>
</form>
```

**Add** user question to timeline immediately (so they see their own message):
```elixir
def handle_event("ask_chairman", %{"question" => question}, socket) do
  question = String.trim(question)
  if question == "" do
    {:noreply, socket}
  else
    sid = socket.assigns.session_id

    # Add user question to timeline immediately
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

    # Check coordinator is alive before sending (note: via/1 needs to be made public, or add Simulation.alive?/1)
    case GenServer.whereis(Simulation.via(sid)) do
      nil ->
        expired = %{entry | type: :system_notice, text: "Session expired. Please start a new simulation."}
        {:noreply, assign(socket, timeline: timeline ++ [expired])}
      _pid ->
        Simulation.ask(sid, question)
        {:noreply, assign(socket, timeline: timeline)}
    end
  end
end
```

**Subscribe** to the new signal pattern — already covered by `"rho.hiring.chairman.*"` wildcard.

### 3. `lib/rho_web/live/observatory_projection.ex`

**Modify** the existing `rho.hiring.chairman.summary` projection to also set `chairman_ready: true` on the socket, enabling the chat input.

**Add** projection for `rho.hiring.chairman.reply` — identical to `chairman.summary` but with type `:chairman_reply`:

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

### 4. `lib/rho_web/components/observatory_components.ex`

**Add** rendering for two new timeline entry types in the `unified_timeline` component:

- `:user_question` — styled as a right-aligned chat bubble (user message)
- `:chairman_reply` — styled same as `:chairman` entries (left-aligned, with Chairman avatar)
- `:system_notice` — centered, muted text (for "Session expired" etc.)

### 5. Chairman system prompt (`.rho.exs`)

**No changes needed.** The Chairman's prompt already says "Only respond to the specific task given" and "Call finish immediately when done." The coordinator's chat prompt will include the instruction to call `finish` with the answer. The existing prompt is compatible.

## What the User Sees

1. Simulation runs normally — 2 rounds, scores, debates, Chairman summary
2. After the summary appears, instead of agents dying, a text input fades in at the bottom of the timeline
3. User types: "Which evaluator was slowest in submitting scores?"
4. Their question appears in the timeline as a right-aligned bubble
5. Chairman's agent card goes from idle → busy (visible in the Observatory)
6. Chairman's response streams in as a new timeline entry
7. User can keep asking questions indefinitely
8. The Chairman's process stats (heap, reductions, mailbox) continue updating in real-time — the agent is visibly alive

## Demo Story

This enhancement tells a specific story: **agents are not request-response endpoints.** They're persistent processes with memory. The Chairman "remembers" the entire simulation because its tape and the evaluator tapes are all still there. It can go from idle to active in milliseconds because it's just a BEAM process — no cold start, no container spin-up, no connection re-establishment.

The user sees an agent that was orchestrated during the simulation, then becomes conversational after. Same process, same memory, different mode. That's the Rho pitch.

## Session Lifecycle

- Simulation completes → `status: :completed`, `summary_delivered` flips after first Chairman response → Chairman stays alive
- User navigates away → LiveView unmounts → no immediate cleanup (Chairman idles cheaply)
- Optional: add an idle timeout (e.g., 5 minutes of no questions) that sends `:stop_chairman` — but not required for MVP
- `Session.stop/1` or explicit cleanup will terminate all agents including Chairman

## Out of Scope

- Streaming the Chairman's response token-by-token into the timeline (would require wiring text_delta signals through to a specific timeline entry — nice-to-have, not MVP)
- Giving the Chairman tools to query tapes directly (the coordinator handles this)
- Persisting chat history across page reloads (tapes handle this naturally, but the timeline UI doesn't rehydrate from tapes today)
