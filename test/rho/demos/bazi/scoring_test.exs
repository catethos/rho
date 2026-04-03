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
      assert is_list(merged)
      assert length(merged) <= 5
      assert "财运" in merged  # appears in all 3
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
      assert String.contains?(summary, "财运")
      assert is_binary(summary)
    end

    test "returns empty string when no major disagreements" do
      scores = %{
        {:bazi_advisor_qwen, 1} => %{"选项A" => %{"事业发展" => 80, "rationale" => "..."}},
        {:bazi_advisor_deepseek, 1} => %{"选项A" => %{"事业发展" => 82, "rationale" => "..."}},
        {:bazi_advisor_gpt, 1} => %{"选项A" => %{"事业发展" => 78, "rationale" => "..."}}
      }
      summary = Scoring.build_disagreement_summary(scores, 1)
      assert summary == ""
    end
  end

  describe "compute_deltas/2" do
    test "computes score changes between rounds" do
      all_scores = %{
        {:bazi_advisor_qwen, 1} => %{"选项A" => %{"事业发展" => 82, "财运" => 70, "rationale" => "..."}},
        {:bazi_advisor_qwen, 2} => %{"选项A" => %{"事业发展" => 85, "财运" => 65, "rationale" => "..."}}
      }
      deltas = Scoring.compute_deltas(all_scores, :bazi_advisor_qwen)
      assert deltas["选项A"]["事业发展"] == 3
      assert deltas["选项A"]["财运"] == -5
    end
  end
end
