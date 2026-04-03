# BaZi Multi-Model Debate Simulation — Design Spec

## Overview

A multi-agent simulation where 3 LLM advisors (Qwen, DeepSeek, GPT-5.4) analyze a user's BaZi (八字) natal chart and debate which option is best for a given life decision. A Chairman agent (Opus) facilitates: parses the chart, mediates between advisors and user, and summarizes the outcome. The entire experience is in Chinese (中文).

This is both a Rho framework demo (showcasing multi-model agent debate) and a real product for BaZi decision-making.

## Architecture

**Approach:** BaZi-first, standalone `demos/bazi/`. Borrows patterns from the hiring demo but does not share code. A shared debate engine can be extracted later if a third demo emerges.

## Agents

| Agent | Model | Role |
|-------|-------|------|
| 主席 Chairman | Opus | Facilitator. Parses chart, merges dimension proposals, relays user questions, broadcasts user replies, produces final summary. Does NOT score. |
| 顾问一 Advisor 1 | Qwen | BaZi analysis + scoring |
| 顾问二 Advisor 2 | DeepSeek | BaZi analysis + scoring |
| 顾问三 Advisor 3 | GPT-5.4 | BaZi analysis + scoring |

Model diversity is intentional — different models produce different interpretive styles on the same chart data and system prompt. No artificial "schools of thought" needed.

## Simulation Flow

### Step 0: User Input

User interacts with the system (chat-style input). They provide:
- A Joey Yap-format BaZi natal chart image
- Context about their decision (free-form text, can be multiple messages)
- The options they're choosing between (2 or more, any format)
- Their question

### Step 1: Chart Parsing

Chairman (Opus) receives the chart image and extracts structured BaZi data:

```elixir
%{
  day_master: "乙木",
  pillars: %{
    year:  %{stem: "丙火", branch: "子水", hidden_stems: ["癸水"], ten_god: "伤官"},
    month: %{stem: "乙木", branch: "未土", hidden_stems: ["丁火", "己土", "乙木"], ten_god: "比肩"},
    day:   %{stem: "乙木", branch: "卯木", hidden_stems: ["乙木"], ten_god: "日元"},
    hour:  %{stem: "癸水", branch: "未土", hidden_stems: ["丁火", "己土", "乙木"], ten_god: "偏印"}
  },
  notes: "月柱未土空亡"
}
```

This structured data is sent to all 3 advisors identically — no advantage to whichever model is better at OCR.

### Step 2: Dimension Proposal

1. Each advisor proposes 3-5 scoring dimensions relevant to the user's specific question (e.g., for a job decision: 事业发展, 财运, 五行契合, 时机, 风险).
2. Chairman merges and deduplicates proposals (e.g., "事业发展" and "职业前景" → pick one). Caps at ~5 dimensions.
3. Chairman presents the merged dimensions to the user for approval.
4. User approves or edits the dimensions.
5. Chairman broadcasts the finalized dimensions to all advisors.

### Step 3: Independent Analysis (Round 1)

Each advisor independently:
1. Performs a full BaZi reading based on the structured chart data
2. Analyzes each option against the chart
3. Scores each option on each agreed dimension (0-100)
4. Submits scores with rationale via `submit_scores` tool

No cross-talk between advisors in this round.

**User clarification flow:** If an advisor needs additional information during analysis, they call `request_user_info`. The chairman surfaces this to the user via the UI popup. When the user replies, the chairman broadcasts the reply to ALL advisors (not just the one who asked).

### Step 4: Debate + Re-score (Round 2)

1. Each advisor receives all other advisors' full analyses and scores from Round 1.
2. Advisors debate via `send_message` — specifically challenging or agreeing on interpretive points (e.g., element interactions, timing analysis, clash/combination interpretations).
3. Advisors can still request user info via chairman during debate.
4. After debate, each advisor re-scores with updated rationale.

### Step 5: Chairman Summary

Chairman produces a final summary including:
- Aggregated scores per dimension per option (average across advisors)
- Key disagreements and what they reveal
- Overall recommendation based on consensus and divergence
- Notable BaZi insights that all advisors agreed on

### Step 6: Post-Simulation Q&A

User can ask follow-up questions. Chairman answers with the full debate context available.

## Custom Tools

### Chairman Tools

| Tool | Description |
|------|-------------|
| `parse_chart` | Accepts image input, returns structured BaZi data (四柱, 天干, 地支, 藏干, 十神) |
| `propose_dimensions` | Presents merged/deduplicated dimensions to user for approval |
| `relay_to_user` | Surfaces an advisor's clarification request to the user |
| `broadcast_reply` | Sends user's answer to all 3 advisors |
| `publish_summary` | Publishes final aggregated report |

### Advisor Tools

| Tool | Description |
|------|-------------|
| `submit_dimensions` | Proposes 3-5 scoring dimensions (Round 0) |
| `submit_scores` | Submits scores per option per dimension with rationale (Round 1 & 2) |
| `request_user_info` | Asks chairman to get clarification from user |
| `send_message` | Sends debate message to other advisors (Round 2) |
| `list_agents` | Discover other agents in the session |

## Scoring

- Each advisor scores each option on each dimension: 0-100
- Dimensions are dynamic — proposed by advisors, approved by user, capped at ~5
- Per-option composite = average across dimensions (equal weight)
- Cross-advisor average = mean of 3 advisors' composites
- Score deltas between Round 1 and Round 2 are tracked for visual feedback

## UI: Observatory Layout

Three-column layout following existing Observatory patterns:

### Left Column: Agent Cards
- One card per advisor (Qwen, DeepSeek, GPT-5.4) showing: status (idle/analyzing/debating), step count, mailbox count
- Chairman card separated below

### Middle Column: Debate Timeline
- Chronological feed of all events: round markers, advisor messages, chairman announcements
- Each message shows: sender → recipient, color-coded by advisor
- Chairman popup at the bottom: appears when chairman needs user input (advisor requested clarification). Contains the question + a text input + send button. Hidden when no pending question.

### Right Column: Scoreboard
- One score table per option
- Rows = advisors (Qwen, DeepSeek, GPT-5.4) + average row
- Columns = dimensions (dynamic, from the proposal step) + composite column
- Score deltas shown visually when Round 2 scores differ from Round 1

### Top Bar
- Title: 八字决策顾问
- Phase progress indicator: ○ 维度 → ○ 分析 → ● 辩论 → ○ 总结

## Signal Bus Events

Following the hiring demo pattern, all events published via `Rho.Comms`:

| Event | Payload |
|-------|---------|
| `rho.bazi.{sid}.simulation.started` | `%{options: [...], question: "..."}` |
| `rho.bazi.{sid}.chart.parsed` | `%{chart_data: %{...}}` |
| `rho.bazi.{sid}.dimensions.proposed` | `%{advisor_id, dimensions: [...]}` |
| `rho.bazi.{sid}.dimensions.approved` | `%{dimensions: [...]}` |
| `rho.bazi.{sid}.round.started` | `%{round: 1 \| 2}` |
| `rho.bazi.{sid}.scores.submitted` | `%{advisor_id, round, scores: %{...}}` |
| `rho.bazi.{sid}.user.question` | `%{from_advisor, question}` |
| `rho.bazi.{sid}.user.reply` | `%{answer}` |
| `rho.bazi.{sid}.chairman.summary` | `%{summary, aggregated_scores}` |
| `rho.bazi.{sid}.simulation.completed` | `%{}` |

## File Structure

```
lib/rho/demos/bazi/
├── simulation.ex          # GenServer coordinator (state machine)
├── tools.ex               # Custom tool definitions (chairman + advisor)
├── chart_parser.ex        # Joey Yap image → structured BaZi data
└── scoring.ex             # Dimension merging, score aggregation, deltas

lib/rho_web/live/
├── bazi_live.ex            # Observatory LiveView for BaZi demo
└── bazi_components.ex      # Scoreboard, agent cards, debate timeline, chairman popup

.rho.exs                    # Add bazi_chairman, bazi_advisor_1/2/3 agent profiles
```

## Language

Everything in Chinese (中文): system prompts, advisor analyses, debate messages, scoring rationale, chairman summary, UI labels, dimension names. BaZi terminology uses standard Chinese terms (天干, 地支, 十神, 五行, etc.).

## State Machine

```
:not_started
  → :parsing_chart        (user submitted input)
  → :proposing_dimensions (chart parsed, advisors proposing)
  → :awaiting_dimension_approval (chairman merged, waiting for user)
  → :round_1              (dimensions approved, independent analysis)
  → :round_2              (round 1 complete, debate + re-score)
  → :summarizing          (round 2 complete, chairman writing summary)
  → :completed            (summary published, Q&A available)
```

## Timeouts

Following hiring demo pattern:
- Per-round timeout: 90 seconds
- Chairman nudges lagging advisors if they haven't submitted scores
- Soft timeout (nudge) not hard (force stop)

## Configuration (.rho.exs)

```elixir
bazi_chairman: [
  model: "openrouter:anthropic/claude-opus-4-6",
  system_prompt: "你是八字决策分析的主席...",
  mounts: [:multi_agent]
],
bazi_advisor_qwen: [
  model: "openrouter:qwen/qwen3-235b-a22b",
  system_prompt: "你是一位八字命理顾问...",
  mounts: [:multi_agent]
],
bazi_advisor_deepseek: [
  model: "openrouter:deepseek/deepseek-v3.2",
  system_prompt: "你是一位八字命理顾问...",
  mounts: [:multi_agent]
],
bazi_advisor_gpt: [
  model: "openrouter:openai/gpt-5.4",
  system_prompt: "你是一位八字命理顾问...",
  mounts: [:multi_agent]
]
```

Same system prompt for all advisors — model diversity provides the interpretive differences naturally.
