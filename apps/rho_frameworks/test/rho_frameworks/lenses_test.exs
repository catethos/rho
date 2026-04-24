defmodule RhoFrameworks.LensesTest do
  use ExUnit.Case, async: false
  use Mimic

  import Ecto.Query

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Lenses

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Lens Test Org",
      slug: "lens-test-#{System.unique_integer([:positive])}"
    })

    %{org_id: org_id}
  end

  describe "seed_aria_lens/1" do
    test "creates ARIA lens with 2 axes, 8 variables, 9 classifications", %{org_id: org_id} do
      {:ok, lens} = Lenses.seed_aria_lens(org_id)

      lens = Lenses.get_lens!(lens.id)

      assert lens.name == "ARIA — AI Readiness Impact Assessment"
      assert lens.slug == "aria"
      assert lens.status == "active"
      assert lens.score_target == "role_profile"

      assert length(lens.axes) == 2

      [ai_impact, adaptability] = Enum.sort_by(lens.axes, & &1.sort_order)
      assert ai_impact.name == "AI Impact"
      assert ai_impact.short_name == "AII"
      assert length(ai_impact.variables) == 4

      assert adaptability.name == "Adaptability"
      assert adaptability.short_name == "ADP"
      assert length(adaptability.variables) == 4

      assert length(lens.classifications) == 9
    end

    test "variable weights sum to 1.0 per axis", %{org_id: org_id} do
      {:ok, lens} = Lenses.seed_aria_lens(org_id)
      lens = Lenses.get_lens!(lens.id)

      for axis <- lens.axes do
        total = axis.variables |> Enum.map(& &1.weight) |> Enum.sum()
        assert_in_delta total, 1.0, 0.001, "Weights for axis #{axis.name} should sum to 1.0"
      end
    end
  end

  describe "score/3" do
    setup %{org_id: org_id} do
      {:ok, lens} = Lenses.seed_aria_lens(org_id)

      # Create a role profile to score
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Score Test Lib #{System.unique_integer([:positive])}"
        })

      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Test Engineer #{System.unique_integer([:positive])}"},
          [%{category: "Technical", cluster: "Dev", skill_name: "Testing", required_level: 3}],
          resolve_library_id: lib.id
        )

      %{lens: lens, role_profile: rp}
    end

    test "computes composite as weighted sum of variable scores", %{
      lens: lens,
      role_profile: rp
    } do
      # AI Impact axis: at=80, td=60, dr=70, os=50
      # composite = 80*0.30 + 60*0.25 + 70*0.25 + 50*0.20 = 24 + 15 + 17.5 + 10 = 66.5
      # Adaptability axis: tla=90, atp=40, cfb=60, csr=70
      # composite = 90*0.30 + 40*0.25 + 60*0.25 + 70*0.20 = 27 + 10 + 15 + 14 = 66.0
      variable_scores = %{
        "at" => 80.0,
        "td" => 60.0,
        "dr" => 70.0,
        "os" => 50.0,
        "tla" => 90.0,
        "atp" => 40.0,
        "cfb" => 60.0,
        "csr" => 70.0
      }

      {:ok, score} = Lenses.score(lens.id, %{role_profile_id: rp.id}, variable_scores)

      assert length(score.axis_scores) == 2

      [ai_score, adp_score] = Enum.sort_by(score.axis_scores, & &1.axis_id)

      # We need to figure out which axis_id is which — sort by the lens axes
      lens = Lenses.get_lens!(lens.id)
      [ai_axis, adp_axis] = Enum.sort_by(lens.axes, & &1.sort_order)

      ai_score = Enum.find(score.axis_scores, &(&1.axis_id == ai_axis.id))
      adp_score = Enum.find(score.axis_scores, &(&1.axis_id == adp_axis.id))

      assert_in_delta ai_score.composite, 66.5, 0.01
      assert_in_delta adp_score.composite, 66.0, 0.01
    end

    test "classifies bands correctly based on thresholds", %{lens: lens, role_profile: rp} do
      # Low scores (all < 40) → band 0
      low_scores = %{
        "at" => 10.0,
        "td" => 20.0,
        "dr" => 15.0,
        "os" => 30.0,
        "tla" => 10.0,
        "atp" => 20.0,
        "cfb" => 15.0,
        "csr" => 30.0
      }

      {:ok, score} = Lenses.score(lens.id, %{role_profile_id: rp.id}, low_scores)

      for axis_score <- score.axis_scores do
        assert axis_score.band == 0, "Low scores should produce band 0"
      end

      # High scores (composite > 70) → band 2
      high_scores = %{
        "at" => 90.0,
        "td" => 85.0,
        "dr" => 80.0,
        "os" => 95.0,
        "tla" => 90.0,
        "atp" => 85.0,
        "cfb" => 80.0,
        "csr" => 95.0
      }

      {:ok, score2} = Lenses.score(lens.id, %{role_profile_id: rp.id}, high_scores)

      for axis_score <- score2.axis_scores do
        assert axis_score.band == 2, "High scores should produce band 2"
      end
    end

    test "matrix classification maps band combinations to labels", %{
      lens: lens,
      role_profile: rp
    } do
      # High AI Impact (band 2) + Low Adaptability (band 0) → Restructure
      scores = %{
        "at" => 90.0,
        "td" => 85.0,
        "dr" => 80.0,
        "os" => 95.0,
        "tla" => 10.0,
        "atp" => 20.0,
        "cfb" => 15.0,
        "csr" => 5.0
      }

      {:ok, score} = Lenses.score(lens.id, %{role_profile_id: rp.id}, scores)

      assert score.classification == "Restructure"
    end

    test "Monitor classification for medium/medium bands", %{lens: lens, role_profile: rp} do
      # Medium bands (composite 40-70 on both axes) → Monitor
      scores = %{
        "at" => 55.0,
        "td" => 50.0,
        "dr" => 55.0,
        "os" => 50.0,
        "tla" => 55.0,
        "atp" => 50.0,
        "cfb" => 55.0,
        "csr" => 50.0
      }

      {:ok, score} = Lenses.score(lens.id, %{role_profile_id: rp.id}, scores)

      assert score.classification == "Monitor"
    end

    test "persists variable scores with raw, adjusted, and weighted values", %{
      lens: lens,
      role_profile: rp
    } do
      variable_scores = %{
        "at" => 80.0,
        "td" => 60.0,
        "dr" => 70.0,
        "os" => 50.0,
        "tla" => 90.0,
        "atp" => 40.0,
        "cfb" => 60.0,
        "csr" => 70.0
      }

      {:ok, score} = Lenses.score(lens.id, %{role_profile_id: rp.id}, variable_scores)

      all_var_scores =
        score.axis_scores |> Enum.flat_map(& &1.variable_scores)

      assert length(all_var_scores) == 8

      for vs <- all_var_scores do
        assert vs.raw_score != nil
        assert vs.adjusted_score != nil
        assert vs.weighted_score != nil
      end
    end
  end

  describe "score_via_llm/2" do
    setup %{org_id: org_id} do
      {:ok, lens} = Lenses.seed_aria_lens(org_id)

      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "LLM Test Lib #{System.unique_integer([:positive])}"
        })

      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{
            name: "Data Analyst #{System.unique_integer([:positive])}",
            description: "Analyzes data and produces reports"
          },
          [%{category: "Technical", cluster: "Data", skill_name: "SQL", required_level: 3}],
          resolve_library_id: lib.id
        )

      %{lens: lens, role_profile: rp}
    end

    test "calls LLM, persists activity tags, and returns a scored result", %{
      lens: lens,
      role_profile: rp
    } do
      mock_object = %{
        "work_activities" => [
          %{
            "activity" => "Write SQL queries for reports",
            "tag" => "automatable",
            "confidence" => 0.85
          },
          %{
            "activity" => "Interpret business requirements",
            "tag" => "human_essential",
            "confidence" => 0.9
          }
        ],
        "variable_scores" => [
          %{"key" => "at", "score" => 65.0, "rationale" => "High automation potential"},
          %{"key" => "td", "score" => 55.0, "rationale" => "Moderate tool displacement"},
          %{"key" => "dr", "score" => 70.0, "rationale" => "Data-heavy role"},
          %{"key" => "os", "score" => 60.0, "rationale" => "Somewhat standardized outputs"},
          %{"key" => "tla", "score" => 50.0, "rationale" => "Moderate learning agility"},
          %{"key" => "atp", "score" => 45.0, "rationale" => "Some AI tool usage"},
          %{"key" => "cfb", "score" => 40.0, "rationale" => "Limited cross-functional work"},
          %{"key" => "csr", "score" => 35.0, "rationale" => "More routine than creative"}
        ]
      }

      mock_response = %ReqLLM.Response{
        id: "mock-id",
        model: "mock",
        context: [],
        object: mock_object
      }

      Mimic.expect(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
        {:ok, mock_response}
      end)

      {:ok, score} =
        Lenses.score_via_llm(lens.id, %{role_profile_id: rp.id}, model: "anthropic:mock")

      # Verify score was persisted
      assert score.classification != nil
      assert length(score.axis_scores) == 2

      # Verify work activity tags were persisted
      tags =
        Repo.all(
          from(t in RhoFrameworks.Frameworks.WorkActivityTag,
            where: t.role_profile_id == ^rp.id and t.lens_id == ^lens.id
          )
        )

      assert length(tags) == 2
      assert Enum.any?(tags, &(&1.tag == "automatable"))
      assert Enum.any?(tags, &(&1.tag == "human_essential"))
    end

    test "returns error when LLM call fails", %{lens: lens, role_profile: rp} do
      Mimic.expect(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
        {:error, %RuntimeError{message: "LLM unavailable"}}
      end)

      assert {:error, %RuntimeError{}} =
               Lenses.score_via_llm(lens.id, %{role_profile_id: rp.id}, model: "anthropic:mock")
    end
  end

  describe "classify_band edge cases" do
    test "boundary value at threshold goes to higher band", %{org_id: org_id} do
      {:ok, lens} = Lenses.seed_aria_lens(org_id)

      # Score exactly at threshold (40.0) should be band 1
      # composite = 40*0.30 + 40*0.25 + 40*0.25 + 40*0.20 = 12 + 10 + 10 + 8 = 40.0
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Boundary Test Lib #{System.unique_integer([:positive])}"
        })

      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Boundary Role #{System.unique_integer([:positive])}"},
          [%{category: "Technical", cluster: "Dev", skill_name: "Testing", required_level: 3}],
          resolve_library_id: lib.id
        )

      scores = %{
        "at" => 40.0,
        "td" => 40.0,
        "dr" => 40.0,
        "os" => 40.0,
        "tla" => 40.0,
        "atp" => 40.0,
        "cfb" => 40.0,
        "csr" => 40.0
      }

      {:ok, score} = Lenses.score(lens.id, %{role_profile_id: rp.id}, scores)

      for axis_score <- score.axis_scores do
        assert axis_score.band == 1, "Score exactly at 40.0 threshold should be band 1"
      end
    end
  end

  describe "dashboard data queries" do
    setup %{org_id: org_id} do
      {:ok, lens} = Lenses.seed_aria_lens(org_id)

      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Dashboard Lib #{System.unique_integer([:positive])}"
        })

      # Create and score two role profiles with different classifications
      {:ok, %{role_profile: rp1}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "High-Risk Role #{System.unique_integer([:positive])}"},
          [%{category: "Technical", cluster: "Dev", skill_name: "Testing", required_level: 3}],
          resolve_library_id: lib.id
        )

      {:ok, %{role_profile: rp2}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Safe Role #{System.unique_integer([:positive])}"},
          [%{category: "Technical", cluster: "Dev", skill_name: "Design", required_level: 2}],
          resolve_library_id: lib.id
        )

      # rp1: high AI impact + low adaptability → Restructure
      {:ok, score1} =
        Lenses.score(lens.id, %{role_profile_id: rp1.id}, %{
          "at" => 90.0,
          "td" => 85.0,
          "dr" => 80.0,
          "os" => 95.0,
          "tla" => 10.0,
          "atp" => 20.0,
          "cfb" => 15.0,
          "csr" => 5.0
        })

      # rp2: low AI impact + high adaptability → Leverage
      {:ok, score2} =
        Lenses.score(lens.id, %{role_profile_id: rp2.id}, %{
          "at" => 10.0,
          "td" => 15.0,
          "dr" => 20.0,
          "os" => 10.0,
          "tla" => 90.0,
          "atp" => 85.0,
          "cfb" => 80.0,
          "csr" => 95.0
        })

      %{lens: lens, rp1: rp1, rp2: rp2, score1: score1, score2: score2}
    end

    test "scores_by_classification/1 returns counts per classification", %{lens: lens} do
      result = Lenses.scores_by_classification(lens.id)

      by_label = Map.new(result, &{&1.classification, &1.count})
      assert by_label["Restructure"] == 1
      assert by_label["Leverage"] == 1
    end

    test "scores_with_axes/1 returns scores with axis composites", %{lens: lens} do
      result = Lenses.scores_with_axes(lens.id)

      assert length(result) == 2

      for entry <- result do
        assert Map.has_key?(entry, :score_id)
        assert Map.has_key?(entry, :classification)
        assert Map.has_key?(entry, :target)
        assert length(entry.axes) == 2

        [first_axis, second_axis] = entry.axes
        assert first_axis.sort_order == 0
        assert second_axis.sort_order == 1
        assert is_float(first_axis.composite)
      end
    end

    test "score_summary/1 returns aggregate stats", %{lens: lens} do
      summary = Lenses.score_summary(lens.id)

      assert summary.total == 2
      assert summary.by_classification["Restructure"] == 1
      assert summary.by_classification["Leverage"] == 1
      assert length(summary.axis_averages) == 2

      for avg <- summary.axis_averages do
        assert Map.has_key?(avg, :axis_name)
        assert Map.has_key?(avg, :average)
        assert is_float(avg.average)
      end
    end

    test "score_detail/1 returns full variable breakdown", %{score1: score1} do
      detail = Lenses.score_detail(score1.id)

      assert detail.score_id == score1.id
      assert detail.classification == "Restructure"
      assert length(detail.axes) == 2

      for axis <- detail.axes do
        assert Map.has_key?(axis, :band_label)
        assert length(axis.variables) == 4

        for var <- axis.variables do
          assert Map.has_key?(var, :key)
          assert Map.has_key?(var, :raw_score)
          assert Map.has_key?(var, :weighted_score)
        end
      end
    end

    test "list_scores/2 filters by classification", %{lens: lens} do
      restructure = Lenses.list_scores(lens.id, classification: "Restructure")
      assert length(restructure) == 1
      assert hd(restructure).classification == "Restructure"

      leverage = Lenses.list_scores(lens.id, classification: "Leverage")
      assert length(leverage) == 1
      assert hd(leverage).classification == "Leverage"

      all = Lenses.list_scores(lens.id)
      assert length(all) == 2
    end

    test "list_scores/2 filters by axis band", %{lens: lens} do
      # AI Impact axis (sort_order 0), band 2 (high) — only rp1
      high_impact = Lenses.list_scores(lens.id, band: {0, 2})
      assert length(high_impact) == 1

      # Adaptability axis (sort_order 1), band 2 (high) — only rp2
      high_adapt = Lenses.list_scores(lens.id, band: {1, 2})
      assert length(high_adapt) == 1
    end

    test "get_score/2 returns latest score for a target", %{lens: lens, rp1: rp1} do
      score = Lenses.get_score(lens.id, %{role_profile_id: rp1.id})

      assert score != nil
      assert score.classification == "Restructure"
      assert length(score.axis_scores) == 2
    end

    test "get_score/2 returns nil for unscored target", %{lens: lens} do
      assert Lenses.get_score(lens.id, %{role_profile_id: Ecto.UUID.generate()}) == nil
    end

    test "get_score/2 returns latest version when multiple scores exist", %{
      lens: lens,
      rp1: rp1
    } do
      # Re-score rp1 with different values (medium/medium → Monitor)
      {:ok, _score_v2} =
        Lenses.score(lens.id, %{role_profile_id: rp1.id}, %{
          "at" => 55.0,
          "td" => 50.0,
          "dr" => 55.0,
          "os" => 50.0,
          "tla" => 55.0,
          "atp" => 50.0,
          "cfb" => 55.0,
          "csr" => 50.0
        })

      latest = Lenses.get_score(lens.id, %{role_profile_id: rp1.id})
      assert latest.classification == "Monitor"
    end
  end
end
