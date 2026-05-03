defmodule RhoFrameworks.Import.Esco.LoaderTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.Frameworks.{Library, RoleProfile, RoleSkill, Skill}
  alias RhoFrameworks.Import.Esco
  alias RhoFrameworks.Import.Esco.Loader

  @fixture_dir Path.expand("../../fixtures/esco", __DIR__)

  # Each test starts with the System org present (committed by migration) but
  # no ESCO library / role profiles. Clean those out first; cascading FKs
  # (libraries→skills→role_skills, role_profiles→role_skills) drop the rest.
  setup do
    system = Repo.get_by!(Organization, slug: "system")

    from(l in Library, where: l.organization_id == ^system.id) |> Repo.delete_all()
    from(rp in RoleProfile, where: rp.organization_id == ^system.id) |> Repo.delete_all()

    %{
      parsed: Esco.parse(@fixture_dir),
      version: "2026.#{System.unique_integer([:positive])}",
      system: system
    }
  end

  describe "import_all/2 — full integration" do
    test "writes library, skills, role profiles, role-skills and publishes",
         %{parsed: parsed, version: version, system: system} do
      result = Loader.import_all(parsed, version)

      # Library was flipped to public + immutable on the publish step.
      lib = Repo.get_by!(Library, organization_id: system.id, version: version)
      assert lib.visibility == "public"
      assert lib.immutable == true
      assert not is_nil(lib.published_at)
      assert lib.metadata["license"] == "CC-BY 4.0"

      # Counts match the fixture: 7 skills, 4 role profiles, 8 kept relations
      # (9 after collapse, minus 1 unmapped (0004 → notinskillsfile)).
      assert result.skills.inserted == 7
      assert result.skills.skipped == 0
      assert result.role_profiles.inserted == 4
      assert result.role_profiles.skipped == 0
      assert result.role_skills.inserted == 8
      assert result.role_skills.kept == 8
      assert result.role_skills.dropped == 1
      assert result.collapsed_relations == 2

      # DB-side counts agree.
      assert Repo.aggregate(from(s in Skill, where: s.library_id == ^lib.id), :count) == 7

      assert Repo.aggregate(
               from(rp in RoleProfile, where: rp.organization_id == ^system.id),
               :count
             ) == 4

      assert role_skill_count(system.id) == 8
    end

    test "the dedup case: tour guide essentially needs handle-multilingual-material",
         %{parsed: parsed, version: version, system: system} do
      Loader.import_all(parsed, version)

      tour_guide =
        Repo.one!(
          from(rp in RoleProfile,
            where:
              rp.organization_id == ^system.id and
                fragment("?->>'esco_uri'", rp.metadata) ==
                  "http://data.europa.eu/esco/occupation/0003"
          )
        )

      handle_skill =
        Repo.one!(
          from(s in Skill,
            where:
              fragment("?->>'esco_uri'", s.metadata) ==
                "http://data.europa.eu/esco/skill/handle0001"
          )
        )

      rs =
        Repo.one!(
          from(rs in RoleSkill,
            where: rs.role_profile_id == ^tour_guide.id and rs.skill_id == ^handle_skill.id
          )
        )

      # Fixture lists this pair as optional then essential — collapse keeps essential.
      assert rs.required == true
    end

    test "unmapped skill URI is counted as dropped (not crashed)",
         %{parsed: parsed, version: version} do
      result = Loader.import_all(parsed, version)
      # The fixture's (0004, notinskillsfile) row has no matching skill.
      assert result.role_skills.dropped == 1
    end
  end

  describe "import_all/2 — idempotency" do
    test "second run inserts 0 rows everywhere; library stays public + immutable",
         %{parsed: parsed, version: version, system: system} do
      first = Loader.import_all(parsed, version)
      assert first.skills.inserted == 7
      assert first.role_profiles.inserted == 4
      assert first.role_skills.inserted == 8

      second = Loader.import_all(parsed, version)

      assert second.skills.inserted == 0
      assert second.skills.skipped == 7
      assert second.role_profiles.inserted == 0
      assert second.role_profiles.skipped == 4
      assert second.role_skills.inserted == 0
      # `kept` still counts the URI-resolvable rows even on a no-op rerun.
      assert second.role_skills.kept == 8
      assert second.role_skills.dropped == 1

      lib = Repo.get_by!(Library, organization_id: system.id, version: version)
      assert lib.visibility == "public"
      assert lib.immutable == true
      assert role_skill_count(system.id) == 8
    end
  end

  describe "import_all/2 — crash recovery" do
    test "first pass that skips publish leaves library private + mutable; full pipeline finishes the job",
         %{parsed: parsed, version: version, system: system} do
      # Simulate a crash *before* publish: run every step except publish_library!.
      org = Loader.resolve_system_org!()
      lib = Loader.upsert_library!(org, version)
      {skill_by_uri, _} = Loader.bulk_insert_skills!(lib, parsed.skills)
      {rp_by_uri, _} = Loader.bulk_insert_role_profiles!(org, parsed.role_profiles)
      _ = Loader.bulk_insert_role_skills!(rp_by_uri, skill_by_uri, parsed.relations)

      partial = Repo.get_by!(Library, organization_id: system.id, version: version)
      assert partial.visibility == "private"
      assert partial.immutable == false
      assert is_nil(partial.published_at)

      # Re-run the full pipeline. All inserts are no-ops; publish flips
      # the library to public + immutable.
      result = Loader.import_all(parsed, version)

      assert result.skills.inserted == 0
      assert result.role_profiles.inserted == 0
      assert result.role_skills.inserted == 0

      final = Repo.get_by!(Library, organization_id: system.id, version: version)
      assert final.visibility == "public"
      assert final.immutable == true
      assert not is_nil(final.published_at)
    end
  end

  defp role_skill_count(org_id) do
    Repo.one!(
      from(rs in RoleSkill,
        join: rp in RoleProfile,
        on: rp.id == rs.role_profile_id,
        where: rp.organization_id == ^org_id,
        select: count(rs.id)
      )
    )
  end
end
