defmodule RhoFrameworks.RolesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.{RoleProfile, Skill}
  alias RhoEmbeddings.Backend.Fake, as: FakeEmbeddings

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "Test Org",
      slug: "test-org-#{System.unique_integer([:positive])}"
    })

    {:ok, lib} =
      RhoFrameworks.Library.create_library(org_id, %{
        name: "Lib #{System.unique_integer([:positive])}"
      })

    %{org_id: org_id, lib: lib}
  end

  describe "save_role_profile/4" do
    test "creates role profile with skills auto-upserted as drafts", %{org_id: org_id, lib: lib} do
      rows = [
        %{category: "Technical", cluster: "Data", skill_name: "SQL", required_level: 4},
        %{category: "Technical", cluster: "Data", skill_name: "Python", required_level: 3}
      ]

      {:ok, %{role_profile: rp, role_skills: count}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Data Engineer"},
          rows,
          resolve_library_id: lib.id
        )

      assert rp.name == "Data Engineer"
      assert count == 2

      # Skills should be draft
      skills = RhoFrameworks.Library.list_skills(lib.id)
      assert match?([_, _], skills)
      assert Enum.all?(skills, &(&1.status == "draft"))
    end

    test "overlapping skills are not duplicated across roles", %{org_id: org_id, lib: lib} do
      rows1 = [
        %{category: "Tech", cluster: "Data", skill_name: "SQL", required_level: 4},
        %{category: "Tech", cluster: "Data", skill_name: "Python", required_level: 3}
      ]

      rows2 = [
        %{category: "Tech", cluster: "Data", skill_name: "SQL", required_level: 3},
        %{category: "Tech", cluster: "ML", skill_name: "TensorFlow", required_level: 2}
      ]

      {:ok, _} =
        RhoFrameworks.Roles.save_role_profile(org_id, %{name: "Data Engineer"}, rows1,
          resolve_library_id: lib.id
        )

      {:ok, _} =
        RhoFrameworks.Roles.save_role_profile(org_id, %{name: "ML Engineer"}, rows2,
          resolve_library_id: lib.id
        )

      skills = RhoFrameworks.Library.list_skills(lib.id)
      assert match?([_, _, _], skills)
    end

    test "only name is required — rich fields optional", %{org_id: org_id, lib: lib} do
      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Minimal Role"},
          [%{category: "General", skill_name: "Communication", required_level: 1}],
          resolve_library_id: lib.id
        )

      assert rp.purpose == nil
      assert rp.accountabilities == nil
    end
  end

  describe "load_role_profile/2" do
    test "returns flat rows for data table", %{org_id: org_id, lib: lib} do
      rows = [
        %{
          category: "Tech",
          cluster: "Data",
          skill_name: "SQL",
          required_level: 4,
          required: true
        },
        %{
          category: "Tech",
          cluster: "ML",
          skill_name: "PyTorch",
          required_level: 2,
          required: false
        }
      ]

      {:ok, _} =
        RhoFrameworks.Roles.save_role_profile(org_id, %{name: "ML Engineer"}, rows,
          resolve_library_id: lib.id
        )

      {:ok, %{rows: loaded_rows}} = RhoFrameworks.Roles.load_role_profile(org_id, "ML Engineer")

      assert match?([_, _], loaded_rows)

      sql_row = Enum.find(loaded_rows, &(&1.skill_name == "SQL"))
      assert sql_row.required_level == 4
      assert sql_row.required == true

      pytorch_row = Enum.find(loaded_rows, &(&1.skill_name == "PyTorch"))
      assert pytorch_row.required == false
    end

    test "returns error for non-existent profile", %{org_id: org_id} do
      assert {:error, :not_found} =
               RhoFrameworks.Roles.load_role_profile(org_id, "Nonexistent")
    end
  end

  describe "delete_role_profile/2" do
    test "deletes role but preserves library skills", %{org_id: org_id, lib: lib} do
      rows = [%{category: "Tech", skill_name: "SQL", required_level: 3}]

      {:ok, _} =
        RhoFrameworks.Roles.save_role_profile(org_id, %{name: "To Delete"}, rows,
          resolve_library_id: lib.id
        )

      {:ok, _} = RhoFrameworks.Roles.delete_role_profile(org_id, "To Delete")

      assert {:error, :not_found} =
               RhoFrameworks.Roles.load_role_profile(org_id, "To Delete")

      # Skill still exists in library
      skills = RhoFrameworks.Library.list_skills(lib.id)
      assert match?([_], skills)
    end
  end

  describe "compare_role_profiles/2" do
    test "identifies shared and unique skills", %{org_id: org_id, lib: lib} do
      {:ok, _} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Role A"},
          [
            %{category: "Tech", skill_name: "SQL", required_level: 3},
            %{category: "Tech", skill_name: "Python", required_level: 3}
          ],
          resolve_library_id: lib.id
        )

      {:ok, _} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "Role B"},
          [
            %{category: "Tech", skill_name: "SQL", required_level: 4},
            %{category: "Tech", skill_name: "Rust", required_level: 2}
          ],
          resolve_library_id: lib.id
        )

      result = RhoFrameworks.Roles.compare_role_profiles(org_id, ["Role A", "Role B"])

      assert "SQL" in result.shared_skills
      assert result.shared_count == 1
      assert "Python" in result.unique_per_role["Role A"]
      assert "Rust" in result.unique_per_role["Role B"]
    end
  end

  describe "clone_role_skills/2" do
    test "unions skills from multiple roles, keeping highest level", %{
      org_id: org_id,
      lib: lib
    } do
      {:ok, %{role_profile: rp1}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "SRE"},
          [
            %{category: "Tech", skill_name: "SQL", required_level: 3},
            %{category: "Tech", skill_name: "Linux", required_level: 4}
          ],
          resolve_library_id: lib.id
        )

      {:ok, %{role_profile: rp2}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "DevOps"},
          [
            %{category: "Tech", skill_name: "SQL", required_level: 5},
            %{category: "Tech", skill_name: "Terraform", required_level: 3}
          ],
          resolve_library_id: lib.id
        )

      cloned = RhoFrameworks.Roles.clone_role_skills(org_id, [rp1.id, rp2.id])

      assert match?([_, _, _], cloned)
      sql = Enum.find(cloned, &(&1.skill_name == "SQL"))
      assert sql.required_level == 5
    end
  end

  describe "clone_skills_for_library/2" do
    test "preserves skill description and proficiency_levels", %{org_id: org_id, lib: lib} do
      # Build the role profile first (auto-creates the SQL skill row via
      # the role-profile upsert), then enrich the skill with description +
      # proficiency_levels so the test exercises the read path Roles uses.
      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "DBA"},
          [
            %{
              category: "Tech",
              cluster: "Data",
              skill_name: "SQL",
              skill_description: "Structured Query Language fundamentals.",
              required_level: 4
            }
          ],
          resolve_library_id: lib.id
        )

      {:ok, _} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "SQL",
          category: "Tech",
          cluster: "Data",
          description: "Structured Query Language fundamentals.",
          proficiency_levels: [
            %{"level" => 1, "level_name" => "Novice", "level_description" => "Basics"},
            %{"level" => 3, "level_name" => "Intermediate", "level_description" => "Joins"},
            %{"level" => 5, "level_name" => "Expert", "level_description" => "Optimization"}
          ]
        })

      cloned = RhoFrameworks.Roles.clone_skills_for_library(org_id, [rp.id])

      assert [row] = cloned
      assert row.skill_name == "SQL"
      assert row.skill_description == "Structured Query Language fundamentals."
      assert row.category == "Tech"
      assert row.cluster == "Data"
      assert is_list(row.proficiency_levels)
      assert length(row.proficiency_levels) == 3

      expert = Enum.find(row.proficiency_levels, &(&1.level == 5))
      assert expert.level_name == "Expert"
      assert expert.level_description == "Optimization"
    end

    test "deduplicates skills shared across roles (first occurrence wins)", %{
      org_id: org_id,
      lib: lib
    } do
      RhoFrameworks.Library.upsert_skill(lib.id, %{
        name: "SQL",
        category: "Tech",
        proficiency_levels: [%{"level" => 3, "level_name" => "Mid"}]
      })

      {:ok, %{role_profile: rp1}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "SRE"},
          [%{category: "Tech", skill_name: "SQL", required_level: 3}],
          resolve_library_id: lib.id
        )

      {:ok, %{role_profile: rp2}} =
        RhoFrameworks.Roles.save_role_profile(
          org_id,
          %{name: "DevOps"},
          [%{category: "Tech", skill_name: "SQL", required_level: 5}],
          resolve_library_id: lib.id
        )

      cloned = RhoFrameworks.Roles.clone_skills_for_library(org_id, [rp1.id, rp2.id])

      assert [row] = cloned
      assert row.skill_name == "SQL"
      assert length(row.proficiency_levels) == 1
    end
  end

  describe "identity-by-id (ESCO duplicate-name resilience)" do
    # Two skills sharing a `name` but with distinct ids — mirrors ESCO's
    # ~200 skills that share a preferredLabel. Identity-by-name would
    # silently collapse them; identity-by-id keeps them distinct.
    setup %{org_id: org_id, lib: lib} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      skill_a =
        Repo.insert!(%Skill{
          name: "Project Management",
          slug: "project-management-aaa111",
          category: "Tech",
          cluster: "PM",
          library_id: lib.id,
          status: "published",
          inserted_at: now,
          updated_at: now
        })

      skill_b =
        Repo.insert!(%Skill{
          name: "Project Management",
          slug: "project-management-bbb222",
          category: "Tech",
          cluster: "PM",
          library_id: lib.id,
          status: "published",
          inserted_at: now,
          updated_at: now
        })

      role_a =
        Repo.insert!(%RhoFrameworks.Frameworks.RoleProfile{
          name: "Role A",
          organization_id: org_id,
          inserted_at: now,
          updated_at: now
        })

      role_b =
        Repo.insert!(%RhoFrameworks.Frameworks.RoleProfile{
          name: "Role B",
          organization_id: org_id,
          inserted_at: now,
          updated_at: now
        })

      Repo.insert!(%RhoFrameworks.Frameworks.RoleSkill{
        role_profile_id: role_a.id,
        skill_id: skill_a.id,
        min_expected_level: 3,
        required: true,
        inserted_at: now,
        updated_at: now
      })

      Repo.insert!(%RhoFrameworks.Frameworks.RoleSkill{
        role_profile_id: role_b.id,
        skill_id: skill_b.id,
        min_expected_level: 3,
        required: true,
        inserted_at: now,
        updated_at: now
      })

      %{skill_a: skill_a, skill_b: skill_b, role_a: role_a, role_b: role_b}
    end

    test "compare_role_profiles/2 does not silently merge same-name skills",
         %{org_id: org_id} do
      result = RhoFrameworks.Roles.compare_role_profiles(org_id, ["Role A", "Role B"])

      # Different skill ids → no shared skills, both roles claim "Project
      # Management" as unique. (With identity-by-name this would have been
      # shared_count: 1 and unique_per_role each empty.)
      assert result.shared_count == 0
      assert result.shared_skills == []
      assert result.unique_per_role["Role A"] == ["Project Management"]
      assert result.unique_per_role["Role B"] == ["Project Management"]
      assert result.total_unique_skills == 2
    end

    test "org_view/1 does not silently merge same-name skills", %{org_id: org_id} do
      view = RhoFrameworks.Roles.org_view(org_id)

      assert view.role_count == 2
      assert view.shared_count == 0
      assert view.total_unique_skills == 2
      assert view.unique_per_role["Role A"] == ["Project Management"]
      assert view.unique_per_role["Role B"] == ["Project Management"]
    end

    test "clone_role_skills/2 returns one row per distinct skill id, not per name",
         %{org_id: org_id, role_a: role_a, role_b: role_b} do
      cloned = RhoFrameworks.Roles.clone_role_skills(org_id, [role_a.id, role_b.id])

      # Two distinct ids → two rows (despite identical names). Identity-by-name
      # would have collapsed to a single merged row.
      assert match?([_, _], cloned)
      assert Enum.all?(cloned, &(&1.skill_name == "Project Management"))
    end

    test "clone_skills_for_library/2 returns one row per distinct skill id",
         %{org_id: org_id, role_a: role_a, role_b: role_b} do
      cloned = RhoFrameworks.Roles.clone_skills_for_library(org_id, [role_a.id, role_b.id])

      assert match?([_, _], cloned)
      assert Enum.all?(cloned, &(&1.skill_name == "Project Management"))
    end
  end

  describe "public role visibility" do
    test "clone_role_skills/2 includes skills from public roles owned by another org",
         %{org_id: caller_org_id, lib: lib} do
      other_org_id = Ecto.UUID.generate()

      Repo.insert!(%RhoFrameworks.Accounts.Organization{
        id: other_org_id,
        name: "Other Org",
        slug: "other-org-#{System.unique_integer([:positive])}"
      })

      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          other_org_id,
          %{name: "Public Role", visibility: "public"},
          [%{category: "Tech", skill_name: "Kubernetes", required_level: 3}],
          resolve_library_id: lib.id
        )

      # Caller is a different org; the role lives in `other_org_id`.
      cloned = RhoFrameworks.Roles.clone_role_skills(caller_org_id, [rp.id])

      assert match?([_], cloned)
      assert hd(cloned).skill_name == "Kubernetes"
    end

    test "clone_skills_for_library/2 includes skills from public roles owned by another org",
         %{org_id: caller_org_id, lib: lib} do
      other_org_id = Ecto.UUID.generate()

      Repo.insert!(%RhoFrameworks.Accounts.Organization{
        id: other_org_id,
        name: "Other Org 2",
        slug: "other-org-#{System.unique_integer([:positive])}"
      })

      {:ok, %{role_profile: rp}} =
        RhoFrameworks.Roles.save_role_profile(
          other_org_id,
          %{name: "Public Role 2", visibility: "public"},
          [%{category: "Tech", skill_name: "Terraform", required_level: 3}],
          resolve_library_id: lib.id
        )

      cloned = RhoFrameworks.Roles.clone_skills_for_library(caller_org_id, [rp.id])

      assert match?([_], cloned)
      assert hd(cloned).skill_name == "Terraform"
    end
  end

  describe "find_similar_roles/3" do
    @query "find an analyst"

    setup %{org_id: org_id} do
      FakeEmbeddings.reset()

      # Shared SQL.Sandbox holds one transaction for the whole test run, so
      # public/embedded role profiles from prior tests in this describe
      # leak in via the `visibility == "public"` clause and tie at
      # distance 0 with our `rp_a`. Wipe them before seeding.
      Repo.delete_all(
        from(rp in RoleProfile,
          where: rp.visibility == "public" or not is_nil(rp.embedding)
        )
      )

      # Pin the query → vec_a so the KNN orders against vec_a, vec_b, vec_c
      # in monotonically increasing cosine distance (0 / 1 / 2).
      :ok = FakeEmbeddings.put_vector(@query, vec_a())

      rp_a = insert_role(org_id, "Data Analyst", "Number cruncher.", embedding: vec_a())
      rp_b = insert_role(org_id, "Project Manager", "Schedules timelines.", embedding: vec_b())
      rp_c = insert_role(org_id, "HR Specialist", "People work.", embedding: vec_c())

      %{rp_a: rp_a, rp_b: rp_b, rp_c: rp_c}
    end

    test "returns roles in KNN order by cosine distance",
         %{org_id: org_id, rp_a: rp_a, rp_b: rp_b, rp_c: rp_c} do
      # Pass max_distance: 3.0 (above pgvector's max cosine distance of 2) so
      # the threshold gate doesn't filter the synthetic far-vectors used to
      # assert ordering.
      results = RhoFrameworks.Roles.find_similar_roles(org_id, @query, max_distance: 3.0)
      ids = Enum.map(results, & &1.id)

      # vec_a is identical to the query → distance 0 (closest).
      # vec_b is orthogonal → distance ~1.
      # vec_c is anti-parallel → distance ~2.
      assert hd(ids) == rp_a.id

      assert Enum.find_index(ids, &(&1 == rp_b.id)) <
               Enum.find_index(ids, &(&1 == rp_c.id))
    end

    test "drops results above :max_distance threshold",
         %{org_id: org_id, rp_a: rp_a} do
      # Default threshold (0.6) keeps vec_a (dist 0) and drops vec_b/vec_c
      # (dist 1 / 2). This is the "superman" guard — off-topic queries don't
      # surface nearest-anything.
      results = RhoFrameworks.Roles.find_similar_roles(org_id, @query)
      assert Enum.map(results, & &1.id) == [rp_a.id]
    end

    test "returns [] (no LIKE fallback) when all KNN results exceed threshold",
         %{org_id: org_id} do
      # Pin the query to a vector orthogonal to all three seeds (dim-2 unit
      # vector — seeds are along dim-0/1/-0). Distance to every seed is 1,
      # which exceeds the default threshold of 0.6. The embedded rows exist,
      # so the bootstrap LIKE fallback must NOT trigger — caller wants an
      # honest "no semantic match".
      far_vec = [0.0, 0.0, 1.0 | List.duplicate(0.0, 381)]
      :ok = FakeEmbeddings.put_vector("superman", far_vec)
      assert RhoFrameworks.Roles.find_similar_roles(org_id, "superman") == []
    end

    test "respects :limit option", %{org_id: org_id, rp_a: rp_a} do
      [only] = RhoFrameworks.Roles.find_similar_roles(org_id, @query, limit: 1)
      assert only.id == rp_a.id
    end

    test "falls back to LIKE when the query is empty (KNN unavailable)",
         %{org_id: org_id, rp_a: rp_a} do
      # Empty query short-circuits embedding; LIKE matches everything (`%%`).
      results = RhoFrameworks.Roles.find_similar_roles(org_id, "")
      ids = Enum.map(results, & &1.id) |> MapSet.new()
      assert rp_a.id in ids
    end

    test "falls back to LIKE when no rows have embeddings", %{org_id: org_id} do
      # Wipe embeddings so KNN returns no candidates; LIKE still finds the
      # role by name match.
      Repo.update_all(RoleProfile, set: [embedding: nil])

      [match] = RhoFrameworks.Roles.find_similar_roles(org_id, "Analyst")
      assert match.name == "Data Analyst"
    end

    test "ignores roles from other orgs that aren't public", %{org_id: org_id} do
      other_org = Ecto.UUID.generate()

      Repo.insert!(%RhoFrameworks.Accounts.Organization{
        id: other_org,
        name: "Other",
        slug: "other-#{System.unique_integer([:positive])}"
      })

      _foreign =
        insert_role(other_org, "Foreign Analyst", "Hidden.",
          embedding: vec_a(),
          visibility: "private"
        )

      results = RhoFrameworks.Roles.find_similar_roles(org_id, @query)
      assert Enum.all?(results, &(&1.name != "Foreign Analyst"))
    end

    test "includes public roles from other orgs", %{org_id: org_id} do
      other_org = Ecto.UUID.generate()

      Repo.insert!(%RhoFrameworks.Accounts.Organization{
        id: other_org,
        name: "Public Owner",
        slug: "pub-#{System.unique_integer([:positive])}"
      })

      pub =
        insert_role(other_org, "Public Analyst", "Shared.",
          embedding: vec_a(),
          visibility: "public"
        )

      ids =
        RhoFrameworks.Roles.find_similar_roles(org_id, @query)
        |> Enum.map(& &1.id)

      assert pub.id in ids
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  # Three orthogonal-ish 384-dim unit vectors. Cosine distance to vec_a:
  # vec_a = 0, vec_b ≈ 1 (orthogonal), vec_c ≈ 2 (antiparallel).
  defp vec_a, do: [1.0 | List.duplicate(0.0, 383)]
  defp vec_b, do: [0.0, 1.0 | List.duplicate(0.0, 382)]
  defp vec_c, do: [-1.0 | List.duplicate(0.0, 383)]

  defp insert_role(org_id, name, description, opts) do
    Repo.insert!(%RoleProfile{
      organization_id: org_id,
      name: name,
      description: description,
      visibility: Keyword.get(opts, :visibility, "private"),
      embedding: Keyword.get(opts, :embedding),
      headcount: 1
    })
  end
end
