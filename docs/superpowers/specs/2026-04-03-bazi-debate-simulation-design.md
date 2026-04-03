# BaZi Multi-Model Debate Simulation — Design Spec

## Overview

A multi-agent simulation where 3 LLM advisors (Qwen, DeepSeek, GPT-5.4) analyze a user's BaZi (八字) natal chart and debate which option is best for a given life decision. A Chairman agent (Opus) facilitates: parses the chart, mediates between advisors and user, and summarizes the outcome. The entire experience is in Chinese (中文).

This is both a Rho framework demo (showcasing multi-model agent debate) and a real product for BaZi decision-making.

## Architecture

**Approach:** BaZi-first, standalone `demos/bazi/`. Borrows patterns from the hiring demo but does not share code. A shared debate engine can be extracted later if a third demo emerges.

**Key pattern from hiring demo:** The coordinator (GenServer) collects mount-provided tools (e.g., `send_message`, `list_agents` from `:multi_agent`), filters to only the allowed subset, then supplements with custom demo-specific tools (e.g., `submit_scores`, `submit_dimensions`) that close over session/agent state. The combined tool list is passed explicitly to agents at spawn time. The `.rho.exs` mount config matters for standard tools; custom tools are built by the coordinator.

## Agents

| Agent | Model | Role |
|-------|-------|------|
| 主席 Chairman | Opus | Facilitator. Parses chart, merges dimension proposals, relays user questions, broadcasts user replies, produces final summary. Does NOT score. |
| 顾问一 Advisor 1 | Qwen | BaZi analysis + scoring |
| 顾问二 Advisor 2 | DeepSeek | BaZi analysis + scoring |
| 顾问三 Advisor 3 | GPT-5.4 | BaZi analysis + scoring |

Model diversity is intentional — different models produce different interpretive styles on the same chart data and system prompt. No artificial "schools of thought" needed.

## Simulation Flow

Each phase is a separate coordinator-driven turn. The coordinator submits prompts to agents and waits for signal bus events before advancing. There is no pause/resume — agents run each turn to completion.

### Step 0: User Input

User interacts with the system (chat-style input in the LiveView). They provide:
- A Joey Yap-format BaZi natal chart image
- Context about their decision (free-form text, can be multiple messages)
- The options they're choosing between (2 or more, any format)
- Their question

### Step 1: Chart Parsing

Chairman (Opus) receives the chart image as a **multipart user message** (text + image content part), NOT as a tool argument. LLM tool calls carry JSON, not binary data — the image must be in the message content.

The coordinator builds the multipart message:
```elixir
content = [
  %{type: "text", text: "请从以下八字命盘图片中提取结构化数据..."},
  %{type: "image", source: %{type: "base64", media_type: "image/png", data: base64_data}}
]
Worker.submit(chairman_pid, content, tools: [submit_chart_data_tool], model: config.model)
```

Chairman extracts and submits structured BaZi data via `submit_chart_data` tool:

```elixir
%{
  day_master: "乙木",
  pillars: %{
    year:  %{stem: "丙", branch: "子", hidden_stems: ["癸"], ten_god: "伤官"},
    month: %{stem: "乙", branch: "未", hidden_stems: ["丁", "己", "乙"], ten_god: "比肩"},
    day:   %{stem: "乙", branch: "卯", hidden_stems: ["乙"], ten_god: "日元"},
    hour:  %{stem: "癸", branch: "未", hidden_stems: ["丁", "己", "乙"], ten_god: "偏印"}
  },
  element_analysis: "日主乙木，月令未土...",
  notes: "月柱未土空亡"
}
```

The coordinator receives this via signal bus event, then distributes the same structured data to all 3 advisors as text in their prompts. This ensures consistent input — no advantage to whichever model is better at OCR.

### Step 2: Dimension Proposal (coordinator-driven turn)

This is a **separate turn** for each advisor. The coordinator:

1. Submits "propose 3-5 scoring dimensions" prompt to each advisor (with chart data + user question + options as context).
2. Each advisor calls `submit_dimensions` tool → publishes event to signal bus.
3. Coordinator collects all 3 proposals, merges/deduplicates similar dimensions (e.g., "事业发展" and "职业前景" → pick one). Caps at ~5 dimensions.
4. Coordinator publishes merged dimensions to UI via `dimensions.proposed` event.
5. **User approves or edits** the dimensions via the LiveView.
6. Coordinator broadcasts finalized dimensions to all advisors as context for the next turn.

### Step 3: Independent Analysis (Round 1, coordinator-driven turn)

Coordinator submits analysis prompt to each advisor (staggered by 1 second to avoid connection pool exhaustion):

1. Prompt includes: structured chart data, user question, options, finalized dimensions.
2. Each advisor independently: performs full BaZi reading → scores each option on each dimension (0-100) → submits via `submit_scores` tool.
3. No cross-talk between advisors in this round.
4. Coordinator collects scores via signal bus, keyed by `{advisor_role, round}`.

**User clarification flow (new infrastructure):** If an advisor needs additional information during analysis, they call `request_user_info` tool → publishes `rho.bazi.{sid}.user_info.requested` event → LiveView shows chairman popup with the question → user replies → LiveView calls `Simulation.reply_to_advisor/2` → coordinator publishes `rho.bazi.{sid}.user_info.replied` event AND delivers the answer to all advisors via `send_message`. This is agent-initiated (unlike hiring demo where Q&A is user-initiated), requiring new event types and LiveView handlers.

### Step 4: Debate + Re-score (Round 2, coordinator-driven turn)

1. Coordinator builds Round 2 prompt including all advisors' full analyses and scores from Round 1, plus a disagreement summary (dimensions with >20 point score spreads).
2. Submits to each advisor (staggered).
3. Advisors debate via `send_message` — specifically challenging or agreeing on interpretive points.
4. Advisors can still request user info via the same flow as Round 1.
5. After debate, each advisor re-scores via `submit_scores`.
6. Coordinator collects Round 2 scores.

### Step 5: Chairman Summary (coordinator-driven turn)

After all Round 2 scores collected:
1. Coordinator stops all advisor agents.
2. Builds closing prompt with full score tables, disagreement summary, and debate highlights.
3. Submits to chairman. Chairman produces summary including:
   - Aggregated scores per dimension per option (average across advisors)
   - Key disagreements and what they reveal
   - Overall recommendation based on consensus and divergence
   - Notable BaZi insights that all advisors agreed on
4. Chairman calls `finish` tool → coordinator publishes `chairman.summary` event.

### Step 6: Post-Simulation Q&A

User can ask follow-up questions. Chairman answers with full debate context. Chairman gets `search_advisor_history` tools (one per advisor) to look up specific reasoning from their tapes, plus `request_round` tool to trigger re-evaluation with new information (same pattern as hiring demo).

## Custom Tools

### Chairman Tools

| Tool | Phase | Description |
|------|-------|-------------|
| `submit_chart_data` | Step 1 | Submits structured BaZi data extracted from chart image (JSON with pillars, stems, branches, hidden stems, ten gods) |
| `finish` | All | Standard finish tool — signals turn completion |

Note: Chairman does NOT need `propose_dimensions`, `relay_to_user`, `broadcast_reply`, or `publish_summary` as separate tools. The coordinator handles all mediation logic. Chairman just extracts data and produces text — the coordinator does the orchestration.

### Chairman Q&A Tools (added post-simulation)

| Tool | Description |
|------|-------------|
| `search_advisor_qwen_history` | Search Qwen advisor's full conversation tape by keyword |
| `search_advisor_deepseek_history` | Search DeepSeek advisor's full conversation tape by keyword |
| `search_advisor_gpt_history` | Search GPT-5.4 advisor's full conversation tape by keyword |
| `request_round` | Request coordinator to reconvene advisors for re-evaluation with new info |
| `send_message` | From multi-agent mount (filtered) |
| `finish` | Signal turn completion |

### Advisor Tools

| Tool | Phase | Description |
|------|-------|-------------|
| `submit_dimensions` | Step 2 | Proposes 3-5 scoring dimensions as JSON array |
| `submit_scores` | Steps 3-4 | Scores per option per dimension with rationale (JSON) |
| `request_user_info` | Steps 3-4 | Publishes event requesting user clarification via chairman popup |
| `send_message` | Step 4 | From multi-agent mount (filtered) — debate with other advisors |
| `list_agents` | Step 4 | From multi-agent mount (filtered) — discover other advisors |
| `finish` | All | Standard finish tool |

### Tool Implementation Pattern

Following hiring demo: each tool has `callback` (LLM-facing, always returns `:ok`) and `execute` (real work — publishes events via `Comms.publish`, returns `{:ok, message}` or `{:error, message}`).

## Scoring

- Each advisor scores each option on each dimension: 0-100
- Dimensions are dynamic — proposed by advisors, approved by user, capped at ~5
- Per-option composite = average across dimensions (equal weight)
- Cross-advisor average = mean of 3 advisors' composites
- Scores keyed by `{advisor_role, round}` in coordinator state
- Score deltas between Round 1 and Round 2 tracked for visual feedback
- Disagreement threshold: >20 point spread on any dimension triggers highlight

## UI: Observatory Layout

Three-column layout following existing Observatory patterns. **Entirely new LiveView and projection module** — not shared with hiring demo.

### Left Column: Agent Cards
- One card per advisor (Qwen, DeepSeek, GPT-5.4) showing: status (idle/analyzing/debating), step count, mailbox count
- Chairman card separated below

### Middle Column: Debate Timeline
- Chronological feed of all events: round markers, advisor messages, chairman announcements
- Each message shows: sender → recipient, color-coded by advisor
- Chairman popup at the bottom: appears when an advisor requests user info. Contains the question + a text input + send button. Hidden when no pending question.

### Right Column: Scoreboard
- One score table per option (e.g., "选项A — 某科技公司高级工程师")
- Rows = advisors (Qwen, DeepSeek, GPT-5.4) + average row
- Columns = dimensions (dynamic, from the proposal step) + composite column
- Score deltas shown visually when Round 2 scores differ from Round 1
- Scoreboard is empty/hidden until dimensions are approved and Round 1 scores arrive

### Top Bar
- Title: 八字决策顾问
- Phase progress indicator: ○ 维度 → ○ 分析 → ● 辩论 → ○ 总结

## Signal Bus Events

All events published via `Rho.Comms` with namespace `rho.bazi.{sid}`:

| Event | Payload |
|-------|---------|
| `rho.bazi.{sid}.simulation.started` | `%{options: [...], question: "..."}` |
| `rho.bazi.{sid}.chart.parsed` | `%{chart_data: %{...}}` |
| `rho.bazi.{sid}.dimensions.proposed` | `%{advisor_id, dimensions: [...]}` |
| `rho.bazi.{sid}.dimensions.approved` | `%{dimensions: [...]}` |
| `rho.bazi.{sid}.round.started` | `%{round: 1 \| 2}` |
| `rho.bazi.{sid}.scores.submitted` | `%{advisor_id, round, scores: %{...}}` |
| `rho.bazi.{sid}.user_info.requested` | `%{from_advisor, question}` |
| `rho.bazi.{sid}.user_info.replied` | `%{answer}` |
| `rho.bazi.{sid}.chairman.summary` | `%{summary, aggregated_scores}` |
| `rho.bazi.{sid}.simulation.completed` | `%{}` |
| `rho.bazi.{sid}.chairman.reply` | `%{text}` (post-sim Q&A) |
| `rho.bazi.{sid}.round.requested` | `%{round, reason}` (re-evaluation) |

LiveView subscribes to `rho.bazi.#{sid}.**` and `rho.agent.#{sid}.*` and `rho.task.#{sid}.*`.

## File Structure

```
lib/rho/demos/bazi/
├── simulation.ex          # GenServer coordinator (state machine)
├── tools.ex               # Custom tool definitions (chairman + advisor)
└── scoring.ex             # Dimension merging, score aggregation, deltas

lib/rho_web/live/
├── bazi_live.ex            # Observatory LiveView for BaZi demo
├── bazi_projection.ex      # Event projection (signal → socket assigns)
└── bazi_components.ex      # Scoreboard, agent cards, debate timeline, chairman popup

.rho.exs                    # Add bazi_chairman, bazi_advisor_qwen/deepseek/gpt profiles
```

Note: No separate `chart_parser.ex` — chart parsing is done by the Chairman LLM agent, not a deterministic module. The structured data extraction happens via the `submit_chart_data` tool's execute function.

## Language

Everything in Chinese (中文): system prompts, advisor analyses, debate messages, scoring rationale, chairman summary, UI labels, dimension names.

### BaZi Terminology in System Prompts

System prompts reference standard BaZi terminology:
- **Core:** 四柱, 天干, 地支, 藏干, 日主/日元, 五行 (金木水火土), 阴阳
- **Analysis:** 十神 (正官/偏官/正印/偏印/正财/偏财/食神/伤官/比肩/劫财), 格局, 用神, 忌神, 喜神, 身强/身弱
- **Dynamics:** 大运, 流年, 流月, 神煞 (天乙贵人, 文昌, 桃花, 华盖, etc.)
- **Relationships:** 合 (六合, 三合, 天干五合), 冲 (六冲), 刑 (三刑), 害, 破, 三会
- **Classical references:** 《渊海子平》, 《三命通会》, 《滴天髓》, 《子平真诠》, 《穷通宝鉴》

### Reference System Prompt Structure (for advisors)

```
你是一位精通四柱八字命理的专业顾问，具有深厚的中国传统文化底蕴和丰富的实践经验。

你的分析原则：
- 使用正统的八字命理理论体系
- 准确运用五行、十神、纳音、神煞等传统概念
- 提供结构化、条理清晰的分析
- 保持客观、理性的咨询态度
- 避免过于绝对化或消极的表述

分析框架：
1. 日主强弱判断（得令、得地、得生、得助）
2. 格局确定（正格/特殊格局）
3. 用神、忌神分析
4. 十神配置与关系
5. 地支藏干与暗合/暗冲
6. 大运流年对选项的影响

评分时你必须调用 submit_scores 工具，不要只在文字中描述分数。
辩论时使用 send_message 与其他顾问交流。
如需用户补充信息，调用 request_user_info。

免责声明：八字命理分析仅供参考，不构成任何决策的唯一依据。
```

## State Machine

```
:not_started
  → :parsing_chart              (user submitted input, chairman parsing image)
  → :proposing_dimensions       (chart parsed, advisors proposing dimensions)
  → :awaiting_dimension_approval (chairman merged dims, waiting for user approval)
  → :round_1                    (dimensions approved, independent analysis)
  → :awaiting_user_reply        (advisor requested info, paused until user replies)
  → :round_2                    (round 1 complete, debate + re-score)
  → :summarizing                (round 2 complete, chairman writing summary)
  → :completed                  (summary published, Q&A available)
```

Note: `:awaiting_user_reply` can occur during `:round_1` or `:round_2`. The coordinator tracks which round to resume after user replies.

## Coordinator State Structure

```elixir
%Rho.Demos.Bazi.Simulation{
  session_id: String.t(),
  status: atom(),                          # state machine
  round: integer(),                        # 0, 1, or 2
  max_rounds: integer(),                   # default 2, bumped on re-eval
  
  # Agent tracking
  chairman_agent_id: String.t(),
  chairman_tools: list(),
  advisors: %{atom() => String.t()},       # %{role => agent_id}
  advisor_tools: %{atom() => {list(), map()}},  # %{role => {tools, config}}
  
  # BaZi-specific
  chart_data: map() | nil,                 # parsed chart struct
  user_options: list(String.t()),          # the decision options
  user_question: String.t(),               # the user's question
  dimensions: list(String.t()) | nil,      # approved scoring dimensions
  dimension_proposals: %{atom() => list()}, # %{role => proposed dims}
  
  # Scoring
  scores: %{{atom(), integer()} => list()}, # %{{role, round} => scores}
  
  # Timeouts & chairman state
  round_started_at: DateTime.t(),
  round_timer_ref: reference(),
  chairman_task: nil | :parse | :nudge | :summary | :chat,
  pending_replies: integer(),
  summary_delivered: boolean(),
  summary_pending: boolean(),
  deferred_closing_prompt: String.t() | nil,
  
  # User info request tracking
  pending_user_info: nil | %{from_advisor: atom(), question: String.t()},
  paused_round: integer() | nil,           # round to resume after user reply
  
  # Q&A
  last_question: String.t() | nil,
  retry_count: integer()
}
```

## Timeouts

- Per-round timeout: **120 seconds** (longer than hiring's 90s due to multi-provider latency variance across Qwen/DeepSeek/GPT-5.4)
- Chairman nudges lagging advisors if they haven't submitted scores/dimensions
- Soft timeout (nudge) not hard (force stop)
- Deferred summary pattern: if nudge is in-flight when round completes, queue summary until nudge finishes

## Configuration (.rho.exs)

```elixir
bazi_chairman: [
  model: "openrouter:anthropic/claude-opus-4-6",
  system_prompt: "你是八字决策分析的主席。你的职责是...",
  max_steps: 10
],
bazi_advisor_qwen: [
  model: "openrouter:qwen/qwen3-235b-a22b",
  provider: %{order: ["fireworks"], allow_fallbacks: true},
  system_prompt: "你是一位精通四柱八字命理的专业顾问...",
  max_steps: 20
],
bazi_advisor_deepseek: [
  model: "openrouter:deepseek/deepseek-v3.2",
  provider: %{order: ["friendli", "google-vertex", "parasail"], allow_fallbacks: true},
  system_prompt: "你是一位精通四柱八字命理的专业顾问...",
  max_steps: 20
],
bazi_advisor_gpt: [
  model: "openrouter:openai/gpt-5.4",
  system_prompt: "你是一位精通四柱八字命理的专业顾问...",
  max_steps: 20
]
```

Same system prompt for all advisors — model diversity provides the interpretive differences naturally. Provider fallback configs included for non-Anthropic models to handle routing reliability.

## External References

- **`yijing-bazi-mcp-server`** (npm: `npx yijing-bazi-mcp@latest`) — potential future integration for deterministic chart computation
- **`mystilight-8char`** (npm) — reference for structured BaZi JSON schema
- **`lunar-javascript` / `lunar-python`** — foundational calendar/BaZi computation libraries
- **Joey Yap** — chart image format; no open API available, must parse visually
