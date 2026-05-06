defmodule RhoFrameworks.Import.EscoTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Import.Esco

  @fixture_dir Path.expand("../../fixtures/esco", __DIR__)

  setup do
    {:ok, parsed: Esco.parse(@fixture_dir)}
  end

  describe "parse/1" do
    test "returns counts in stats", %{parsed: parsed} do
      # 8 rows in skills_en.csv minus 1 SkillGroup filter = 7 KnowledgeSkillCompetence skills.
      assert parsed.stats.skills == 7
      assert parsed.stats.role_profiles == 4
      assert parsed.stats.relations_raw == 11
      # Two duplicate `(occupation, skill)` pairs collapse into one each.
      assert parsed.stats.relations_kept == 9
      assert parsed.stats.relations_collapsed == 2
    end

    test "filters out non-KnowledgeSkillCompetence rows from skills file", %{parsed: parsed} do
      uris = Enum.map(parsed.skills, & &1.esco_uri)
      refute Enum.any?(uris, &String.ends_with?(&1, "/L1_S5"))
    end
  end

  describe "skill slug suffixing" do
    test "two skills with the same preferredLabel get distinct slugs", %{parsed: parsed} do
      manage_staff = Enum.filter(parsed.skills, &(&1.name == "manage staff"))
      assert length(manage_staff) == 2

      slugs = manage_staff |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ["manage-staff-a4f2c1", "manage-staff-b7c0d3"]
    end

    test "slug suffix is the last 6 chars of the URI", %{parsed: parsed} do
      java =
        Enum.find(
          parsed.skills,
          &(&1.esco_uri == "http://data.europa.eu/esco/skill/javapr0001")
        )

      assert java.slug == "java-computer-programming-pr0001"
    end
  end

  describe "skill category fallback" do
    test "uses hierarchy L1 when the URI is in skillsHierarchy_en.csv", %{parsed: parsed} do
      managing =
        Enum.find(
          parsed.skills,
          &(&1.esco_uri == "http://data.europa.eu/esco/skill/L3_S5.0.1")
        )

      assert managing.category == "Management skills"
      assert managing.cluster == "leading and motivating"
    end

    test "falls back to reuseLevel when the URI is missing from the hierarchy", %{parsed: parsed} do
      # `manage staff` (managea4f2c1) has no hierarchy entry but reuseLevel=occupation-specific.
      # No broaderRelations fixture in this test bundle, so the walk returns nothing
      # and `cluster` falls back to `category` (the orphan-safe default that lets
      # downstream `library_schema()` row-validation accept the row).
      manage =
        Enum.find(
          parsed.skills,
          &(&1.esco_uri == "http://data.europa.eu/esco/skill/managea4f2c1")
        )

      assert manage.category == "occupation-specific"
      assert manage.cluster == "occupation-specific"
    end

    test "falls back to Uncategorized when neither hierarchy nor reuseLevel applies",
         %{parsed: parsed} do
      lead =
        Enum.find(
          parsed.skills,
          &(&1.esco_uri == "http://data.europa.eu/esco/skill/leadteam0001")
        )

      assert lead.category == "Uncategorized"
    end
  end

  describe "skill metadata" do
    test "parses altLabels from newline-separated cell", %{parsed: parsed} do
      managing =
        Enum.find(
          parsed.skills,
          &(&1.esco_uri == "http://data.europa.eu/esco/skill/L3_S5.0.1")
        )

      assert managing.metadata["alt_labels"] == ["manage personnel", "oversee staff"]
      assert managing.metadata["esco_uri"] == "http://data.europa.eu/esco/skill/L3_S5.0.1"
      assert managing.metadata["source"] == "ESCO v1.2.1"
      assert managing.metadata["reuse_level"] == "sector-specific"
    end
  end

  describe "role profiles" do
    test "joins ISCO group label into role_family", %{parsed: parsed} do
      director =
        Enum.find(
          parsed.role_profiles,
          &(&1.esco_uri == "http://data.europa.eu/esco/occupation/0001")
        )

      assert director.name == "film director"
      assert director.role_family == "Film, stage and related directors and producers"
      assert director.metadata["isco_code"] == "2654"
    end

    test "leaves role_family nil when ISCO code is unknown", %{parsed: parsed} do
      unknown =
        Enum.find(
          parsed.role_profiles,
          &(&1.esco_uri == "http://data.europa.eu/esco/occupation/0004")
        )

      assert unknown.role_family == nil
      assert unknown.metadata["isco_code"] == "9999"
      assert unknown.metadata["isco_label"] == nil
    end
  end

  describe "relation collapse" do
    test "duplicate (occupation_uri, skill_uri) pairs collapse to one essential row",
         %{parsed: parsed} do
      pair = fn {occ, sk} ->
        Enum.filter(
          parsed.relations,
          &(&1.occupation_uri == occ and &1.skill_uri == sk)
        )
      end

      # Tour guide + handle multilingual material — fixture lists optional THEN essential.
      [handle] =
        pair.(
          {"http://data.europa.eu/esco/occupation/0003",
           "http://data.europa.eu/esco/skill/handle0001"}
        )

      assert handle.required == true

      # Tour guide + lead a team — fixture lists essential THEN optional.
      [lead] =
        pair.(
          {"http://data.europa.eu/esco/occupation/0003",
           "http://data.europa.eu/esco/skill/leadteam0001"}
        )

      assert lead.required == true
    end

    test "non-duplicate optional relations stay optional", %{parsed: parsed} do
      [r] =
        Enum.filter(
          parsed.relations,
          &(&1.occupation_uri == "http://data.europa.eu/esco/occupation/0001" and
              &1.skill_uri == "http://data.europa.eu/esco/skill/leadteam0001")
        )

      assert r.required == false
    end
  end

  describe "mix task --dry-run" do
    test "parse + summary works without DB writes" do
      # Capture the IO from running the dry-run path. Asserts the task emits
      # a summary with the expected counts.
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("rho.import_esco", [@fixture_dir, "--dry-run"])
        end)

      assert out =~ "[DRY RUN]"
      assert out =~ "Skills:         7"
      assert out =~ "Role profiles:  4"
      assert out =~ "9 kept (2 collapsed from 11 raw)"
    end
  end
end
