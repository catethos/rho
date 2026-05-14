defmodule RhoFrameworks.GapAnalysisTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Repo

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Test Org",
      slug: "test-org-#{System.unique_integer([:positive])}"
    })

    {:ok, lib} =
      RhoFrameworks.Library.create_library(org_id, %{
        name: "Gap Lib #{System.unique_integer([:positive])}"
      })

    rows = [
      %{category: "Tech", skill_name: "SQL", required_level: 4},
      %{category: "Tech", skill_name: "Python", required_level: 3},
      %{category: "Soft", skill_name: "Communication", required_level: 2}
    ]

    {:ok, %{role_profile: rp}} =
      RhoFrameworks.Roles.save_role_profile(org_id, %{name: "DE"}, rows,
        resolve_library_id: lib.id
      )

    skills = RhoFrameworks.Library.list_skills(lib.id)
    skill_map = Map.new(skills, &{&1.name, &1.id})

    %{org_id: org_id, rp: rp, skill_map: skill_map}
  end

  describe "individual_gap/2" do
    test "computes gaps correctly", %{rp: rp, skill_map: sm} do
      snapshot = %{
        sm["SQL"] => 3.0,
        sm["Python"] => 4.0
        # Communication not in snapshot -> :unknown
      }

      gaps = RhoFrameworks.GapAnalysis.individual_gap(snapshot, rp.id)

      assert match?([_, _, _], gaps)

      sql_gap = Enum.find(gaps, &(&1.skill_name == "SQL"))
      assert sql_gap.gap == 1.0
      assert sql_gap.positive_gap == 1.0

      python_gap = Enum.find(gaps, &(&1.skill_name == "Python"))
      assert python_gap.gap == -1.0
      assert python_gap.positive_gap == 0

      comm_gap = Enum.find(gaps, &(&1.skill_name == "Communication"))
      assert comm_gap.current_level == :unknown
      assert comm_gap.gap == :unknown
      assert comm_gap.positive_gap == :unknown
    end

    test "all skills at or above requirement show zero positive gap", %{rp: rp, skill_map: sm} do
      snapshot = %{
        sm["SQL"] => 5.0,
        sm["Python"] => 3.0,
        sm["Communication"] => 4.0
      }

      gaps = RhoFrameworks.GapAnalysis.individual_gap(snapshot, rp.id)
      assert Enum.all?(gaps, &(&1.positive_gap == 0))
    end

    test "empty snapshot returns all skills as unknown", %{rp: rp} do
      gaps = RhoFrameworks.GapAnalysis.individual_gap(%{}, rp.id)
      assert match?([_, _, _], gaps)
      assert Enum.all?(gaps, &(&1.current_level == :unknown))
      assert Enum.all?(gaps, &(&1.gap == :unknown))
    end
  end

  describe "team_gap/2" do
    test "aggregates with unknown tracking", %{rp: rp, skill_map: sm} do
      snapshots = [
        {"alice", %{sm["SQL"] => 4.0, sm["Python"] => 3.0, sm["Communication"] => 2.0}},
        {"bob", %{sm["SQL"] => 2.0, sm["Python"] => 3.0}}
      ]

      result = RhoFrameworks.GapAnalysis.team_gap(snapshots, rp.id)

      assert length(result.individual_gaps) == 2

      sql_agg = Enum.find(result.aggregate, &(&1.skill_name == "SQL"))
      assert sql_agg.known_count == 2
      assert sql_agg.unknown_count == 0
      # Alice meets (4.0 >= 4), Bob doesn't (2.0 < 4) → 50%
      assert sql_agg.pct_meeting == 50.0
      # positive gaps: Alice=0, Bob=2 → avg=1.0
      assert sql_agg.avg_positive_gap == 1.0
      # weighted: all weights=1.0 → same as avg_positive_gap
      assert sql_agg.weighted_avg_gap == 1.0

      comm_agg = Enum.find(result.aggregate, &(&1.skill_name == "Communication"))
      assert comm_agg.known_count == 1
      assert comm_agg.unknown_count == 1
      assert comm_agg.pct_meeting == 100.0
      assert comm_agg.weighted_avg_gap == 0.0
    end

    test "all-unknown team returns :unknown for aggregates", %{rp: rp} do
      snapshots = [
        {"alice", %{}},
        {"bob", %{}}
      ]

      result = RhoFrameworks.GapAnalysis.team_gap(snapshots, rp.id)

      assert length(result.individual_gaps) == 2

      Enum.each(result.aggregate, fn agg ->
        assert agg.known_count == 0
        assert agg.unknown_count == 2
        assert agg.pct_meeting == :unknown
        assert agg.avg_positive_gap == :unknown
      end)
    end

    test "single person team produces both individual and aggregate", %{rp: rp, skill_map: sm} do
      snapshots = [
        {"alice", %{sm["SQL"] => 3.0, sm["Python"] => 3.0, sm["Communication"] => 2.0}}
      ]

      result = RhoFrameworks.GapAnalysis.team_gap(snapshots, rp.id)

      assert length(result.individual_gaps) == 1
      assert length(result.aggregate) == 3

      sql_agg = Enum.find(result.aggregate, &(&1.skill_name == "SQL"))
      assert sql_agg.avg_positive_gap == 1.0
      assert sql_agg.weighted_avg_gap == 1.0
      assert sql_agg.pct_meeting == 0.0
    end
  end
end
