defmodule Rho.SkillStoreTest do
  # NOTE: async: false because ecto_sqlite3 does not support SQL.Sandbox
  # and tests share a single SQLite DB file
  use ExUnit.Case, async: false

  alias Rho.SkillStore

  setup do
    # Use on_exit to guarantee cleanup even if test crashes
    on_exit(fn ->
      Rho.SkillStore.Repo.delete_all(Rho.SkillStore.FrameworkRow)
      Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Framework)
      Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Company)
    end)

    # Also clean before to ensure fresh state
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.FrameworkRow)
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Framework)
    Rho.SkillStore.Repo.delete_all(Rho.SkillStore.Company)
    :ok
  end

  # Helper to build a complete row fixture
  defp full_row(overrides \\ %{}) do
    Map.merge(
      %{
        role: "",
        category: "Technical",
        cluster: "Programming",
        skill_name: "Test Skill",
        skill_description: "A test skill",
        level: 1,
        level_name: "Novice",
        level_description: "Basic level",
        skill_code: ""
      },
      overrides
    )
  end

  describe "ensure_company/1" do
    test "creates a new company" do
      assert {:ok, company} = SkillStore.ensure_company("test_co")
      assert company.id == "test_co"
    end

    test "is idempotent — second call does not crash" do
      assert {:ok, first} = SkillStore.ensure_company("test_co")
      assert first.id == "test_co"
      assert {:ok, _} = SkillStore.ensure_company("test_co")
    end
  end

  describe "save_framework/1 + get_framework_rows/1" do
    test "creates new framework with rows" do
      SkillStore.ensure_company("test_co")

      {:ok, framework} =
        SkillStore.save_framework(%{
          name: "Test Framework",
          type: "company",
          company_id: "test_co",
          source: "test",
          rows: [
            full_row(%{
              role: "Data Analyst",
              skill_name: "Python",
              level: 1,
              level_name: "Novice",
              level_description: "Basic scripts"
            }),
            full_row(%{
              role: "Data Analyst",
              skill_name: "Python",
              level: 2,
              level_name: "Developing",
              level_description: "Builds pipelines"
            })
          ]
        })

      assert framework.id != nil
      assert framework.row_count == 2
      assert framework.skill_count == 1

      rows = SkillStore.get_framework_rows(framework.id)
      assert length(rows) == 2
      assert hd(rows).skill_name == "Python"
      assert hd(rows).role == "Data Analyst"
    end

    test "updates existing framework (replaces rows and name)" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "V1",
          type: "company",
          company_id: "test_co",
          rows: [full_row(%{skill_name: "SQL", role: "DA"})]
        })

      {:ok, fw2} =
        SkillStore.save_framework(%{
          id: fw.id,
          name: "V2",
          type: "company",
          company_id: "test_co",
          rows: [
            full_row(%{skill_name: "Python", role: "DE"}),
            full_row(%{skill_name: "SQL", role: "DE"})
          ]
        })

      assert fw2.id == fw.id
      assert fw2.name == "V2"
      rows = SkillStore.get_framework_rows(fw.id)
      assert length(rows) == 2
    end

    test "get_framework_rows returns empty list for nonexistent id" do
      assert SkillStore.get_framework_rows(999_999) == []
    end
  end

  describe "list_frameworks_for/3" do
    setup do
      SkillStore.ensure_company("co_a")
      SkillStore.ensure_company("co_b")

      SkillStore.save_framework(%{
        name: "AICB",
        type: "industry",
        company_id: nil,
        rows: [full_row(%{skill_name: "Risk Mgmt"})]
      })

      SkillStore.save_framework(%{
        name: "Co A Framework",
        type: "company",
        company_id: "co_a",
        rows: [full_row(%{skill_name: "Python", role: "DA"})]
      })

      SkillStore.save_framework(%{
        name: "Co B Framework",
        type: "company",
        company_id: "co_b",
        rows: [full_row(%{skill_name: "SQL", role: "DE"})]
      })

      :ok
    end

    test "admin sees everything" do
      frameworks = SkillStore.list_frameworks_for(nil, true)
      names = Enum.map(frameworks, & &1.name) |> Enum.sort()
      assert names == ["AICB", "Co A Framework", "Co B Framework"]
    end

    test "company user sees industry + own company only" do
      frameworks = SkillStore.list_frameworks_for("co_a", false)
      names = Enum.map(frameworks, & &1.name)
      assert "AICB" in names
      assert "Co A Framework" in names
      refute "Co B Framework" in names
    end

    test "non-admin with nil company sees only industry" do
      frameworks = SkillStore.list_frameworks_for(nil, false)
      names = Enum.map(frameworks, & &1.name)
      assert names == ["AICB"]
    end

    test "type filter works" do
      frameworks = SkillStore.list_frameworks_for("co_a", false, "industry")
      assert length(frameworks) == 1
      assert hd(frameworks).name == "AICB"
    end

    test "includes roles in response" do
      frameworks = SkillStore.list_frameworks_for("co_a", false, "company")
      co_a = Enum.find(frameworks, &(&1.name == "Co A Framework"))
      assert co_a != nil
      assert "DA" in co_a.roles
    end
  end

  describe "get_framework_role_directory/1" do
    test "returns distinct roles with skill counts and top skills" do
      SkillStore.ensure_company("co_a")

      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "Industry FW",
          type: "industry",
          company_id: nil,
          rows: [
            full_row(%{
              role: "Risk Analyst",
              category: "Core",
              skill_name: "Risk Assessment",
              level: 1
            }),
            full_row(%{
              role: "Risk Analyst",
              category: "Core",
              skill_name: "Risk Assessment",
              level: 2
            }),
            full_row(%{
              role: "Risk Analyst",
              category: "Core",
              skill_name: "Credit Analysis",
              level: 1
            }),
            full_row(%{
              role: "Risk Analyst",
              category: "Technical",
              skill_name: "Basel Compliance",
              level: 1
            }),
            full_row(%{
              role: "Compliance Officer",
              category: "Core",
              skill_name: "AML",
              level: 1
            }),
            full_row(%{
              role: "Compliance Officer",
              category: "Core",
              skill_name: "Policy Review",
              level: 1
            }),
            full_row(%{role: "", skill_name: "Communication", level: 1})
          ]
        })

      directory = SkillStore.get_framework_role_directory(fw.id)

      roles = Enum.map(directory, & &1.role)
      refute "" in roles

      ra = Enum.find(directory, &(&1.role == "Risk Analyst"))
      assert ra.skill_count == 3
      assert length(ra.top_skills) == 3
      assert "Risk Assessment" in ra.top_skills
      assert "Credit Analysis" in ra.top_skills
      assert "Basel Compliance" in ra.top_skills

      co = Enum.find(directory, &(&1.role == "Compliance Officer"))
      assert co.skill_count == 2
    end

    test "returns empty list for framework with no roles" do
      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "No Roles FW",
          type: "industry",
          company_id: nil,
          rows: [full_row(%{role: "", skill_name: "Communication", level: 1})]
        })

      assert SkillStore.get_framework_role_directory(fw.id) == []
    end

    test "caps top_skills at 5" do
      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "Big Role FW",
          type: "industry",
          company_id: nil,
          rows:
            for name <- ~w(A B C D E F G) do
              full_row(%{role: "Analyst", category: "Core", skill_name: name, level: 1})
            end
        })

      [entry] = SkillStore.get_framework_role_directory(fw.id)
      assert entry.skill_count == 7
      assert length(entry.top_skills) == 5
    end
  end

  describe "get_framework_rows_for_roles/2" do
    test "returns only rows matching the given roles" do
      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "Multi Role FW",
          type: "industry",
          company_id: nil,
          rows: [
            full_row(%{role: "Risk Analyst", skill_name: "Risk Assessment", level: 1}),
            full_row(%{role: "Risk Analyst", skill_name: "Risk Assessment", level: 2}),
            full_row(%{role: "Compliance Officer", skill_name: "AML", level: 1}),
            full_row(%{role: "Trader", skill_name: "Execution", level: 1}),
            full_row(%{role: "", skill_name: "Communication", level: 1})
          ]
        })

      rows =
        SkillStore.get_framework_rows_for_roles(fw.id, ["Risk Analyst", "Compliance Officer"])

      assert length(rows) == 3

      roles = Enum.map(rows, & &1.role) |> Enum.uniq() |> Enum.sort()
      assert roles == ["Compliance Officer", "Risk Analyst"]
    end

    test "returns empty list when no roles match" do
      {:ok, fw} =
        SkillStore.save_framework(%{
          name: "FW",
          type: "industry",
          company_id: nil,
          rows: [full_row(%{role: "Trader", skill_name: "Execution", level: 1})]
        })

      assert SkillStore.get_framework_rows_for_roles(fw.id, ["Risk Analyst"]) == []
    end
  end

  describe "save_role_framework/1" do
    test "creates first version with is_default=true" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "spreadsheet_editor",
          rows: [
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 1}),
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 2})
          ]
        })

      assert fw.role_name == "Data Scientist"
      assert fw.year == 2026
      assert fw.version == 1
      assert fw.is_default == true
      assert fw.name == "data_scientist_2026_v1"
      assert fw.row_count == 2
      assert fw.skill_count == 1
    end

    test "creates second version as draft (is_default=false)" do
      SkillStore.ensure_company("test_co")

      {:ok, _v1} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, v2} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})]
        })

      assert v2.version == 2
      assert v2.is_default == false
      assert v2.name == "data_scientist_2026_v2"
    end

    test "update mode overwrites existing rows" do
      SkillStore.ensure_company("test_co")

      {:ok, v1} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, updated} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :update,
          existing_id: v1.id,
          source: "test",
          rows: [
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 1}),
            full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})
          ]
        })

      assert updated.id == v1.id
      rows = SkillStore.get_framework_rows(v1.id)
      assert length(rows) == 2
    end

    test "normalizes role_name to title case" do
      SkillStore.ensure_company("test_co")

      {:ok, fw} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "data scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "data scientist", skill_name: "Python", level: 1})]
        })

      assert fw.role_name == "Data Scientist"
    end
  end

  describe "get_company_roles_summary/1" do
    test "returns roles grouped with default and version history" do
      SkillStore.ensure_company("test_co")

      {:ok, _} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2025,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, _} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [
            full_row(%{role: "Data Scientist", skill_name: "Python", level: 1}),
            full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})
          ]
        })

      {:ok, _} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Risk Analyst",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Risk Analyst", skill_name: "Risk Mgmt", level: 1})]
        })

      summary = SkillStore.get_company_roles_summary("test_co")
      assert length(summary) == 2

      ds = Enum.find(summary, &(&1.role_name == "Data Scientist"))
      assert ds.default.year == 2025
      assert ds.default.version == 1
      assert length(ds.versions) == 2

      ra = Enum.find(summary, &(&1.role_name == "Risk Analyst"))
      assert ra.default.year == 2026
      assert ra.default.version == 1
    end
  end

  describe "set_default_version/1" do
    test "flips is_default in transaction" do
      SkillStore.ensure_company("test_co")

      {:ok, v1} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2025,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "Python", level: 1})]
        })

      {:ok, v2} =
        SkillStore.save_role_framework(%{
          company_id: "test_co",
          role_name: "Data Scientist",
          year: 2026,
          action: :create,
          source: "test",
          rows: [full_row(%{role: "Data Scientist", skill_name: "SQL", level: 1})]
        })

      assert v1.is_default == true
      assert v2.is_default == false

      {:ok, _} = SkillStore.set_default_version(v2.id)

      v1_reloaded = SkillStore.get_framework(v1.id)
      v2_reloaded = SkillStore.get_framework(v2.id)
      assert v1_reloaded.is_default == false
      assert v2_reloaded.is_default == true
    end
  end
end
