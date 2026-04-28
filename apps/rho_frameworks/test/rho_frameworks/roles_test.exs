defmodule RhoFrameworks.RolesTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Frameworks.Skill

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
      assert length(skills) == 2
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
      assert length(skills) == 3
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

      assert length(loaded_rows) == 2

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
      assert length(skills) == 1
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

      assert length(cloned) == 3
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
end
