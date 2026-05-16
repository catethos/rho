# AI Readiness Assessment Agent — Build Plan

## Overview

An AI agent that conducts a natural conversation with a human to assess their AI readiness across 3 dimensions × 4 tenets (12 cells). Instead of a static survey, the agent **is** the assessment — it poses scenarios, follows up on reasoning, and silently maps responses to a readiness matrix.

No new infrastructure required. Uses the existing chat interface (CLI or web) with a custom plugin for assessment-specific tools.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Existing Rho Chat Interface         │
│                  (CLI / Web)                     │
└──────────────────────┬──────────────────────────┘
                       │
              ┌────────▼────────┐
              │  assessor agent  │  ← new agent config in .rho.exs
              │  (system prompt  │
              │   + methodology) │
              └────────┬────────┘
                       │ uses
              ┌────────▼────────┐
              │  AIReadiness    │  ← new plugin module
              │  Plugin         │
              │                 │
              │  Tools:         │
              │  • record_observation │
              │  • score_assessment   │
              └────────┬────────┘
                       │ state
              ┌────────▼────────┐
              │  ETS / Agent    │  ← observations stored per session
              │  (session-scoped)│
              └─────────────────┘
```

### What we build

| Artifact | Location | Purpose |
|----------|----------|---------|
| Agent config | `.rho.exs` (`:assessor` key) | System prompt with assessment methodology, conversation phases, scoring rubric |
| Plugin module | `apps/rho_frameworks/lib/rho_frameworks/ai_readiness/plugin.ex` | Provides `record_observation` and `score_assessment` tools |
| Observation store | `apps/rho_frameworks/lib/rho_frameworks/ai_readiness/store.ex` | ETS-backed per-session state for observations |
| Scoring logic | `apps/rho_frameworks/lib/rho_frameworks/ai_readiness/scoring.ex` | Pure functions: aggregate observations → cell scores → maturity levels → report |

### What we do NOT build

- No `Simulation` GenServer — the chat interface handles the conversation loop
- No new channels or transports — works with existing CLI/web
- No database tables — assessment results are ephemeral (can persist later via `save_framework` pattern if needed)
- No sub-agents — one agent does the whole interview

---

## The 3×4 Assessment Matrix

### Dimensions (rows)

| Dimension | What it measures | How the agent detects it |
|-----------|-----------------|--------------------------|
| **Knowledge** | What the person knows — concepts, principles, contextual awareness | Accuracy of explanations, correct use of terminology, awareness of limitations |
| **Skills** | What the person can do — technical competency, tool use, practical application | Problem-solving approach, tool selection reasoning, workflow descriptions |
| **Behaviours** | How the person acts — decision-making, ethics, collaboration, risk management | Choices in scenarios, unprompted risk consideration, verification habits |

### Tenets (columns)

| Tenet | Scope | Example probe |
|-------|-------|---------------|
| **Learn about AI** | Foundational knowledge of AI concepts, capabilities, limitations | "What types of tasks do you think AI handles well vs poorly?" |
| **Learn with AI** | Collaborative interaction — prompting, interpreting outputs, integrating into workflows | "If an AI gives you a confident-sounding answer, how do you decide whether to trust it?" |
| **Learn using AI** | Leveraging AI tools for productivity, decision-making, process optimization | "Walk me through how you'd use an AI tool to prepare a report from meeting notes." |
| **Learn beyond AI** | Strategic thinking — organizational impact, ethics, future implications | "If your team wanted to automate a customer-facing process with AI, what would you want to evaluate first?" |

### The 12 Cells

| | Learn about AI | Learn with AI | Learn using AI | Learn beyond AI |
|---|---|---|---|---|
| **Knowledge** | AI concepts, model types, capabilities vs limits, hallucination awareness | Prompting principles, output interpretation, human-in-the-loop understanding | Approved tools awareness, data classification, workflow integration rules | Strategy, ethics, regulation, workforce impact, ROI |
| **Skills** | Identify good-fit vs poor-fit AI use cases, evaluate feasibility | Prompt effectively, iterate, verify, synthesize | Use tools to draft, analyze, summarize, automate | Build business cases, redesign processes, define controls and KPIs |
| **Behaviours** | Healthy skepticism, governance adherence, escalation of misuse | Verify before acting, maintain accountability, disclose AI use | Consistent responsible use, documentation, stop when unsure | Stakeholder inclusion, fairness consideration, long-term thinking |

---

## Conversation Design

### Phase 1: Context & Rapport (2-3 exchanges)

**Goal**: Establish who the person is and calibrate the conversation difficulty.

The agent asks about:
- Role, department, industry
- Current AI tool usage (if any)
- General comfort level with technology

**What the agent learns**: Baseline context for tailoring scenarios. A finance manager gets different scenarios than a software developer.

**No scoring yet** — this is pure calibration.

### Phase 2: Scenario Probing (6-8 exchanges)

**Goal**: Surface evidence across all 12 cells through natural workplace scenarios.

The agent presents 4-6 scenarios, each designed to touch multiple cells simultaneously. The agent does NOT ask one question per cell — that would feel like a quiz. Instead, each scenario is an open-ended situation that reveals the person's knowledge, skills, and behaviours together.

**Scenario design principles**:
- Grounded in the person's role/industry (from Phase 1)
- Open-ended — no "right answer" to game
- Multi-cell: a single scenario can generate observations for 3-4 cells
- Escalating complexity — start accessible, increase strategic depth

**Example scenario flow**:

> **Scenario 1** (touches: Knowledge×about, Skills×about, Behaviours×about)
> "Your organization is considering using AI to help draft customer communications. A colleague says 'AI can write perfectly — we just need to copy-paste the output.' What's your reaction?"

> **Scenario 2** (touches: Skills×with, Behaviours×with, Knowledge×using)
> "You're using an AI assistant to analyze quarterly sales data. It produces a summary that looks reasonable but includes a trend you didn't expect. What do you do next?"

> **Scenario 3** (touches: Skills×using, Behaviours×using, Knowledge×with)
> "Your manager asks you to use an AI tool to summarize 50 customer feedback emails for a board presentation. Walk me through your approach."

> **Scenario 4** (touches: Knowledge×beyond, Skills×beyond, Behaviours×beyond)
> "Leadership proposes automating the initial screening of job applications using AI. You're asked for your input. What questions do you raise?"

After each response, the agent silently calls `record_observation` mapping evidence to the relevant cells.

### Phase 3: Adaptive Follow-up (2-4 exchanges)

**Goal**: Probe gaps and strengthen weak evidence.

After Phase 2, the agent reviews its observation coverage. For any cell with insufficient evidence (fewer than 2 observations or low confidence), it asks a targeted follow-up.

**Examples**:
- If Behaviours×Learn with AI is thin: "When you've used AI suggestions in the past, did you ever share with colleagues that AI helped? Why or why not?"
- If Knowledge×Learn beyond AI is thin: "Are you aware of any regulations or guidelines about AI use in your industry?"
- If Skills×Learn using AI is thin: "Can you describe a specific workflow where you've used (or would use) an AI tool? What steps would you take?"

### Phase 4: Scoring & Report (1 exchange)

**Goal**: Synthesize all observations into the readiness report.

The agent calls `score_assessment`, which:
1. Aggregates all observations per cell
2. Computes cell scores (0-100)
3. Maps to maturity levels (1-5)
4. Checks critical-control flags
5. Identifies top strengths and gaps
6. Generates recommended learning path

The agent presents the report as a conversational summary — not a raw data dump.

---

## Tool Specifications

### Tool 1: `record_observation`

Called silently by the agent after each human response during Phases 2-3. The human never sees this tool being called.

```
Name: record_observation
Description: Record an assessment observation from the current exchange. 
             Call this after each substantive response to log evidence 
             against specific cells in the readiness matrix.

Parameters:
  observations_json (string, required):
    JSON array of observations. Each observation:
    {
      "dimension": "knowledge" | "skills" | "behaviours",
      "tenet": "about" | "with" | "using" | "beyond",
      "evidence": "Brief quote or paraphrase of what the person said/demonstrated",
      "signal": "positive" | "negative" | "neutral",
      "confidence": "low" | "medium" | "high",
      "notes": "Optional agent reasoning about why this maps here"
    }

Returns: Confirmation with current coverage summary 
         (e.g., "Recorded 3 observations. Coverage: 8/12 cells have evidence.")
```

**Design rationale**: 
- Multiple observations per call — a single response often touches several cells
- `signal` field — not just presence/absence but directional evidence
- `confidence` — the agent's own certainty about the mapping
- Coverage summary in the return — helps the agent decide when to move to Phase 3

### Tool 2: `score_assessment`

Called once at the end of the conversation to produce the final report.

```
Name: score_assessment
Description: Compute the final AI readiness assessment from all recorded 
             observations. Returns the complete readiness report.

Parameters:
  participant_context (string, required):
    JSON object with participant metadata:
    {
      "role": "Job title or role",
      "department": "Department or function",
      "industry": "Industry/sector",
      "ai_experience": "none" | "basic" | "moderate" | "advanced"
    }

Returns: Formatted readiness report (see Report Format below)
```

---

## Scoring Logic

### Cell Score Computation

Each cell's score is derived from its observations:

```
cell_score = weighted_average(observations_in_cell)

where each observation contributes:
  - signal=positive:  base_score = 75
  - signal=neutral:   base_score = 50  
  - signal=negative:  base_score = 20

  - confidence=high:   weight = 1.0
  - confidence=medium: weight = 0.7
  - confidence=low:    weight = 0.4

  - Multiple positive observations compound: 
    2+ positive high-confidence → eligible for 80-100 range
```

Cells with no observations score 0 and are flagged as "not assessed".

### Maturity Level Mapping

| Level | Score | Label | Description |
|-------|-------|-------|-------------|
| 1 | 0-20 | Not Ready | Minimal understanding; cannot apply safely |
| 2 | 21-40 | Aware | Basic awareness; needs close guidance |
| 3 | 41-60 | Applied | Can handle common tasks; usually verifies |
| 4 | 61-80 | Operational | Uses AI effectively and responsibly |
| 5 | 81-100 | Strategic | Shapes adoption, mentors others, links to business value |

### Aggregate Scores

- **Dimension score** = average of 4 cells in that row
- **Tenet score** = average of 3 cells in that column
- **Overall AI Readiness** = average of all 12 cell scores

### Critical-Control Flags

Regardless of score, flag if any observation shows:
- Willingness to use unverified AI output for high-stakes decisions
- No awareness of data privacy when using AI tools
- No concept of human oversight / accountability
- Dismissal of bias or fairness considerations

These override the overall score with a "critical gap" warning.

---

## Report Format

The `score_assessment` tool returns a structured report that the agent presents conversationally:

```
# AI Readiness Assessment Report

## Participant
- Role: [role]
- Department: [dept]  
- Industry: [industry]

## Overall Readiness
- Score: [X]/100
- Maturity Level: [Level N — Label]
- Critical Flags: [none | list]

## Dimension Scores
- Knowledge:  [score] — Level [N]
- Skills:     [score] — Level [N]  
- Behaviours: [score] — Level [N]

## Tenet Scores
- Learn about AI:  [score] — Level [N]
- Learn with AI:   [score] — Level [N]
- Learn using AI:  [score] — Level [N]
- Learn beyond AI: [score] — Level [N]

## 12-Cell Heatmap
|              | About AI | With AI | Using AI | Beyond AI |
|--------------|----------|---------|----------|-----------|
| Knowledge    | [L/M/H]  | [L/M/H] | [L/M/H]  | [L/M/H]   |
| Skills       | [L/M/H]  | [L/M/H] | [L/M/H]  | [L/M/H]   |
| Behaviours   | [L/M/H]  | [L/M/H] | [L/M/H]  | [L/M/H]   |

## Top Strengths
1. [strongest cell + evidence summary]
2. [second strongest]

## Priority Gaps  
1. [weakest cell + what was missing]
2. [second weakest]

## Recommended Learning Path
- Immediate: [based on gaps]
- Short-term (30 days): [based on dimension weakness]
- Medium-term (90 days): [based on tenet weakness]

## Confidence Note
- Cells assessed with high confidence: [N]/12
- Cells with limited evidence: [list]
```

---

## Files to Create

### 1. `apps/rho_frameworks/lib/rho_frameworks/ai_readiness/plugin.ex`

```elixir
defmodule RhoFrameworks.AIReadiness.Plugin do
  @behaviour Rho.Plugin

  # tools/2 → returns [record_observation, score_assessment]
  # prompt_sections/2 → returns assessment context (matrix reference)
end
```

~120 lines. Follows `RhoFrameworks.Plugin` pattern.

### 2. `apps/rho_frameworks/lib/rho_frameworks/ai_readiness/store.ex`

```elixir
defmodule RhoFrameworks.AIReadiness.Store do
  # ETS-backed per-session observation storage
  # init/1, record/2, get_observations/1, coverage_summary/1, clear/1
end
```

~80 lines. Simple ETS wrapper keyed by `session_id`.

### 3. `apps/rho_frameworks/lib/rho_frameworks/ai_readiness/scoring.ex`

```elixir
defmodule RhoFrameworks.AIReadiness.Scoring do
  # Pure functions: observations → scores → report
  # score_cell/1, score_dimensions/1, score_tenets/1
  # maturity_level/1, critical_flags/1, format_report/2
end
```

~150 lines. Pure functions, fully testable.

### 4. `.rho.exs` — add `:assessor` agent config

```elixir
assessor: [
  model: "openrouter:anthropic/claude-sonnet-4",
  description: "AI readiness assessor that evaluates individuals through conversation",
  skills: ["assessment", "AI literacy evaluation", "competency analysis"],
  system_prompt: "...",  # ~800 words covering methodology + phases + rubric
  mounts: [RhoFrameworks.AIReadiness.Plugin],
  reasoner: :direct,
  max_steps: 40
]
```

---

## System Prompt Design (for the assessor agent)

The system prompt encodes the assessment methodology so the agent knows HOW to conduct the interview. Key sections:

1. **Role**: "You are an AI readiness assessor. Your goal is to understand how the participant thinks about, works with, and makes decisions around AI."

2. **Conversation phases**: The 4-phase structure with transition criteria.

3. **Scenario bank**: 8-10 template scenarios the agent can adapt to the participant's role. Not a script — the agent selects and tailors based on context.

4. **Observation protocol**: When and how to call `record_observation`. Key instruction: "After every substantive response, call record_observation before your next message. Map evidence to the most relevant cells. A single response may generate 1-4 observations."

5. **Adaptive rules**: 
   - "If a participant gives short/vague answers, probe deeper with 'Can you give me a specific example?'"
   - "If a participant demonstrates strong knowledge, escalate to strategic scenarios earlier"
   - "If you detect overconfidence (strong claims without evidence), test with a counter-scenario"

6. **Tone**: Professional but warm. Not an exam — a conversation. Never say "I'm now testing your knowledge of X."

7. **Completion criteria**: "Call score_assessment when you have medium+ confidence observations in at least 10 of 12 cells, or after 12 substantive exchanges, whichever comes first."

---

## Estimated Effort

| Task | Lines | Time |
|------|-------|------|
| Plugin module | ~120 | 30 min |
| Store module | ~80 | 20 min |
| Scoring module | ~150 | 40 min |
| Agent config + system prompt | ~100 | 30 min |
| Integration testing | — | 30 min |
| **Total** | **~450** | **~2.5 hours** |

---

## Future Extensions (not in scope now)

- **Persist results**: Save assessments to DB (follow `save_framework` pattern)
- **Batch mode**: Aggregate results across an organization for team/department heatmaps
- **Benchmark norms**: Compare individual scores against role-based or industry baselines
- **Re-assessment**: Track readiness over time with delta reports
- **Multi-language**: System prompt variants for non-English assessments
- **Live Render integration**: Show the heatmap updating in real-time during the conversation via the `:live_render` mount
