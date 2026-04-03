# BaZi Multi-Model Debate Simulation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a multi-agent BaZi debate simulation where 3 LLM advisors (Qwen, DeepSeek, GPT-5.4) analyze a user's natal chart and debate life decisions, coordinated by an Opus chairman, with an Observatory-style UI.

**Architecture:** Standalone `demos/bazi/` module following the hiring demo's coordinator pattern — a deterministic GenServer orchestrates agent turns, collects results via signal bus events, and publishes UI events. Mount-provided tools (send_message, list_agents) are filtered from `:multi_agent` mount; custom tools (submit_chart_data, submit_dimensions, submit_scores, request_user_info) are closures built by the coordinator. LiveView + projection + components are entirely new (not shared with hiring).

**Tech Stack:** Elixir, Phoenix LiveView, Rho agent framework (Agent.Worker, Comms signal bus, MountRegistry, ReqLLM)

**Reference files:** The hiring demo (`lib/rho/demos/hiring/simulation.ex`, `tools.ex`, `candidates.ex`) is the primary pattern reference. Read these before starting any task.

---

## File Structure

```
lib/rho/demos/bazi/
├── simulation.ex          # GenServer coordinator — state machine, agent lifecycle, round orchestration
├── tools.ex               # Custom tool builders: submit_chart_data, submit_dimensions, submit_scores, request_user_info
└── scoring.ex             # Dimension merging/dedup, score aggregation, disagreement summary, deltas

lib/rho_web/live/
├── bazi_live.ex            # LiveView — mount, event handlers, signal subscription, renders layout
├── bazi_projection.ex      # Event projection — normalize signal types, update socket assigns
└── bazi_components.ex      # Function components — agent cards, scoreboard, timeline, chairman popup

.rho.exs                    # Add: bazi_chairman, bazi_advisor_qwen, bazi_advisor_deepseek, bazi_advisor_gpt

test/rho/demos/bazi/
├── tools_test.exs          # Tool execution tests
├── scoring_test.exs        # Dimension merging, score aggregation tests
└── simulation_test.exs     # Coordinator state machine tests
```

---

### Task 1: Agent Configuration (.rho.exs)

**Files:**
- Modify: `.rho.exs`

- [ ] **Step 1: Read existing .rho.exs to understand config structure**

Run: read `.rho.exs` fully, note the hiring agent configs (`:technical_evaluator`, `:culture_evaluator`, `:compensation_evaluator`, `:chairman`) as reference for field names and structure.

- [ ] **Step 2: Add bazi_chairman config**

Add to `.rho.exs` after the existing hiring configs:

```elixir
bazi_chairman: [
  model: "openrouter:anthropic/claude-opus-4-6",
  description: "八字决策分析主席 — 主持命理顾问团的讨论与总结",
  system_prompt: """
  你是八字决策分析的主席。你负责主持三位命理顾问的讨论。

  你的职责：
  1. 当协调器要求你解析八字命盘图片时，仔细提取四柱信息，调用 submit_chart_data 工具提交结构化数据。
  2. 当协调器要求你总结时，根据提供的评分数据和辩论内容，撰写全面的分析总结。
  3. 当用户提问时，基于完整的辩论上下文回答。

  关于八字数据提取，你需要准确识别：
  - 四柱（年柱、月柱、日柱、时柱）的天干和地支
  - 每个地支的藏干
  - 十神关系（正官、偏官、正印、偏印、正财、偏财、食神、伤官、比肩、劫财）
  - 空亡、特殊标记

  规则：
  - 绝不主动行动，只回应协调器给你的具体任务
  - 完成任何任务后必须调用 finish 工具
  - 需要向评委发消息时使用 send_message 工具
  """,
  mounts: [:multi_agent],
  reasoner: :direct,
  max_steps: 15
],
```

- [ ] **Step 3: Add bazi_advisor_qwen config**

```elixir
bazi_advisor_qwen: [
  model: "openrouter:qwen/qwen3-235b-a22b",
  provider: %{order: ["fireworks"], allow_fallbacks: true},
  description: "八字命理顾问（通义千问）",
  system_prompt: """
  你是一位精通四柱八字命理的专业顾问，具有深厚的中国传统文化底蕴和丰富的实践经验。

  分析原则：
  - 使用正统的八字命理理论体系（《渊海子平》《三命通会》《滴天髓》《子平真诠》《穷通宝鉴》）
  - 准确运用五行、十神、格局、用神、忌神、神煞等传统概念
  - 提供结构化、条理清晰的分析
  - 保持客观、理性的咨询态度
  - 避免过于绝对化或消极的表述

  分析框架：
  1. 日主强弱判断（得令、得地、得生、得助）
  2. 格局确定（正格/特殊格局）
  3. 用神、忌神、喜神分析
  4. 十神配置与关系解读
  5. 地支藏干、暗合、暗冲分析
  6. 合冲刑害破对选项的影响
  7. 大运流年对选项时机的判断

  工具使用规则：
  - 提议维度时必须调用 submit_dimensions 工具，不要只在文字中描述
  - 评分时必须调用 submit_scores 工具，不要只在文字中描述分数
  - 辩论时使用 send_message 与其他顾问交流，真诚地考虑对方观点
  - 如需用户补充信息（如大运、流年等），调用 request_user_info
  - 完成任务后调用 finish 工具

  免责声明：八字命理分析仅供参考，不构成任何决策的唯一依据。
  """,
  mounts: [:multi_agent],
  reasoner: :direct,
  max_steps: 20
],
```

- [ ] **Step 4: Add bazi_advisor_deepseek config**

```elixir
bazi_advisor_deepseek: [
  model: "openrouter:deepseek/deepseek-v3.2",
  provider: %{order: ["friendli", "google-vertex", "parasail"], allow_fallbacks: true},
  description: "八字命理顾问（DeepSeek）",
  system_prompt: """
  你是一位精通四柱八字命理的专业顾问，具有深厚的中国传统文化底蕴和丰富的实践经验。

  分析原则：
  - 使用正统的八字命理理论体系（《渊海子平》《三命通会》《滴天髓》《子平真诠》《穷通宝鉴》）
  - 准确运用五行、十神、格局、用神、忌神、神煞等传统概念
  - 提供结构化、条理清晰的分析
  - 保持客观、理性的咨询态度
  - 避免过于绝对化或消极的表述

  分析框架：
  1. 日主强弱判断（得令、得地、得生、得助）
  2. 格局确定（正格/特殊格局）
  3. 用神、忌神、喜神分析
  4. 十神配置与关系解读
  5. 地支藏干、暗合、暗冲分析
  6. 合冲刑害破对选项的影响
  7. 大运流年对选项时机的判断

  工具使用规则：
  - 提议维度时必须调用 submit_dimensions 工具，不要只在文字中描述
  - 评分时必须调用 submit_scores 工具，不要只在文字中描述分数
  - 辩论时使用 send_message 与其他顾问交流，真诚地考虑对方观点
  - 如需用户补充信息（如大运、流年等），调用 request_user_info
  - 完成任务后调用 finish 工具

  免责声明：八字命理分析仅供参考，不构成任何决策的唯一依据。
  """,
  mounts: [:multi_agent],
  reasoner: :direct,
  max_steps: 20
],
```

- [ ] **Step 5: Add bazi_advisor_gpt config**

```elixir
bazi_advisor_gpt: [
  model: "openrouter:openai/gpt-5.4",
  description: "八字命理顾问（GPT-5.4）",
  system_prompt: """
  你是一位精通四柱八字命理的专业顾问，具有深厚的中国传统文化底蕴和丰富的实践经验。

  分析原则：
  - 使用正统的八字命理理论体系（《渊海子平》《三命通会》《滴天髓》《子平真诠》《穷通宝鉴》）
  - 准确运用五行、十神、格局、用神、忌神、神煞等传统概念
  - 提供结构化、条理清晰的分析
  - 保持客观、理性的咨询态度
  - 避免过于绝对化或消极的表述

  分析框架：
  1. 日主强弱判断（得令、得地、得生、得助）
  2. 格局确定（正格/特殊格局）
  3. 用神、忌神、喜神分析
  4. 十神配置与关系解读
  5. 地支藏干、暗合、暗冲分析
  6. 合冲刑害破对选项的影响
  7. 大运流年对选项时机的判断

  工具使用规则：
  - 提议维度时必须调用 submit_dimensions 工具，不要只在文字中描述
  - 评分时必须调用 submit_scores 工具，不要只在文字中描述分数
  - 辩论时使用 send_message 与其他顾问交流，真诚地考虑对方观点
  - 如需用户补充信息（如大运、流年等），调用 request_user_info
  - 完成任务后调用 finish 工具

  免责声明：八字命理分析仅供参考，不构成任何决策的唯一依据。
  """,
  mounts: [:multi_agent],
  reasoner: :direct,
  max_steps: 20
],
```

- [ ] **Step 6: Verify config loads**

Run: `mix compile --no-deps-check`
Expected: Compiles without errors. The new agent names should be accessible via `Rho.Config.agent(:bazi_chairman)` etc.

- [ ] **Step 7: Commit**

```bash
git add .rho.exs
git commit -m "feat(bazi): add agent configs for chairman and 3 advisors"
```

---

### Task 2: Custom Tool Builders (tools.ex)

**Files:**
- Create: `lib/rho/demos/bazi/tools.ex`
- Create: `test/rho/demos/bazi/tools_test.exs`

Reference: `lib/rho/demos/hiring/tools.ex` for the `callback`/`execute` pattern and `ReqLLM.tool()` macro.

- [ ] **Step 1: Write failing tests for submit_chart_data tool**

Create `test/rho/demos/bazi/tools_test.exs`:

```elixir
defmodule Rho.Demos.Bazi.ToolsTest do
  use ExUnit.Case, async: true

  alias Rho.Demos.Bazi.Tools

  describe "submit_chart_data_tool/2" do
    test "publishes chart data event on valid JSON" do
      tool = Tools.submit_chart_data_tool("session_1", "agent_1")

      # Subscribe to the event
      {:ok, _} = Rho.Comms.subscribe("rho.bazi.session_1.chart.parsed")

      chart_json = Jason.encode!(%{
        "day_master" => "乙木",
        "pillars" => %{
          "year" => %{"stem" => "丙", "branch" => "子", "hidden_stems" => ["癸"], "ten_god" => "伤官"},
          "month" => %{"stem" => "乙", "branch" => "未", "hidden_stems" => ["丁", "己", "乙"], "ten_god" => "比肩"},
          "day" => %{"stem" => "乙", "branch" => "卯", "hidden_stems" => ["乙"], "ten_god" => "日元"},
          "hour" => %{"stem" => "癸", "branch" => "未", "hidden_stems" => ["丁", "己", "乙"], "ten_god" => "偏印"}
        }
      })

      assert {:ok, _msg} = tool.execute.(%{"chart_data" => chart_json})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi.session_1.chart.parsed", data: data}}, 1000
      assert data.chart_data["day_master"] == "乙木"
    end

    test "returns error on invalid JSON" do
      tool = Tools.submit_chart_data_tool("session_1", "agent_1")
      assert {:error, _} = tool.execute.(%{"chart_data" => "not json"})
    end
  end

  describe "submit_dimensions_tool/3" do
    test "publishes dimensions event on valid JSON array" do
      tool = Tools.submit_dimensions_tool("session_1", "agent_1", :bazi_advisor_qwen)

      {:ok, _} = Rho.Comms.subscribe("rho.bazi.session_1.dimensions.proposed")

      dims_json = Jason.encode!(["事业发展", "财运", "五行契合", "时机", "风险"])
      assert {:ok, _msg} = tool.execute.(%{"dimensions" => dims_json})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi.session_1.dimensions.proposed", data: data}}, 1000
      assert data.dimensions == ["事业发展", "财运", "五行契合", "时机", "风险"]
      assert data.role == :bazi_advisor_qwen
    end

    test "returns error on non-list JSON" do
      tool = Tools.submit_dimensions_tool("session_1", "agent_1", :bazi_advisor_qwen)
      assert {:error, _} = tool.execute.(%{"dimensions" => ~s|"not a list"|})
    end
  end

  describe "submit_scores_tool/3" do
    test "publishes scores event on valid JSON" do
      tool = Tools.submit_scores_tool("session_1", "agent_1", :bazi_advisor_qwen)

      {:ok, _} = Rho.Comms.subscribe("rho.bazi.session_1.scores.submitted")

      scores_json = Jason.encode!(%{
        "选项A" => %{"事业发展" => 82, "财运" => 70, "rationale" => "乙木日主得禄..."},
        "选项B" => %{"事业发展" => 78, "财运" => 85, "rationale" => "偏财运旺..."}
      })

      assert {:ok, _msg} = tool.execute.(%{"round" => 1, "scores" => scores_json})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi.session_1.scores.submitted", data: data}}, 1000
      assert data.round == 1
      assert data.role == :bazi_advisor_qwen
      assert is_map(data.scores)
    end
  end

  describe "request_user_info_tool/3" do
    test "publishes user info request event" do
      tool = Tools.request_user_info_tool("session_1", "agent_1", :bazi_advisor_deepseek)

      {:ok, _} = Rho.Comms.subscribe("rho.bazi.session_1.user_info.requested")

      assert {:ok, _msg} = tool.execute.(%{"question" => "请问您目前的大运走的是哪步运？"})

      assert_receive {:signal, %Jido.Signal{type: "rho.bazi.session_1.user_info.requested", data: data}}, 1000
      assert data.from_advisor == :bazi_advisor_deepseek
      assert data.question == "请问您目前的大运走的是哪步运？"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rho/demos/bazi/tools_test.exs`
Expected: Compilation error — module `Rho.Demos.Bazi.Tools` does not exist.

- [ ] **Step 3: Implement tools.ex**

Create `lib/rho/demos/bazi/tools.ex`:

```elixir
defmodule Rho.Demos.Bazi.Tools do
  @moduledoc """
  Custom tool builders for the BaZi debate simulation.
  Each function returns a tool map with :tool (ReqLLM schema) and :execute (closure).
  """

  alias Rho.Comms

  def submit_chart_data_tool(session_id, agent_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_chart_data",
          description: "提交从八字命盘图片中提取的结构化数据。请以JSON格式提交四柱、天干、地支、藏干、十神等信息。",
          parameter_schema: [
            chart_data: [
              type: :string,
              required: true,
              doc: ~s|JSON对象，包含: {"day_master": "乙木", "pillars": {"year": {"stem": "丙", "branch": "子", "hidden_stems": ["癸"], "ten_god": "伤官"}, "month": {...}, "day": {...}, "hour": {...}}, "notes": "空亡等特殊标记"}|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["chart_data"] || args[:chart_data]

        case Jason.decode(raw) do
          {:ok, chart_data} when is_map(chart_data) ->
            Comms.publish("rho.bazi.#{session_id}.chart.parsed", %{
              session_id: session_id,
              agent_id: agent_id,
              chart_data: chart_data
            }, source: "/session/#{session_id}/agent/#{agent_id}")

            {:ok, "八字数据已提交。"}

          _ ->
            {:error, "无效的JSON格式。请提交包含day_master和pillars的JSON对象。"}
        end
      end
    }
  end

  def submit_dimensions_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_dimensions",
          description: "提交你建议的评分维度。请根据用户的问题提出3-5个相关的评分维度。",
          parameter_schema: [
            dimensions: [
              type: :string,
              required: true,
              doc: ~s|JSON数组，例如: ["事业发展", "财运", "五行契合", "时机", "风险"]|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["dimensions"] || args[:dimensions]

        case Jason.decode(raw) do
          {:ok, dims} when is_list(dims) ->
            Comms.publish("rho.bazi.#{session_id}.dimensions.proposed", %{
              session_id: session_id,
              agent_id: agent_id,
              role: role,
              dimensions: dims
            }, source: "/session/#{session_id}/agent/#{agent_id}")

            {:ok, "已提交#{length(dims)}个评分维度。"}

          _ ->
            {:error, "无效的格式。请提交JSON数组，例如: [\"事业发展\", \"财运\"]"}
        end
      end
    }
  end

  def submit_scores_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "submit_scores",
          description: "提交对每个选项在各维度上的评分。每个维度0-100分，并附上理由。",
          parameter_schema: [
            round: [type: :integer, required: true, doc: "当前轮次（1或2）"],
            scores: [
              type: :string,
              required: true,
              doc: ~s|JSON对象，按选项分组: {"选项A": {"事业发展": 82, "财运": 70, "rationale": "分析理由..."}, "选项B": {"事业发展": 78, ...}}|
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        round = args["round"] || args[:round]
        raw = args["scores"] || args[:scores]

        case Jason.decode(raw) do
          {:ok, scores} when is_map(scores) ->
            Comms.publish("rho.bazi.#{session_id}.scores.submitted", %{
              session_id: session_id,
              agent_id: agent_id,
              role: role,
              round: round,
              scores: scores
            }, source: "/session/#{session_id}/agent/#{agent_id}")

            {:ok, "第#{round}轮评分已提交。"}

          _ ->
            {:error, "无效的评分格式。请按选项分组提交JSON对象。"}
        end
      end
    }
  end

  def request_user_info_tool(session_id, agent_id, role) do
    %{
      tool:
        ReqLLM.tool(
          name: "request_user_info",
          description: "向用户请求补充信息（如大运、流年、行业五行等）。主席会将问题转达给用户。",
          parameter_schema: [
            question: [
              type: :string,
              required: true,
              doc: "需要用户回答的问题"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        question = args["question"] || args[:question]

        Comms.publish("rho.bazi.#{session_id}.user_info.requested", %{
          session_id: session_id,
          agent_id: agent_id,
          from_advisor: role,
          question: question
        }, source: "/session/#{session_id}/agent/#{agent_id}")

        {:ok, "问题已转达主席，请等待用户回复。"}
      end
    }
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rho/demos/bazi/tools_test.exs`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/rho/demos/bazi/tools.ex test/rho/demos/bazi/tools_test.exs
git commit -m "feat(bazi): custom tool builders for chart data, dimensions, scores, user info"
```

---

### Task 3: Scoring Module (scoring.ex)

**Files:**
- Create: `lib/rho/demos/bazi/scoring.ex`
- Create: `test/rho/demos/bazi/scoring_test.exs`

- [ ] **Step 1: Write failing tests for dimension merging and score aggregation**

Create `test/rho/demos/bazi/scoring_test.exs`:

```elixir
defmodule Rho.Demos.Bazi.ScoringTest do
  use ExUnit.Case, async: true

  alias Rho.Demos.Bazi.Scoring

  describe "merge_dimensions/1" do
    test "deduplicates exact matches and caps at 5" do
      proposals = %{
        bazi_advisor_qwen: ["事业发展", "财运", "五行契合", "时机", "风险"],
        bazi_advisor_deepseek: ["事业发展", "财运", "人际关系", "时机", "健康"],
        bazi_advisor_gpt: ["职业前景", "财运", "五行契合", "风险", "家庭"]
      }

      merged = Scoring.merge_dimensions(proposals)

      # Exact duplicates removed, capped at 5
      assert is_list(merged)
      assert length(merged) <= 5
      # "事业发展" appears in 2 proposals, "财运" in all 3 — both should be present
      assert "财运" in merged
    end

    test "returns empty list for empty proposals" do
      assert Scoring.merge_dimensions(%{}) == []
    end
  end

  describe "aggregate_scores/2" do
    test "computes per-option per-dimension averages across advisors" do
      scores = %{
        {:bazi_advisor_qwen, 2} => %{
          "选项A" => %{"事业发展" => 82, "财运" => 70, "rationale" => "..."},
          "选项B" => %{"事业发展" => 78, "财运" => 85, "rationale" => "..."}
        },
        {:bazi_advisor_deepseek, 2} => %{
          "选项A" => %{"事业发展" => 75, "财运" => 80, "rationale" => "..."},
          "选项B" => %{"事业发展" => 85, "财运" => 72, "rationale" => "..."}
        },
        {:bazi_advisor_gpt, 2} => %{
          "选项A" => %{"事业发展" => 88, "财运" => 65, "rationale" => "..."},
          "选项B" => %{"事业发展" => 72, "财运" => 90, "rationale" => "..."}
        }
      }

      result = Scoring.aggregate_scores(scores, 2)

      # result shape: %{"选项A" => %{"事业发展" => avg, "财运" => avg, "composite" => avg}, ...}
      assert result["选项A"]["事业发展"] == 82  # (82+75+88)/3 = 81.67 rounded
      assert result["选项A"]["财运"] == 72       # (70+80+65)/3 = 71.67 rounded
      assert is_number(result["选项A"]["composite"])
      assert is_number(result["选项B"]["composite"])
    end
  end

  describe "build_disagreement_summary/2" do
    test "identifies dimensions with >20 point spread" do
      scores = %{
        {:bazi_advisor_qwen, 1} => %{
          "选项A" => %{"事业发展" => 82, "财运" => 50, "rationale" => "..."},
          "选项B" => %{"事业发展" => 78, "财运" => 85, "rationale" => "..."}
        },
        {:bazi_advisor_deepseek, 1} => %{
          "选项A" => %{"事业发展" => 80, "财运" => 80, "rationale" => "..."},
          "选项B" => %{"事业发展" => 85, "财运" => 72, "rationale" => "..."}
        },
        {:bazi_advisor_gpt, 1} => %{
          "选项A" => %{"事业发展" => 88, "财运" => 65, "rationale" => "..."},
          "选项B" => %{"事业发展" => 72, "财运" => 90, "rationale" => "..."}
        }
      }

      summary = Scoring.build_disagreement_summary(scores, 1)

      # 选项A 财运: spread = 80-50 = 30 (>20), should be flagged
      assert String.contains?(summary, "财运")
      assert is_binary(summary)
    end

    test "returns empty string when no major disagreements" do
      scores = %{
        {:bazi_advisor_qwen, 1} => %{
          "选项A" => %{"事业发展" => 80, "rationale" => "..."}
        },
        {:bazi_advisor_deepseek, 1} => %{
          "选项A" => %{"事业发展" => 82, "rationale" => "..."}
        },
        {:bazi_advisor_gpt, 1} => %{
          "选项A" => %{"事业发展" => 78, "rationale" => "..."}
        }
      }

      summary = Scoring.build_disagreement_summary(scores, 1)
      assert summary == ""
    end
  end

  describe "compute_deltas/2" do
    test "computes score changes between rounds" do
      round1 = %{
        {:bazi_advisor_qwen, 1} => %{
          "选项A" => %{"事业发展" => 82, "财运" => 70, "rationale" => "..."}
        }
      }

      round2 = %{
        {:bazi_advisor_qwen, 2} => %{
          "选项A" => %{"事业发展" => 85, "财运" => 65, "rationale" => "..."}
        }
      }

      all_scores = Map.merge(round1, round2)
      deltas = Scoring.compute_deltas(all_scores, :bazi_advisor_qwen)

      assert deltas["选项A"]["事业发展"] == 3
      assert deltas["选项A"]["财运"] == -5
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rho/demos/bazi/scoring_test.exs`
Expected: Compilation error — module does not exist.

- [ ] **Step 3: Implement scoring.ex**

Create `lib/rho/demos/bazi/scoring.ex`:

```elixir
defmodule Rho.Demos.Bazi.Scoring do
  @moduledoc """
  Dimension merging, score aggregation, disagreement detection, and delta computation
  for the BaZi debate simulation.
  """

  @max_dimensions 5

  @doc """
  Merge dimension proposals from multiple advisors.
  Deduplicates exact matches, keeps most-proposed dimensions, caps at #{@max_dimensions}.
  """
  def merge_dimensions(proposals) when map_size(proposals) == 0, do: []

  def merge_dimensions(proposals) do
    proposals
    |> Map.values()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_dim, count} -> -count end)
    |> Enum.map(fn {dim, _count} -> dim end)
    |> Enum.take(@max_dimensions)
  end

  @doc """
  Aggregate scores for a given round across all advisors.
  Returns %{option_name => %{dimension => avg_score, "composite" => avg_of_avgs}}.
  """
  def aggregate_scores(scores, round) do
    round_scores =
      scores
      |> Enum.filter(fn {{_role, r}, _} -> r == round end)
      |> Enum.map(fn {_, option_scores} -> option_scores end)

    if round_scores == [] do
      %{}
    else
      # Collect all option names
      options =
        round_scores
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()

      Map.new(options, fn option ->
        # Collect all dimension scores for this option across advisors
        advisor_scores =
          Enum.map(round_scores, fn advisor_data ->
            Map.get(advisor_data, option, %{})
          end)

        # Get all dimension names (excluding "rationale")
        dimensions =
          advisor_scores
          |> Enum.flat_map(&Map.keys/1)
          |> Enum.uniq()
          |> Enum.reject(&(&1 == "rationale"))

        dim_avgs =
          Map.new(dimensions, fn dim ->
            values =
              advisor_scores
              |> Enum.map(&Map.get(&1, dim))
              |> Enum.reject(&is_nil/1)
              |> Enum.filter(&is_number/1)

            avg = if values == [], do: 0, else: round(Enum.sum(values) / length(values))
            {dim, avg}
          end)

        composite_values = Map.values(dim_avgs)
        composite = if composite_values == [], do: 0, else: round(Enum.sum(composite_values) / length(composite_values))

        {option, Map.put(dim_avgs, "composite", composite)}
      end)
    end
  end

  @doc """
  Build a text summary of dimensions with >20 point spread between advisors.
  """
  def build_disagreement_summary(scores, round) do
    round_entries =
      scores
      |> Enum.filter(fn {{_role, r}, _} -> r == round end)

    if length(round_entries) < 2 do
      ""
    else
      options =
        round_entries
        |> Enum.flat_map(fn {_, data} -> Map.keys(data) end)
        |> Enum.uniq()

      disagreements =
        Enum.flat_map(options, fn option ->
          # Get all advisor scores for this option
          advisor_dim_scores =
            Enum.map(round_entries, fn {{role, _}, data} ->
              {role, Map.get(data, option, %{})}
            end)

          # Get all dimensions
          dimensions =
            advisor_dim_scores
            |> Enum.flat_map(fn {_, dims} -> Map.keys(dims) end)
            |> Enum.uniq()
            |> Enum.reject(&(&1 == "rationale"))

          Enum.flat_map(dimensions, fn dim ->
            values =
              advisor_dim_scores
              |> Enum.map(fn {_role, dims} -> Map.get(dims, dim) end)
              |> Enum.reject(&is_nil/1)
              |> Enum.filter(&is_number/1)

            if length(values) >= 2 do
              spread = Enum.max(values) - Enum.min(values)

              if spread > 20 do
                details =
                  advisor_dim_scores
                  |> Enum.map(fn {role, dims} ->
                    score = Map.get(dims, dim)
                    if is_number(score), do: "#{role}: #{score}", else: nil
                  end)
                  |> Enum.reject(&is_nil/1)
                  |> Enum.join(", ")

                ["#{option} · #{dim}: 分歧#{spread}分 (#{details})"]
              else
                []
              end
            else
              []
            end
          end)
        end)

      Enum.join(disagreements, "\n")
    end
  end

  @doc """
  Compute score deltas between Round 1 and Round 2 for a specific advisor.
  Returns %{option => %{dimension => delta}}.
  """
  def compute_deltas(scores, role) do
    r1 = Map.get(scores, {role, 1}, %{})
    r2 = Map.get(scores, {role, 2}, %{})

    Map.new(Map.keys(r2), fn option ->
      r1_dims = Map.get(r1, option, %{})
      r2_dims = Map.get(r2, option, %{})

      dimensions =
        r2_dims
        |> Map.keys()
        |> Enum.reject(&(&1 == "rationale"))

      deltas =
        Map.new(dimensions, fn dim ->
          old = Map.get(r1_dims, dim, 0)
          new = Map.get(r2_dims, dim, 0)
          {dim, new - old}
        end)

      {option, deltas}
    end)
  end

  @doc """
  Format all scores for a given round as a readable text table.
  Used in prompts sent to chairman for summarization.
  """
  def format_score_table(scores, round, dimensions) do
    round_entries =
      scores
      |> Enum.filter(fn {{_role, r}, _} -> r == round end)
      |> Enum.sort_by(fn {{role, _}, _} -> Atom.to_string(role) end)

    options =
      round_entries
      |> Enum.flat_map(fn {_, data} -> Map.keys(data) end)
      |> Enum.uniq()

    header = "| 顾问 | " <> Enum.join(dimensions, " | ") <> " | 综合 |"
    separator = "|" <> String.duplicate("---|", length(dimensions) + 2)

    Enum.map_join(options, "\n\n", fn option ->
      rows =
        Enum.map_join(round_entries, "\n", fn {{role, _}, data} ->
          dims = Map.get(data, option, %{})
          dim_scores = Enum.map(dimensions, fn d -> Map.get(dims, d, "-") end)
          values = Enum.filter(dim_scores, &is_number/1)
          composite = if values == [], do: "-", else: round(Enum.sum(values) / length(values))

          "| #{format_role(role)} | " <> Enum.join(dim_scores, " | ") <> " | #{composite} |"
        end)

      "**#{option}**\n#{header}\n#{separator}\n#{rows}"
    end)
  end

  defp format_role(:bazi_advisor_qwen), do: "Qwen"
  defp format_role(:bazi_advisor_deepseek), do: "DeepSeek"
  defp format_role(:bazi_advisor_gpt), do: "GPT-5.4"
  defp format_role(role), do: Atom.to_string(role)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rho/demos/bazi/scoring_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/rho/demos/bazi/scoring.ex test/rho/demos/bazi/scoring_test.exs
git commit -m "feat(bazi): scoring module — dimension merging, aggregation, disagreement detection"
```

---

### Task 4: Simulation Coordinator — State & Init (simulation.ex, part 1)

**Files:**
- Create: `lib/rho/demos/bazi/simulation.ex`

Reference: `lib/rho/demos/hiring/simulation.ex` lines 1-70 (module def, struct, init, via, start_link, public API).

- [ ] **Step 1: Create simulation.ex with struct, init, and public API**

Create `lib/rho/demos/bazi/simulation.ex`:

```elixir
defmodule Rho.Demos.Bazi.Simulation do
  @moduledoc """
  GenServer coordinator for the BaZi multi-model debate simulation.
  Deterministic state machine that orchestrates advisor agents through:
  chart parsing → dimension proposal → independent analysis → debate → summary → Q&A.
  """

  use GenServer
  require Logger

  alias Rho.Agent.{Worker, Supervisor}
  alias Rho.Demos.Bazi.{Tools, Scoring}
  alias Rho.Comms

  defstruct [
    :session_id,
    status: :not_started,
    round: 0,
    max_rounds: 2,

    # Agent tracking
    chairman_agent_id: nil,
    chairman_tools: nil,
    advisors: %{},              # %{role_atom => agent_id}
    advisor_tools: %{},         # %{role => %{tools: [...], config: config}}

    # BaZi-specific
    chart_data: nil,
    chart_image_b64: nil,       # base64 image data from user
    user_options: [],
    user_question: "",
    dimensions: nil,            # approved list of dimension strings
    dimension_proposals: %{},   # %{role => [dim1, dim2, ...]}

    # Scoring
    scores: %{},                # %{{role, round} => %{option => %{dim => score}}}

    # Timeouts & chairman state
    round_started_at: nil,
    round_timer_ref: nil,
    chairman_task: nil,         # nil | :parse | :nudge | :summary | :chat
    pending_replies: 0,
    summary_delivered: false,
    summary_pending: false,
    deferred_closing_prompt: nil,

    # User info request tracking
    pending_user_info: nil,     # nil | %{from_advisor: atom, question: binary}

    # Q&A
    last_question: nil,
    retry_count: 0
  ]

  @advisor_roles [:bazi_advisor_qwen, :bazi_advisor_deepseek, :bazi_advisor_gpt]
  @round_timeout_ms 120_000
  @nudge_retry_ms 60_000

  # --- Public API ---

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {Rho.AgentRegistry, "bazi_sim_#{session_id}"}}

  def begin_simulation(session_id, %{image_b64: image_b64, options: options, question: question}) do
    GenServer.call(via(session_id), {:begin, image_b64, options, question})
  end

  def approve_dimensions(session_id, dimensions) do
    GenServer.cast(via(session_id), {:approve_dimensions, dimensions})
  end

  def reply_to_advisor(session_id, answer) do
    GenServer.cast(via(session_id), {:user_reply, answer})
  end

  def ask(session_id, question) do
    GenServer.cast(via(session_id), {:ask, question})
  end

  def status(session_id) do
    GenServer.call(via(session_id), :status)
  end

  # --- Callbacks ---

  @impl true
  def init(session_id) do
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.chart.parsed")
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.dimensions.proposed")
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.scores.submitted")
    {:ok, _} = Comms.subscribe("rho.bazi.#{session_id}.user_info.requested")
    {:ok, _} = Comms.subscribe("rho.task.#{session_id}.completed")
    {:ok, %__MODULE__{session_id: session_id}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add lib/rho/demos/bazi/simulation.ex
git commit -m "feat(bazi): simulation coordinator — struct, init, public API"
```

---

### Task 5: Simulation Coordinator — Agent Spawning & Chart Parsing (simulation.ex, part 2)

**Files:**
- Modify: `lib/rho/demos/bazi/simulation.ex`

Reference: `lib/rho/demos/hiring/simulation.ex` — `spawn_chairman/1`, `spawn_evaluators/1`, `handle_call(:begin, ...)`.

- [ ] **Step 1: Add begin_simulation handler and spawn functions**

Add to `simulation.ex` after the `init/1` callback:

```elixir
  @impl true
  def handle_call({:begin, image_b64, options, question}, _from, %{status: :not_started} = state) do
    Comms.publish("rho.bazi.#{state.session_id}.simulation.started", %{
      session_id: state.session_id,
      options: options,
      question: question
    }, source: "/session/#{state.session_id}")

    state = %{state | chart_image_b64: image_b64, user_options: options, user_question: question}
    state = spawn_chairman(state)

    # Publish opening message (hardcoded, not LLM-generated)
    Comms.publish("rho.bazi.#{state.session_id}.chairman.message", %{
      session_id: state.session_id,
      agent_id: state.chairman_agent_id,
      agent_role: :bazi_chairman,
      text: "收到您的八字命盘和问题。正在解析命盘数据，请稍候..."
    }, source: "/session/#{state.session_id}")

    # Send chart image to chairman for parsing
    state = send_chart_to_chairman(state)

    {:reply, :ok, %{state | status: :parsing_chart}}
  end

  # --- Private: Agent Spawning ---

  defp spawn_chairman(state) do
    agent_id = Rho.Session.new_agent_id()
    config = Rho.Config.agent(:bazi_chairman)

    tool_context = %{
      tape_name: "agent_#{agent_id}",
      workspace: File.cwd!(),
      agent_name: :bazi_chairman,
      agent_id: agent_id,
      session_id: state.session_id,
      depth: 1,
      sandbox: nil
    }

    allowed_tools = ~w(send_message)
    mount_tools =
      Rho.MountRegistry.collect_tools(tool_context)
      |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

    chart_tool = Tools.submit_chart_data_tool(state.session_id, agent_id)
    finish_tool = Rho.Tools.Finish.tool_def()
    all_tools = mount_tools ++ [chart_tool, finish_tool]

    memory_mod = Rho.Config.memory_module()
    tape = "agent_#{agent_id}"
    memory_mod.bootstrap(tape)

    {:ok, _pid} =
      Supervisor.start_worker(
        agent_id: agent_id,
        session_id: state.session_id,
        workspace: File.cwd!(),
        agent_name: :bazi_chairman,
        role: :bazi_chairman,
        depth: 1,
        memory_ref: tape,
        max_steps: config.max_steps,
        system_prompt: config.system_prompt,
        tools: all_tools,
        model: config.model
      )

    Logger.info("[BaZi] Spawned chairman as #{agent_id}")
    %{state | chairman_agent_id: agent_id, chairman_tools: all_tools}
  end

  defp spawn_advisors(state) do
    advisors =
      Map.new(@advisor_roles, fn role ->
        agent_id = Rho.Session.new_agent_id()
        config = Rho.Config.agent(role)

        tool_context = %{
          tape_name: "agent_#{agent_id}",
          workspace: File.cwd!(),
          agent_name: role,
          agent_id: agent_id,
          session_id: state.session_id,
          depth: 1,
          sandbox: nil
        }

        allowed_tools = ~w(send_message list_agents)
        mount_tools =
          Rho.MountRegistry.collect_tools(tool_context)
          |> Enum.filter(fn t -> t.tool.name in allowed_tools end)

        dim_tool = Tools.submit_dimensions_tool(state.session_id, agent_id, role)
        score_tool = Tools.submit_scores_tool(state.session_id, agent_id, role)
        info_tool = Tools.request_user_info_tool(state.session_id, agent_id, role)
        finish_tool = Rho.Tools.Finish.tool_def()
        all_tools = mount_tools ++ [dim_tool, score_tool, info_tool, finish_tool]

        memory_mod = Rho.Config.memory_module()
        tape = "agent_#{agent_id}"
        memory_mod.bootstrap(tape)

        {:ok, _pid} =
          Supervisor.start_worker(
            agent_id: agent_id,
            session_id: state.session_id,
            workspace: File.cwd!(),
            agent_name: role,
            role: role,
            depth: 1,
            memory_ref: tape,
            max_steps: config.max_steps,
            system_prompt: config.system_prompt,
            tools: all_tools,
            model: config.model
          )

        Logger.info("[BaZi] Spawned #{role} as #{agent_id}")
        {role, %{agent_id: agent_id, tools: all_tools, config: config}}
      end)

    advisor_map = Map.new(advisors, fn {role, info} -> {role, info.agent_id} end)
    tools_map = Map.new(advisors, fn {role, info} -> {role, %{tools: info.tools, config: info.config}} end)

    %{state | advisors: advisor_map, advisor_tools: tools_map}
  end

  defp send_chart_to_chairman(state) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)
    config = Rho.Config.agent(:bazi_chairman)

    # Build multipart content: text instruction + base64 image
    content = [
      %{type: "text", text: """
      请仔细分析以下八字命盘图片，提取结构化数据。

      需要提取的信息：
      1. 日主（日元）
      2. 四柱的天干和地支（年柱、月柱、日柱、时柱）
      3. 每个地支的藏干
      4. 每个天干对应的十神
      5. 特殊标记（空亡等）

      提取完成后，调用 submit_chart_data 工具提交JSON格式的结构化数据。
      """},
      %{type: "image", source: %{type: "base64", media_type: "image/png", data: state.chart_image_b64}}
    ]

    Worker.submit(chairman_pid, content,
      tools: state.chairman_tools,
      model: config.model
    )

    %{state | chairman_task: :parse}
  end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles. Some warnings about unused functions are fine at this stage.

- [ ] **Step 3: Commit**

```bash
git add lib/rho/demos/bazi/simulation.ex
git commit -m "feat(bazi): coordinator — begin simulation, spawn agents, chart parsing"
```

---

### Task 6: Simulation Coordinator — Dimension Proposal & Approval (simulation.ex, part 3)

**Files:**
- Modify: `lib/rho/demos/bazi/simulation.ex`

- [ ] **Step 1: Add chart parsed handler and dimension proposal flow**

Add these `handle_info` clauses to `simulation.ex`:

```elixir
  # --- Signal Handlers ---

  # Chart parsed by chairman
  @impl true
  def handle_info({:signal, %Jido.Signal{type: "rho.bazi." <> rest, data: data}}, %{status: :parsing_chart} = state) do
    if String.ends_with?(rest, ".chart.parsed") do
      Logger.info("[BaZi] Chart parsed successfully")

      state = %{state | chart_data: data.chart_data}

      # Spawn advisors and start dimension proposal
      state = spawn_advisors(state)
      state = start_dimension_proposal(state)

      {:noreply, %{state | status: :proposing_dimensions, chairman_task: nil}}
    else
      {:noreply, state}
    end
  end

  # Dimension proposed by an advisor
  def handle_info({:signal, %Jido.Signal{type: "rho.bazi." <> rest, data: data}}, %{status: :proposing_dimensions} = state) do
    if String.ends_with?(rest, ".dimensions.proposed") do
      role = data.role
      dims = data.dimensions
      Logger.info("[BaZi] #{role} proposed dimensions: #{inspect(dims)}")

      proposals = Map.put(state.dimension_proposals, role, dims)
      state = %{state | dimension_proposals: proposals}

      # Check if all advisors have proposed
      if map_size(proposals) >= length(@advisor_roles) do
        merged = Scoring.merge_dimensions(proposals)
        Logger.info("[BaZi] Merged dimensions: #{inspect(merged)}")

        Comms.publish("rho.bazi.#{state.session_id}.dimensions.merged", %{
          session_id: state.session_id,
          dimensions: merged
        }, source: "/session/#{state.session_id}")

        {:noreply, %{state | dimensions: merged, status: :awaiting_dimension_approval}}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # User approves dimensions
  @impl true
  def handle_cast({:approve_dimensions, dimensions}, %{status: :awaiting_dimension_approval} = state) do
    Logger.info("[BaZi] User approved dimensions: #{inspect(dimensions)}")

    Comms.publish("rho.bazi.#{state.session_id}.dimensions.approved", %{
      session_id: state.session_id,
      dimensions: dimensions
    }, source: "/session/#{state.session_id}")

    state = %{state | dimensions: dimensions}
    state = start_round(state, 1)

    {:noreply, %{state | status: :round_1}}
  end

  # --- Private: Dimension Proposal ---

  defp start_dimension_proposal(state) do
    chart_text = format_chart_data(state.chart_data)
    options_text = Enum.join(state.user_options, "\n")

    prompt = """
    八字命盘数据：
    #{chart_text}

    用户的问题：#{state.user_question}

    选项：
    #{options_text}

    请根据以上八字命盘和用户的具体问题，提议3-5个最相关的评分维度。
    这些维度应该是能够通过八字分析来评估的方面。

    例如对于职业选择，可能的维度包括：事业发展、财运、五行契合、时机、风险等。
    请根据实际问题选择最合适的维度。

    调用 submit_dimensions 工具提交你的维度建议。
    """

    state.advisors
    |> Enum.with_index()
    |> Enum.each(fn {{role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)
      if pid do
        role_info = Map.get(state.advisor_tools, role, %{})
        Worker.submit(pid, prompt,
          tools: role_info[:tools],
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end)

    state
  end

  defp format_chart_data(nil), do: "（未解析）"

  defp format_chart_data(chart_data) do
    day_master = chart_data["day_master"] || "未知"
    notes = chart_data["notes"] || ""

    pillars_text =
      ["year", "month", "day", "hour"]
      |> Enum.map(fn key ->
        pillar = get_in(chart_data, ["pillars", key]) || %{}
        label = case key do
          "year" -> "年柱"
          "month" -> "月柱"
          "day" -> "日柱"
          "hour" -> "时柱"
        end

        stem = pillar["stem"] || "?"
        branch = pillar["branch"] || "?"
        hidden = pillar["hidden_stems"] || []
        ten_god = pillar["ten_god"] || "?"

        "#{label}: #{stem}#{branch} (十神: #{ten_god}, 藏干: #{Enum.join(hidden, "、")})"
      end)
      |> Enum.join("\n")

    """
    日主: #{day_master}
    #{pillars_text}
    #{if notes != "", do: "备注: #{notes}", else: ""}
    """
  end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add lib/rho/demos/bazi/simulation.ex
git commit -m "feat(bazi): coordinator — chart parsed handler, dimension proposal, user approval"
```

---

### Task 7: Simulation Coordinator — Rounds, Scoring, Debate (simulation.ex, part 4)

**Files:**
- Modify: `lib/rho/demos/bazi/simulation.ex`

Reference: `lib/rho/demos/hiring/simulation.ex` — `start_round/2`, `maybe_advance_round/1`, score handling, timeout/nudge.

- [ ] **Step 1: Add round orchestration, score handling, debate, and timeout logic**

Add to `simulation.ex`:

```elixir
  # Scores submitted by an advisor
  def handle_info({:signal, %Jido.Signal{type: "rho.bazi." <> rest, data: data}}, %{status: status} = state)
      when status in [:round_1, :round_2] do
    cond do
      String.ends_with?(rest, ".scores.submitted") ->
        role = data.role
        round = data.round
        scores = data.scores
        Logger.info("[BaZi] #{role} submitted scores for round #{round}")

        state = record_scores(state, role, round, scores)
        state = maybe_advance_round(state)
        {:noreply, state}

      String.ends_with?(rest, ".user_info.requested") ->
        Logger.info("[BaZi] #{data.from_advisor} requests user info: #{data.question}")
        # Surface to UI — the LiveView will show the chairman popup
        {:noreply, %{state | pending_user_info: %{from_advisor: data.from_advisor, question: data.question}}}

      true ->
        {:noreply, state}
    end
  end

  # User replies to advisor's info request
  @impl true
  def handle_cast({:user_reply, answer}, state) when state.pending_user_info != nil do
    Logger.info("[BaZi] User replied to info request: #{String.slice(answer, 0, 100)}")

    # Broadcast reply to all advisors via send_message from chairman
    for {_role, agent_id} <- state.advisors do
      pid = Worker.whereis(agent_id)
      if pid do
        # Deliver as a signal so it appears in the advisor's mailbox
        signal = %{
          type: "message",
          data: %{
            from: state.chairman_agent_id,
            from_role: :bazi_chairman,
            content: "用户回复：#{answer}"
          }
        }
        Worker.deliver_signal(pid, signal)
      end
    end

    Comms.publish("rho.bazi.#{state.session_id}.user_info.replied", %{
      session_id: state.session_id,
      answer: answer,
      original_question: state.pending_user_info.question
    }, source: "/session/#{state.session_id}")

    {:noreply, %{state | pending_user_info: nil}}
  end

  # Round timeout check
  @impl true
  def handle_info({:check_round_timeout, round_num}, %{status: status, round: current_round} = state)
      when status in [:round_1, :round_2] and round_num == current_round do
    submitted_roles =
      state.scores
      |> Map.keys()
      |> Enum.filter(fn {_role, r} -> r == state.round end)
      |> Enum.map(fn {role, _r} -> role end)

    missing = Map.keys(state.advisors) -- submitted_roles

    if missing != [] do
      Logger.warning("[BaZi] Round #{state.round} timeout — nudging #{length(missing)} advisors: #{inspect(missing)}")

      chairman_pid = Worker.whereis(state.chairman_agent_id)
      config = Rho.Config.agent(:bazi_chairman)

      if chairman_pid do
        missing_names = Enum.map_join(missing, "、", fn role ->
          case role do
            :bazi_advisor_qwen -> "Qwen顾问"
            :bazi_advisor_deepseek -> "DeepSeek顾问"
            :bazi_advisor_gpt -> "GPT-5.4顾问"
            other -> Atom.to_string(other)
          end
        end)

        Worker.submit(chairman_pid,
          "请向以下顾问发送消息，催促他们立即提交第#{state.round}轮评分：#{missing_names}。发送消息后调用 finish。不要做其他事情。",
          tools: state.chairman_tools,
          model: config.model
        )
      end

      ref = Process.send_after(self(), {:check_round_timeout, round_num}, @nudge_retry_ms)
      {:noreply, %{state | round_timer_ref: ref, chairman_task: :nudge}}
    else
      {:noreply, state}
    end
  end

  # Catch-all for stale timeout messages
  def handle_info({:check_round_timeout, _}, state), do: {:noreply, state}

  # Task completion (chairman)
  def handle_info({:signal, %Jido.Signal{type: "rho.task." <> _rest, data: data}}, %{status: :completed} = state) do
    if data.agent_id == state.chairman_agent_id do
      cond do
        state.chairman_task == :nudge ->
          Logger.debug("[BaZi] Nudge completed")
          if state.summary_pending do
            send(self(), :send_deferred_summary)
            {:noreply, %{state | chairman_task: :summary, summary_pending: false}}
          else
            {:noreply, %{state | chairman_task: nil}}
          end

        state.chairman_task == :summary and not state.summary_delivered ->
          Logger.info("[BaZi] Chairman produced summary")
          Comms.publish("rho.bazi.#{state.session_id}.chairman.summary", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :bazi_chairman,
            text: data.result
          }, source: "/session/#{state.session_id}")
          {:noreply, %{state | summary_delivered: true, chairman_task: nil}}

        state.chairman_task == :chat and String.starts_with?(to_string(data.result), "error:") and state.retry_count < 3 ->
          Logger.warning("[BaZi] Chairman chat failed (attempt #{state.retry_count + 1}/3)")
          Process.send_after(self(), {:retry_ask, state.last_question}, 2_000)
          {:noreply, %{state | retry_count: state.retry_count + 1}}

        state.chairman_task == :chat and String.starts_with?(to_string(data.result), "error:") ->
          Logger.error("[BaZi] Chairman failed after 3 retries")
          Comms.publish("rho.bazi.#{state.session_id}.chairman.reply", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :bazi_chairman,
            text: "抱歉，目前无法回答您的问题。请稍后再试。"
          }, source: "/session/#{state.session_id}")
          {:noreply, %{state | pending_replies: state.pending_replies - 1, retry_count: 0, chairman_task: nil}}

        state.chairman_task == :chat ->
          Logger.info("[BaZi] Chairman replied to user question")
          Comms.publish("rho.bazi.#{state.session_id}.chairman.reply", %{
            session_id: state.session_id,
            agent_id: state.chairman_agent_id,
            agent_role: :bazi_chairman,
            text: data.result
          }, source: "/session/#{state.session_id}")
          {:noreply, %{state | pending_replies: state.pending_replies - 1, chairman_task: nil}}

        true ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Deferred summary (nudge was in-flight when round completed)
  def handle_info(:send_deferred_summary, state) do
    if state.deferred_closing_prompt do
      send_summary_to_chairman(state, state.deferred_closing_prompt)
      {:noreply, %{state | deferred_closing_prompt: nil}}
    else
      {:noreply, state}
    end
  end

  # Retry failed chairman chat
  def handle_info({:retry_ask, question}, %{status: :completed} = state) do
    handle_cast({:ask, question}, state)
  end

  # Catch-all for unmatched signals
  def handle_info({:signal, _}, state), do: {:noreply, state}

  # --- Private: Round Orchestration ---

  defp start_round(state, round_num) do
    prompt = round_prompt(round_num, state)

    if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

    Comms.publish("rho.bazi.#{state.session_id}.round.started", %{
      session_id: state.session_id,
      round: round_num
    }, source: "/session/#{state.session_id}")

    Logger.info("[BaZi] Starting round #{round_num}")

    state.advisors
    |> Enum.with_index()
    |> Enum.each(fn {{role, agent_id}, idx} ->
      if idx > 0, do: Process.sleep(1_000)
      pid = Worker.whereis(agent_id)
      if pid do
        role_info = Map.get(state.advisor_tools, role, %{})
        Worker.submit(pid, prompt,
          tools: role_info[:tools],
          system_prompt: role_info[:config] && role_info.config.system_prompt,
          model: role_info[:config] && role_info.config.model
        )
      end
    end)

    ref = Process.send_after(self(), {:check_round_timeout, round_num}, @round_timeout_ms)

    %{state | round: round_num, round_started_at: System.monotonic_time(:millisecond), round_timer_ref: ref}
  end

  defp round_prompt(1, state) do
    chart_text = format_chart_data(state.chart_data)
    options_text = Enum.join(state.user_options, "\n")
    dims_text = Enum.join(state.dimensions, "、")

    """
    八字命盘数据：
    #{chart_text}

    用户的问题：#{state.user_question}

    选项：
    #{options_text}

    已确认的评分维度：#{dims_text}

    请独立分析此八字命盘，评估每个选项在各维度上的优劣。

    分析步骤：
    1. 判断日主强弱
    2. 确定格局和用神
    3. 分析每个选项与命盘的五行关系
    4. 对每个选项的每个维度给出0-100的评分
    5. 提供详细的分析理由

    第一轮不要与其他顾问讨论，请独立完成分析。
    如需用户补充信息（如大运、流年等），请调用 request_user_info。
    完成后调用 submit_scores 提交评分（round: 1）。
    """
  end

  defp round_prompt(round_num, state) do
    chart_text = format_chart_data(state.chart_data)
    options_text = Enum.join(state.user_options, "\n")
    dims_text = Enum.join(state.dimensions, "、")
    score_table = Scoring.format_score_table(state.scores, round_num - 1, state.dimensions)
    disagreement = Scoring.build_disagreement_summary(state.scores, round_num - 1)

    disagreement_section =
      if disagreement == "" do
        "各顾问评分较为一致。"
      else
        "以下维度存在较大分歧（>20分）：\n#{disagreement}"
      end

    """
    第#{round_num}轮：委员会已完成初步评估。以下是上一轮各顾问的分析和评分：

    #{score_table}

    #{disagreement_section}

    八字命盘数据：
    #{chart_text}

    用户的问题：#{state.user_question}

    选项：
    #{options_text}

    评分维度：#{dims_text}

    请认真考虑其他顾问的观点和分析。如有不同意见，使用 send_message 与对方讨论具体的命理解读。
    当其他顾问提出有说服力的论点时，请真诚地重新考虑并调整评分。
    如需用户补充信息，请调用 request_user_info。
    讨论完成后，调用 submit_scores 提交修改后的评分（round: #{round_num}）。
    """
  end

  defp record_scores(state, role, round, scores) do
    %{state | scores: Map.put(state.scores, {role, round}, scores)}
  end

  defp maybe_advance_round(state) do
    expected = map_size(state.advisors)

    submitted =
      state.scores
      |> Map.keys()
      |> Enum.count(fn {_role, r} -> r == state.round end)

    if submitted >= expected do
      if state.round >= state.max_rounds do
        if state.round_timer_ref, do: Process.cancel_timer(state.round_timer_ref)

        # Stop all advisor agents
        for {_role, agent_id} <- state.advisors do
          pid = Worker.whereis(agent_id)
          if pid do
            try do
              GenServer.stop(pid, :normal, 5_000)
            catch
              :exit, _ -> :ok
            end
          end
        end

        Logger.info("[BaZi] Advisors stopped. Preparing summary.")

        aggregated = Scoring.aggregate_scores(state.scores, state.round)
        closing_prompt = build_closing_prompt(state, aggregated)

        Comms.publish("rho.bazi.#{state.session_id}.simulation.completed", %{
          session_id: state.session_id,
          aggregated_scores: aggregated
        }, source: "/session/#{state.session_id}")

        if state.chairman_task == :nudge do
          Logger.info("[BaZi] Nudge in-flight — deferring summary")
          %{state | status: :completed, round_timer_ref: nil, summary_pending: true, deferred_closing_prompt: closing_prompt}
        else
          send_summary_to_chairman(state, closing_prompt)
          %{state | status: :completed, round_timer_ref: nil, chairman_task: :summary}
        end
      else
        start_round(state, state.round + 1)
        |> Map.put(:status, if(state.round + 1 == 2, do: :round_2, else: :round_1))
      end
    else
      Logger.info("[BaZi] Waiting for scores: #{submitted}/#{expected} for round #{state.round}")
      state
    end
  end

  defp send_summary_to_chairman(state, closing_prompt) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)
    config = Rho.Config.agent(:bazi_chairman)

    if chairman_pid do
      Worker.submit(chairman_pid, closing_prompt,
        tools: state.chairman_tools,
        model: config.model
      )
    end
  end

  defp build_closing_prompt(state, aggregated) do
    score_table = Scoring.format_score_table(state.scores, state.round, state.dimensions)
    disagreement = Scoring.build_disagreement_summary(state.scores, state.round)

    aggregated_text =
      Enum.map_join(aggregated, "\n", fn {option, dims} ->
        composite = dims["composite"]
        dim_scores = dims |> Map.delete("composite") |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)
        "#{option}: 综合#{composite}分 (#{dim_scores})"
      end)

    """
    三位顾问已完成全部评估。请撰写最终总结报告。

    ## 各顾问评分明细
    #{score_table}

    ## 综合评分
    #{aggregated_text}

    #{if disagreement != "", do: "## 主要分歧\n#{disagreement}\n", else: ""}

    请撰写全面的总结报告，包括：
    1. 各选项的综合评估
    2. 三位顾问的主要共识
    3. 关键分歧点及其命理依据
    4. 你的综合建议
    5. 需要注意的风险和时机因素

    完成后调用 finish 提交报告。报告内容就是用户将看到的最终分析，请直接面向用户撰写。
    """
  end
```

- [ ] **Step 2: Add post-simulation Q&A handler**

Add to `simulation.ex`:

```elixir
  # Post-simulation Q&A
  @impl true
  def handle_cast({:ask, question}, %{status: :completed} = state) do
    chairman_pid = Worker.whereis(state.chairman_agent_id)

    if chairman_pid do
      prompt = build_chat_prompt(state, question)
      config = Rho.Config.agent(:bazi_chairman)

      chat_tools = state.chairman_tools ++ advisor_search_tools(state)

      Worker.submit(chairman_pid, prompt,
        tools: chat_tools,
        model: config.model
      )

      {:noreply, %{state |
        pending_replies: state.pending_replies + 1,
        last_question: question,
        retry_count: 0,
        chairman_task: :chat
      }}
    else
      {:noreply, state}
    end
  end

  defp build_chat_prompt(state, question) do
    memory_mod = Rho.Config.memory_module()
    score_table = Scoring.format_score_table(state.scores, state.round, state.dimensions)

    chairman_history = memory_mod.history("agent_#{state.chairman_agent_id}")
    prior_chat = summarize_chairman_chat(chairman_history)

    prior_section =
      if prior_chat == "" do
        ""
      else
        "\n### 之前的问答\n#{prior_chat}\n"
      end

    search_tool_list =
      state.advisors
      |> Enum.map_join("\n", fn {role, _id} ->
        name = case role do
          :bazi_advisor_qwen -> "Qwen顾问"
          :bazi_advisor_deepseek -> "DeepSeek顾问"
          :bazi_advisor_gpt -> "GPT-5.4顾问"
          _ -> Atom.to_string(role)
        end
        "- `search_#{role}_history(query)` — 搜索#{name}的完整对话记录"
      end)

    """
    你是八字决策分析的主席，正在回答用户的后续提问。

    ### 最终评分
    #{score_table}
    #{prior_section}
    ### 顾问历史搜索工具
    你有以下工具可以查找各顾问的详细分析和辩论记录：
    #{search_tool_list}

    搜索提示：使用1-2个关键词（如"五行"、"财运"、"选项A"），不要使用完整句子。

    ### 用户当前问题
    #{question}

    请简洁、有针对性地回答。引用具体的顾问观点和评分。
    完成后调用 finish，finish的参数内容就是用户将直接看到的回答。
    """
  end

  defp advisor_search_tools(state) do
    Enum.map(state.advisors, fn {role, agent_id} ->
      name = case role do
        :bazi_advisor_qwen -> "Qwen顾问"
        :bazi_advisor_deepseek -> "DeepSeek顾问"
        :bazi_advisor_gpt -> "GPT-5.4顾问"
        _ -> Atom.to_string(role)
      end

      %{
        tool:
          ReqLLM.tool(
            name: "search_#{role}_history",
            description: "搜索#{name}的完整对话记录",
            parameter_schema: [
              query: [type: :string, required: true, doc: "搜索关键词"],
              limit: [type: :integer, doc: "最大返回条数（默认10）"]
            ],
            callback: fn _args -> :ok end
          ),
        execute: fn args ->
          query = args["query"] || args[:query] || ""
          limit = args["limit"] || args[:limit] || 10
          results = Rho.Tape.Service.search("agent_#{agent_id}", query, limit)

          if results == [] do
            {:ok, "未找到匹配\"#{query}\"的记录。"}
          else
            formatted =
              Enum.map_join(results, "\n---\n", fn entry ->
                "[#{entry.date}] [#{entry.payload["role"]}] #{entry.payload["content"]}"
              end)
            {:ok, "找到#{length(results)}条记录:\n#{formatted}"}
          end
        end
      }
    end)
  end

  defp summarize_chairman_chat(history) do
    history
    |> Enum.filter(fn msg -> msg["role"] == "assistant" end)
    |> Enum.map(fn msg -> msg["content"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add lib/rho/demos/bazi/simulation.ex
git commit -m "feat(bazi): coordinator — rounds, scoring, debate, timeout, Q&A"
```

---

### Task 8: LiveView — Event Projection (bazi_projection.ex)

**Files:**
- Create: `lib/rho_web/live/bazi_projection.ex`

Reference: `lib/rho_web/live/observatory_projection.ex` for the `project/3` → `normalize_type/2` → `do_project/3` pattern.

- [ ] **Step 1: Create bazi_projection.ex**

```elixir
defmodule RhoWeb.BaziProjection do
  @moduledoc """
  Projects BaZi simulation signal bus events onto LiveView socket assigns.
  """

  import Phoenix.Component, only: [assign: 3]

  def project(socket, type, data) do
    normalized = normalize_type(socket.assigns[:session_id], type)
    do_project(socket, normalized, data)
  end

  defp normalize_type(nil, type), do: type
  defp normalize_type(sid, type), do: String.replace(type, ".#{sid}.", ".")

  # Simulation started
  defp do_project(socket, "rho.bazi.simulation.started", data) do
    socket
    |> assign(:simulation_status, :running)
    |> assign(:user_options, data[:options] || data["options"] || [])
    |> assign(:user_question, data[:question] || data["question"] || "")
  end

  # Chart parsed
  defp do_project(socket, "rho.bazi.chart.parsed", data) do
    assign(socket, :chart_data, data[:chart_data] || data["chart_data"])
  end

  # Chairman message (hardcoded opening, etc.)
  defp do_project(socket, "rho.bazi.chairman.message", data) do
    entry = %{
      type: :chairman,
      agent_role: :bazi_chairman,
      agent_id: data[:agent_id],
      text: data[:text] || data["text"],
      timestamp: System.monotonic_time(:millisecond)
    }

    assign(socket, :timeline, (socket.assigns[:timeline] || []) ++ [entry])
  end

  # Dimensions merged (awaiting user approval)
  defp do_project(socket, "rho.bazi.dimensions.merged", data) do
    dims = data[:dimensions] || data["dimensions"] || []

    socket
    |> assign(:proposed_dimensions, dims)
    |> assign(:phase, :awaiting_dimension_approval)
  end

  # Dimensions approved
  defp do_project(socket, "rho.bazi.dimensions.approved", data) do
    dims = data[:dimensions] || data["dimensions"] || []
    assign(socket, :dimensions, dims)
  end

  # Round started
  defp do_project(socket, "rho.bazi.round.started", data) do
    round = data[:round] || data["round"]
    phase = case round do
      1 -> :round_1
      2 -> :round_2
      _ -> :round_1
    end

    entry = %{
      type: :round_start,
      text: "第#{round}轮开始",
      round: round,
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:round, round)
    |> assign(:phase, phase)
    |> assign(:timeline, (socket.assigns[:timeline] || []) ++ [entry])
  end

  # Scores submitted
  defp do_project(socket, "rho.bazi.scores.submitted", data) do
    role = data[:role] || data["role"]
    round = data[:round] || data["round"]
    scores_data = data[:scores] || data["scores"] || %{}

    role_key = advisor_key(role)

    # Update scores: %{option => %{role_key => %{dim => score}}}
    scores =
      Enum.reduce(scores_data, socket.assigns[:scores] || %{}, fn {option, dim_scores}, acc ->
        option_data = Map.get(acc, option, %{})

        # Store previous scores for delta display
        prev_key = :"prev_#{role_key}"
        prev = Map.get(option_data, role_key)

        option_data =
          option_data
          |> Map.put(prev_key, prev)
          |> Map.put(role_key, dim_scores)

        Map.put(acc, option, option_data)
      end)

    # Add timeline entries
    timeline_entries =
      Enum.map(scores_data, fn {option, dim_scores} ->
        rationale = dim_scores["rationale"] || ""
        %{
          type: :score,
          agent_role: role,
          text: "#{format_role(role)}对#{option}的评分: #{String.slice(rationale, 0, 120)}",
          round: round,
          timestamp: System.monotonic_time(:millisecond)
        }
      end)

    socket
    |> assign(:scores, scores)
    |> assign(:timeline, (socket.assigns[:timeline] || []) ++ timeline_entries)
  end

  # User info requested by advisor
  defp do_project(socket, "rho.bazi.user_info.requested", data) do
    socket
    |> assign(:pending_user_question, data[:question] || data["question"])
    |> assign(:pending_user_question_from, data[:from_advisor] || data["from_advisor"])
  end

  # User info replied
  defp do_project(socket, "rho.bazi.user_info.replied", data) do
    entry = %{
      type: :user_reply,
      text: "用户回复：#{data[:answer] || data["answer"]}",
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:pending_user_question, nil)
    |> assign(:pending_user_question_from, nil)
    |> assign(:timeline, (socket.assigns[:timeline] || []) ++ [entry])
  end

  # Chairman summary
  defp do_project(socket, "rho.bazi.chairman.summary", data) do
    entry = %{
      type: :chairman_summary,
      agent_role: :bazi_chairman,
      text: data[:text] || data["text"],
      timestamp: System.monotonic_time(:millisecond)
    }

    socket
    |> assign(:phase, :completed)
    |> assign(:chairman_ready, true)
    |> assign(:timeline, (socket.assigns[:timeline] || []) ++ [entry])
  end

  # Chairman reply (post-sim Q&A)
  defp do_project(socket, "rho.bazi.chairman.reply", data) do
    entry = %{
      type: :chairman_reply,
      agent_role: :bazi_chairman,
      text: data[:text] || data["text"],
      timestamp: System.monotonic_time(:millisecond)
    }

    assign(socket, :timeline, (socket.assigns[:timeline] || []) ++ [entry])
  end

  # Simulation completed
  defp do_project(socket, "rho.bazi.simulation.completed", _data) do
    assign(socket, :simulation_status, :completed)
  end

  # Agent events (status changes) — reuse existing observatory patterns
  defp do_project(socket, "rho.agent." <> _, data) do
    agents = socket.assigns[:agents] || %{}
    agent_id = data[:agent_id] || data["agent_id"]

    if agent_id do
      agent = Map.get(agents, agent_id, %{id: agent_id})
      agent = Map.merge(agent, Map.take(data, [:status, :step, :mailbox, :tool, "status", "step", "mailbox", "tool"]))
      assign(socket, :agents, Map.put(agents, agent_id, agent))
    else
      socket
    end
  end

  # Catch-all
  defp do_project(socket, _type, _data), do: socket

  # --- Helpers ---

  defp advisor_key(:bazi_advisor_qwen), do: :qwen
  defp advisor_key(:bazi_advisor_deepseek), do: :deepseek
  defp advisor_key(:bazi_advisor_gpt), do: :gpt
  defp advisor_key(role) when is_binary(role), do: advisor_key(String.to_existing_atom(role))
  defp advisor_key(role), do: role

  defp format_role(:bazi_advisor_qwen), do: "Qwen"
  defp format_role(:bazi_advisor_deepseek), do: "DeepSeek"
  defp format_role(:bazi_advisor_gpt), do: "GPT-5.4"
  defp format_role(role), do: to_string(role)
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/live/bazi_projection.ex
git commit -m "feat(bazi): event projection — signal bus events to LiveView assigns"
```

---

### Task 9: LiveView — BaziLive (bazi_live.ex)

**Files:**
- Create: `lib/rho_web/live/bazi_live.ex`

Reference: `lib/rho_web/live/observatory_live.ex` for mount, subscription, signal handling, and event handler patterns.

- [ ] **Step 1: Create bazi_live.ex**

Create `lib/rho_web/live/bazi_live.ex`:

```elixir
defmodule RhoWeb.BaziLive do
  use RhoWeb, :live_view

  alias Rho.Demos.Bazi.Simulation
  alias RhoWeb.BaziProjection

  @impl true
  def mount(%{"session_id" => sid}, _session, socket) do
    socket =
      socket
      |> assign(:session_id, sid)
      |> assign(:simulation_status, :not_started)
      |> assign(:phase, :not_started)
      |> assign(:round, 0)
      |> assign(:timeline, [])
      |> assign(:scores, %{})
      |> assign(:agents, %{})
      |> assign(:chart_data, nil)
      |> assign(:dimensions, [])
      |> assign(:proposed_dimensions, [])
      |> assign(:user_options, [])
      |> assign(:user_question, "")
      |> assign(:chairman_ready, false)
      |> assign(:pending_user_question, nil)
      |> assign(:pending_user_question_from, nil)

    if connected?(socket) do
      subs =
        [
          "rho.agent.#{sid}.*",
          "rho.task.#{sid}.*",
          "rho.bazi.#{sid}.**"
        ]
        |> Enum.flat_map(fn pattern ->
          case Rho.Comms.subscribe(pattern) do
            {:ok, sub_id} -> [sub_id]
            {:error, _} -> []
          end
        end)

      Process.send_after(self(), :tick, 500)

      socket = assign(socket, :subscriptions, subs)

      # Start simulation coordinator if not already running
      case GenServer.whereis(Simulation.via(sid)) do
        nil ->
          {:ok, _} = Simulation.start_link(sid)
          {:ok, socket}

        _pid ->
          {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    sid = Rho.Session.new_session_id()
    {:ok, push_navigate(socket, to: ~p"/bazi/#{sid}")}
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("begin_simulation", %{"image" => image_data, "options" => options, "question" => question}, socket) do
    sid = socket.assigns.session_id

    # Parse options (newline or comma separated)
    parsed_options =
      options
      |> String.split(~r/[\n,]/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Simulation.begin_simulation(sid, %{image_b64: image_data, options: parsed_options, question: question}) do
      :ok -> {:noreply, socket}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "无法开始模拟: #{inspect(reason)}")}
    end
  end

  def handle_event("approve_dimensions", %{"dimensions" => dimensions_json}, socket) do
    case Jason.decode(dimensions_json) do
      {:ok, dims} when is_list(dims) ->
        Simulation.approve_dimensions(socket.assigns.session_id, dims)
        {:noreply, assign(socket, :phase, :round_1)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reply_to_advisor", %{"answer" => answer}, socket) do
    answer = String.trim(answer)
    if answer != "" do
      Simulation.reply_to_advisor(socket.assigns.session_id, answer)
    end
    {:noreply, socket}
  end

  def handle_event("ask_chairman", %{"question" => question}, socket) do
    question = String.trim(question)
    if question != "" do
      Simulation.ask(socket.assigns.session_id, question)
    end
    {:noreply, socket}
  end

  # --- Signal Handling ---

  @impl true
  def handle_info({:signal, %Jido.Signal{type: type, data: data}}, socket) do
    socket = BaziProjection.project(socket, type, data)
    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bazi-observatory">
      <RhoWeb.BaziComponents.top_bar phase={@phase} round={@round} />

      <div class="bazi-layout">
        <div class="bazi-agents">
          <RhoWeb.BaziComponents.agent_panel agents={@agents} advisors={assigns[:advisors] || %{}} />
        </div>

        <div class="bazi-timeline">
          <RhoWeb.BaziComponents.timeline
            timeline={@timeline}
            phase={@phase}
            proposed_dimensions={@proposed_dimensions}
            pending_user_question={@pending_user_question}
            chairman_ready={@chairman_ready}
            simulation_status={@simulation_status}
          />
        </div>

        <div class="bazi-scoreboard">
          <RhoWeb.BaziComponents.scoreboard
            scores={@scores}
            dimensions={@dimensions}
            user_options={@user_options}
          />
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Add route**

Add to `lib/rho_web/router.ex` (find the existing live routes section):

```elixir
live "/bazi/:session_id", BaziLive
live "/bazi", BaziLive
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles (may warn about missing BaziComponents — that's next task).

- [ ] **Step 4: Commit**

```bash
git add lib/rho_web/live/bazi_live.ex lib/rho_web/router.ex
git commit -m "feat(bazi): LiveView — mount, event handlers, signal subscription, routing"
```

---

### Task 10: LiveView — BaziComponents (bazi_components.ex)

**Files:**
- Create: `lib/rho_web/live/bazi_components.ex`

Reference: `lib/rho_web/components/observatory_components.ex` for function component patterns.

- [ ] **Step 1: Create bazi_components.ex with all components**

Create `lib/rho_web/live/bazi_components.ex`:

```elixir
defmodule RhoWeb.BaziComponents do
  use Phoenix.Component

  # --- Top Bar ---

  attr :phase, :atom, required: true
  attr :round, :integer, required: true

  def top_bar(assigns) do
    ~H"""
    <div class="bazi-topbar">
      <span class="bazi-title">八字决策顾问</span>
      <span class="bazi-phase-indicator">
        <.phase_dot active={@phase in [:proposing_dimensions, :awaiting_dimension_approval]} label="维度" />
        <span class="bazi-phase-arrow">→</span>
        <.phase_dot active={@phase == :round_1} label="分析" />
        <span class="bazi-phase-arrow">→</span>
        <.phase_dot active={@phase == :round_2} label="辩论" />
        <span class="bazi-phase-arrow">→</span>
        <.phase_dot active={@phase == :completed} label="总结" />
      </span>
    </div>
    """
  end

  attr :active, :boolean, required: true
  attr :label, :string, required: true

  defp phase_dot(assigns) do
    ~H"""
    <span class={["bazi-phase-dot", @active && "active"]}>
      <%= if @active, do: "●", else: "○" %> <%= @label %>
    </span>
    """
  end

  # --- Agent Panel ---

  attr :agents, :map, required: true
  attr :advisors, :map, required: true

  def agent_panel(assigns) do
    ~H"""
    <div class="bazi-agent-panel">
      <div class="panel-label">顾问 Advisors</div>
      <.advisor_card name="Qwen" role={:bazi_advisor_qwen} color="blue" agents={@agents} advisors={@advisors} />
      <.advisor_card name="DeepSeek" role={:bazi_advisor_deepseek} color="green" agents={@agents} advisors={@advisors} />
      <.advisor_card name="GPT-5.4" role={:bazi_advisor_gpt} color="amber" agents={@agents} advisors={@advisors} />
      <hr class="bazi-divider" />
      <.chairman_card agents={@agents} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :role, :atom, required: true
  attr :color, :string, required: true
  attr :agents, :map, required: true
  attr :advisors, :map, required: true

  defp advisor_card(assigns) do
    agent_id = Map.get(assigns.advisors, assigns.role)
    agent = if agent_id, do: Map.get(assigns.agents, agent_id, %{}), else: %{}
    assigns = assign(assigns, :agent, agent)

    ~H"""
    <div class={"bazi-agent-card bazi-agent-#{@color}"}>
      <div class="bazi-agent-header">
        <strong><%= @name %></strong>
        <span class={"bazi-status bazi-status-#{Map.get(@agent, :status, "idle")}"}>
          <%= Map.get(@agent, :status, "idle") %>
        </span>
      </div>
      <div class="bazi-agent-meta">
        Step <%= Map.get(@agent, :step, 0) %> · 📬 <%= Map.get(@agent, :mailbox, 0) %>
      </div>
    </div>
    """
  end

  attr :agents, :map, required: true

  defp chairman_card(assigns) do
    ~H"""
    <div class="bazi-agent-card bazi-agent-purple">
      <strong>🎓 主席 Opus</strong>
      <div class="bazi-agent-meta">monitoring</div>
    </div>
    """
  end

  # --- Timeline ---

  attr :timeline, :list, required: true
  attr :phase, :atom, required: true
  attr :proposed_dimensions, :list, required: true
  attr :pending_user_question, :any, required: true
  attr :chairman_ready, :boolean, required: true
  attr :simulation_status, :atom, required: true

  def timeline(assigns) do
    ~H"""
    <div class="bazi-timeline-panel">
      <div class="panel-label">辩论实况 Timeline</div>

      <div class="bazi-timeline-feed">
        <%= for entry <- @timeline do %>
          <.timeline_entry entry={entry} />
        <% end %>
      </div>

      <%= if @phase == :awaiting_dimension_approval and @proposed_dimensions != [] do %>
        <.dimension_approval_form dimensions={@proposed_dimensions} />
      <% end %>

      <%= if @pending_user_question do %>
        <.chairman_popup question={@pending_user_question} />
      <% end %>

      <%= if @simulation_status == :completed and @chairman_ready do %>
        <.chairman_qa_input />
      <% end %>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp timeline_entry(assigns) do
    ~H"""
    <div class={"bazi-timeline-entry bazi-entry-#{@entry.type}"}>
      <%= case @entry.type do %>
        <% :round_start -> %>
          <div class="bazi-round-marker">— <%= @entry.text %> —</div>
        <% :chairman -> %>
          <div class="bazi-msg bazi-msg-chairman">
            <div class="bazi-msg-sender">🎓 主席</div>
            <div class="bazi-msg-text"><%= @entry.text %></div>
          </div>
        <% :chairman_summary -> %>
          <div class="bazi-msg bazi-msg-chairman bazi-msg-summary">
            <div class="bazi-msg-sender">🎓 主席总结</div>
            <div class="bazi-msg-text"><%= @entry.text %></div>
          </div>
        <% :chairman_reply -> %>
          <div class="bazi-msg bazi-msg-chairman">
            <div class="bazi-msg-sender">🎓 主席</div>
            <div class="bazi-msg-text"><%= @entry.text %></div>
          </div>
        <% :score -> %>
          <div class={"bazi-msg bazi-msg-#{role_color(@entry.agent_role)}"}>
            <div class="bazi-msg-sender"><%= format_role(@entry.agent_role) %></div>
            <div class="bazi-msg-text"><%= @entry.text %></div>
          </div>
        <% :debate -> %>
          <div class={"bazi-msg bazi-msg-#{role_color(@entry.agent_role)}"}>
            <div class="bazi-msg-sender"><%= format_role(@entry.agent_role) %> → <%= @entry[:target] || "All" %></div>
            <div class="bazi-msg-text"><%= @entry.text %></div>
          </div>
        <% :user_reply -> %>
          <div class="bazi-msg bazi-msg-user">
            <div class="bazi-msg-sender">👤 用户</div>
            <div class="bazi-msg-text"><%= @entry.text %></div>
          </div>
        <% _ -> %>
          <div class="bazi-msg"><%= @entry.text %></div>
      <% end %>
    </div>
    """
  end

  attr :dimensions, :list, required: true

  defp dimension_approval_form(assigns) do
    ~H"""
    <div class="bazi-dimension-approval">
      <div class="bazi-popup-title">🎓 主席提议以下评分维度：</div>
      <ul class="bazi-dim-list">
        <%= for dim <- @dimensions do %>
          <li><%= dim %></li>
        <% end %>
      </ul>
      <form phx-submit="approve_dimensions">
        <input type="hidden" name="dimensions" value={Jason.encode!(@dimensions)} />
        <button type="submit" class="bazi-btn">确认维度</button>
      </form>
    </div>
    """
  end

  attr :question, :string, required: true

  defp chairman_popup(assigns) do
    ~H"""
    <div class="bazi-chairman-popup">
      <div class="bazi-popup-title">🎓 主席提问：</div>
      <div class="bazi-popup-question"><%= @question %></div>
      <form phx-submit="reply_to_advisor">
        <input type="text" name="answer" placeholder="输入回复..." class="bazi-input" autocomplete="off" />
        <button type="submit" class="bazi-btn">发送</button>
      </form>
    </div>
    """
  end

  defp chairman_qa_input(assigns) do
    ~H"""
    <div class="bazi-qa-input">
      <form phx-submit="ask_chairman">
        <input type="text" name="question" placeholder="向主席提问..." class="bazi-input" autocomplete="off" />
        <button type="submit" class="bazi-btn">提问</button>
      </form>
    </div>
    """
  end

  # --- Scoreboard ---

  attr :scores, :map, required: true
  attr :dimensions, :list, required: true
  attr :user_options, :list, required: true

  def scoreboard(assigns) do
    ~H"""
    <div class="bazi-scoreboard-panel">
      <div class="panel-label">评分板 Scoreboard</div>

      <%= if @dimensions == [] do %>
        <div class="bazi-empty">等待维度确认...</div>
      <% else %>
        <%= for option <- @user_options do %>
          <.option_score_table option={option} scores={@scores} dimensions={@dimensions} />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :option, :string, required: true
  attr :scores, :map, required: true
  attr :dimensions, :list, required: true

  defp option_score_table(assigns) do
    option_scores = Map.get(assigns.scores, assigns.option, %{})
    assigns = assign(assigns, :option_scores, option_scores)

    ~H"""
    <div class="bazi-option-table">
      <div class="bazi-option-title"><%= @option %></div>
      <table class="bazi-score-table">
        <thead>
          <tr>
            <th></th>
            <%= for dim <- @dimensions do %>
              <th><%= String.slice(dim, 0, 4) %></th>
            <% end %>
            <th>综合</th>
          </tr>
        </thead>
        <tbody>
          <.advisor_score_row name="Qwen" role_key={:qwen} dims={@dimensions} option_scores={@option_scores} color="blue" />
          <.advisor_score_row name="DeepSeek" role_key={:deepseek} dims={@dimensions} option_scores={@option_scores} color="green" />
          <.advisor_score_row name="GPT-5.4" role_key={:gpt} dims={@dimensions} option_scores={@option_scores} color="amber" />
          <.average_row dims={@dimensions} option_scores={@option_scores} />
        </tbody>
      </table>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :role_key, :atom, required: true
  attr :dims, :list, required: true
  attr :option_scores, :map, required: true
  attr :color, :string, required: true

  defp advisor_score_row(assigns) do
    dim_data = Map.get(assigns.option_scores, assigns.role_key, %{})
    scores = Enum.map(assigns.dims, fn d -> Map.get(dim_data, d) end)
    numeric = Enum.filter(scores, &is_number/1)
    composite = if numeric == [], do: nil, else: round(Enum.sum(numeric) / length(numeric))
    assigns = assign(assigns, scores: scores, composite: composite)

    ~H"""
    <tr class={"bazi-row-#{@color}"}>
      <td><%= @name %></td>
      <%= for score <- @scores do %>
        <td class="bazi-score-cell"><%= score || "-" %></td>
      <% end %>
      <td class="bazi-score-composite"><%= @composite || "-" %></td>
    </tr>
    """
  end

  attr :dims, :list, required: true
  attr :option_scores, :map, required: true

  defp average_row(assigns) do
    avgs =
      Enum.map(assigns.dims, fn dim ->
        values =
          [:qwen, :deepseek, :gpt]
          |> Enum.map(fn key -> get_in(assigns.option_scores, [key, dim]) end)
          |> Enum.filter(&is_number/1)

        if values == [], do: nil, else: round(Enum.sum(values) / length(values))
      end)

    numeric = Enum.filter(avgs, &is_number/1)
    composite = if numeric == [], do: nil, else: round(Enum.sum(numeric) / length(numeric))
    assigns = assign(assigns, avgs: avgs, composite: composite)

    ~H"""
    <tr class="bazi-row-avg">
      <td>平均</td>
      <%= for avg <- @avgs do %>
        <td class="bazi-score-cell"><%= avg || "-" %></td>
      <% end %>
      <td class="bazi-score-composite"><%= @composite || "-" %></td>
    </tr>
    """
  end

  # --- Helpers ---

  defp format_role(:bazi_advisor_qwen), do: "Qwen"
  defp format_role(:bazi_advisor_deepseek), do: "DeepSeek"
  defp format_role(:bazi_advisor_gpt), do: "GPT-5.4"
  defp format_role(role), do: to_string(role)

  defp role_color(:bazi_advisor_qwen), do: "blue"
  defp role_color(:bazi_advisor_deepseek), do: "green"
  defp role_color(:bazi_advisor_gpt), do: "amber"
  defp role_color(:bazi_chairman), do: "purple"
  defp role_color(_), do: "gray"
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --no-deps-check`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add lib/rho_web/live/bazi_components.ex
git commit -m "feat(bazi): UI components — agent cards, scoreboard, timeline, chairman popup"
```

---

### Task 11: CSS Styling

**Files:**
- Modify: `lib/rho_web/inline_css.ex` (or wherever Observatory CSS lives)

Reference: Check existing Observatory CSS patterns in `lib/rho_web/inline_css.ex`.

- [ ] **Step 1: Read existing inline_css.ex to understand CSS injection pattern**

Run: read `lib/rho_web/inline_css.ex` to find how Observatory CSS is organized.

- [ ] **Step 2: Add BaZi-specific CSS**

Add CSS for the BaZi observatory classes (`.bazi-observatory`, `.bazi-layout`, `.bazi-topbar`, `.bazi-agent-card`, `.bazi-timeline-feed`, `.bazi-score-table`, `.bazi-chairman-popup`, etc.) following the existing Observatory styling patterns. The three-column layout uses CSS grid:

```css
.bazi-layout {
  display: grid;
  grid-template-columns: 200px 1fr 320px;
  min-height: calc(100vh - 60px);
  gap: 0;
}
```

Match the existing Observatory color scheme and card styles. Agent colors: blue (Qwen), green (DeepSeek), amber (GPT-5.4), purple (Chairman).

- [ ] **Step 3: Verify the page renders**

Run: `mix phx.server`
Navigate to `http://localhost:4000/bazi`
Expected: Page loads with the three-column layout visible (empty state).

- [ ] **Step 4: Commit**

```bash
git add lib/rho_web/inline_css.ex
git commit -m "feat(bazi): CSS styling for observatory layout"
```

---

### Task 12: Image Upload Handler

**Files:**
- Modify: `lib/rho_web/live/bazi_live.ex`

The LiveView needs to handle file uploads (chart image). Phoenix LiveView has built-in upload support.

- [ ] **Step 1: Add upload config to mount**

In `bazi_live.ex`, add to the `mount` function (inside the `connected?` block):

```elixir
socket = allow_upload(socket, :chart_image,
  accept: ~w(.png .jpg .jpeg .webp),
  max_entries: 1,
  max_file_size: 10_000_000
)
```

- [ ] **Step 2: Update begin_simulation event handler**

Replace the existing `begin_simulation` handler to consume the uploaded file:

```elixir
def handle_event("begin_simulation", %{"options" => options, "question" => question}, socket) do
  sid = socket.assigns.session_id

  # Consume uploaded image
  [image_b64] =
    consume_uploaded_entries(socket, :chart_image, fn %{path: path}, _entry ->
      data = File.read!(path)
      {:ok, Base.encode64(data)}
    end)

  parsed_options =
    options
    |> String.split(~r/[\n,]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  case Simulation.begin_simulation(sid, %{image_b64: image_b64, options: parsed_options, question: question}) do
    :ok -> {:noreply, socket}
    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "无法开始模拟: #{inspect(reason)}")}
  end
end
```

- [ ] **Step 3: Add upload form to render (pre-simulation state)**

Update the render function to show an input form when `simulation_status == :not_started`:

```elixir
<%= if @simulation_status == :not_started do %>
  <div class="bazi-setup-form">
    <h2>八字决策顾问</h2>
    <p>上传您的八字命盘（Joey Yap格式），输入选项和问题。</p>
    <form phx-submit="begin_simulation" phx-change="validate_upload">
      <.live_file_input upload={@uploads.chart_image} />
      <textarea name="options" placeholder="选项（每行一个）&#10;例如：&#10;选项A — 某科技公司高级工程师&#10;选项B — 某金融公司技术主管" rows="4" class="bazi-textarea"></textarea>
      <textarea name="question" placeholder="您的问题（例如：从八字角度看，哪份工作更适合我？）" rows="2" class="bazi-textarea"></textarea>
      <button type="submit" class="bazi-btn bazi-btn-primary">开始分析</button>
    </form>
  </div>
<% end %>
```

- [ ] **Step 4: Add validate_upload event handler**

```elixir
def handle_event("validate_upload", _params, socket) do
  {:noreply, socket}
end
```

- [ ] **Step 5: Verify upload works**

Run: `mix phx.server`
Navigate to `http://localhost:4000/bazi`
Expected: Upload form visible. Can select a chart image, enter options and question.

- [ ] **Step 6: Commit**

```bash
git add lib/rho_web/live/bazi_live.ex
git commit -m "feat(bazi): image upload handler for chart input"
```

---

### Task 13: Integration Test — Full Simulation Flow

**Files:**
- Create: `test/rho/demos/bazi/simulation_test.exs`

- [ ] **Step 1: Write integration test for coordinator state machine**

```elixir
defmodule Rho.Demos.Bazi.SimulationTest do
  use ExUnit.Case

  alias Rho.Demos.Bazi.Simulation
  alias Rho.Comms

  @session_id "bazi_test_#{System.unique_integer([:positive])}"

  setup do
    {:ok, _pid} = Simulation.start_link(@session_id)
    :ok
  end

  test "init subscribes to events and starts in :not_started" do
    assert Simulation.status(@session_id) == :not_started
  end

  test "begin_simulation transitions to :parsing_chart" do
    # Use a minimal base64 image (1x1 white PNG)
    tiny_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

    assert :ok =
      Simulation.begin_simulation(@session_id, %{
        image_b64: tiny_png,
        options: ["选项A — 科技公司", "选项B — 金融公司"],
        question: "哪份工作更适合我？"
      })

    assert Simulation.status(@session_id) == :parsing_chart
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/rho/demos/bazi/simulation_test.exs`
Expected: Tests pass (the begin test may timeout on LLM call in CI — that's expected, the state transition is what matters).

- [ ] **Step 3: Commit**

```bash
git add test/rho/demos/bazi/simulation_test.exs
git commit -m "test(bazi): integration test for coordinator state machine"
```

---

### Task 14: End-to-End Smoke Test

**Files:** None (manual testing)

- [ ] **Step 1: Start the server**

Run: `mix phx.server`

- [ ] **Step 2: Navigate to BaZi demo**

Open `http://localhost:4000/bazi` in browser.

- [ ] **Step 3: Upload chart and begin simulation**

Upload the Joey Yap chart image, enter two job options, enter the question. Click "开始分析".

- [ ] **Step 4: Verify the full flow**

Check that:
1. Chairman parses chart → chart data appears in timeline
2. Advisors propose dimensions → dimension approval form appears
3. Approve dimensions → Round 1 starts, scores appear in scoreboard
4. Round 2 → debate messages appear in timeline, scores update
5. Summary appears → post-sim Q&A input shows
6. Ask a question → chairman replies

- [ ] **Step 5: Fix any issues found during smoke test**

Address bugs, adjust prompts, tune timeouts as needed.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat(bazi): end-to-end smoke test fixes and polish"
```
